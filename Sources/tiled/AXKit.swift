import AppKit
import ApplicationServices

/// Thin wrapper over the Accessibility API: permissions, focused window,
/// frame read/write. All coordinate conversion lives here.
enum AXKit {
    // MARK: Permissions

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user (System Settings > Accessibility) if not yet trusted.
    /// Returns the current trust state.
    @discardableResult
    static func promptIfUntrusted() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: Focused window

    static func focusedWindow() -> (element: AXUIElement, pid: pid_t)? {
        let systemWide = AXUIElementCreateSystemWide()

        var appValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedApplicationAttribute as CFString, &appValue)
                == .success,
            let app = appValue
        else { return nil }
        let appElement = app as! AXUIElement

        var pid: pid_t = 0
        guard AXUIElementGetPid(appElement, &pid) == .success else { return nil }

        var winValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &winValue)
                == .success,
            let win = winValue
        else { return nil }

        return (win as! AXUIElement, pid)
    }

    // MARK: Liveness

    /// Cheap liveness probe: the element is considered gone when its position
    /// attribute can no longer be read (window closed, app quit).
    static func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &value) == .success
    }

    // MARK: Geometry

    /// Frame of a window in AppKit global coordinates (bottom-left origin).
    static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let origin = readPoint(element, positionAttribute),
            let size = readSize(element, sizeAttribute)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Sets position and size. `nsFrame` uses AppKit global coordinates
    /// (bottom-left origin); converted to AX top-left coordinates internally.
    @discardableResult
    static func setFrame(_ element: AXUIElement, to nsFrame: CGRect) -> Bool {
        guard
            let sizeValue = sizeValue(CGSize(width: nsFrame.width, height: nsFrame.height)),
            let positionValue = pointValue(axTopLeft(of: nsFrame))
        else { return false }

        let sizeOK = AXUIElementSetAttributeValue(
            element, kAXSizeAttribute as CFString, sizeValue) == .success
        let positionOK = AXUIElementSetAttributeValue(
            element, kAXPositionAttribute as CFString, positionValue) == .success
        return sizeOK && positionOK
    }

    /// Converts an AppKit global frame (bottom-left origin) to the AX top-left
    /// point. AX y coordinates count down from the top of the primary screen.
    private static func axTopLeft(of nsFrame: CGRect) -> CGPoint {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? nsFrame.maxY
        return CGPoint(x: nsFrame.minX, y: primaryTop - nsFrame.maxY)
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
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let axValue = value
        else { return nil }
        var point = CGPoint()
        guard AXValueGetValue(axValue as! AXValue, pointType, &point) else { return nil }
        return point
    }

    private static func readSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let axValue = value
        else { return nil }
        var size = CGSize()
        guard AXValueGetValue(axValue as! AXValue, sizeType, &size) else { return nil }
        return size
    }
}
