import CoreGraphics

/// Opaque reference to a window under management.
///
/// Handles are issued by the `WindowGateway` (one per live window, stable
/// across calls) and never forged: the controller maps them to occupancy,
/// pre-tile frames, and undo snapshots without ever seeing the underlying
/// AX element. `Hashable` so records key on handles directly; no CF
/// identity scans outside the live adapter.
struct WindowHandle: Hashable {
    let id: Int
}

/// Liveness of a window, as far as the gateway can tell.
enum Liveness {
    case alive
    /// The window is gone (closed, app quit): safe to prune.
    case dead
    /// Unknowable right now: the app was too busy to answer the probe.
    /// Treated as alive by every caller: pruning on a maybe would drop a
    /// live window from management, and the next real interaction re-probes.
    case unknown
}

/// The single seam between Tiled and the OS window layer.
///
/// Everything the product needs from the window server (focus, geometry,
/// liveness, observation, activation, permission state, and Mission
/// Control Space identity) goes through here. `LiveWindowGateway` is the
/// production adapter; tests substitute an in-memory fake. Two adapters
/// justify the seam.
protocol WindowGateway: AnyObject {
    /// The currently focused window, if any.
    func focusedWindow() -> WindowHandle?
    /// Frame in AppKit global coordinates (bottom-left origin).
    func frame(of handle: WindowHandle) -> CGRect?
    /// Every Space id the window server reports per display. Empty means
    /// "unknown": canvas pruning is skipped rather than guessed.
    var existingSpaceIDs: [CGDirectDisplayID: Set<SpaceID>] { get }
    /// Moves and resizes; false when the write did not land — no binding,
    /// an AX refusal, or a retryable failure exhausted. Only the last two
    /// are a refusal in the placement pipeline's sense.
    @discardableResult
    func setFrame(_ handle: WindowHandle, to frame: CGRect) -> Bool
    /// `.dead` once the window is closed or its app quit; `.unknown`
    /// when the app was too busy to answer (never treated as dead).
    func liveness(of handle: WindowHandle) -> Liveness
    /// Calls `onChange` on resize/move, and `onDestroyed` when the window
    /// element itself is destroyed: the OS's own report that the window
    /// is gone, which lets the slot release at once instead of waiting
    /// for the periodic death check. One call registers both, because
    /// they always travel together and the adapter dedupes per element.
    /// Repeats replace the handlers; they never double-register.
    func observe(
        _ handle: WindowHandle, onChange: @escaping () -> Void,
        onDestroyed: @escaping () -> Void)
    /// Calls `onChange` when the frontmost application's focused window
    /// changes: the keyboard-focus move that picks which display's layout
    /// the status icon depicts. Replaces any previous handler. The live
    /// adapter re-targets as applications activate; the fake exposes
    /// `simulateFocusChange` for tests.
    func observeFocusChanges(_ onChange: @escaping () -> Void)
    /// The Mission Control Space shown on `display` right now, or nil
    /// when the window server cannot say (a display-less environment,
    /// or a future OS without the private Space table). Nil keeps the
    /// old per-display behavior: one layout per display.
    func activeSpace(on display: CGDirectDisplayID) -> SpaceID?
    /// Calls `onChange` when the active Space changes on any display:
    /// the swipe that swaps which canvas is on screen. Replaces any
    /// previous handler. The live adapter observes the workspace
    /// notification; the fake exposes `simulateSpaceChange` for tests.
    func observeSpaceChanges(_ onChange: @escaping () -> Void)
    /// Calls `onCreated` with a fresh handle for every window the OS
    /// creates, in any app: the birth-sizing hook. Replaces any previous
    /// handler. The live adapter subscribes each running app (and future
    /// launches) to the window-creation notification; the fake exposes
    /// `simulateWindowCreated` for tests.
    func observeWindowCreations(_ onCreated: @escaping (WindowHandle) -> Void)
    /// Brings the window forward without disturbing layout.
    func focus(_ handle: WindowHandle)
    /// Raises the window above its siblings without focusing it: the
    /// z-order nicety that keeps a restored evictee below the survivors
    /// that grew into its cells. Best-effort; failures are non-fatal.
    func raise(_ handle: WindowHandle)
    /// Owning app's display name, for user-visible messages.
    func appName(of handle: WindowHandle) -> String?
    /// Accessibility permission state (process-wide).
    var isTrusted: Bool { get }
    /// Registers the app with TCC's Accessibility list: no dialog. An
    /// app that never issues this call may not appear in System
    /// Settings' list at all, leaving only the manual "+" path. Idempotent.
    func registerAccessibilityInterest()
    /// Releases the adapter's resources for a handle the controller has
    /// confirmed gone (a confirmed prune or an OS destroy report).
    /// Untile, evict, and drag-out do NOT release: a window that may
    /// come back through undo keeps its element so its frame can be
    /// restored. Stateless adapters need no implementation.
    func release(_ handle: WindowHandle)
}

extension WindowGateway {
    func release(_ handle: WindowHandle) {}
}


extension WindowGateway {
    /// Test doubles keep the old behavior: an empty inventory means no
    /// Space is known to be missing.
    var existingSpaceIDs: [CGDirectDisplayID: Set<SpaceID>] { [:] }
}
