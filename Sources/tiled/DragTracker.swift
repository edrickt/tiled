import CoreGraphics
import Foundation

/// Owns the live drag-resize loop (observe & compensate): gateway change
/// callbacks in, splitter moves and neighbor re-pushes out.
///
/// Previously interleaved with placement records inside TilingController;
/// the real bugs hid in how echo entries interacted with edge diffs, not
/// in either alone. Now the whole loop (echo suppression, edge
/// detection, splitter updates, apply coalescing) lives behind one
/// interface and is testable through it with a fake gateway.
///
/// Protocol: the controller feeds each gateway callback to
/// `handleChange`, and every rect the tracker computes via
/// `rect(for:in:)`; the dragged window's own edge is the source of truth
/// and is skipped on re-push so the tracker never fights an in-progress
/// native drag. Writes are bookkept as expected frames so our own echoes
/// don't recurse.
///
/// Edge drags resize only the dragged window while the button is down:
/// splitter fractions commit live, but the neighbor re-pushes wait for
/// mouse-up (`mouseLifted`, wired by the controller's global event
/// monitor). Resizing the tiles under a held button fights the drag and
/// rewrites frames the user is still steering; on release the whole
/// grid commits at once. A resize tick that trails the mouse-up (AX
/// streams the drag's final frame) re-arms the pending apply, and the
/// next mouse-up anywhere commits it.
///
/// Title-bar drags (origin-only changes) are tracked separately from
/// edge drags: moved ticks stream in, and when they go silent the drag
/// ended: past the untile distance the window untiles where dropped
/// (via the `onUntile` callback), otherwise it snaps back into its slot
/// rect. A single far jump is never a hand drag, so it snaps back too.
final class DragTracker {
    /// Reads live frames and resolves occupancy for the tracker.
    struct Context {
        var slotOf: (WindowID) -> Slot?
        var frameOf: (WindowID) -> CGRect?
        var boundsOf: (CGRect) -> CGRect
        var occupants: () -> [Slot: WindowID]
        /// Clock for echo-bookkeeping timestamps. Injectable so tests can
        /// fast-forward past the stale-write window without waiting on a
        /// real 3-second timeout.
        var now: () -> Date = Date.init
        /// Canvas owning a tiled window (its display plus Mission
        /// Control Space). Nil = legacy single-canvas mode: the shared
        /// `grid` serves everyone, and all per-canvas paths fall back to
        /// it. The controller wires this to its occupancy lookup; tests
        /// that never set it keep one grid.
        var spaceOf: (WindowID) -> TilingSpaceKey? = { _ in nil }
        /// Occupants of one canvas, for neighbor re-push. Nil falls back
        /// to `occupants()`.
        var occupantsOf: ((TilingSpaceKey) -> [Slot: WindowID])? = nil
        /// The window's live frame, as the app reports it; unlike
        /// `frameOf`, which may prefer our last pushed target (intent)
        /// for edge diffing. No-op write detection must consult the live
        /// frame: intent says where we wanted the window, the live frame
        /// says where it actually is.
        var liveFrameOf: (WindowID) -> CGRect? = { _ in nil }
    }

    private(set) var grid = GridLayout()
    /// Per-canvas splitter sets. Only populated when `spaceOf` resolves:
    /// each monitor's each Space drags its own dividers, so a resize on
    /// one canvas never moves tiles on another.
    private var grids: [TilingSpaceKey: GridLayout] = [:]

    /// Splitter set for `space` (defaults when untouched). Nil selects
    /// the legacy shared grid.
    func grid(for space: TilingSpaceKey?) -> GridLayout {
        guard let space else { return grid }
        return grids[space] ?? GridLayout()
    }
    private let context: Context
    /// Pushes computed rects (excluding the dragged window); reports refusals.
    private let apply: (_ rects: [WindowID: CGRect], _ excluding: WindowID?) -> Int
    /// Called when a title-bar drag ends past the untile distance: the
    /// controller releases the slot and leaves the window where dropped.
    private let onUntile: (WindowID) -> Void
    private let log: (String) -> Void
    private var lastKnownFrames: [WindowID: CGRect] = [:]
    /// Frames recently pushed (echo suppression).
    private var expectedFrames: [WindowID: ExpectedWrite] = [:]

    /// In-progress title-bar drag for one window: frame at drag start,
    /// latest frame, moved-tick count, and the pending drag-end canceller.
    private struct DragState {
        let startFrame: CGRect
        var lastFrame: CGRect
        var ticks = 0
        var cancelDragEnd: (() -> Void)?
    }
    private var drags: [WindowID: DragState] = [:]

    private var applyScheduled = false
    private var pendingRects: [WindowID: CGRect] = [:]
    private var pendingExclusion: WindowID?
    /// Edge drags with splitter moves awaiting mouse-up, keyed by canvas.
    /// The splitter fractions already committed; only the neighbor
    /// re-push they imply waits for the click to lift (see `mouseLifted`).
    private var pendingResizeApplies: [TilingSpaceKey?: WindowID] = [:]

    private static let echoTolerance: CGFloat = 32
    /// Writes within this distance of the window's current frame are
    /// no-ops: the app changes nothing and emits no AX notification, so
    /// marking them expected would leave an echo entry that never
    /// converges, and the late convergence check would read that silence
    /// as a silent ignore and evict an already-correct window. Skipped
    /// writes are success: state already agrees with the screen.
    static let noOpWriteTolerance: CGFloat = 1
    private static let staleWrite: TimeInterval = 3
    /// Post-converge settle window: macOS animation tails run ~0.2-0.5s,
    /// so 1s swallows them with margin while barely extending the blind
    /// prefix on a drag-out that starts the instant a write lands (a real
    /// drag escapes the moment it leaves the tolerance radius anyway,
    /// landing the splitter on its absolute position; only the untile
    /// distance, measured from the first escaped tick, can read short).
    private static let settleWindow: TimeInterval = 1
    /// Minimum edge travel that counts as a drag (below this is jitter).
    private static let edgeMoveThreshold: CGFloat = 1
    /// Origin drag distance past which a title-bar drag untiles the window.
    private static let untileDragDistance: CGFloat = 100
    /// Move silence after which a title-bar drag counts as finished.
    private static let dragEndDebounce: TimeInterval = 0.5

    /// Schedules the drag-end debounce; returns a canceller. Injectable
    /// so tests fire drag ends manually instead of waiting on the runloop.
    typealias DragEndScheduler = (_ fire: @escaping () -> Void) -> () -> Void

    /// Delay before a placement write is judged converged or ignored.
    /// Past the stale-write window (no tick even approached the target),
    /// with margin for slow apps: animations settle in ~0.5s, so 3.5s of
    /// total silence means the app ignored the write, not that it is
    /// still animating.
    static let verifyDelay: TimeInterval = 3.5

    /// Schedules a convergence check; returns a canceller. Same shape as
    /// the drag-end scheduler so tests fire verifications manually.
    static let scheduleVerifyOnMain: DragEndScheduler = { fire in
        let item = DispatchWorkItem(block: fire)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DragTracker.verifyDelay, execute: item)
        return { item.cancel() }
    }

    static let scheduleDragEndOnMain: DragEndScheduler = { fire in
        let item = DispatchWorkItem(block: fire)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DragTracker.dragEndDebounce, execute: item)
        return { item.cancel() }
    }

    private struct ExpectedWrite {
        let frame: CGRect
        /// Last observed sum-of-edge-deltas from `frame`. Starts at infinity;
        /// only a strictly increasing distance means a user took over.
        var lastDistance: CGFloat
        /// Write time, or the consume moment once settled: bounds both
        /// the unapplied-write wait and the post-converge settle window.
        var date: Date
        /// True once a tick landed within tolerance: the write applied and
        /// the window is settling. Close ticks keep being swallowed for
        /// `settleWindow` so the animation tail is never mistaken for a
        /// drag; a tick beyond tolerance ends settling and processes live.
        var settled: Bool
    }

    init(
        context: Context,
        apply: @escaping (_ rects: [WindowID: CGRect], _ excluding: WindowID?) -> Int,
        onUntile: @escaping (WindowID) -> Void = { _ in },
        scheduleDragEnd: @escaping DragEndScheduler = DragTracker.scheduleDragEndOnMain,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.context = context
        self.apply = apply
        self.onUntile = onUntile
        self.scheduleDragEnd = scheduleDragEnd
        self.log = log
    }

    private let scheduleDragEnd: DragEndScheduler

    // MARK: Tracking

    /// Notes a rect we pushed, so its echo is swallowed, not mistaken for
    /// a drag. Also seeds the last-known frame for edge diffing. Any
    /// in-progress drag on the window is dropped: its baseline is stale.
    func markExpected(_ id: WindowID, _ frame: CGRect) {
        expectedFrames[id] = ExpectedWrite(
            frame: frame, lastDistance: .infinity, date: context.now(), settled: false)
        lastKnownFrames[id] = frame
        clearDrag(id)
    }

    /// Last rect pushed for `id` (via `markExpected`), if any: our
    /// intent for the window, as opposed to whatever the gateway last
    /// reported. Lets diffing prefer intent over echoes.
    func lastPushedTarget(for id: WindowID) -> CGRect? {
        expectedFrames[id]?.frame
    }

    /// Convergence verdict for one pending write, read by the controller's
    /// late verification. Nil = inconclusive, leave the window alone:
    /// the entry is gone (consumed by success, cleared by takeover, or
    /// superseded by a newer write) or frames arrived but never settled.
    /// `.ignored` = the write never took effect and nothing echoed.
    /// `.converged` = a tick landed within tolerance of the target.
    enum Convergence { case converged, ignored }
    func convergence(for id: WindowID) -> Convergence? {
        guard var entry = expectedFrames[id] else { return nil }
        if entry.settled { return .converged }
        guard entry.lastDistance == .infinity else { return nil }
        // Total echo silence alone is not a silent ignore: apps that
        // round frames to an internal grid (Terminal rounds to character
        // cells) can absorb a write whose target sits within their
        // rounding distance: the frame does not actually change, so no
        // notification is emitted. Before calling it ignored, check the
        // live frame directly: within the echo tolerance of the target
        // means the write took effect (or needed no effect). An
        // UNREADABLE live frame is also not a silent ignore: it is a
        // can't-judge. During a lid close/open the frame read fails for
        // live windows, and judging that as ignored rolled fresh
        // placements back (observed on live AX); benefit of the doubt
        // applies — the next write re-verifies.
        guard let live = context.liveFrameOf(id) else {
            expectedFrames[id] = nil
            log("convergence win\(id): live frame unreadable, skipping")
            return nil
        }
        if Self.framesClose(entry.frame, live, tolerance: Self.echoTolerance)
        {
            expectedFrames[id] = nil
            log("convergence win\(id): silent but at target (live=\(live))")
            return .converged
        }
        return .ignored
    }

    /// Forgets a window: untile, restore, and prune paths call this so
    /// stale echo entries never swallow a future drag on a recycled id.
    /// Push targets are intentionally kept: undo chapters replay writes
    /// for ids whose frames were restored out from under them, and the
    /// intent (last pushed target) must survive the record clearing.
    /// Fresh `markExpected` calls overwrite; only recycled ids could
    /// collide, and those re-mark on their first new write.
    func forget(_ id: WindowID) {
        lastKnownFrames[id] = nil
        expectedFrames[id] = nil
        clearDrag(id)
    }

    /// Writes `updated` as `space`'s splitter set (nil selects the
    /// legacy shared grid). The diff against the previous frame's grid
    /// decides the drag, mirroring the single-canvas read path.
    func setGrid(_ updated: GridLayout, for space: TilingSpaceKey?) {
        if let space {
            grids[space] = updated
        } else {
            grid = updated
        }
    }

    /// Snaps all splitters back to defaults. Callers re-push occupants.
    /// The displaced fractions come back as the return value, so the
    /// caller can park them as a one-step restore (see
    /// TilingController.resetDividers): nothing else in the app knows the
    /// live fractions, and a bare reset would be the one destruction the
    /// app performs without keeping receipts.
    @discardableResult
    func resetDividers() -> GridLayout {
        let previous = grid
        grid = GridLayout()
        return previous
    }

    /// Snaps one canvas's splitters back to defaults. Returns that
    /// canvas's displaced fractions as the caller's one-step restore.
    @discardableResult
    func resetDividers(for space: TilingSpaceKey) -> GridLayout {
        let previous = grid(for: space)
        grids[space] = GridLayout()
        return previous
    }

    /// Restores splitter fractions parked by an earlier reset, re-pushed
    /// by the caller onto current occupants.
    func restoreDividers(_ saved: GridLayout) {
        grid = saved
    }

    /// Restores one canvas's parked splitter fractions.
    func restoreDividers(_ saved: GridLayout, for space: TilingSpaceKey) {
        grids[space] = saved
    }

    /// Rect for `id`'s slot under its canvas's grid. Nil when the window
    /// has no slot (untiled) or no readable frame.
    func rect(for id: WindowID) -> CGRect? {
        guard let slot = context.slotOf(id), let frame = context.frameOf(id) else { return nil }
        return grid(for: context.spaceOf(id)).rect(for: slot, in: context.boundsOf(frame))
    }

    // MARK: Change entry point

    /// Feeds one gateway change callback through echo suppression and edge
    /// detection. `slotOf` returning nil means untiled: ignored, since
    /// observation registrations outlive records.
    func handleChange(id: WindowID, frame: CGRect) {
        guard context.slotOf(id) != nil else { return }
        log("notif win\(id) frame=\(frame)")

        // Echo suppression: our writes apply (often animated) as a stream of
        // notifications converging on the requested frame. Swallow them; a
        // tick that moves AWAY from the target means a real user drag took
        // over, so we clear the entry and process it.
        if var entry = expectedFrames[id] {
            if Self.framesClose(entry.frame, frame, tolerance: Self.echoTolerance) {
                if entry.settled,
                    context.now().timeIntervalSince(entry.date) > Self.settleWindow
                {
                    // Settling over, but this tick already proved close:
                    // swallow it against the target rather than falling
                    // into the escape check below, whose stale
                    // lastDistance would misread any tail offset as a
                    // takeover. The next tick processes fully live.
                    expectedFrames[id] = nil
                    lastKnownFrames[id] = frame
                    log("echo win\(id) settle-expired")
                    return
                } else {
                    let wasSettled = entry.settled
                    if !wasSettled {
                        // Write converged: keep swallowing close ticks
                        // through the settle window instead of going live:
                        // the animation tail is still in flight, and its
                        // absolute positions must never reach the splitters.
                        entry.settled = true
                        entry.date = context.now()
                        entry.lastDistance = 0
                        expectedFrames[id] = entry
                        log("echo win\(id) consumed")
                    } else {
                        log("echo win\(id) settling")
                    }
                    // A pure-origin drift inside the radius is a hand on
                    // the title bar, not animation settling (settling moves
                    // edges): track the drag so snapback/untile still work
                    // for grabs that start the instant a write lands.
                    // Splitters stay untouched: processMove never moves
                    // them, and the snapback rect is the grid truth.
                    if wasSettled, let previous = lastKnownFrames[id],
                        previous.size == frame.size, previous.origin != frame.origin
                    {
                        lastKnownFrames[id] = frame
                        processMove(windowID: id, from: previous, to: frame)
                        return
                    }
                    lastKnownFrames[id] = frame
                    return
                }
            } else if entry.settled {
                expectedFrames[id] = nil // left the radius; live below
                log("echo win\(id) settle-end")
            }
            let distance = Self.frameDistance(entry.frame, frame)
            if distance > entry.lastDistance + 1 {
                expectedFrames[id] = nil // user took over
                log("echo win\(id) ESCAPE dist=\(distance) last=\(entry.lastDistance)")
            } else if context.now().timeIntervalSince(entry.date) > Self.staleWrite {
                expectedFrames[id] = nil // write never applied; stop waiting
                log("echo win\(id) stale")
            } else {
                entry.lastDistance = distance
                expectedFrames[id] = entry
                lastKnownFrames[id] = frame
                log("echo win\(id) converging dist=\(distance)")
                return
            }
        }

        // Diff against the previous frame of ANY kind. Drags that change a
        // window's origin arrive as Moved+Resized pairs with identical
        // frames; comparing Resized against the paired Moved would silently
        // drop every left/top/corner drag. Origin-only changes are title-bar
        // moves: left off-grid until the next layout assertion.
        let previous = lastKnownFrames[id]
        lastKnownFrames[id] = frame
        guard let previous, previous != frame else { return }
        guard previous.size == frame.size else {
            clearDrag(id)
            processResize(windowID: id, from: previous, to: frame)
            return
        }
        processMove(windowID: id, from: previous, to: frame)
    }

    // MARK: Drag-out untile

    /// Tracks a title-bar drag: origin-only changes stream in as the user
    /// moves the window. Each tick reschedules the drag-end debounce, so
    /// a mid-drag pause longer than the debounce ends the drag early
    /// (snapback or untile); continuing the drag re-tracks from the new
    /// frame. Hand drags stream ticks, so this only bites on real pauses.
    private func processMove(windowID id: WindowID, from previous: CGRect, to frame: CGRect) {
        if drags[id] == nil {
            drags[id] = DragState(startFrame: previous, lastFrame: frame)
        }
        drags[id]?.lastFrame = frame
        drags[id]?.ticks += 1
        log("move win\(id) dragging tick=\(drags[id]?.ticks ?? 0) frame=\(frame)")
        drags[id]?.cancelDragEnd?()
        drags[id]?.cancelDragEnd = scheduleDragEnd { [weak self] in
            self?.endDrag(id: id)
        }
    }

    /// A drag just ended (moved ticks went silent): untile past the
    /// untile distance, snap back otherwise. A single far tick snaps
    /// back too: hand drags stream, one-shot programmatic jumps don't.
    /// (Residual exposure: a programmatic move that arrives as several
    /// ticks and travels far enough untiles; accepted, since such moves
    /// are rare and the window ends up untiled where it was put.)
    private func endDrag(id: WindowID) {
        guard let slot = context.slotOf(id), let drag = drags[id] else { return }
        drags[id] = nil
        let distance = hypot(
            drag.lastFrame.origin.x - drag.startFrame.origin.x,
            drag.lastFrame.origin.y - drag.startFrame.origin.y)
        log("dragend win\(id) ticks=\(drag.ticks) distance=\(distance)")
        guard distance > Self.untileDragDistance, drag.ticks >= 2 else {
            let rect = grid(for: context.spaceOf(id)).rect(for: slot, in: context.boundsOf(drag.lastFrame))
            log("dragend win\(id) snapback -> \(rect)")
            schedule(rects: [id: rect], excluding: nil)
            return
        }
        log("dragend win\(id) untile")
        onUntile(id)
    }

    /// Drops all drag state for `id`, cancelling any pending drag end.
    private func clearDrag(_ id: WindowID) {
        drags[id]?.cancelDragEnd?()
        drags[id] = nil
    }

    /// Detects which edges moved, maps them to grid boundaries, updates the
    /// splitters from the dragged window's *actual* frame, then schedules
    /// new rects for the neighbors.
    private func processResize(windowID id: WindowID, from old: CGRect, to new: CGRect) {
        guard let slot = context.slotOf(id) else { return }
        let bounds = context.boundsOf(new)
        let threshold = Self.edgeMoveThreshold

        func moved(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > threshold }

        var changed = false
        for edge in TileEdge.allCases {
            let edgeMoved: Bool
            let position: CGFloat
            switch edge {
            case .left:
                edgeMoved = moved(new.minX, old.minX); position = new.minX
            case .right:
                edgeMoved = moved(new.maxX, old.maxX); position = new.maxX
            case .top:
                edgeMoved = moved(new.maxY, old.maxY); position = new.maxY
            case .bottom:
                edgeMoved = moved(new.minY, old.minY); position = new.minY
            }
            guard edgeMoved else { continue }
            // The dragged window's own edge is the source of truth; skip it
            // below so we never fight an in-progress native drag.
            guard let boundary = GridLayout.boundary(edge: edge, slot: slot) else { continue }
            let space = context.spaceOf(id)
            let centered = centeredTwoThirds(
                on: boundary, draggedSlot: slot, in: space)
            var spaceGrid = grid(for: space)
            if spaceGrid.update(
                boundary: boundary, toPosition: position, in: bounds,
                centeringTwoThirds: centered)
            {
                setGrid(spaceGrid, for: space)
                changed = true
                log("resize win\(id) edge=\(edge) position=\(position) -> \(boundary) grid=\(spaceGrid)")
            }
        }
        if changed {
            // The splitter moved now, but the neighbors it will displace
            // wait for mouse-up: pushing tiles while the button is down
            // fights the drag the user is still steering.
            pendingResizeApplies[context.spaceOf(id)] = id
        }
    }

    /// The occupied two-thirds window whose hidden one-thirds divider
    /// must follow `boundary`, if any. Dragging the two-thirds window's
    /// own outer edge counts directly; so does dragging the adjacent
    /// third's facing edge, since that is the same splitter resizing both
    /// windows. Any other boundary leaves the two-thirds divider alone.
    private func centeredTwoThirds(
        on boundary: GridBoundary, draggedSlot: Slot, in space: TilingSpaceKey?
    ) -> Slot? {
        if draggedSlot == .sixthsLeftTwoThirds, boundary == .sixthsRightSplit {
            return draggedSlot
        }
        if draggedSlot == .sixthsRightTwoThirds, boundary == .sixthsLeftSplit {
            return draggedSlot
        }
        let occupants: [Slot: WindowID]
        if let space, let occupantsOf = context.occupantsOf {
            occupants = occupantsOf(space)
        } else {
            occupants = context.occupants()
        }
        switch boundary {
        case .sixthsRightSplit:
            return occupants[.sixthsLeftTwoThirds] != nil ? .sixthsLeftTwoThirds : nil
        case .sixthsLeftSplit:
            return occupants[.sixthsRightTwoThirds] != nil ? .sixthsRightTwoThirds : nil
        default:
            return nil
        }
    }

    // MARK: Mouse-up commit

    /// The user released the mouse button: commit every deferred neighbor
    /// re-push at once, so the tiles around a resized window resize on
    /// the click lifting, never under it. A trailing resize tick re-arms
    /// its canvas's entry; the next mouse-up anywhere commits it.
    func mouseLifted() {
        guard !pendingResizeApplies.isEmpty else { return }
        let pending = pendingResizeApplies
        pendingResizeApplies = [:]
        for id in pending.values {
            scheduleApply(excluding: id)
        }
    }

    // MARK: Coalescing

    /// Recomputes every occupant's rect under its canvas's grid, except
    /// the dragged window, and schedules one push per runloop tick.
    func reassertAll(occupants: [Slot: WindowID], excluding: WindowID? = nil) {
        var rects: [WindowID: CGRect] = [:]
        for (slot, occupant) in occupants {
            guard occupant != excluding, let frame = context.frameOf(occupant) else { continue }
            // Seed the diff baseline for windows the tracker hasn't seen:
            // without this the first drag after a reassert diffs against a
            // stale frame and misreads the edge.
            if lastKnownFrames[occupant] == nil {
                lastKnownFrames[occupant] = frame
            }
            rects[occupant] = grid(for: context.spaceOf(occupant)).rect(
                for: slot, in: context.boundsOf(frame))
        }
        schedule(rects: rects, excluding: excluding)
    }

    private func scheduleApply(excluding id: WindowID) {
        // Neighbor rects are computed now, pushed on the next tick: the
        // dragged window keeps moving under the user's hand meanwhile.
        // Only the dragged window's canvas re-pushes: neighbors on other
        // displays and Spaces keep their frames, so a resize never
        // crosses canvases.
        if let space = context.spaceOf(id), let occupantsOf = context.occupantsOf {
            reassertAll(occupants: occupantsOf(space), excluding: id)
            return
        }
        reassertAll(occupants: context.occupants(), excluding: id)
    }

    private func schedule(rects: [WindowID: CGRect], excluding: WindowID?) {
        for (id, rect) in rects {
            // No-op writes are skipped, not pushed: nothing would change,
            // nothing would echo, and the pending convergence check would
            // evict an already-correct window. Live frame, not intent;
            // intent equals the target by definition.
            if let live = context.liveFrameOf(id),
                Self.close(live, rect, tolerance: Self.noOpWriteTolerance)
            {
                log("skip win\(id) no-op write rect=\(rect)")
                continue
            }
            pendingRects[id] = rect
        }
        pendingExclusion = excluding
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyScheduled = false
            let rects = self.pendingRects
            self.pendingRects = [:]
            let excluding = self.pendingExclusion
            self.pendingExclusion = nil
            for (id, rect) in rects {
                self.markExpected(id, rect)
            }
            // `excluding` names a window whose frame is the drag's source
            // of truth; nil is the snapback case (the dragged window itself
            // is the only rect). Either way the rects must be pushed.
            _ = self.apply(rects, excluding)
        }
    }

    // MARK: Geometry helpers

    private static func framesClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.maxX - b.maxX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    /// True when `a` and `b` differ by at most `tolerance` per edge.
    static func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        framesClose(a, b, tolerance: tolerance)
    }

    /// Sum of per-edge deltas between two frames.
    private static func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.maxX - b.maxX)
            + abs(a.minY - b.minY) + abs(a.maxY - b.maxY)
    }
}
