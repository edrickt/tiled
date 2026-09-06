import AppKit
import ApplicationServices

/// Thin wrapper over the Accessibility API: permissions, focused window,
/// frame read/write. All coordinate conversion lives here.
/// The production `WindowGateway`: macOS Accessibility, behind the seam.
///
/// Owns every framework detail the controller must never see: AX element
/// identity, AppKit/AX coordinate conversion, AXObserver registration
/// with its refcon plumbing, and app activation. Issues one stable
/// `WindowHandle` per live window so the controller keys records on
/// handles, never on `AXUIElement`s.
final class LiveWindowGateway: WindowGateway {
    /// The single live instance (AXObserver callbacks carry no user data).
    static weak var active: LiveWindowGateway?

    private var nextHandleID = 1
    /// Live element per issued handle. Entries are removed when the
    /// window dies (probed via `isAlive`) so handles never dangle.
    private var elements: [WindowHandle: AXUIElement] = [:]
    private var pids: [WindowHandle: pid_t] = [:]
    /// Observer per pid; registrations outlive untiled records and can
    /// never be unregistered, so they are created once and shared.
    private var observers: [pid_t: AXObserver] = [:]
    /// Handles with notifications registered (CFHash keyed; dedupe, since
    /// re-tiling must not double-register).
    private var observedElements: Set<UInt> = []
    /// Change handler per observed handle.
    private var changeHandlers: [WindowHandle: () -> Void] = [:]

    init() {
        LiveWindowGateway.active = self
    }

    // MARK: WindowGateway

    func focusedWindow() -> WindowHandle? {
        guard let (element, pid) = Self.focusedAXWindow() else { return nil }
        return handle(for: element, pid: pid)
    }

    func frame(of handle: WindowHandle) -> CGRect? {
        guard let element = elements[handle] else { return nil }
        return Self.frame(of: element)
    }

    @discardableResult
    func setFrame(_ handle: WindowHandle, to frame: CGRect) -> Bool {
        guard let element = elements[handle] else { return false }
        return Self.setFrame(element, to: frame)
    }

    func isAlive(_ handle: WindowHandle) -> Bool {
        guard let element = elements[handle] else { return false }
        let alive = Self.isAlive(element)
        if !alive {
            elements[handle] = nil
            pids[handle] = nil
            changeHandlers[handle] = nil
        }
        return alive
    }

    func observe(_ handle: WindowHandle, onChange: @escaping () -> Void) {
        guard let element = elements[handle], let pid = pids[handle] else { return }
        changeHandlers[handle] = onChange
        let key = UInt(CFHash(element))
        guard !observedElements.contains(key) else { return }
        observedElements.insert(key)

        let observer: AXObserver
        if let existing = observers[pid] {
            observer = existing
        } else {
            var created: AXObserver?
            let result = AXObserverCreate(
                pid, Self.observerCallback, &created)
            guard result == .success, let newObserver = created else {
                observedElements.remove(key)
                NSLog(
                    "tiled: AXObserverCreate failed for pid %d (%d)", pid,
                    result.rawValue)
                return
            }
            observer = newObserver
            observers[pid] = observer
            CFRunLoopAddSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer),
                CFRunLoopMode.commonModes)
        }

        for name in [kAXWindowResizedNotification, kAXWindowMovedNotification] {
            let status = AXObserverAddNotification(
                observer, element, name as CFString, nil)
            if status != .success {
                NSLog(
                    "tiled: could not observe %@ on pid %d (%d)", name as String, pid,
                    status.rawValue)
            }
        }
    }

    func focus(_ handle: WindowHandle) {
        guard let element = elements[handle], let pid = pids[handle] else { return }
        AXUIElementSetAttributeValue(
            element, kAXMainAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    func appName(of handle: WindowHandle) -> String? {
        pids[handle].flatMap {
            NSRunningApplication(processIdentifier: $0)?.localizedName
        }
    }

    var isTrusted: Bool { Self.isTrusted }

    func registerAccessibilityInterest() {
        // Prompt:false — the explainer window asks in the product's own
        // words; this call only puts tiled on the System Settings list
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
        return handle
    }

    private static let observerCallback: AXObserverCallback = {
        _, element, notification, _ in
        guard let gateway = LiveWindowGateway.active else { return }
        gateway.handleAXNotification(
            notification: notification as String, element: element)
    }

    /// Routes an AX notification to the registered handler of whichever
    /// handle owns `element`. Element identity is resolved here so the
    /// controller never touches `AXUIElement` (the old refcon-id scheme
    /// went stale for the same reason: registrations outlive records).
    private func handleAXNotification(notification: String, element: AXUIElement) {
        for (handle, registered) in elements
        where CFEqual(registered, element) {
            changeHandlers[handle]?()
            return
        }
    }
    // MARK: Permissions

    /// Fresh trust probe: `AXIsProcessTrusted()` caches per-process, so a
    /// poll built on it returns `false` forever once it has seen `false` —
    /// the grant would never be noticed and the permission window would
    /// linger. The WithOptions variant re-queries the TCC daemon, so the
    /// launch poll sees the flip while running and the window closes.
    private static var isTrusted: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    // MARK: Focused window

    private static func focusedAXWindow() -> (element: AXUIElement, pid: pid_t)? {
        let systemWide = AXUIElementCreateSystemWide()

        var appValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedApplicationAttribute as CFString, &appValue)
                == .success,
            let rawApp = appValue,
            CFGetTypeID(rawApp) == AXUIElementGetTypeID()
        else { return nil }
        let appElement = rawApp as! AXUIElement

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

    /// Cheap liveness probe: the element is considered gone when its position
    /// attribute can no longer be read (window closed, app quit).
    private static func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &value) == .success
    }

    // MARK: Geometry

    /// Frame of a window in AppKit global coordinates (bottom-left origin).
    /// The AX position attribute is the top-left corner in top-left-origin
    /// global coordinates, so the y axis must be converted here — everything
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

        let positionOK = AXUIElementSetAttributeValue(
            element, kAXPositionAttribute as CFString, positionValue) == .success
        let sizeOK = AXUIElementSetAttributeValue(
            element, kAXSizeAttribute as CFString, sizeValue) == .success
        return sizeOK && positionOK
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
