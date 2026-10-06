import CoreGraphics

/// Owns the frame-write policy every push path shares: no-op skip,
/// off-Space deferral, echo marking, and the convergence check every
/// write must classify. Stateless: the owner injects the collaborators
/// that vary per context (visibility, echo bookkeeping, verification,
/// logging), so the policy lives in exactly one module.
struct FrameWriter {
    enum Result: Equatable {
        /// The gateway accepted the write.
        case written
        /// The live frame already matches the target: no write issued.
        case skippedNoOp
        /// The canvas is not the visible Space: no write issued, and the
        /// canvas is marked stale for the swipe back.
        case deferredOffSpace
        /// The gateway refused the write.
        case refused

        /// The write is on screen, or already correct: callers count
        /// both as a successful placement.
        var isAccepted: Bool { self == .written || self == .skippedNoOp }
    }

    /// What a silent ignore of this write means. Every write must
    /// classify itself, so skipping verification is a visible decision
    /// at the call site rather than an omission.
    enum Check {
        /// Schedule the late convergence check after a successful write.
        case rollback
        /// No convergence check: the caller owns verification for this
        /// write. Plan placements schedule per plan in `settle`;
        /// expansion has no rollback path yet and says so here.
        case none
    }

    private let gateway: WindowGateway
    private let isVisible: (TilingSpaceKey) -> Bool
    private let markStale: (TilingSpaceKey) -> Void
    private let markExpected: (WindowID, CGRect) -> Void
    private let scheduleCheck: (WindowID, TilingSpaceKey) -> Void
    private let log: (String) -> Void

    init(
        gateway: WindowGateway,
        isVisible: @escaping (TilingSpaceKey) -> Bool,
        markStale: @escaping (TilingSpaceKey) -> Void,
        markExpected: @escaping (WindowID, CGRect) -> Void,
        scheduleCheck: @escaping (WindowID, TilingSpaceKey) -> Void,
        log: @escaping (String) -> Void
    ) {
        self.gateway = gateway
        self.isVisible = isVisible
        self.markStale = markStale
        self.markExpected = markExpected
        self.scheduleCheck = scheduleCheck
        self.log = log
    }

    /// Writes one window's target frame under the shared policy: a
    /// target the window already holds is skipped (writing it would
    /// draw no echo, and a marked expectation that never converges
    /// reads as a silent ignore); otherwise the expectation is armed
    /// before the write, and the declared check is scheduled only when
    /// the gateway accepted the write.
    @discardableResult
    func write(
        _ id: WindowID, handle: WindowHandle, to target: CGRect,
        on space: TilingSpaceKey, check: Check
    ) -> Result {
        // A write to a canvas the user cannot see waits for the swipe
        // back: sizing an off-Space window can pull it onto the visible
        // Space. The mark re-asserts the canvas later.
        guard isVisible(space) else {
            markStale(space)
            log("write win\(id) deferred off-Space")
            return .deferredOffSpace
        }
        // No-op writes are skipped, not pushed: the app changes
        // nothing and emits no echo, so a marked expectation here
        // would never converge and the late check would misread an
        // already-correct window.
        if let live = gateway.frame(of: handle),
            DragTracker.close(live, target, tolerance: DragTracker.noOpWriteTolerance)
        {
            log("write win\(id) no-op skip target=\(target)")
            return .skippedNoOp
        }
        markExpected(id, target)
        guard gateway.setFrame(handle, to: target) else {
            log("write win\(id) refused target=\(target)")
            return .refused
        }
        if case .rollback = check { scheduleCheck(id, space) }
        log("write win\(id) target=\(target)")
        return .written
    }
}
