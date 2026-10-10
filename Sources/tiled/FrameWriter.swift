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
    /// The glide stepper. Nil disables animation entirely: the write is
    /// instant, exactly as before the animator existed.
    private let animator: Animator?
    private let isVisible: (TilingSpaceKey) -> Bool
    /// The visible frame a target sits in: the boundary a clamped write
    /// must be pulled back inside (see `repinnedInsideBounds`).
    private let boundsOf: (CGRect) -> CGRect
    private let markStale: (TilingSpaceKey) -> Void
    private let markExpected: (WindowID, CGRect) -> Void
    private let scheduleCheck: (WindowID, TilingSpaceKey) -> Void
    /// Called when a glide's final write was refused. A glide ends within
    /// a pixel of its target, so the late convergence check would read a
    /// refused landing as converged; the landing result itself is the
    /// evidence, and the owner runs the standard refusal rollback.
    private let onLandingFailed: (WindowID, TilingSpaceKey) -> Void
    private let log: (String) -> Void

    init(
        gateway: WindowGateway,
        animator: Animator? = nil,
        isVisible: @escaping (TilingSpaceKey) -> Bool,
        boundsOf: @escaping (CGRect) -> CGRect,
        markStale: @escaping (TilingSpaceKey) -> Void,
        markExpected: @escaping (WindowID, CGRect) -> Void,
        scheduleCheck: @escaping (WindowID, TilingSpaceKey) -> Void,
        onLandingFailed: @escaping (WindowID, TilingSpaceKey) -> Void,
        log: @escaping (String) -> Void
    ) {
        self.gateway = gateway
        self.animator = animator
        self.isVisible = isVisible
        self.boundsOf = boundsOf
        self.markStale = markStale
        self.markExpected = markExpected
        self.scheduleCheck = scheduleCheck
        self.onLandingFailed = onLandingFailed
        self.log = log
    }

    /// Writes one window's target frame under the shared policy: a
    /// target the window already holds is skipped (writing it would
    /// draw no echo, and a marked expectation that never converges
    /// reads as a silent ignore); otherwise the expectation is armed
    /// before the write, and the declared check is scheduled only when
    /// the gateway accepted the write. The caller declares whether the
    /// move may glide: an enabled animator swaps the instant write for a
    /// glide over the same target and expectation, while a declared
    /// non-animated write (display reassert, failure cleanup) lands
    /// instantly even with animation on. The glide's landing re-enters
    /// this same policy, so the final frame is classified exactly like
    /// an instant write.
    @discardableResult
    func write(
        _ id: WindowID, handle: WindowHandle, to target: CGRect,
        on space: TilingSpaceKey, check: Check, animated: Bool
    ) -> Result {
        write(
            id, handle: handle, to: target, on: space, check: check,
            animated: animated, allowNoOpSkip: true)
    }

    @discardableResult
    private func write(
        _ id: WindowID, handle: WindowHandle, to target: CGRect,
        on space: TilingSpaceKey, check: Check,
        animated: Bool, allowNoOpSkip: Bool
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
        // already-correct window. A glide's landing opts out: the glide
        // was aiming there, and the screen must end exactly on target.
        let live = gateway.frame(of: handle)
        if allowNoOpSkip, let live,
            DragTracker.close(live, target, tolerance: DragTracker.noOpWriteTolerance)
        {
            log("write win\(id) no-op skip target=\(target)")
            return .skippedNoOp
        }
        // Arm the expectation before the first frame moves: the echoes
        // of every step (and of the landing) must read as ours, not as
        // a user drag.
        markExpected(id, target)
        if animated, let animator, animator.isAnimating, let live {
            // Tiled-driven animation: the first step is synchronous, so
            // a refusal fails exactly like the instant path. The check
            // is scheduled now, when responsibility is taken, so a glide
            // the hand later cancels cannot dodge the silent-ignore
            // verification.
            let accepted = animator.play(
                id: id, handle: handle, from: live, to: target
            ) { [self] in
                self.land(id, handle: handle, to: target, on: space, check: check)
            }
            guard accepted else {
                log("write win\(id) refused gliding first step target=\(target)")
                return .refused
            }
            scheduleDeclaredCheck(id, on: space, check: check)
            log("write win\(id) gliding target=\(target)")
            return .written
        }
        return writeImmediately(id, handle: handle, to: target, on: space, check: check)
    }

    /// The glide's final write: the exact target through the instant
    /// policy (clamp repin included), then the landing verdict. A refused
    /// final write leaves the window off-target, and because the glide
    /// carried it to within a pixel of the target the late convergence
    /// check would misread the landing as converged: the owner's refusal
    /// rollback runs instead. A deferred landing (the canvas went hidden
    /// mid-glide) is the off-Space policy, not a failure; a clamp repin is
    /// a normal success.
    private func land(
        _ id: WindowID, handle: WindowHandle, to target: CGRect,
        on space: TilingSpaceKey, check: Check
    ) {
        let result = write(
            id, handle: handle, to: target, on: space, check: check,
            animated: false, allowNoOpSkip: false)
        guard result == .refused else { return }
        log("write win\(id) landing refused target=\(target)")
        onLandingFailed(id, space)
    }

    /// The instant path: one gateway write plus the minimum-size clamp
    /// repair and the declared convergence check. The animated glide's
    /// landing runs this too, so the final write keeps the write
    /// policy's classification exactly. Any in-flight glide for the
    /// window is superseded first: an instant write (a display reassert,
    /// a failure rollback) must land now, and a stale step must never
    /// overwrite the frame it snapped.
    @discardableResult
    private func writeImmediately(
        _ id: WindowID, handle: WindowHandle, to target: CGRect,
        on space: TilingSpaceKey, check: Check
    ) -> Result {
        animator?.cancel(handle: handle)
        guard gateway.setFrame(handle, to: target) else {
            log("write win\(id) refused target=\(target)")
            return .refused
        }
        // Minimum-size clamp: an app that cannot go below its floor lands
        // the position exactly and snaps only the size (probed on live
        // AX: target (1300, 300, 150, 350) applied (1300, 300, 400, 350)),
        // so the window keeps its origin and grows away from it - past
        // the screen edge when the target hugged one. Repin the clamped
        // frame inside its bounds: it keeps its floor size and simply
        // stops shrinking at the screen edge, never off it.
        if let applied = gateway.frame(of: handle),
            let repinned = Self.repinnedInsideBounds(
                applied: applied, target: target, bounds: boundsOf(target))
        {
            gateway.setFrame(handle, to: repinned)
            markExpected(id, repinned)
            log("write win\(id) clamped at \(applied); repinned \(repinned)")
        }
        scheduleDeclaredCheck(id, on: space, check: check)
        log("write win\(id) target=\(target)")
        return .written
    }

    /// Schedules the declared convergence check, if the write declared
    /// one. One spelling, so the animated and instant paths cannot drift.
    private func scheduleDeclaredCheck(
        _ id: WindowID, on space: TilingSpaceKey, check: Check
    ) {
        if case .rollback = check { scheduleCheck(id, space) }
    }

    /// The frame to rewrite after an app clamped a write, or nil when
    /// the write needs no repair.
    ///
    /// The clamp signature is a size the app refused: a frame it applied
    /// as requested is left alone, so a target that legitimately runs
    /// past the bounds (a pre-tile restore straddling displays) keeps
    /// the placement the user gave it. A clamped frame is pulled back by
    /// the edge that escaped, so the bounds edge its target hugged stays
    /// held and the window stops at its floor size in place.
    static func repinnedInsideBounds(
        applied: CGRect, target: CGRect, bounds: CGRect
    ) -> CGRect? {
        let tolerance = DragTracker.noOpWriteTolerance
        guard abs(applied.width - target.width) > tolerance
            || abs(applied.height - target.height) > tolerance
        else { return nil }
        func shift(
            appliedMin: CGFloat, appliedMax: CGFloat,
            boundsMin: CGFloat, boundsMax: CGFloat
        ) -> CGFloat {
            if appliedMax > boundsMax + tolerance { return boundsMax - appliedMax }
            if appliedMin < boundsMin - tolerance { return boundsMin - appliedMin }
            return 0
        }
        let dx = shift(
            appliedMin: applied.minX, appliedMax: applied.maxX,
            boundsMin: bounds.minX, boundsMax: bounds.maxX)
        let dy = shift(
            appliedMin: applied.minY, appliedMax: applied.maxY,
            boundsMin: bounds.minY, boundsMax: bounds.maxY)
        guard dx != 0 || dy != 0 else { return nil }
        return applied.offsetBy(dx: dx, dy: dy)
    }
}
