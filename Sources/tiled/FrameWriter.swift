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
        /// canvas is marked stale for the swipe back. Not a failure: the
        /// write's intent stands and reconciles when the canvas becomes
        /// visible (see `stands`).
        case deferredOffSpace
        /// The gateway refused the write.
        case refused

        /// Whether the write's intent stands: it happened, was already
        /// correct, or was deferred off-Space (and reconciles when the
        /// canvas becomes visible). Only a gateway refusal is a failure.
        /// The one reading every push path shares, so a deferral cannot
        /// mean one thing to a placement and another to a reflow.
        var stands: Bool { self != .refused }
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
    /// Drops an expectation armed for a write the gateway then refused.
    /// Without this a pending convergence check judges a frame that never
    /// landed and can roll the window back.
    private let cancelExpected: (WindowID) -> Void
    /// Seeds the tracker's diff baseline for a write that lands nowhere:
    /// a deferral, a no-op skip, or a refusal. None of them arms an echo
    /// expectation, so without this a later one-tick drag diffs against a
    /// stale frame and is dropped.
    private let seedBaseline: (WindowID, CGRect) -> Void
    private let scheduleCheck: (WindowID, TilingSpaceKey) -> Void
    private let log: (String) -> Void

    init(
        gateway: WindowGateway,
        isVisible: @escaping (TilingSpaceKey) -> Bool,
        markStale: @escaping (TilingSpaceKey) -> Void,
        markExpected: @escaping (WindowID, CGRect) -> Void,
        cancelExpected: @escaping (WindowID) -> Void,
        seedBaseline: @escaping (WindowID, CGRect) -> Void,
        scheduleCheck: @escaping (WindowID, TilingSpaceKey) -> Void,
        log: @escaping (String) -> Void
    ) {
        self.gateway = gateway
        self.isVisible = isVisible
        self.markStale = markStale
        self.markExpected = markExpected
        self.cancelExpected = cancelExpected
        self.seedBaseline = seedBaseline
        self.scheduleCheck = scheduleCheck
        self.log = log
    }

    /// Writes one window's target frame under the shared policy: a
    /// target the window already holds is skipped (writing it would
    /// draw no echo, and a marked expectation that never converges
    /// reads as a silent ignore); otherwise the expectation is armed
    /// before the write, and the declared check is scheduled only when
    /// the gateway accepted the write. `bounds` is the canvas's one
    /// visible frame, the frame the target derived from: a clamped write
    /// is repinned against it, never against the window's own frame.
    @discardableResult
    func write(
        _ id: WindowID, handle: WindowHandle, to target: CGRect,
        bounds: CGRect, on space: TilingSpaceKey, check: Check
    ) -> Result {
        // A write to a canvas the user cannot see waits for the swipe
        // back: sizing an off-Space window can pull it onto the visible
        // Space. The mark re-asserts the canvas later.
        guard isVisible(space) else {
            markStale(space)
            // The swipe back reasserts onto this target, so the baseline
            // claims it now: the first drag after the return measures
            // from the frame the canvas will write.
            seedBaseline(id, target)
            log("write win\(id) deferred off-Space")
            return .deferredOffSpace
        }
        // No-op writes are skipped, not pushed: the app changes
        // nothing and emits no echo, so a marked expectation here
        // would never converge and the late check would misread an
        // already-correct window.
        let liveBefore = gateway.frame(of: handle)
        if let live = liveBefore,
            DragTracker.framesClose(live, target, tolerance: DragTracker.noOpWriteTolerance)
        {
            seedBaseline(id, target)
            log("write win\(id) no-op skip target=\(target)")
            return .skippedNoOp
        }
        markExpected(id, target)
        guard gateway.setFrame(handle, to: target) else {
            // The expectation armed above must not outlive a refusal: a
            // pending convergence check would see the silent target and
            // roll back a window that never moved there. Reset the diff
            // baseline to the frame the gateway still reports, so an
            // immediate short drag is measured against reality.
            cancelExpected(id)
            seedBaseline(id, gateway.frame(of: handle) ?? liveBefore ?? target)
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
                applied: applied, target: target, bounds: bounds)
        {
            guard gateway.setFrame(handle, to: repinned) else {
                // The repair is a second expected write, not a side effect.
                // If the app refuses it the window still holds `applied`, so
                // cancel the target expectation, reseed the drag baseline
                // from the frame that actually landed, and fail the whole
                // write: a caller must not roll the placement forward as if
                // the repinned frame reached the screen.
                cancelExpected(id)
                seedBaseline(id, gateway.frame(of: handle) ?? applied)
                log("write win\(id) clamp repair refused target=\(repinned)")
                return .refused
            }
            markExpected(id, repinned)
            log("write win\(id) clamped at \(applied); repinned \(repinned)")
        }
        if case .rollback = check { scheduleCheck(id, space) }
        log("write win\(id) target=\(target)")
        return .written
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
