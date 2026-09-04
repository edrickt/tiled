import CoreGraphics

/// Opaque reference to a window under management.
///
/// Handles are issued by the `WindowGateway` (one per live window, stable
/// across calls) and never forged: the controller maps them to occupancy,
/// pre-tile frames, and undo snapshots without ever seeing the underlying
/// AX element. `Hashable` so records key on handles directly — no CF
/// identity scans outside the live adapter.
struct WindowHandle: Hashable {
    let id: Int
}

/// The single seam between tiled and the macOS Accessibility framework.
///
/// Everything the product needs from AX — focus, geometry, liveness,
/// observation, activation, and permission state — goes through here.
/// `LiveWindowGateway` is the production adapter; tests substitute an
/// in-memory fake. Two adapters justify the seam.
protocol WindowGateway: AnyObject {
    /// The currently focused window, if any.
    func focusedWindow() -> WindowHandle?
    /// Frame in AppKit global coordinates (bottom-left origin).
    func frame(of handle: WindowHandle) -> CGRect?
    /// Moves and resizes; false when the app refused.
    @discardableResult
    func setFrame(_ handle: WindowHandle, to frame: CGRect) -> Bool
    /// False once the window is closed or its app quit.
    func isAlive(_ handle: WindowHandle) -> Bool
    /// Calls `onChange` on resize/move. Dedupes repeat registrations.
    func observe(_ handle: WindowHandle, onChange: @escaping () -> Void)
    /// Brings the window forward without disturbing layout.
    func focus(_ handle: WindowHandle)
    /// Owning app's display name, for user-visible messages.
    func appName(of handle: WindowHandle) -> String?
    /// Accessibility permission state (process-wide).
    var isTrusted: Bool { get }
    /// Prompts in System Settings when untrusted; returns current state.
    @discardableResult
    func promptIfUntrusted() -> Bool
}
