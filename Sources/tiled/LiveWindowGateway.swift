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

/// Thin wrapper over the Accessibility API: permissions, focused window,
/// frame read/write. All coordinate conversion lives here.
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
    /// Live element per issued handle. Entries are removed when the
    /// window dies (probed via `isAlive`) so handles never dangle.
    private var elements: [WindowHandle: AXUIElement] = [:]
    private var pids: [WindowHandle: pid_t] = [:]
    /// The observation key registered per observed handle, so `release`
    /// can forget exactly that key while the pid's shared observer and
    /// its other windows stay.
    private var observedKeys: [WindowHandle: UInt] = [:]
    /// Last focused-window resolution, memoized for one refresh pass:
    /// a single menu build asks three times (has-focused, the expanded
    /// slot, the icon's canvas), and every answer is a system-wide AX
    /// element plus attribute reads. The focus observer clears it; the
    /// TTL only bounds a pass that races a notification.
    private var focusedCache: (handle: WindowHandle?, stamp: Date)?
    private static let focusedCacheLifetime: TimeInterval = 0.05
    /// Last successfully-read frame per handle: the geometry a death
    /// confirmation matches against, refreshed by frame reads and by
    /// successful liveness probes — a window whose move notifications
    /// failed to register is probed but never re-read otherwise, and a
    /// stale baseline would condemn it after a drag. Window element
    /// identity is useless for that check — after a display teardown a
    /// held element stops comparing equal (CFEqual) to the app's fresh
    /// reference for the same window (observed on live AX: `listed=no`
    /// while the app listed every window) — but the window's frame is
    /// stable.
    private var lastFrames: [WindowHandle: CGRect] = [:]
    /// Observer per pid; registrations outlive untiled records and can
    /// never be unregistered, so they are created once and shared.
    private var observers: [pid_t: AXObserver] = [:]
    /// Which elements have change notifications registered, and which
    /// processes already own a shared observer (CFHash keyed; dedupe, since
    /// re-tiling must not double-register). The adapter performs the AX
    /// calls; this decides what a registration request needs.
    private var registry = ObservationRegistry()
    /// Change handler per observed handle.
    private var changeHandlers: [WindowHandle: () -> Void] = [:]
    /// Destruction handler per observed handle: the OS reported the
    /// element destroyed. Separate from `changeHandlers` because the
    /// notification means something categorically different (the window
    /// is gone, not moved), and the controller must not read a frame for
    /// an element that no longer answers.
    private var destructionHandlers: [WindowHandle: () -> Void] = [:]
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

    init() {
        LiveWindowGateway.active = self
        activeAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            let activated = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication
            self?.retargetFocusObserver(to: activated)
        }
        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            let terminated = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication
            guard let pid = terminated?.processIdentifier else { return }
            if pid == self?.focusObserverPID { self?.releaseFocusObserver() }
            self?.pruneObserver(for: pid)
        }
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // One main-queue hop: the notification can arrive while the
            // window server is still committing the switch, and the
            // Space table must answer with the newly visible Space.
            DispatchQueue.main.async {
                self?.spaceCacheStamp = nil
                self?.spaceChangeHandler?()
            }
        }
    }

    deinit {
        if let activeAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeAppObserver)
        }
        if let appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
        }
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
        }
        releaseFocusObserver()
    }

    // MARK: WindowGateway

    func focusedWindow() -> WindowHandle? {
        if let cache = focusedCache,
           Date().timeIntervalSince(cache.stamp) < Self.focusedCacheLifetime {
            return cache.handle
        }
        guard let (element, pid) = Self.focusedAXWindow() else {
            focusedCache = (nil, Date())
            return nil
        }
        let handle = handle(for: element, pid: pid)
        focusedCache = (handle, Date())
        return handle
    }

    func frame(of handle: WindowHandle) -> CGRect? {
        guard let element = elements[handle] else { return nil }
        guard let frame = Self.frame(of: element) else { return nil }
        lastFrames[handle] = frame
        return frame
    }

    @discardableResult
    func setFrame(_ handle: WindowHandle, to frame: CGRect) -> Bool {
        guard let element = elements[handle] else { return false }
        return Self.setFrame(element, to: frame)
    }

    /// Drops a confirmed-gone handle: element, pid, handlers, baseline,
    /// and its observation key. The shared observer outlives any one
    /// window and only goes when the pid's last handle does.
    func release(_ handle: WindowHandle) {
        guard let pid = pids[handle] else { return }
        if let key = observedKeys[handle] {
            registry.forget(key: key, pid: pid)
        }
        observedKeys[handle] = nil
        elements[handle] = nil
        pids[handle] = nil
        changeHandlers[handle] = nil
        destructionHandlers[handle] = nil
        lastFrames[handle] = nil
        if !pids.values.contains(pid) { pruneObserver(for: pid) }
    }

    /// Liveness for every requested handle in one pass. The per-window
    /// probe is one AX read per handle; a failed probe is corroborated
    /// against its owning app, and the pass asks each app once — one
    /// window list, each listed frame read once — however many of its
    /// windows failed. The prune pass runs on the main runloop, so the
    /// pass costs one app walk per app, never one per record.
    ///
    /// A successful probe also refreshes the frame baseline the death
    /// match reads: move notifications can fail to register, and a user
    /// drag then leaves the baseline stale — the geometric match would
    /// confirm the live window's absence against a frame it left behind
    /// (D13).
    ///
    /// A dead verdict is not a retirement. The controller confirms it
    /// across `deathConfirmation`, precisely so a transient (a lid
    /// close where window probes fail for live windows) can recover on
    /// the next probe. Retiring the element here would make the next
    /// call return `.dead` without probing and collapse the
    /// confirmation window to a single tick. The element stays until
    /// the controller confirms and forgets the window, which is when
    /// `release` runs and the slot actually frees.
    func liveness(of handles: [WindowHandle]) -> [WindowHandle: Liveness] {
        var probes: [ProbedWindow] = []
        var missing: [WindowHandle: Liveness] = [:]
        for handle in handles {
            guard let element = elements[handle], let pid = pids[handle] else {
                missing[handle] = .dead
                continue
            }
            var value: CFTypeRef?
            let probeError = AXUIElementCopyAttributeValue(
                element, kAXPositionAttribute as CFString, &value)
            probes.append(ProbedWindow(
                handle: handle, pid: pid, error: probeError,
                frame: probeError == .success ? Self.frame(of: element) : nil))
        }
        let pass = Self.livenessPass(
            probes: probes,
            baselines: lastFrames,
            appAnswer: { pid in
                // Frames only matter where a failed handle has a
                // baseline to compare them against; an app with
                // none gets its window list read but no frames.
                self.appWindowAnswer(
                    for: pid,
                    needsFrames: probes.contains {
                        $0.pid == pid && $0.error != .success
                            && self.lastFrames[$0.handle] != nil
                    })
            },
            log: { message in
                guard ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1"
                else { return }
                NSLog("Tiled: [DEBUG-lv] %@", message)
            })
        lastFrames = pass.baselines
        return missing.merging(pass.verdicts) { _, new in new }
    }

    /// One managed window as a liveness pass found it: the probe's error
    /// and — when the probe answered — the frame read alongside it. A
    /// successful probe is the pass's chance to refresh the death-match
    /// baseline; a failed one carries no frame, only its error and its
    /// owning app.
    struct ProbedWindow {
        var handle: WindowHandle
        var pid: pid_t
        var error: AXError
        var frame: CGRect?
    }

    /// What one owning app answered when asked about its windows: whether
    /// the process still exists, how the window-list request ended, and
    /// one frame read per listed window (nil for a frame that could not
    /// be read — the display-teardown case).
    struct AppWindowAnswer {
        var processAlive: Bool
        var appWindowsError: AXError
        var listedFrames: [CGRect?]
    }

    /// One liveness pass assembled from raw probe and app answers:
    /// successful probes are alive and refresh the frame baseline the
    /// geometric match reads; every failed probe is judged against its
    /// app's single answer for the pass — the app is asked at most once,
    /// however many of its windows failed their probe. Pure so the
    /// assembly (and its one-walk-per-app rule) is testable with exact
    /// scenarios, no AX. `log` receives one line per judged probe; the
    /// adapter routes it through TILED_DEBUG.
    static func livenessPass(
        probes: [ProbedWindow],
        baselines: [WindowHandle: CGRect],
        appAnswer: (pid_t) -> AppWindowAnswer,
        log: (String) -> Void = { _ in }
    ) -> (verdicts: [WindowHandle: Liveness], baselines: [WindowHandle: CGRect]) {
        var verdicts: [WindowHandle: Liveness] = [:]
        var refreshed = baselines
        for probe in probes where probe.error == .success {
            verdicts[probe.handle] = .alive
            // A successful probe is the baseline's only chance to track
            // a window nothing reads: move notifications can fail to
            // register and a drag then leaves the stale frame the death
            // match would confirm absence against (D13). A frame that
            // will not read keeps the old baseline — a maybe, never a
            // reset to nothing.
            if let frame = probe.frame { refreshed[probe.handle] = frame }
        }
        var answers: [pid_t: AppWindowAnswer] = [:]
        for probe in probes where probe.error != .success {
            let answer: AppWindowAnswer
            if let cached = answers[probe.pid] {
                answer = cached
            } else {
                answer = appAnswer(probe.pid)
                answers[probe.pid] = answer
            }
            let match = appWindowMatch(
                baseline: baselines[probe.handle], listedFrames: answer.listedFrames)
            let verdict = liveness(
                probeError: probe.error,
                appWindowsError: answer.appWindowsError,
                appWindowMatch: match,
                processAlive: answer.processAlive)
            verdicts[probe.handle] = verdict
            log(
                "win handle \(probe.handle.id) probe=\(probe.error.rawValue) "
                    + "appList err=\(answer.appWindowsError.rawValue) "
                    + "count=\(answer.listedFrames.count) "
                    + "match=\(match.map { $0 ? "yes" : "no" } ?? "unknown") "
                    + "processAlive=\(answer.processAlive ? 1 : 0) -> "
                    + "\(verdict == .alive ? "alive" : verdict == .dead ? "dead" : "unknown")")
        }
        return (verdicts, refreshed)
    }

    /// Gathers one app's answer for a liveness pass: process probe, app
    /// element, and window list, each exactly once. The listed frames
    /// are read only when some failed handle of this app has a baseline
    /// to compare them against — their only use; without one the extra
    /// reads could not change a verdict. Called at most once per pid per
    /// pass by `livenessVerdicts`.
    private func appWindowAnswer(
        for pid: pid_t, needsFrames: Bool
    ) -> AppWindowAnswer {
        let processAlive = Self.processExists(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        var listRef: CFTypeRef?
        let listError = AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &listRef)
        let list = listRef as? [AXUIElement] ?? []
        return AppWindowAnswer(
            processAlive: processAlive,
            appWindowsError: listError,
            listedFrames: needsFrames ? list.map { Self.frame(of: $0) } : [])
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
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer),
            CFRunLoopMode.commonModes)
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

    /// How far the app's listed frame may sit from the window's baseline
    /// and still be that window: apps that round frames to an internal
    /// grid (Terminal rounds to character cells) settle a few points off
    /// between reads, and the baseline refreshed at the last successful
    /// probe can sit that far from the frame the app lists a moment
    /// later. A rounding-level difference must never read as absence —
    /// that is how a live window gets confirmed dead. Deliberately wider
    /// than the element-adoption fallback's within-a-point bound above:
    /// there a sibling's near frame would steal a live handle, while here
    /// a wider bound only delays a ghost's release (a maybe never
    /// untiles).
    static let roundingTolerance: CGFloat = 5

    /// Frames within `roundingTolerance` of each other per edge (origin
    /// and size): the death match's "same frame".
    private static func framesClose(
        _ a: CGRect, _ b: CGRect, tolerance: CGFloat
    ) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    func observe(
        _ handle: WindowHandle, onChange: @escaping () -> Void,
        onDestroyed: @escaping () -> Void
    ) {
        guard let element = elements[handle], let pid = pids[handle] else { return }
        changeHandlers[handle] = onChange
        destructionHandlers[handle] = onDestroyed
        // The death check confirms absence geometrically (the app answers
        // and no listed frame matches the last read frame), so it needs a
        // baseline even for a window whose frame was never read: a
        // destroy notification can arrive before any move or resize tick.
        if lastFrames[handle] == nil, let frame = Self.frame(of: element) {
            lastFrames[handle] = frame
        }
        let key = UInt(CFHash(element))
        observedKeys[handle] = key
        if ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1" {
            NSLog("Tiled: [DEBUG-obs] observe win%d pid=%d key=%lu observed=%d",
                  handle.id, pid, key, registry.isObserved(key: key) ? 1 : 0)
        }
        switch registry.begin(key: key, pid: pid) {
        case .skip:
            return

        case .createObserver:
            var created: AXObserver?
            let result = AXObserverCreate(
                pid, Self.observerCallback, &created)
            guard result == .success, let newObserver = created else {
                registry.finish(key: key, pid: pid, outcome: .observerUnavailable)
                NSLog(
                    "tiled: AXObserverCreate failed for pid %d (%d)", pid,
                    result.rawValue)
                return
            }
            observers[pid] = newObserver
            CFRunLoopAddSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver),
                CFRunLoopMode.commonModes)
            registerChanges(
                on: newObserver, element: element, pid: pid, key: key)

        case .register:
            guard let observer = observers[pid] else {
                // The registry believed this pid had an observer and the
                // object is gone: forget the belief so the next attempt
                // creates one instead of failing here forever.
                registry.finish(key: key, pid: pid, outcome: .observerUnavailable)
                return
            }
            registerChanges(on: observer, element: element, pid: pid, key: key)
        }
    }

    /// Registers the resize and move notifications for one element, then
    /// reports how the attempt ended. Only a landed registration is
    /// remembered: a window whose notifications could not be registered
    /// stays retryable, instead of losing drag-resize for the rest of the
    /// session with nothing on screen to say so.
    private func registerChanges(
        on observer: AXObserver, element: AXUIElement, pid: pid_t, key: UInt
    ) {
        var failure: AXError?
        for name in [
            kAXWindowResizedNotification, kAXWindowMovedNotification,
            kAXUIElementDestroyedNotification,
        ] {
            let status = AXObserverAddNotification(
                observer, element, name as CFString, nil)
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

    /// Cache lifetime for the Space table. Long enough to collapse a
    /// menu build's repeated per-row lookups, short enough that a Space
    /// the workspace notification missed cannot misdirect a hotkey.
    private static let spaceCacheLifetime: TimeInterval = 0.1

    private func refreshSpaceCacheIfNeeded() {
        if let stamp = spaceCacheStamp,
            Date().timeIntervalSince(stamp) < Self.spaceCacheLifetime
        { return }
        spaceCacheStamp = Date()
        spaceCache = Self.currentSpaces()
    }

    /// One pass over the live window server's managed-display Space
    /// table: display UUID -> id of the Space currently shown there.
    /// Empty when the private symbols are unavailable, which keeps every
    /// canvas keyed by display (the old behavior).
    private static func currentSpaces() -> [CGDirectDisplayID: SpaceID] {
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
        guard let element = elements[handle], let pid = pids[handle] else { return }
        AXUIElementSetAttributeValue(
            element, kAXMainAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    /// Raises the window above its siblings without focusing it. Best
    /// effort: not every app supports the AXRaise action, and a z-order
    /// nicety must never surface as an error.
    func raise(_ handle: WindowHandle) {
        guard let element = elements[handle] else { return }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    func appName(of handle: WindowHandle) -> String? {
        pids[handle].flatMap {
            NSRunningApplication(processIdentifier: $0)?.localizedName
        }
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
        for (handle, registered) in elements where CFEqual(registered, element) {
            return handle
        }
        // A held element can stop comparing equal to the app's fresh
        // reference for the same window after a display teardown (the
        // death rule relies on the same fact). Fall back to geometry:
        // same pid, last-read frame within a point. Adopt the fresh
        // element so CFEqual routing recovers with it.
        if let frame = Self.frame(of: element) {
            for (handle, registeredPID) in pids where registeredPID == pid {
                guard let cached = lastFrames[handle],
                      Self.framesClose(cached, frame)
                else { continue }
                elements[handle] = element
                lastFrames[handle] = frame
                Self.applyMessagingTimeout(element)
                return handle
            }
        }
        let handle = WindowHandle(id: nextHandleID)
        nextHandleID += 1
        elements[handle] = element
        pids[handle] = pid
        Self.applyMessagingTimeout(element)
        return handle
    }

    /// Bounds every future message to `element` (reads and writes alike)
    /// at `messagingTimeout`. Idempotent per element; elements register
    /// once, so this runs once per window.
    private static func applyMessagingTimeout(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
    }

    private static let observerCallback: AXObserverCallback = {
        _, element, notification, _ in
        guard let gateway = LiveWindowGateway.active else { return }
        gateway.handleAXNotification(
            notification: notification as String, element: element)
    }

    /// Focus arrives on its own observer, not `observerCallback`: its
    /// element is an application element, not a registered window, so the
    /// window-handle routing would never match it.
    private static let focusObserverCallback: AXObserverCallback = { _, _, _, _ in
        // The focus changed: the memoized resolution is stale by
        // definition, and the handler redraws from the new answer.
        LiveWindowGateway.active?.focusedCache = nil
        LiveWindowGateway.active?.focusChangeHandler?()
    }

    /// Routes an AX notification to the registered handler of whichever
    /// handle owns `element`. Element identity is resolved here so the
    /// controller never touches `AXUIElement` (the old refcon-id scheme
    /// went stale for the same reason: registrations outlive records).
    private func handleAXNotification(notification: String, element: AXUIElement) {
        if ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1" {
            NSLog("Tiled: [DEBUG-obs] notification %@ arrived", notification)
        }
        for (handle, registered) in elements
        where CFEqual(registered, element) {
            if notification == kAXUIElementDestroyedNotification as String {
                destructionHandlers[handle]?()
            } else {
                changeHandlers[handle]?()
            }
            return
        }
        if ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1" {
            NSLog("Tiled: [DEBUG-obs] notification %@ matched NO handle (%d elements)",
                  notification, elements.count)
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

    /// Geometry membership of a window's last read frame among the app's
    /// listed windows — never element identity: after a display teardown
    /// a held element stops comparing equal to the app's fresh reference
    /// for the same window, but the frame is stable. Tolerates the
    /// rounding-level drift between reads (`roundingTolerance`); exact
    /// frame identity would condemn a window its app rounded or settled
    /// after the baseline was refreshed. True: a listed
    /// frame matches. False: the app answered and no listed frame
    /// matches — every listed frame read (or the app listed nothing).
    /// Nil: undeterminable — no baseline was ever read, or some listed
    /// frame could not be read (during the teardown listed windows'
    /// frame reads fail too, so membership is a maybe, never a death).
    static func appWindowMatch(
        baseline: CGRect?, listedFrames: [CGRect?]
    ) -> Bool? {
        guard let baseline else { return nil }
        let readFrames = listedFrames.compactMap { $0 }
        if readFrames.contains(where: {
            framesClose($0, baseline, tolerance: roundingTolerance)
        }) {
            return true
        }
        if listedFrames.isEmpty || readFrames.count == listedFrames.count {
            return false
        }
        return nil
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
    private static func frame(of element: AXUIElement) -> CGRect? {
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

    /// Sets position and size. `nsFrame` uses AppKit global coordinates
    /// (bottom-left origin); converted to AX top-left coordinates
    /// internally, the space the two write messages speak.
    ///
    /// The pair's life — the pre-write snapshot, the write order, the
    /// retries, and the put-back when only one message lands — is
    /// `AXWrite.pushFrame`, the same policy the test fake drives, so the
    /// half-apply restore is pinned end-to-end and not just here.
    @discardableResult
    private static func setFrame(_ element: AXUIElement, to nsFrame: CGRect) -> Bool {
        // Same reasoning as the read path: with no screen there is no
        // coordinate space to convert into, so refuse the write rather
        // than place the window at a guessed position. Marshalling is
        // verified up front too: a frame whose values cannot even be
        // built must not half-push.
        guard let primaryTop = NSScreen.screens.first?.frame.maxY else { return false }
        let targetSize = CGSize(width: nsFrame.width, height: nsFrame.height)
        guard
            let sizeValue = sizeValue(targetSize),
            let positionValue = pointValue(axTopLeft(of: nsFrame, primaryTop: primaryTop))
        else { return false }

        let error = AXWrite.pushFrame(
            position: positionValue, size: sizeValue,
            readPosition: { readAXValue(element, positionAttribute) },
            readSize: { readAXValue(element, sizeAttribute) },
            writePosition: {
                AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, $0)
            },
            writeSize: {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, $0)
            })
        if let error, ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1" {
            NSLog("Tiled: setFrame failed after retries (error %d)", error.rawValue)
        }
        return error == nil
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

        /// Whether a failed write pair needs the pre-write frame put
        /// back. The two messages are one logical push: whenever the
        /// pair failed after landing anything, the caller reads a
        /// refusal and rolls its state back, so the screen has to
        /// follow. Exactly one message landed is the half-moved window
        /// the README forbids; both landing on different attempts while
        /// the pair still fails leaves the same disagreement in a
        /// fuller frame. Nothing landed is already left alone, and a
        /// pair that landed both on one attempt succeeded.
        static func needsRestore(
            positionLanded: Bool, sizeLanded: Bool, failed: Bool
        ) -> Bool {
            failed && (positionLanded || sizeLanded)
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

        /// Pushes a frame as the write pair — position, then size — and
        /// puts the window back whenever the pair half-applied.
        ///
        /// Position is written BEFORE size: AX size-sets anchor the
        /// window's top-left at its *current* position, so sizing first
        /// can push a bottom window past the screen bottom, where AppKit
        /// silently clamps the height and the later position write can't
        /// undo it. Anchoring at the target top-left (always inside the
        /// visible frame) never clamps.
        ///
        /// The pair retries as a unit: position writes are idempotent, so
        /// a retry after a partial application (position landed, size hit
        /// a busy app) just rewrites both, never a half-moved window. But
        /// an app can refuse one attribute on every attempt while the
        /// other lands, and then the window is left half-applied — the
        /// README promises a refusing app's window is left alone, not
        /// half-moved with state believing nothing happened. Both values
        /// are therefore snapshotted before the first message and a
        /// failed pair is put back whole (see `needsRestore`).
        ///
        /// The values are the attributes' own representations (AX
        /// top-left position and size for the live adapter; whatever the
        /// caller reads back through `read*` is what `write*` receives).
        static func pushFrame<PositionValue, SizeValue>(
            position: PositionValue, size: SizeValue,
            readPosition: () -> PositionValue?, readSize: () -> SizeValue?,
            writePosition: (PositionValue) -> AXError,
            writeSize: (SizeValue) -> AXError,
            sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        ) -> AXError? {
            let previousPosition = readPosition()
            let previousSize = readSize()
            var positionLanded = false
            var sizeLanded = false
            var lastError: AXError = .success
            let error = retrying(operation: {
                let positionResult = writePosition(position)
                if positionResult == .success { positionLanded = true }
                let sizeResult = writeSize(size)
                if sizeResult == .success { sizeLanded = true }
                guard positionResult == .success, sizeResult == .success else {
                    // Report whichever write failed so the retry policy can
                    // judge it; when both failed, either is a valid cause.
                    lastError = positionResult == .success ? sizeResult : positionResult
                    return lastError
                }
                return .success
            }, sleep: sleep)
            if needsRestore(
                positionLanded: positionLanded, sizeLanded: sizeLanded, failed: error != nil)
            {
                // Best effort: if even a put-back write is refused, the
                // window is where the app left it and the refusal is
                // still reported, so screen and state agree on the
                // outcome either way. Both values are written back —
                // the untouched half is reasserted, never assumed.
                if let previousPosition { _ = writePosition(previousPosition) }
                if let previousSize { _ = writeSize(previousSize) }
            }
            return error
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
        mutating func forget(key: UInt, pid: pid_t) {
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

    private static func pointValue(_ p: CGPoint) -> AXValue? {
        var value = p
        return AXValueCreate(pointType, &value)
    }

    private static func sizeValue(_ s: CGSize) -> AXValue? {
        var value = s
        return AXValueCreate(sizeType, &value)
    }

    private static func readPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
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
