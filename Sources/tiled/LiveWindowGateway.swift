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

    /// Per-message timeout (seconds) applied to every element we touch.
    /// The AX default is ~6s per call, and a beachballing app would block
    /// the hotkey path that long on every read or write — a swap loop
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

    func liveness(of handle: WindowHandle) -> Liveness {
        guard let element = elements[handle] else { return .dead }
        switch Self.probe(element) {
        case .alive:
            return .alive
        case .unknown:
            // A busy app fails the probe without being gone: keep the
            // element registered so the window never falls out of
            // management on a maybe.
            return .unknown
        case .dead:
            elements[handle] = nil
            pids[handle] = nil
            changeHandlers[handle] = nil
            return .dead
        }
    }

    func observe(_ handle: WindowHandle, onChange: @escaping () -> Void) {
        guard let element = elements[handle], let pid = pids[handle] else { return }
        changeHandlers[handle] = onChange
        let key = UInt(CFHash(element))
        if ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1" {
            NSLog("Tiled: [DEBUG-obs] observe win%d pid=%d key=%lu already=%d",
                  handle.id, pid, key, observedElements.contains(key) ? 1 : 0)
        }
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
            if ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1" {
                NSLog("Tiled: [DEBUG-obs] add %@ on pid %d (%d)", name as String, pid, status.rawValue)
            }
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

    /// Liveness probe outcome for one element.
    private enum Probe { case alive, dead, unknown }

    /// Cheap liveness probe: read the position attribute. A read that
    /// names a gone element (invalid element, no window) is dead; a read
    /// the app could not complete right now (`.cannotComplete` — busy,
    /// beachballing, mid-launch) is unknown, never dead: dropping a live
    /// window on a transient failure would untile it on the next prune.
    private static func probe(_ element: AXUIElement) -> Probe {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &value)
        {
        case .success: return .alive
        case .cannotComplete: return .unknown
        default: return .dead
        }
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

        // The write pair retries as a unit: position writes are idempotent,
        // so a retry after a partial application (position landed, size hit
        // a busy app) just rewrites both — never a half-moved window.
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
    /// refused (permanent — retrying changes nothing) or because its main
    /// thread was momentarily unable to service the message (`.cannotComplete`:
    /// busy, beachballing, mid-launch — the classic flaky swap). Only the
    /// transient class retries, with a short backoff, on the calling
    /// thread: hotkey handling already blocks the main runloop on the AX
    /// round-trip itself, and an asynchronous retry would break the
    /// executor's synchronous all-or-nothing writes.
    enum AXWrite {
        /// The error class worth retrying: the app could not complete the
        /// request right now. Everything else — unsupported attribute,
        /// disabled API, invalid element — is a permanent refusal.
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
        /// the last error (retryable or not — callers only distinguish
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
