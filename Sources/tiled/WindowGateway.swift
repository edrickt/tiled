import CoreGraphics

/// Opaque reference to a window under management.
///
/// Handles are issued by the `WindowGateway` (one per live window, stable
/// across calls) and never forged: the controller maps them to occupancy,
/// pre-tile frames, and undo snapshots without ever seeing the underlying
/// AX element. `Hashable` so records key on handles directly - no CF
/// identity scans outside the live adapter.
struct WindowHandle: Hashable {
    let id: Int
}

/// Liveness of a window, as far as the gateway can tell.
enum Liveness {
    case alive
    /// The window is gone (closed, app quit): safe to prune.
    case dead
    /// Unknowable right now - the app was too busy to answer the probe.
    /// Treated as alive by every caller: pruning on a maybe would drop a
    /// live window from management, and the next real interaction re-probes.
    case unknown
}

/// The single seam between Tiled and the macOS Accessibility framework.
///
/// Everything the product needs from AX - focus, geometry, liveness,
/// observation, activation, and permission state - goes through here.
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
    /// `.dead` once the window is closed or its app quit; `.unknown`
    /// when the app was too busy to answer (never treated as dead).
    func liveness(of handle: WindowHandle) -> Liveness
    /// Calls `onChange` on resize/move. Dedupes repeat registrations.
    func observe(_ handle: WindowHandle, onChange: @escaping () -> Void)
    /// Brings the window forward without disturbing layout.
    func focus(_ handle: WindowHandle)
    /// Owning app's display name, for user-visible messages.
    func appName(of handle: WindowHandle) -> String?
    /// Accessibility permission state (process-wide).
    var isTrusted: Bool { get }
    /// Registers the app with TCC's Accessibility list - no dialog. An
    /// app that never issues this call may not appear in System
    /// Settings' list at all, leaving only the manual "+" path. Idempotent.
    func registerAccessibilityInterest()
}
