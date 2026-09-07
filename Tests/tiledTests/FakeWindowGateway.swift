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
    /// Whether `focus` makes `focusedWindow` return the focused handle.
    /// The real adapter only requests activation: the system may ignore
    /// it, and the next focus query answers with whatever actually has
    /// focus. Off, focus requests are recorded but the environment keeps
    /// its own focus (the fidelity mode for that divergence).
    var focusChangesFocused = true
    /// The frame a successful write actually applies. Real apps can
    /// clamp or round the requested rect while still reporting success,
    /// so the live frame can differ from the target. Identity by default.
    var writtenFrame: (WindowHandle, CGRect) -> CGRect = { _, target in target }

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
    /// Focus requests issued, in order: tests assert post-swap refocus.
    private(set) var focusCalls: [WindowHandle] = []

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
        window.frame = writtenFrame(handle, frame)
        windows[handle] = window
        return true
    }

    /// Handles whose liveness probe reports unknown (a busy app that
    /// cannot answer the probe): alive for every other purpose, never
    /// pruned.
    var busy: Set<WindowHandle> = []

    func liveness(of handle: WindowHandle) -> Liveness {
        guard let window = windows[handle] else { return .dead }
        if !window.alive { return .dead }
        return busy.contains(handle) ? .unknown : .alive
    }

    func observe(_ handle: WindowHandle, onChange: @escaping () -> Void) {
        changeHandlers[handle] = onChange
    }

    func focus(_ handle: WindowHandle) {
        focusCalls.append(handle)
        if focusChangesFocused { focused = handle }
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
