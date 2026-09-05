import CoreGraphics
@testable import tiled

/// In-memory `WindowGateway`: the second adapter behind the seam.
///
/// Windows are plain frames in a dictionary; observation handlers fire
/// synchronously via `simulateChange`. Refusals are scripted per handle
/// (`refuseFrames`), deaths via `kill`. No AX, no AppKit, no runloop.
final class FakeWindowGateway: WindowGateway {
    private var nextID = 1
    struct Window {
        var frame: CGRect
        var alive = true
        var refuseNextWrites = 0
        var appName: String?
    }
    private(set) var windows: [WindowHandle: Window] = [:]
    private var changeHandlers: [WindowHandle: () -> Void] = [:]
    /// Handles in issuance order (stable ids for tests).
    private(set) var issued: [WindowHandle] = []

    var isTrusted = true

    func registerAccessibilityInterest() {}
    /// Handles whose writes report success but never change the frame:
    /// the dominant real-world refusal shape (an app that ignores AX
    /// resizes while returning success).
    var silentIgnore: Set<WindowHandle> = []

    @discardableResult
    func addWindow(frame: CGRect, appName: String? = "TestApp") -> WindowHandle {
        let handle = WindowHandle(id: nextID)
        nextID += 1
        windows[handle] = Window(frame: frame, appName: appName)
        issued.append(handle)
        return handle
    }

    /// The fake has no focus model: tests declare the focused window.
    var focused: WindowHandle?

    // MARK: WindowGateway

    func focusedWindow() -> WindowHandle? {
        guard let focused, windows[focused]?.alive == true else { return nil }
        return focused
    }

    func frame(of handle: WindowHandle) -> CGRect? {
        guard let window = windows[handle], window.alive else { return nil }
        return window.frame
    }

    @discardableResult
    func setFrame(_ handle: WindowHandle, to frame: CGRect) -> Bool {
        guard var window = windows[handle], window.alive else { return false }
        if silentIgnore.contains(handle) { return true }
        if window.refuseNextWrites > 0 {
            window.refuseNextWrites -= 1
            windows[handle] = window
            return false
        }
        window.frame = frame
        windows[handle] = window
        return true
    }

    func isAlive(_ handle: WindowHandle) -> Bool {
        windows[handle]?.alive ?? false
    }

    func observe(_ handle: WindowHandle, onChange: @escaping () -> Void) {
        changeHandlers[handle] = onChange
    }

    func focus(_ handle: WindowHandle) {
        focused = handle
    }

    func appName(of handle: WindowHandle) -> String? {
        windows[handle]?.appName
    }

    // MARK: Test controls

    /// Moves the window as a user drag would, firing the change handler.
    func simulateChange(_ handle: WindowHandle, to frame: CGRect) {
        windows[handle]?.frame = frame
        changeHandlers[handle]?()
    }

    /// Moves without firing (asserts echo suppression absorbed it).
    func simulateSilentChange(_ handle: WindowHandle, to frame: CGRect) {
        windows[handle]?.frame = frame
    }

    func kill(_ handle: WindowHandle) {
        windows[handle]?.alive = false
    }

    func refuseNextWrites(_ handle: WindowHandle, count: Int = 1) {
        windows[handle]?.refuseNextWrites = count
    }

    func observedHandles() -> [WindowHandle] {
        Array(changeHandlers.keys)
    }
}
