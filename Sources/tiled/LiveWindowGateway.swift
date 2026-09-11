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
    /// Last successfully-read frame per handle: the geometry a death
    /// confirmation matches against. Window element identity is useless
    /// for that check — after a display teardown a held element stops
    /// comparing equal (CFEqual) to the app's fresh reference for the
    /// same window (observed on live AX: `listed=no` while the app
    /// listed every window) — but the window's frame is stable.
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
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
        }
        releaseFocusObserver()
    }

    // MARK: WindowGateway

    func focusedWindow() -> WindowHandle? {
        guard let (element, pid) = Self.focusedAXWindow() else { return nil }
        return handle(for: element, pid: pid)
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

    func liveness(of handle: WindowHandle) -> Liveness {
        guard let element = elements[handle], let pid = pids[handle] else { return .dead }
        var value: CFTypeRef?
        let probeError = AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &value)
        guard probeError != .success else { return .alive }
        // The probe failed — but a failure can be a transient. Across a
        // lid close/open, window-level probes fail (.invalidUIElement on
        // held refs, .attributeUnsupported on fresh refs) for LIVE
        // windows; the app element keeps answering and still lists them.
        // Death is therefore confirmed against the app's own window
        // list, never from the window probe alone.
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        var listRef: CFTypeRef?
        let listError = AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &listRef)
        let list = listRef as? [AXUIElement] ?? []
        // Geometry membership, not element identity: a listed window
        // whose frame matches the last read frame means the window is
        // alive. During the teardown listed windows' frame reads fail
        // too, so membership stays undeterminable — a maybe, never a
        // death. Absence is only confirmed when the app answers and at
        // least one listed frame reads and none matches.
        var match: Bool?
        if let cached = lastFrames[handle] {
            let readFrames = list.compactMap { Self.frame(of: $0) }
            if readFrames.contains(where: { Self.framesClose($0, cached) }) {
                match = true
            } else if list.isEmpty || readFrames.count == list.count {
                // Every listed frame read and none matched (or the app
                // lists nothing at all): the window is really gone.
                match = false
            }
            // Some listed frames unreadable: undeterminable — a maybe.
        }
        let verdict = Self.liveness(
            probeError: probeError, appWindowsError: listError, appWindowMatch: match)
        if ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1" {
            NSLog("Tiled: [DEBUG-lv] win handle %ld probe=%d appList err=%d count=%ld match=%@ → %@",
                  handle.id, probeError.rawValue, listError.rawValue,
                  list.count,
                  match.map { $0 ? "yes" : "no" } ?? "unknown",
                  verdict == .alive ? "alive" : verdict == .dead ? "dead" : "unknown")
        }
        if verdict == .dead {
            elements[handle] = nil
            pids[handle] = nil
            changeHandlers[handle] = nil
            lastFrames[handle] = nil
        }
        return verdict
    }

    /// Frames within a point of each other: the cached last-read frame
    /// and a fresh read of the same window differ only by rounding.
    private static func framesClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1
            && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    func observe(_ handle: WindowHandle, onChange: @escaping () -> Void) {
        guard let element = elements[handle], let pid = pids[handle] else { return }
        changeHandlers[handle] = onChange
        let key = UInt(CFHash(element))
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
        for name in [kAXWindowResizedNotification, kAXWindowMovedNotification] {
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
            changeHandlers[handle]?()
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
    /// quit), or the app answers and no listed window matches the
    /// window's last read frame. A frame match, or an undeterminable
    /// check (nil), stays unknown: a maybe never untiles.
    static func liveness(
        probeError: AXError, appWindowsError: AXError, appWindowMatch: Bool?
    ) -> Liveness {
        if probeError == .success { return .alive }
        if appWindowsError == .invalidUIElement { return .dead }
        if appWindowsError == .success, appWindowMatch == false { return .dead }
        return .unknown
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
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? (axOrigin.y + size.height)
        return appKitFrame(axOrigin: axOrigin, size: size, primaryTop: primaryTop)
    }

    /// Sets position and size. `nsFrame` uses AppKit global coordinates
    /// (bottom-left origin); converted to AX top-left coordinates internally.
    ///
    /// Position is written BEFORE size: AX size-sets anchor the window's
    /// top-left at its *current* position, so sizing first can push a bottom
    /// window past the screen bottom, where AppKit silently clamps the height
    /// and the later position write can't undo it. Anchoring at the target
    /// top-left (always inside the visible frame) never clamps.
    @discardableResult
    private static func setFrame(_ element: AXUIElement, to nsFrame: CGRect) -> Bool {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? nsFrame.maxY
        guard
            let sizeValue = sizeValue(CGSize(width: nsFrame.width, height: nsFrame.height)),
            let positionValue = pointValue(axTopLeft(of: nsFrame, primaryTop: primaryTop))
        else { return false }

        // The write pair retries as a unit: position writes are idempotent,
        // so a retry after a partial application (position landed, size hit
        // a busy app) just rewrites both, never a half-moved window.
        var lastError: AXError = .success
        let error = AXWrite.retrying {
            let positionResult = AXUIElementSetAttributeValue(
                element, kAXPositionAttribute as CFString, positionValue)
            let sizeResult = AXUIElementSetAttributeValue(
                element, kAXSizeAttribute as CFString, sizeValue)
            guard positionResult == .success, sizeResult == .success else {
                // Report whichever write failed so the retry policy can
                // judge it; when both failed, either is a valid cause.
                lastError = positionResult == .success ? sizeResult : positionResult
                return lastError
            }
            return .success
        }
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
    /// executor's synchronous all-or-nothing writes.
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

        /// Whether the element's change notifications are registered.
        func isObserved(key: UInt) -> Bool { registeredKeys[key] != nil }
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
