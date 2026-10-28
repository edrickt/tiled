import AppKit
import ApplicationServices
import CoreGraphics

/// The private window-server Space table. These symbols live in
/// SkyLight/CoreGraphics on every macOS that has Mission Control; they
/// are resolved with `dlsym` so a future OS that drops them degrades to
/// per-display tiling instead of failing to launch.
private typealias CGSDefaultConnectionFn = @convention(c) () -> Int32
private typealias CGSCopyManagedDisplaySpacesFn =
    @convention(c) (Int32) -> Unmanaged<CFArray>?

private enum CGS {
    static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        ?? dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)

    static let defaultConnection: CGSDefaultConnectionFn? = symbol(
        "_CGSDefaultConnection", as: CGSDefaultConnectionFn.self)
    static let copyManagedDisplaySpaces: CGSCopyManagedDisplaySpacesFn? = symbol(
        "CGSCopyManagedDisplaySpaces", as: CGSCopyManagedDisplaySpacesFn.self)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}

/// Opaque handle to an AX observer. Production wraps `AXObserver`; a fake
/// can stand in for it, so the suite pins observer reuse and registration
/// without creating a real observer.
protocol AXObserverHandle: AnyObject {}

/// The AXObserver boundary: create the per-pid observer, register the
/// per-window notifications, attach and detach its run-loop source, and
/// deliver notifications. Injecting it keeps the adapter constructible
/// and testable without a live Accessibility grant.
protocol AXObserverDriver: AnyObject {
    /// Creates the observer for `pid`. `onNotification` receives the
    /// notification name and the AXUIElement token (its CFHash) so
    /// a fake can deliver one; the live AXObserver callback carries no
    /// user data, so the production driver routes through the one active
    /// gateway instead.
    func createObserver(
        pid: pid_t, onNotification: @escaping (String, UInt) -> Void
    ) -> (status: AXError, observer: AXObserverHandle?)
    /// Adds one notification for one AXUIElement. `element` is nil for
    /// a scripted test window, which a fake ignores; production refuses.
    func addNotification(
        _ notification: String, to observer: AXObserverHandle,
        element: AXUIElement?) -> AXError
    func addRunLoopSource(_ observer: AXObserverHandle)
    func removeRunLoopSource(_ observer: AXObserverHandle)
}

/// Production AXObserver adapter. Its handles are `AXObserver`s; a
/// foreign handle belongs to a test fake and is left alone.
final class LiveAXObserverDriver: AXObserverDriver {
    private final class LiveObserver: AXObserverHandle {
        let observer: AXObserver

        init(_ observer: AXObserver) {
            self.observer = observer
        }
    }

    func createObserver(
        pid: pid_t, onNotification: @escaping (String, UInt) -> Void
    ) -> (status: AXError, observer: AXObserverHandle?) {
        // The closure is for fakes: AXObserverCreate's C callback has no
        // user data, so the live path routes through the one active
        // gateway, exactly as the adapter always has.
        _ = onNotification
        var created: AXObserver?
        let result = AXObserverCreate(pid, Self.callback, &created)
        guard result == .success, let created else { return (result, nil) }
        return (.success, LiveObserver(created))
    }

    func addNotification(
        _ notification: String, to observer: AXObserverHandle,
        element: AXUIElement?
    ) -> AXError {
        guard let observer = observer as? LiveObserver, let element else {
            return .invalidUIElement
        }
        return AXObserverAddNotification(
            observer.observer, element, notification as CFString, nil)
    }

    func addRunLoopSource(_ observer: AXObserverHandle) {
        guard let observer = observer as? LiveObserver else { return }
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer.observer),
            CFRunLoopMode.commonModes)
    }

    func removeRunLoopSource(_ observer: AXObserverHandle) {
        guard let observer = observer as? LiveObserver else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer.observer),
            CFRunLoopMode.commonModes)
    }

    private static let callback: AXObserverCallback = {
        _, element, notification, _ in
        LiveWindowGateway.active?.handleAXNotification(
            notification: notification as String,
            token: UInt(CFHash(element)))
    }
}

/// The AX frame calls for one registered window, in AppKit global
/// coordinates. Production wraps `AXUIElement`; a fake scripts position,
/// size, and refusal answers, so the adapter's write pair, retry, and
/// partial-write rollback are testable without a live app.
protocol WindowFrames: AnyObject {
    /// The window's frame, or nil when the app will not answer.
    func frame() -> CGRect?
    /// The window's top-left corner in AppKit global coordinates (y
    /// grows up): the counterpart of AX's top-left position attribute,
    /// and the point the partial-write rollback restores. Nil when it
    /// cannot be read.
    func topLeft() -> CGPoint?
    /// Moves the window's top-left corner; the AX result. The size is
    /// unchanged.
    func setTopLeft(_ topLeft: CGPoint) -> AXError
    /// Resizes; the AX result. AX anchors a resize at the window's
    /// top-left, so the size write never moves that corner.
    func setSize(_ size: CGSize) -> AXError
}

/// The production window frames: AX position/size reads and writes with
/// the AppKit y-flip. No screen means no coordinate space, so every
/// method refuses rather than guessing, exactly as the old write path did.
final class AXWindowFrames: WindowFrames {
    private let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
    }

    func frame() -> CGRect? {
        LiveWindowGateway.frame(of: element)
    }

    func topLeft() -> CGPoint? {
        guard
            let primaryTop = NSScreen.screens.first?.frame.maxY,
            let axOrigin = LiveWindowGateway.readPoint(
                element, kAXPositionAttribute)
        else { return nil }
        return CGPoint(x: axOrigin.x, y: primaryTop - axOrigin.y)
    }

    func setTopLeft(_ topLeft: CGPoint) -> AXError {
        guard
            let primaryTop = NSScreen.screens.first?.frame.maxY,
            let value = LiveWindowGateway.pointValue(
                CGPoint(x: topLeft.x, y: primaryTop - topLeft.y))
        else { return .failure }
        return AXUIElementSetAttributeValue(
            element, kAXPositionAttribute as CFString, value)
    }

    func setSize(_ size: CGSize) -> AXError {
        guard
            NSScreen.screens.first != nil,
            let value = LiveWindowGateway.sizeValue(size)
        else { return .failure }
        return AXUIElementSetAttributeValue(
            element, kAXSizeAttribute as CFString, value)
    }
}

/// The production `WindowGateway`: macOS Accessibility plus the private
/// window-server Space table, behind the seam.
///
/// Owns every framework detail the controller must never see: AX element
/// identity, AppKit/AX coordinate conversion, AXObserver registration
/// with its refcon plumbing, app activation, and the display-to-Space
/// lookup that makes each Mission Control Space an independent canvas.
/// Issues one stable `WindowHandle` per live window so the controller
/// keys records on handles, never on `AXUIElement`s.
final class LiveWindowGateway: WindowGateway {
    /// The single live instance (AXObserver callbacks carry no user data).
    static weak var active: LiveWindowGateway?

    /// Per-message timeout (seconds) applied to every element we touch.
    /// The AX default is ~6s per call, and a beachballing app would block
    /// the hotkey path that long on every read or write; a drag-resize loop
    /// makes several. One second bounds the worst case while leaving
    /// healthy-but-busy apps room to answer; a write that times out is
    /// retryable anyway, so an over-tight bound costs a retry, not the
    /// placement.
    private static let messagingTimeout: Float = 1.0

    private var nextHandleID = 1
    /// One handle's registration. One value per handle makes a
    /// registration all-or-nothing: a test window's missing AX element is
    /// an explicit nil field, not a half-registered set of maps, and
    /// `release` is one removal.
    struct WindowBinding {
        /// The live element; nil for a scripted test window.
        var element: AXUIElement? = nil
        let pid: pid_t
        /// The frame calls: production resolves the live element, a test
        /// window carries scripted answers.
        var frames: WindowFrames
        /// The AXUIElement token (production: its CFHash; a test window
        /// carries its own).
        var token: UInt
        /// The observation key registered per observed handle, so `release`
        /// can forget exactly that key while the pid's shared observer and
        /// its other windows stay. Nil until `observe`.
        var observedKey: UInt? = nil
        /// Change handler per observed handle.
        var changeHandler: (() -> Void)? = nil
        /// Destruction handler per observed handle: the OS reported the
        /// element destroyed, which is categorically different from a
        /// move or resize, so the controller never reads a frame for it.
        var destructionHandler: (() -> Void)? = nil
        /// Last successfully-read frame per handle: the geometry a death
        /// confirmation matches against, refreshed by every frame read and
        /// by a successful liveness probe.
        var lastFrame: CGRect? = nil
    }

    /// The one registration per live handle.
    private var bindings: [WindowHandle: WindowBinding] = [:]
    /// Observation token -> handle: the notification router's index,
    /// derived from each binding's `observedKey` and updated with it.
    private var tokenIndex: [UInt: WindowHandle] = [:]
    /// Last focused-window resolution, memoized for one refresh pass:
    /// a single menu build asks three times (has-focused, the expanded
    /// slot, the icon's canvas), and every answer is a system-wide AX
    /// element plus attribute reads. The focus observer and `release`
    /// clear it; the lifetime only bounds a pass that races a notification.
    private var focusMemo = FocusMemo()
    /// Test seam: replaces the system-wide focus read so the memo's
    /// lifetime and release invalidation run without an Accessibility
    /// grant. Production leaves it nil.
    private var testFocusedWindow: (() -> WindowHandle?)?
    /// Observer per pid; registrations outlive untiled records and can
    /// never be unregistered, so they are created once and shared.
    private var observers: [pid_t: AXObserverHandle] = [:]
    /// The AXObserver calls behind registration and teardown. Injected so
    /// the adapter can be constructed and exercised without a real
    /// observer or an Accessibility grant.
    private let observerDriver: AXObserverDriver
    /// Retry backoff for the AX write pair. Injected so tests exercise a
    /// transient failure through the adapter without waiting.
    private let writeRetrySleep: (TimeInterval) -> Void
    /// Which elements have change notifications registered, and which
    /// processes already own a shared observer (CFHash keyed; dedupe, since
    /// re-tiling must not double-register). The adapter performs the AX
    /// calls; this decides what a registration request needs.
    private var registry = ObservationRegistry()
    /// Focus observer for the frontmost application: its key-window
    /// changes move which display's layout the status icon depicts.
    /// Separate from the per-window resize observers so an app with no
    /// managed windows still reports focus moves.
    private var focusObserver: AXObserver?
    private var focusObserverPID: pid_t?
    private var focusObserverElement: AXUIElement?
    private var focusChangeHandler: (() -> Void)?
    /// Re-targets `focusObserver` when a different app becomes frontmost.
    private var activeAppObserver: NSObjectProtocol?
    /// Drops a quit app's shared observer. Window death alone cannot
    /// catch this: an app that quits with every window untiled leaves no
    /// handle to probe, and its observer and runloop source would
    /// otherwise outlive it for the life of the session.
    private var appTerminationObserver: NSObjectProtocol?
    /// Space-change observer: swiping to another Space must rebuild the
    /// menu and, when the focused display changed canvas, the glyph.
    private var spaceChangeHandler: (() -> Void)?
    private var spaceChangeObserver: NSObjectProtocol?
    /// Display-to-Space cache, refreshed on a short interval and
    /// invalidated by the workspace notification, so one menu build
    /// never walks the window-server Space table once per row.
    private var spaceCache: [CGDirectDisplayID: SpaceID] = [:]
    private var spaceCacheStamp: Date?
    /// The window-server Space table, injected so the cache policy is
    /// testable without the private SkyLight symbols.
    private let spaceTable: () -> [CGDirectDisplayID: SpaceID]
    /// The clock behind the cache lifetime. Injected so a test can age
    /// the cache without sleeping.
    private let now: () -> Date
    /// The workspace notification centre. The production default is
    /// NSWorkspace's; tests pass a private centre so constructing the
    /// adapter never subscribes to the running session.
    private let workspaceNotifications: NotificationCenter

    init(
        observerDriver: AXObserverDriver = LiveAXObserverDriver(),
        spaceTable: @escaping () -> [CGDirectDisplayID: SpaceID] =
            LiveWindowGateway.currentSpaces,
        now: @escaping () -> Date = Date.init,
        workspaceNotifications: NotificationCenter =
            NSWorkspace.shared.notificationCenter,
        writeRetrySleep: @escaping (TimeInterval) -> Void = {
            Thread.sleep(forTimeInterval: $0)
        }
    ) {
        self.observerDriver = observerDriver
        self.spaceTable = spaceTable
        self.now = now
        self.workspaceNotifications = workspaceNotifications
        self.writeRetrySleep = writeRetrySleep
        LiveWindowGateway.active = self
        activeAppObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            let activated = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication
            self?.retargetFocusObserver(to: activated)
        }
        appTerminationObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            let terminated = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication
            guard let pid = terminated?.processIdentifier else { return }
            self?.appTerminated(pid: pid)
        }
        spaceChangeObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // One main-queue hop: the notification can arrive while the
            // window server is still committing the switch, and the
            // Space table must answer with the newly visible Space.
            DispatchQueue.main.async {
                self?.spaceDidChange()
            }
        }
    }

    deinit {
        if let activeAppObserver {
            workspaceNotifications.removeObserver(activeAppObserver)
        }
        if let appTerminationObserver {
            workspaceNotifications.removeObserver(appTerminationObserver)
        }
        if let spaceChangeObserver {
            workspaceNotifications.removeObserver(spaceChangeObserver)
        }
        releaseFocusObserver()
    }

    // MARK: WindowGateway

    func focusedWindow() -> WindowHandle? {
        focusMemo.resolve(now: now()) {
            if let testFocusedWindow {
                return testFocusedWindow()
            }
            guard let (element, pid) = Self.focusedAXWindow() else {
                return nil
            }
            return handle(for: element, pid: pid)
        }
    }

    /// Test seam: supplies the focus answer in place of the system-wide
    /// read. Production never calls this.
    func setTestFocusedWindow(_ read: (() -> WindowHandle?)?) {
        testFocusedWindow = read
    }

    func frame(of handle: WindowHandle) -> CGRect? {
        guard let frames = bindings[handle]?.frames else { return nil }
        guard let frame = frames.frame() else { return nil }
        bindings[handle]?.lastFrame = frame
        return frame
    }

    /// Writes the position and size as one retrying pair, then restores
    /// the origin if the position landed and the size did not. The calls
    /// live behind `WindowFrames`, so a fake can model position-landed /
    /// size-refused and silent-ignore without a live app.
    ///
    /// Position is written BEFORE size: AX size-sets anchor the window's
    /// top-left at its *current* position, so sizing first can push a bottom
    /// window past the screen bottom, where AppKit silently clamps the height
    /// and the later position write can't undo it. Anchoring at the target
    /// top-left (always inside the visible frame) never clamps.
    @discardableResult
    func setFrame(_ handle: WindowHandle, to frame: CGRect) -> Bool {
        guard let frames = bindings[handle]?.frames else { return false }
        // The pair can part-apply: a position write that lands followed by
        // a permanently refused size leaves the window moved at its old
        // size. Remember the top-left before writing, so the failure path
        // can put the window back; the README promises a refusing app's
        // window is left alone, not half-moved with state believing
        // nothing happened.
        let previousTopLeft = frames.topLeft()
        var positionLanded = false

        // The write pair retries as a unit: position writes are idempotent,
        // so a retry after a partial application (position landed, size hit
        // a busy app) just rewrites both, never a half-moved window. A
        // refused position stops before the size: sizing at the old origin
        // would half-apply the write in the other direction.
        var lastError: AXError = .success
        let error = AXWrite.retrying(
            operation: {
                // AX's position attribute is the top-left corner, so hand
                // it frame.maxY: passing the AppKit frame's bottom-left
                // origin (frame.origin) lands every window a full height
                // too low, pushing bottom-row tiles off the screen.
                let positionResult = frames.setTopLeft(
                    CGPoint(x: frame.minX, y: frame.maxY))
                guard positionResult == .success else {
                    lastError = positionResult
                    return lastError
                }
                positionLanded = true
                let sizeResult = frames.setSize(frame.size)
                guard sizeResult == .success else {
                    lastError = sizeResult
                    return lastError
                }
                return .success
            },
            sleep: writeRetrySleep)
        if AXWrite.needsPositionRestore(
            positionLanded: positionLanded, failed: error != nil),
            let previousTopLeft
        {
            // Best effort: if even the position write is refused, the
            // window is where the app left it and the refusal is still
            // reported, so screen and state agree on the outcome.
            _ = frames.setTopLeft(previousTopLeft)
        }
        if let error, ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1" {
            NSLog("Tiled: setFrame failed after retries (error %d)", error.rawValue)
        }
        return error == nil
    }

    /// Drops a confirmed-gone handle: its whole binding and its
    /// observation-token entry. The shared observer outlives any one
    /// window and only goes when the pid's last handle does.
    func release(_ handle: WindowHandle) {
        guard let binding = bindings.removeValue(forKey: handle) else { return }
        focusMemo.invalidate(handle)
        if let key = binding.observedKey {
            registry.forget(key: key)
            if tokenIndex[key] == handle { tokenIndex[key] = nil }
        }
        if !bindings.values.contains(where: { $0.pid == binding.pid }) {
            pruneObserver(for: binding.pid)
        }
    }

    /// Test seam: registers a handle with a scripted AXUIElement token and
    /// frame source, so the observation and frame wiring run without a
    /// live `AXUIElement` or an Accessibility grant. Production never
    /// calls this; a test window has no AX element, so liveness, focus,
    /// and raise are outside this seam.
    @discardableResult
    func registerTestWindow(
        pid: pid_t, token: UInt, frames: WindowFrames
    ) -> WindowHandle {
        let handle = WindowHandle(id: nextHandleID)
        nextHandleID += 1
        bindings[handle] = WindowBinding(pid: pid, frames: frames, token: token)
        return handle
    }

    /// Test seam: apply the adoption update the live `handle(for:)` path
    /// performs, without a live AXUIElement.
    func adoptTestWindow(
        _ handle: WindowHandle, token: UInt, frames: WindowFrames
    ) {
        guard let pid = bindings[handle]?.pid else { return }
        adopt(handle, element: nil, token: token, frames: frames, pid: pid)
    }

    /// An app quit. Its windows are gone; drop the bindings opened only for
    /// focus reads (menu builds, the status glyph), which have no record
    /// for the controller's death pass to release. Observed bindings stay:
    /// the controller's prune owns their record, and the undo chapter skips
    /// a dead handle by itself.
    func appTerminated(pid: pid_t) {
        if pid == focusObserverPID { releaseFocusObserver() }
        pruneObserver(for: pid)
        let stale = bindings.filter { $0.value.pid == pid && $0.value.observedKey == nil }
        for handle in stale.keys {
            bindings[handle] = nil
            focusMemo.invalidate(handle)
        }
    }

    func liveness(of handle: WindowHandle) -> Liveness {
        guard let binding = bindings[handle], let element = binding.element else {
            return .dead
        }
        let pid = binding.pid
        var value: CFTypeRef?
        let probeError = AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &value)
        // The frame read alongside a successful probe is the death match's
        // one chance to catch up with a window nothing else re-reads (move
        // notifications can fail to register, and a user drag or a sleep
        // rescale then moves it): the baseline must not keep the frame the
        // window left behind.
        let probedFrame = probeError == .success ? Self.frame(of: element) : nil
        let processAlive = Self.processExists(pid)
        var appAnswer = Self.AppWindowAnswer(
            appWindowsError: .success, listedFrames: [], processAlive: processAlive,
            identityListed: false, identityFrame: nil)
        if probeError != .success {
            // The probe failed — but a failure can be a transient. Across a
            // lid close/open, window-level probes fail (.invalidUIElement on
            // held refs, .attributeUnsupported on fresh refs) for LIVE
            // windows; the app element keeps answering and still lists them.
            // Death is therefore confirmed against the app's own window
            // list, never from the window probe alone. Which is also why the
            // owning process gets a vote: a process that no longer exists
            // owns no live windows, and its AX answers (.cannotComplete) are
            // not a maybe.
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
            var listRef: CFTypeRef?
            let listError = AXUIElementCopyAttributeValue(
                app, kAXWindowsAttribute as CFString, &listRef)
            let list = listRef as? [AXUIElement] ?? []
            // The app's fresh list naming our own element is the primary
            // membership signal: a frame that moved or rescaled during
            // sleep is still the window the app lists, not absence.
            // Geometry stays the fallback, because after a display
            // teardown a held element stops comparing equal.
            let mine = list.first { CFEqual($0, element) }
            // Frames only matter where the failed handle has a baseline to
            // compare them against; the count of listed windows still
            // decides absence.
            let listedFrames: [CGRect?] =
                binding.lastFrame != nil ? list.map { Self.frame(of: $0) } : []
            appAnswer = Self.AppWindowAnswer(
                appWindowsError: listError, listedFrames: listedFrames,
                processAlive: processAlive, identityListed: mine != nil,
                identityFrame: mine.flatMap { Self.frame(of: $0) })
        }
        let pass = Self.livenessPass(
            probe: Self.LivenessProbe(error: probeError, frame: probedFrame),
            baseline: binding.lastFrame, appAnswer: appAnswer)
        if let refreshed = pass.baseline {
            bindings[handle]?.lastFrame = refreshed
        }
        if ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1" {
            NSLog(
                "Tiled: [DEBUG-lv] win handle %ld probe=%d appList err=%d count=%ld identity=%d processAlive=%d → %@",
                handle.id, probeError.rawValue, appAnswer.appWindowsError.rawValue,
                appAnswer.listedFrames.count, appAnswer.identityListed ? 1 : 0,
                processAlive ? 1 : 0,
                pass.verdict == .alive ? "alive" : pass.verdict == .dead ? "dead" : "unknown")
        }
        // A dead verdict is not a retirement. The controller confirms it
        // across `deathConfirmation`, precisely so a transient (a lid
        // close where window probes fail for live windows) can recover on
        // the next probe. Retiring the element here would make the next
        // call return `.dead` without probing and collapse the
        // confirmation window to a single tick. The element stays until
        // the controller confirms and forgets the window, which is when
        // `release` runs and the slot actually frees.
        return pass.verdict
    }

    /// Raw answers for one window's liveness observation, gathered by the
    /// adapter and judged purely by `livenessPass` so the death standard
    /// and the frame-baseline refresh are testable without AX.
    struct LivenessProbe {
        /// The per-window position-probe error.
        var error: AXError
        /// The frame read when the probe answered; nil when the probe
        /// failed or the frame would not read.
        var frame: CGRect?
    }

    /// What one owning app answered about its windows.
    struct AppWindowAnswer {
        /// The app element's window-list read.
        var appWindowsError: AXError
        /// One entry per listed window, in order: its frame, or nil when
        /// that frame would not read (membership stays undeterminable).
        var listedFrames: [CGRect?]
        /// Whether the owning process still exists.
        var processAlive: Bool
        /// Whether the app's fresh list contains the probed window's own
        /// element: the app still names this exact window, wherever its
        /// frame moved. Death confirmation is geometric, so this is an
        /// additional membership signal, never a replacement.
        var identityListed: Bool
        /// The probed window's frame as the app's list reports it, when
        /// the list contains it and its frame reads. Refreshes the
        /// baseline after a move.
        var identityFrame: CGRect?
    }

    /// One window's liveness pass assembled from its raw answers. A
    /// successful probe is alive and refreshes the frame baseline; a
    /// failed probe is judged against its app's answer. Returns the
    /// verdict and the baseline to cache. Pure, so the assembly and the
    /// baseline rules are testable without AX.
    static func livenessPass(
        probe: LivenessProbe, baseline: CGRect?, appAnswer: AppWindowAnswer
    ) -> (verdict: Liveness, baseline: CGRect?) {
        if probe.error == .success {
            // A successful probe refreshes the baseline: it is the only
            // chance to track a window nothing reads, and a frame that
            // will not read keeps the old baseline — a maybe, never a
            // reset to nothing.
            return (.alive, probe.frame ?? baseline)
        }
        let match = appWindowMatch(
            baseline: baseline, listedFrames: appAnswer.listedFrames,
            identityListed: appAnswer.identityListed)
        let verdict = Self.liveness(
            probeError: probe.error, appWindowsError: appAnswer.appWindowsError,
            appWindowMatch: match, processAlive: appAnswer.processAlive)
        // The app still lists the window: refresh the baseline to where
        // the app reports it, so the next comparison does not judge
        // against the frame the window left.
        return (verdict, appAnswer.identityFrame ?? baseline)
    }

    /// Whether the app's window list contains the probed window, from its
    /// last-read baseline and the app's listed frames. A listed window is
    /// membership even at a moved or rescaled frame: `identityListed`
    /// (the app's fresh list naming the window's own element) matches
    /// outright. Otherwise geometry decides: a listed frame close to the
    /// baseline is a match; the app answering with a complete list and no
    /// match means absent; an unreadable listed frame, or no baseline
    /// read yet, is a maybe. Never identity alone for absence — after a
    /// display teardown a held element stops comparing equal, so a false
    /// negative there falls through to geometry, not death.
    static func appWindowMatch(
        baseline: CGRect?, listedFrames: [CGRect?], identityListed: Bool
    ) -> Bool? {
        if identityListed { return true }
        guard let baseline else { return nil }
        let readFrames = listedFrames.compactMap { $0 }
        if readFrames.contains(where: { Self.framesClose($0, baseline) }) {
            return true
        }
        if listedFrames.isEmpty || readFrames.count == listedFrames.count {
            // Every listed frame read and none matched (or the app lists
            // nothing at all): the window is really gone.
            return false
        }
        // Some listed frames unreadable: undeterminable — a maybe.
        return nil
    }

    /// Drops a pid's shared observer once nothing is left to observe:
    /// the runloop source comes off the main runloop and the registry
    /// forgets which pids and element keys it was serving. The observer's
    /// elements are already gone by the time this runs (that is the
    /// condition), so there is no notification left to unregister: what
    /// would leak is the observer object and its runloop source, which
    /// the runloop retains forever once added.
    private func pruneObserver(for pid: pid_t) {
        let keys = registry.forget(pid: pid)
        guard let observer = observers[pid] else { return }
        observerDriver.removeRunLoopSource(observer)
        observers[pid] = nil
        if ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1" {
            NSLog("Tiled: [DEBUG-obs] pruned observer for pid %d (%d keys)",
                  pid, keys.count)
        }
    }

    /// Frames within a point of each other: the cached last-read frame
    /// and a fresh read of the same window differ only by rounding.
    private static func framesClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1
            && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    func observe(
        _ handle: WindowHandle, onChange: @escaping () -> Void,
        onDestroyed: @escaping () -> Void
    ) {
        guard let binding = bindings[handle] else { return }
        let pid = binding.pid
        let token = binding.token
        bindings[handle]?.changeHandler = onChange
        bindings[handle]?.destructionHandler = onDestroyed
        // The death check confirms absence geometrically (the app answers
        // and no listed frame matches the last read frame), so it needs a
        // baseline even for a window whose frame was never read: a
        // destroy notification can arrive before any move or resize tick.
        if binding.lastFrame == nil {
            _ = frame(of: handle)
        }
        bindings[handle]?.observedKey = token
        tokenIndex[token] = handle
        if ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1" {
            NSLog("Tiled: [DEBUG-obs] observe win%d pid=%d key=%lu observed=%d",
                  handle.id, pid, token, registry.isObserved(key: token) ? 1 : 0)
        }
        switch registry.begin(key: token, pid: pid) {
        case .skip:
            return

        case .createObserver:
            let result = observerDriver.createObserver(
                pid: pid,
                onNotification: { [weak self] notification, token in
                    self?.handleAXNotification(
                        notification: notification, token: token)
                })
            guard result.status == .success, let newObserver = result.observer
            else {
                registry.finish(
                    key: token, pid: pid, outcome: .observerUnavailable)
                NSLog(
                    "tiled: AXObserverCreate failed for pid %d (%d)", pid,
                    result.status.rawValue)
                return
            }
            observers[pid] = newObserver
            observerDriver.addRunLoopSource(newObserver)
            registerChanges(
                on: newObserver, element: bindings[handle]?.element, pid: pid,
                key: token)

        case .register:
            guard let observer = observers[pid] else {
                // The registry believed this pid had an observer and the
                // object is gone: forget the belief so the next attempt
                // creates one instead of failing here forever.
                registry.finish(
                    key: token, pid: pid, outcome: .observerUnavailable)
                return
            }
            registerChanges(
                on: observer, element: bindings[handle]?.element, pid: pid, key: token)
        }
    }

    /// Registers the resize and move notifications for one element, then
    /// reports how the attempt ended. Only a landed registration is
    /// remembered: a window whose notifications could not be registered
    /// stays retryable, instead of losing drag-resize for the rest of the
    /// session with nothing on screen to say so.
    private func registerChanges(
        on observer: AXObserverHandle, element: AXUIElement?, pid: pid_t,
        key: UInt
    ) {
        var failure: AXError?
        for name in [
            kAXWindowResizedNotification, kAXWindowMovedNotification,
            kAXUIElementDestroyedNotification,
        ] {
            let status = observerDriver.addNotification(
                name, to: observer, element: element)
            if ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1" {
                NSLog("Tiled: [DEBUG-obs] add %@ on pid %d (%d)", name as String, pid, status.rawValue)
            }
            if !ObservationRegistry.addSucceeded(status) {
                failure = status
                NSLog(
                    "tiled: could not observe %@ on pid %d (%d)", name as String, pid,
                    status.rawValue)
            }
        }
        registry.finish(
            key: key, pid: pid,
            outcome: failure == nil ? .registered : .registrationFailed)
    }

    func observeFocusChanges(_ onChange: @escaping () -> Void) {
        focusChangeHandler = onChange
        retargetFocusObserver()
    }

    func activeSpace(on display: CGDirectDisplayID) -> SpaceID? {
        guard display != 0 else { return nil }
        refreshSpaceCacheIfNeeded()
        return spaceCache[display]
    }

    func observeSpaceChanges(_ onChange: @escaping () -> Void) {
        spaceChangeHandler = onChange
    }

    /// Drops the cached Space table and tells the canvas layer to rebuild.
    /// The workspace notification calls this after one main-queue hop;
    /// tests call it directly, so the invalidation is pinned without
    /// posting a real notification.
    func spaceDidChange() {
        spaceCacheStamp = nil
        spaceChangeHandler?()
    }

    /// Cache lifetime for the Space table. Long enough to collapse a
    /// menu build's repeated per-row lookups, short enough that a Space
    /// the workspace notification missed cannot misdirect a hotkey.
    private static let spaceCacheLifetime: TimeInterval = 0.1

    private func refreshSpaceCacheIfNeeded() {
        let current = now()
        if let stamp = spaceCacheStamp,
            current.timeIntervalSince(stamp) < Self.spaceCacheLifetime
        { return }
        spaceCacheStamp = current
        spaceCache = spaceTable()
    }

    /// One pass over the live window server's managed-display Space
    /// table: display UUID -> id of the Space currently shown there.
    /// Empty when the private symbols are unavailable, which keeps every
    /// canvas keyed by display (the old behavior).
    static func currentSpaces() -> [CGDirectDisplayID: SpaceID] {
        guard
            let connection = CGS.defaultConnection?(),
            let displays = CGS.copyManagedDisplaySpaces?(connection)?
                .takeRetainedValue() as? [[String: Any]]
        else { return [:] }
        return spaces(
            from: displays,
            displayIDs: displayIDs(),
            mainDisplayID: CGMainDisplayID(),
            uuidString: uuidString(for:))
    }

    /// Pure core of the Space-table parse. Injecting the table, display
    /// list, and UUID lookup keeps the release-dependent table shapes
    /// unit-testable without window-server symbols or attached displays.
    static func spaces(
        from displays: [[String: Any]],
        displayIDs: [CGDirectDisplayID],
        mainDisplayID: CGDirectDisplayID,
        uuidString: (CGDirectDisplayID) -> String?
    ) -> [CGDirectDisplayID: SpaceID] {
        var spaces: [CGDirectDisplayID: SpaceID] = [:]
        for display in displays {
            let identifier = display["Display Identifier"] as? String
            guard
                let current = display["Current Space"] as? [String: Any],
                let space = spaceID(from: current["id64"]),
                let displayID = displayID(
                    identifier: identifier,
                    among: displays,
                    displayIDs: displayIDs,
                    mainDisplayID: mainDisplayID,
                    uuidString: uuidString)
            else { continue }
            spaces[displayID] = space
        }
        return spaces
    }

    /// Window-server Space ids bridge as numbers; accept every numeric
    /// shape the table has used across releases.
    static func spaceID(from value: Any?) -> SpaceID? {
        if let number = value as? NSNumber { return SpaceID(rawValue: number.uint64Value) }
        if let value = value as? UInt64 { return SpaceID(rawValue: value) }
        if let value = value as? Int64 { return SpaceID(rawValue: UInt64(bitPattern: value)) }
        if let string = value as? String, let raw = UInt64(string) {
            return SpaceID(rawValue: raw)
        }
        return nil
    }

    /// Map a Space-table entry back to its CoreGraphics display. The
    /// table identifies displays by UUID (or "Main" for the menu-bar
    /// display); both round-trip through the same UUID the public
    /// CGDisplay APIs produce, so there is no index guessing.
    static func displayID(
        identifier: String?,
        among displays: [[String: Any]],
        displayIDs: [CGDirectDisplayID],
        mainDisplayID: CGDirectDisplayID,
        uuidString: (CGDirectDisplayID) -> String?
    ) -> CGDirectDisplayID? {
        if let identifier {
            for displayID in displayIDs {
                guard let string = uuidString(displayID) else { continue }
                if string.caseInsensitiveCompare(identifier) == .orderedSame {
                    return displayID
                }
            }
            if identifier == "Main" { return mainDisplayID }
        }
        // Unknown identifier shapes: a single-display machine is
        // unambiguous, and guessing there is safer than dropping Space
        // identity on an OS that renamed the key.
        if displays.count == 1, let only = displayIDs.first { return only }
        return nil
    }

    /// The UUID string CoreGraphics publishes for a live display, the
    /// same identity the managed-display Space table writes down.
    private static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?
                .takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Every attached CoreGraphics display, for UUID mapping and the
    /// unambiguous single-display fallback.
    private static func displayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return [CGMainDisplayID()]
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return [CGMainDisplayID()]
        }
        return Array(ids.prefix(Int(count)))
    }

    /// Moves the focus observer to `application` (the just-activated app,
    /// when the activation notification names one) or the current
    /// frontmost application. AX cannot observe the system-wide element
    /// (it does not support notifications), so following focus means
    /// observing each frontmost app's `kAXFocusedWindowChangedNotification`.
    /// App activation re-targets; same-app window focus changes arrive on
    /// the callback.
    private func retargetFocusObserver(to application: NSRunningApplication? = nil) {
        guard focusChangeHandler != nil else { return }
        guard
            let frontmost = application ?? NSWorkspace.shared.frontmostApplication,
            frontmost.processIdentifier > 0
        else {
            releaseFocusObserver()
            return
        }
        let pid = frontmost.processIdentifier
        guard pid != focusObserverPID else { return }
        releaseFocusObserver()

        var created: AXObserver?
        let createResult = AXObserverCreate(pid, Self.focusObserverCallback, &created)
        guard createResult == .success, let observer = created else {
            NSLog(
                "tiled: AXObserverCreate failed for focus on pid %d (%d)",
                pid, createResult.rawValue)
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        Self.applyMessagingTimeout(appElement)
        let addResult = AXObserverAddNotification(
            observer, appElement, kAXFocusedWindowChangedNotification as CFString, nil)
        guard addResult == .success else {
            NSLog(
                "tiled: could not observe focused window on pid %d (%d)",
                pid, addResult.rawValue)
            return
        }
        focusObserver = observer
        focusObserverPID = pid
        focusObserverElement = appElement
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer),
            CFRunLoopMode.commonModes)
    }

    /// Drops the current focus observer and its runloop source. Called
    /// when the frontmost app changes and from `deinit`.
    private func releaseFocusObserver() {
        if let observer = focusObserver {
            if let appElement = focusObserverElement {
                AXObserverRemoveNotification(
                    observer, appElement, kAXFocusedWindowChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer),
                CFRunLoopMode.commonModes)
        }
        focusObserver = nil
        focusObserverPID = nil
        focusObserverElement = nil
    }

    func focus(_ handle: WindowHandle) {
        guard let binding = bindings[handle], let element = binding.element else { return }
        AXUIElementSetAttributeValue(
            element, kAXMainAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: binding.pid)?.activate()
    }

    /// Raises the window above its siblings without focusing it. Best
    /// effort: not every app supports the AXRaise action, and a z-order
    /// nicety must never surface as an error.
    func raise(_ handle: WindowHandle) {
        guard let element = bindings[handle]?.element else { return }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    func appName(of handle: WindowHandle) -> String? {
        guard let pid = bindings[handle]?.pid else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    var isTrusted: Bool { Self.isTrusted }

    func registerAccessibilityInterest() {
        // Prompt:false, so the explainer window asks in the product's own
        // words; this call only puts Tiled on the System Settings list
        // so the toggle is findable when the user gets there.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: Handle registry

    /// Stable handle for a live element: reuses the existing handle when
    /// the element is already registered, issues a fresh one otherwise.
    /// (The controller used to scan records with `CFEqual`; the registry
    /// does that once, here, behind the seam.)
    private func handle(for element: AXUIElement, pid: pid_t) -> WindowHandle {
        for (handle, binding) in bindings {
            if let registered = binding.element, CFEqual(registered, element) {
                return handle
            }
        }
        // A held element can stop comparing equal to the app's fresh
        // reference for the same window after a display teardown (the
        // death rule relies on the same fact). Fall back to geometry:
        // same pid, last-read frame within a point. Adopt the fresh
        // element so CFEqual routing recovers with it — but only when
        // the held element is provably stale: geometry alone cannot
        // tell the churned reference of the SAME window from a
        // DIFFERENT window that happens to share its frame (Firefox's
        // tab tear-out opens the detached window on the source
        // window's frame; adopting it silently untiled the original).
        // See `heldElementIsStale` and `inheritedHandle`.
        if let frame = Self.frame(of: element) {
            var matching: [WindowHandle] = []
            for (handle, binding) in bindings where binding.pid == pid {
                guard let cached = binding.lastFrame,
                      Self.framesClose(cached, frame)
                else { continue }
                matching.append(handle)
            }
            if !matching.isEmpty {
                // One list read serves every candidate; only a geometry
                // match pays for it. Nil means the app would not answer:
                // membership is undeterminable, never "absent".
                let listed = Self.appWindowList(pid: pid)
                let candidates = matching.map { handle -> HandleCandidate in
                    let held = bindings[handle]?.element
                    let listedByApp = listed.map { list in
                        guard let held else { return false }
                        return list.contains { CFEqual($0, held) }
                    }
                    let heldIsStale = Self.heldElementIsStale(
                        listedByApp: listedByApp,
                        probeAnswers: { held.map(Self.elementAnswers) ?? false })
                    if ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1" {
                        NSLog(
                            "Tiled: [DEBUG-obs] geometry match win%d listed=%@ stale=%d",
                            handle.id, listedByApp.map { $0 ? "yes" : "no" } ?? "unknown",
                            heldIsStale ? 1 : 0)
                    }
                    return HandleCandidate(handle: handle, heldIsStale: heldIsStale)
                }
                if let inherited = Self.inheritedHandle(candidates) {
                    adopt(
                        inherited, element: element, token: UInt(CFHash(element)),
                        frames: AXWindowFrames(element: element), pid: pid)
                    bindings[inherited]?.lastFrame = frame
                    return inherited
                }
            }
        }
        let handle = WindowHandle(id: nextHandleID)
        nextHandleID += 1
        let token = UInt(CFHash(element))
        let frames = AXWindowFrames(element: element)
        bindings[handle] = WindowBinding(pid: pid, frames: frames, token: token)
        adopt(handle, element: element, token: token, frames: frames, pid: pid)
        return handle
    }

    /// Points a handle at the fresh AXUIElement and token. An observed
    /// handle also moves its registry key and re-registers notifications
    /// on the shared observer, so routing follows the adopted identity;
    /// otherwise the old CFHash stayed registered and the fresh element's
    /// notifications fell through.
    private func adopt(
        _ handle: WindowHandle, element: AXUIElement?, token: UInt,
        frames: WindowFrames, pid: pid_t
    ) {
        guard var binding = bindings[handle] else { return }
        let oldKey = binding.observedKey
        if let element {
            binding.element = element
            Self.applyMessagingTimeout(element)
        }
        binding.token = token
        binding.frames = frames
        if let oldKey, oldKey != token {
            registry.forget(key: oldKey)
            if tokenIndex[oldKey] == handle { tokenIndex[oldKey] = nil }
            binding.observedKey = token
            tokenIndex[token] = handle
            bindings[handle] = binding
            if let observer = observers[pid] {
                registerChanges(
                    on: observer, element: element, pid: pid, key: token)
            } else {
                registry.finish(key: token, pid: pid, outcome: .observerUnavailable)
            }
            return
        }
        bindings[handle] = binding
    }

    /// One same-pid handle whose last-read frame matches the fresh
    /// element's frame: the only handles geometry could hand over to.
    /// Whether the held element is stale (see `heldElementIsStale`)
    /// decides if it actually may be.
    struct HandleCandidate: Equatable {
        var handle: WindowHandle
        var heldIsStale: Bool
    }

    /// The handle a fresh element may inherit, or nil for a fresh handle.
    /// Only a provably stale candidate can be inherited: a live window
    /// that merely shares the frame must never lose its identity to a
    /// newcomer. Among several stale candidates (stacked churned
    /// references) the first is as good as any.
    static func inheritedHandle(_ candidates: [HandleCandidate]) -> WindowHandle? {
        candidates.first(where: { $0.heldIsStale })?.handle
    }

    /// Whether a held element is provably stale, from what the owning app
    /// answered. The fresh window list decides when it read: a listed
    /// element is a live window (listed wins even if this probe fails),
    /// and an absent one is a churned reference. Only an unreadable list
    /// falls back to the element's own position probe — an element that
    /// still answers is a live window, not a stale reference — so an
    /// undeterminable membership never silently hands a live window's
    /// identity away.
    static func heldElementIsStale(
        listedByApp: Bool?, probeAnswers: () -> Bool
    ) -> Bool {
        if let listedByApp { return !listedByApp }
        return !probeAnswers()
    }

    /// The owning app's fresh window list, for CFEqual membership of held
    /// elements. Nil when the app element does not answer; an app that
    /// answers an empty list genuinely lists nothing.
    private static func appWindowList(pid: pid_t) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                == .success
        else { return nil }
        return value as? [AXUIElement] ?? []
    }

    /// Whether a held element still answers its own position probe: a
    /// live reference, whatever any window list says.
    private static func elementAnswers(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &value) == .success
    }

    /// Bounds every future message to `element` (reads and writes alike)
    /// at `messagingTimeout`. Idempotent per element; elements register
    /// once, so this runs once per window.
    private static func applyMessagingTimeout(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
    }

    /// Focus arrives on its own observer: its element is an application
    /// element, not a registered window, so the window-handle routing
    /// would never match it.
    private static let focusObserverCallback: AXObserverCallback = { _, _, _, _ in
        // The focus changed: the memoized resolution is stale by
        // definition, and the handler redraws from the new answer.
        LiveWindowGateway.active?.focusMemo.clear()
        LiveWindowGateway.active?.focusChangeHandler?()
    }

    /// Routes an AX notification to the registered handler of whichever
    /// handle owns `token` (the AXUIElement's CFHash). Identity is resolved
    /// here so the controller never touches `AXUIElement`; registrations
    /// outlive records, so routing keys on the observation token rather
    /// than a refcon id. A released handle has forgotten its token, and
    /// the notification falls through.
    func handleAXNotification(notification: String, token: UInt) {
        if ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1" {
            NSLog("Tiled: [DEBUG-obs] notification %@ arrived", notification)
        }
        guard let handle = tokenIndex[token] else {
            if ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1" {
                NSLog(
                    "Tiled: [DEBUG-obs] notification %@ matched NO handle (%d observed)",
                    notification, tokenIndex.count)
            }
            return
        }
        if notification == kAXUIElementDestroyedNotification as String {
            bindings[handle]?.destructionHandler?()
        } else {
            bindings[handle]?.changeHandler?()
        }
    }
    // MARK: Permissions

    /// Fresh trust probe: `AXIsProcessTrusted()` caches per-process, so a
    /// poll built on it returns `false` forever once it has seen `false`:
    /// the grant would never be noticed and the permission window would
    /// linger. The WithOptions variant re-queries the TCC daemon, so the
    /// launch poll sees the flip while running and the window closes.
    private static var isTrusted: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    // MARK: Focused window

    private static func focusedAXWindow() -> (element: AXUIElement, pid: pid_t)? {
        let systemWide = AXUIElementCreateSystemWide()
        // The system-wide and app elements here are transient (never
        // registered), so the per-element timeout must be applied inline:
        // a hung focused app would otherwise block focus resolution for
        // the default ~6s on every hotkey press.
        applyMessagingTimeout(systemWide)

        var appValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedApplicationAttribute as CFString, &appValue)
                == .success,
            let rawApp = appValue,
            CFGetTypeID(rawApp) == AXUIElementGetTypeID()
        else { return nil }
        let appElement = rawApp as! AXUIElement
        applyMessagingTimeout(appElement)

        var pid: pid_t = 0
        guard AXUIElementGetPid(appElement, &pid) == .success else { return nil }

        var winValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &winValue)
                == .success,
            let rawWin = winValue,
            CFGetTypeID(rawWin) == AXUIElementGetTypeID()
        else { return nil }

        return (rawWin as! AXUIElement, pid)
    }

    // MARK: Liveness

    /// Death standard for a failed liveness probe, confirmed against
    /// the app element's window list, pure so it is testable without
    /// AX. A failed window probe is a maybe: live windows fail it all
    /// through a lid close/open (see `liveness(of:)`). Death requires
    /// the app to confirm: the app element itself is stale (the app
    /// quit), the app's process is gone (its AX answers read
    /// `.cannotComplete`, which is not a maybe when there is nobody left
    /// to answer), or the app answers and no listed window matches the
    /// window's last read frame. A frame match, or an undeterminable
    /// check (nil), stays unknown: a maybe never untiles.
    static func liveness(
        probeError: AXError, appWindowsError: AXError, appWindowMatch: Bool?,
        processAlive: Bool
    ) -> Liveness {
        if probeError == .success { return .alive }
        if appWindowsError == .invalidUIElement { return .dead }
        // A window outlives nothing: with the owning process gone, its
        // element cannot be anything but stale. Dead apps answer window
        // probes with `.cannotComplete`, not `.invalidUIElement`, so
        // without this a ghost keeps its slot and the status icon keeps
        // showing it until the pid is recycled.
        if !processAlive { return .dead }
        if appWindowsError == .success, appWindowMatch == false { return .dead }
        return .unknown
    }

    /// Whether `pid` still exists. `NSRunningApplication` knows every
    /// live process that can own a window; the `kill(pid, 0)` probe
    /// covers the rest, and its errno separates "gone" (ESRCH) from
    /// "exists but not ours to signal" (EPERM), which must not read as
    /// death.
    static func processExists(_ pid: pid_t) -> Bool {
        if NSRunningApplication(processIdentifier: pid) != nil { return true }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    // MARK: Geometry

    /// Frame of a window in AppKit global coordinates (bottom-left origin).
    /// The AX position attribute is the top-left corner in top-left-origin
    /// global coordinates, so the y axis must be converted here; everything
    /// downstream (layout, drag detection, echo suppression) speaks AppKit.
    fileprivate static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let axOrigin = readPoint(element, positionAttribute),
            let size = readSize(element, sizeAttribute)
        else { return nil }
        // The y-flip needs the primary screen's top edge: with no screen
        // reported there is no coordinate space to convert into, and the
        // old guess (`axOrigin.y + size.height`) silently flattened every
        // frame's y to 0. An unreadable frame is the honest answer, and
        // every caller already treats nil as "unknown".
        guard let primaryTop = NSScreen.screens.first?.frame.maxY else { return nil }
        return appKitFrame(axOrigin: axOrigin, size: size, primaryTop: primaryTop)
    }


    // MARK: AX transient failures (pure policy, unit-tested without AX)

    /// Retry policy for AX writes. A write fails either because the app
    /// refused (permanent: retrying changes nothing) or because its main
    /// thread was momentarily unable to service the message (`.cannotComplete`:
    /// busy, beachballing, mid-launch). Only the
    /// transient class retries, with a short backoff, on the calling
    /// thread: hotkey handling already blocks the main runloop on the AX
    /// round-trip itself, and an asynchronous retry would break the
    /// placement's synchronous all-or-nothing writes.
    enum AXWrite {
        /// The error class worth retrying: the app could not complete the
        /// request right now. Everything else (unsupported attribute,
        /// disabled API, invalid element) is a permanent refusal.
        static func isRetryable(_ error: AXError) -> Bool {
            error == .cannotComplete
        }

        /// Total attempts per write: one initial try plus two retries.
        /// More retries would stack multi-second latencies onto a single
        /// hotkey press for an app that is genuinely stuck.
        static let maxAttempts = 3

        /// Backoff before the first retry. Doubles per attempt; the total
        /// added latency across a fully-retried write is 0.3s.
        static let baseDelay: TimeInterval = 0.1

        /// Whether a failed write pair needs the already-landed position
        /// rolled back. The size write is mandatory, so a landed position
        /// plus any failure means the window is half-moved unless the
        /// caller restores the previous origin.
        static func needsPositionRestore(positionLanded: Bool, failed: Bool) -> Bool {
            positionLanded && failed
        }

        /// Wait before retrying after `attempt` (0-indexed) failed.
        static func delay(forAttempt attempt: Int) -> TimeInterval {
            baseDelay * pow(2, Double(attempt))
        }

        /// Runs `operation` up to `maxAttempts` times, retrying only
        /// retryable errors with backoff. Returns nil on success, else
        /// the last error (retryable or not; callers only distinguish
        /// success, but the code is kept for logging and tests).
        /// `sleep` is injectable so tests can observe the backoff without
        /// waiting on real time.
        static func retrying(
            operation: () -> AXError,
            sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        ) -> AXError? {
            var lastError: AXError?
            for attempt in 0..<maxAttempts {
                let error = operation()
                if error == .success { return nil }
                lastError = error
                guard isRetryable(error), attempt < maxAttempts - 1 else { break }
                sleep(delay(forAttempt: attempt))
            }
            return lastError
        }
    }

    // MARK: AXObserver registration (pure policy, unit-tested without AX)

    /// Bookkeeping for per-window change notifications. The adapter owns
    /// the AX objects; this decides what a registration request needs and
    /// remembers what the objects cannot answer: which element keys are
    /// observed (re-tiling must not double-register) and which processes
    /// own a shared observer (registrations outlive untiled records, so an
    /// observer is created once per pid and reused).
    ///
    /// Only a *landed* registration counts as observed. Remembering an
    /// attempt that failed would lock that window out of drag-resize for
    /// the life of the process: the next `observe` for the same element
    /// would read it as already registered, return without doing anything,
    /// and nothing on screen would say so.
    struct ObservationRegistry {
        /// What the adapter must do for a registration request.
        enum Step: Equatable {
            /// Observed already, or an attempt is still in flight.
            case skip
            /// The pid has no observer yet: create one, then register.
            case createObserver
            /// The pid's shared observer exists: register on it.
            case register
        }

        /// How the AX calls for one attempt turned out.
        enum Outcome: Equatable {
            /// Every notification is in place: remember the key.
            case registered
            /// The observer exists, but at least one notification could not
            /// be registered. Forget the attempt, so a later `observe`
            /// retries, and keep the observer shareable.
            case registrationFailed
            /// There was no observer to register on (creation failed, or the
            /// object was already gone). Forget the attempt and the pid's
            /// observer, so the retry creates one.
            case observerUnavailable
        }

        private var observerPIDs: Set<pid_t> = []
        private var registeredKeys: [UInt: pid_t] = [:]
        private var pendingKeys: Set<UInt> = []

        /// Whether `AXObserverAddNotification` left the notification in
        /// place. `.notificationAlreadyRegistered` counts: the retry after
        /// a partial failure re-adds what the first attempt already landed,
        /// and reading that as failure would retry forever.
        static func addSucceeded(_ status: AXError) -> Bool {
            status == .success || status == .notificationAlreadyRegistered
        }

        /// Decides the step for `key` on `pid` and marks the attempt
        /// pending, so a re-entrant `observe` (the same element requested
        /// twice before the AX calls return) cannot double-register.
        mutating func begin(key: UInt, pid: pid_t) -> Step {
            guard registeredKeys[key] == nil, !pendingKeys.contains(key) else {
                return .skip
            }
            pendingKeys.insert(key)
            return observerPIDs.contains(pid) ? .register : .createObserver
        }

        /// Records how the attempt ended and releases the key's pending
        /// slot, so a key that failed can be attempted again.
        mutating func finish(key: UInt, pid: pid_t, outcome: Outcome) {
            pendingKeys.remove(key)
            switch outcome {
            case .registered:
                registeredKeys[key] = pid
                observerPIDs.insert(pid)
            case .registrationFailed:
                observerPIDs.insert(pid)
            case .observerUnavailable:
                observerPIDs.remove(pid)
            }
        }

        /// Forgets one released handle's key. The pid's shared observer
        /// stays (its other windows still use it); the key must not, so a
        /// window re-tiled under a fresh handle can register again.
        /// Forgets one element key. The registry is keyed by CFHash, not
        /// pid: a pid's shared observer outlives any one window, and only
        /// `forget(pid:)` drops the observer's own rows.
        mutating func forget(key: UInt) {
            registeredKeys[key] = nil
            pendingKeys.remove(key)
        }

        /// Whether the element's change notifications are registered.
        func isObserved(key: UInt) -> Bool { registeredKeys[key] != nil }

        /// Forgets a pid's observer and returns the element keys that were
        /// registered on it, so the caller can drop the object they were
        /// served by. Other pids keep their keys and their observer: this
        /// is a process leaving, not a registry reset.
        mutating func forget(pid: pid_t) -> [UInt] {
            observerPIDs.remove(pid)
            let keys = registeredKeys.filter { $0.value == pid }.map(\.key)
            for key in keys { registeredKeys[key] = nil }
            return keys
        }
    }

    // MARK: Geometry (pure conversions, unit-tested without AX)

    /// AppKit global frame (bottom-left origin) for an AX top-left origin
    /// and size. `primaryTop` is the primary screen's top edge in AppKit
    /// coordinates; AX y counts down from that top. Pure so the subtle
    /// y-flip is testable without AX elements or attached displays.
    static func appKitFrame(
        axOrigin: CGPoint, size: CGSize, primaryTop: CGFloat
    ) -> CGRect {
        CGRect(
            x: axOrigin.x,
            y: primaryTop - axOrigin.y - size.height,
            width: size.width,
            height: size.height)
    }

    /// AX top-left point (top-left-origin global coordinates) for an AppKit
    /// global frame. `primaryTop` as in `appKitFrame(axOrigin:size:primaryTop:)`.
    static func axTopLeft(of nsFrame: CGRect, primaryTop: CGFloat) -> CGPoint {
        CGPoint(x: nsFrame.minX, y: primaryTop - nsFrame.maxY)
    }

    // MARK: AXValue plumbing

    private static let positionAttribute = kAXPositionAttribute
    private static let sizeAttribute = kAXSizeAttribute
    private static let pointType = AXValueType(rawValue: kAXValueCGPointType)!
    private static let sizeType = AXValueType(rawValue: kAXValueCGSizeType)!

    fileprivate static func pointValue(_ p: CGPoint) -> AXValue? {
        var value = p
        return AXValueCreate(pointType, &value)
    }

    fileprivate static func sizeValue(_ s: CGSize) -> AXValue? {
        var value = s
        return AXValueCreate(sizeType, &value)
    }

    fileprivate static func readPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let axValue = readAXValue(element, attribute) else { return nil }
        var point = CGPoint()
        guard AXValueGetValue(axValue, pointType, &point) else { return nil }
        return point
    }

    private static func readSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let axValue = readAXValue(element, attribute) else { return nil }
        var size = CGSize()
        guard AXValueGetValue(axValue, sizeType, &size) else { return nil }
        return size
    }

    /// Reads an attribute expected to hold an AXValue, verifying the type
    /// before casting (AX returns whatever the app provides).
    private static func readAXValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let raw = value,
            CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        return (raw as! AXValue)
    }
}
