import CoreGraphics
import Foundation

/// Owns the live drag-resize loop (observe & compensate): gateway change
/// callbacks in, splitter moves and neighbor re-pushes out.
///
/// Previously interleaved with placement records inside TilingController;
/// the real bugs hid in how echo entries interacted with edge diffs, not
/// in either alone. Now the drag loop (edge detection, splitter updates,
/// apply coalescing) lives behind one interface and is testable through
/// it with a fake gateway, while `WriteExpectations` owns our writes'
/// echo entries and classifies each tick.
///
/// Protocol: the controller feeds each gateway callback to
/// `handleChange`, and every rect the tracker computes via
/// `rect(for:in:)`; the dragged window's own edge is the source of truth
/// and is skipped on re-push so the tracker never fights an in-progress
/// native drag. `handleChange` consumes the owner's verdict per tick:
/// swallowed ticks never reach the edge diff, a live tick diffs against
/// the last-known frame.
///
/// Edge drags resize only the dragged window while the button is down:
/// splitter fractions commit live, but the neighbor re-pushes wait for
/// mouse-up (`mouseLifted`, wired by the controller's global event
/// monitor). Resizing the tiles under a held button fights the drag and
/// rewrites frames the user is still steering. On release the commit
/// waits out a short trailing-tick delay: AX streams the drag's final
/// frame, and it can arrive after the mouse-up, so an immediate commit
/// would push the neighbors to a splitter the user already left behind
/// (the visible gap then shrinks or overlaps until some later click
/// commits the trailing tick). Each resize tick that lands while the
/// button is up re-arms the delay; a new press (`mousePressed`, wired
/// by the controller's global monitor) cancels it, so a fresh drag
/// still defers everything to its own release.
///
/// Title-bar drags (origin-only changes) are tracked separately from
/// edge drags: moved ticks stream in, and when they go silent the drag
/// ended: past the untile distance the window untiles where dropped
/// (via the `onUntile` callback), otherwise it snaps back into its slot
/// rect. A single far jump is never a hand drag, so it snaps back too.
final class DragTracker {
    /// Reads and writes splitter fractions: the canvas owns them, the
    /// tracker only moves them. Nil keys are the display-less fallback
    /// (headless tests and windows whose canvas is unknown). Injected at
    /// construction so a tracker never keeps a second copy of a canvas's
    /// grid.
    struct GridProvider {
        var grid: (TilingSpaceKey?) -> GridLayout
        var setGrid: (GridLayout, TilingSpaceKey?) -> Void
    }

    /// Reads live frames and resolves occupancy for the tracker.
    struct Context {
        var slotOf: (WindowID) -> Slot?
        var frameOf: (WindowID) -> CGRect?
        var boundsOf: (CGRect) -> CGRect
        /// The tile gap in points, read live (the tracker's context is
        /// built once, so a snapshot would freeze the setting).
        var gap: () -> CGFloat = { 0 }
        var occupants: () -> [Slot: WindowID]
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

    private let gridProvider: GridProvider

    /// Splitter set for `space` (defaults when the canvas has none).
    func grid(for space: TilingSpaceKey?) -> GridLayout {
        gridProvider.grid(space)
    }

    private let context: Context
    /// Owns our writes' echo entries and classifies each gateway tick;
    /// the tracker keeps only drag state (last-known frames, drags,
    /// pending pushes).
    private let expectations: WriteExpectations
    /// Pushes computed rects (excluding the dragged window). Refusal
    /// attribution belongs to the canvas the push routes to.
    private let apply: (_ rects: [WindowID: CGRect], _ excluding: WindowID?) -> Void
    /// Called when a title-bar drag ends past the untile distance: the
    /// controller releases the slot and leaves the window where dropped.
    private let onUntile: (WindowID) -> Void
    private let log: (String) -> Void
    private var lastKnownFrames: [WindowID: CGRect] = [:]

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
    /// Edge drags with splitter moves awaiting the release's trailing
    /// ticks, keyed by canvas. The splitter fractions already committed;
    /// only the neighbor re-push they imply waits for the click to lift
    /// and the AX stream to go quiet (see `mouseLifted`).
    private var pendingResizeApplies: [TilingSpaceKey?: WindowID] = [:]
    /// Whether the left mouse button is down. Initialised true: until the
    /// controller's monitors report otherwise, deferring a neighbor
    /// re-push is the safe side, and a release can always commit. The
    /// monitors (`mousePressed` / `mouseLifted`) keep it current.
    private var mouseIsDown = true
    /// The scheduled trailing-tick commit, if any; cancelled by a new
    /// press and re-armed by each post-release resize tick.
    private var cancelPendingCommit: (() -> Void)?

    /// Minimum edge travel that counts as a drag (below this is jitter).
    private static let edgeMoveThreshold: CGFloat = 1
    /// Origin drag distance past which a title-bar drag untiles the window.
    private static let untileDragDistance: CGFloat = 100
    /// Move silence after which a title-bar drag counts as finished.
    private static let dragEndDebounce: TimeInterval = 0.5

    /// Schedules the drag-end debounce; returns a canceller. Injectable
    /// so tests fire drag ends manually instead of waiting on the runloop.
    typealias DragEndScheduler = (_ fire: @escaping () -> Void) -> () -> Void

    static let scheduleDragEndOnMain: DragEndScheduler = { fire in
        let item = DispatchWorkItem(block: fire)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DragTracker.dragEndDebounce, execute: item)
        return { item.cancel() }
    }

    /// Schedules the post-release trailing-tick commit; returns a
    /// canceller. Injectable like the drag-end scheduler so tests fire
    /// the commit without waiting on the runloop.
    typealias CommitScheduler = (_ fire: @escaping () -> Void) -> () -> Void

    /// Delay between the last resize tick (or the release that ended the
    /// drag) and the neighbor re-push. Long enough for the drag's final
    /// AX notification to land, short enough to still read as attached
    /// to the release; a later tick re-arms it, so a miss only delays
    /// the correction, never loses it.
    static let trailingCommitDelay: TimeInterval = 0.1

    static let scheduleCommitOnMain: CommitScheduler = { fire in
        let item = DispatchWorkItem(block: fire)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DragTracker.trailingCommitDelay, execute: item)
        return { item.cancel() }
    }

    init(
        expectations: WriteExpectations,
        context: Context,
        gridProvider: GridProvider,
        apply: @escaping (_ rects: [WindowID: CGRect], _ excluding: WindowID?) -> Void,
        onUntile: @escaping (WindowID) -> Void = { _ in },
        scheduleDragEnd: @escaping DragEndScheduler = DragTracker.scheduleDragEndOnMain,
        scheduleCommit: @escaping CommitScheduler = DragTracker.scheduleCommitOnMain,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.expectations = expectations
        self.context = context
        self.gridProvider = gridProvider
        self.apply = apply
        self.onUntile = onUntile
        self.scheduleDragEnd = scheduleDragEnd
        self.scheduleCommit = scheduleCommit
        self.log = log
    }

    private let scheduleDragEnd: DragEndScheduler
    private let scheduleCommit: CommitScheduler

    // MARK: Pushed targets

    /// A frame write for `id` is in flight (or the drag loop scheduled a
    /// push for it): the target we asked for becomes the diff baseline,
    /// and any in-progress drag is dropped - its baseline predates the
    /// write, so its eventual snapback/untile decision would be stale.
    /// The owner arms the echo expectation separately.
    func notePushed(_ id: WindowID, _ frame: CGRect) {
        lastKnownFrames[id] = frame
        clearDrag(id)
    }

    // MARK: Forgetting

    /// Forgets a window: untile, restore, and prune paths call this so
    /// stale echo entries never swallow a future drag on a recycled id,
    /// and a pending convergence check never rolls back a window that
    /// already moved on. The owner clears the echo entry and cancels the
    /// check but keeps the intent (undo chapters replay writes for ids
    /// whose frames were restored out from under them); the tracker drops
    /// its diff baseline and any in-flight drag.
    func forget(_ id: WindowID) {
        lastKnownFrames[id] = nil
        expectations.forget(id)
        clearDrag(id)
    }

    /// Rect for `id`'s slot under its canvas's grid. Nil when the window
    /// has no slot (untiled) or no readable frame.
    func rect(for id: WindowID) -> CGRect? {
        guard let slot = context.slotOf(id) else { return nil }
        return rect(for: id, slot: slot)
    }

    /// Rect for `id` in `slot` (not necessarily its current one) under
    /// its canvas's grid. The state that names a prospective slot lives
    /// in the caller's canvas, which is why the slot comes in instead of
    /// being read back from the tracker's session. Nil when the window
    /// has no readable frame.
    func rect(for id: WindowID, slot: Slot) -> CGRect? {
        guard let frame = context.frameOf(id) else { return nil }
        return grid(for: context.spaceOf(id)).rect(
            for: slot, in: context.boundsOf(frame), gap: context.gap())
    }

    // MARK: Change entry point

    /// Feeds one gateway change callback through the expectation owner's
    /// verdict and edge detection. `slotOf` returning nil means untiled:
    /// ignored, since observation registrations outlive records.
    func handleChange(id: WindowID, frame: CGRect) {
        guard context.slotOf(id) != nil else { return }
        log("notif win\(id) frame=\(frame)")

        // Echo suppression: our writes apply (often animated) as a stream
        // of notifications converging on the requested frame. The owner
        // classifies each tick against the pending expectation; a tick
        // that moves AWAY from the target means a real user drag took
        // over, and processes live below.
        switch expectations.classify(id, frame: frame) {
        case .live:
            break
        case .settleExpired, .consumed:
            // Swallowed: the write converged (or its settle window just
            // ended on a close tick). Re-seed the diff baseline and stop.
            lastKnownFrames[id] = frame
            return
        case .settling:
            // A pure-origin drift inside the radius is a hand on the
            // title bar, not animation settling (settling moves edges):
            // track the drag so snapback/untile still work for grabs
            // that start the instant a write lands. Splitters stay
            // untouched: processMove never moves them, and the snapback
            // rect is the grid truth.
            if let previous = lastKnownFrames[id],
                previous.size == frame.size, previous.origin != frame.origin
            {
                lastKnownFrames[id] = frame
                processMove(windowID: id, from: previous, to: frame)
                return
            }
            lastKnownFrames[id] = frame
            return
        case .converging:
            // Swallowed: the tick moved toward the target but has not
            // reached it. The owner tracks the distance; seed the
            // baseline so a later takeover diffs correctly.
            lastKnownFrames[id] = frame
            return
        case .settleEnd, .escape, .stale:
            // The entry is gone (settling ended, the user took over, or
            // the write never applied): process the tick live below.
            break
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
            let rect = grid(for: context.spaceOf(id)).rect(
                for: slot, in: context.boundsOf(drag.lastFrame), gap: context.gap())
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
        // The frame we read is the *placed* one, inset by half the gap, so
        // the visible edge sits half a gap inside the splitter line. Add it
        // back before mapping to a boundary, or the splitter lands on the
        // visible edge and the tile jumps half a gap on mouse-up. Min edges
        // (left/bottom) sit inset away from their line; max edges (right/
        // top) likewise, in the opposite direction.
        let halfGap = context.gap() / 2

        func moved(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > threshold }

        var changed = false
        for edge in TileEdge.allCases {
            let edgeMoved: Bool
            let position: CGFloat
            switch edge {
            case .left:
                edgeMoved = moved(new.minX, old.minX); position = new.minX - halfGap
            case .right:
                edgeMoved = moved(new.maxX, old.maxX); position = new.maxX + halfGap
            case .top:
                edgeMoved = moved(new.maxY, old.maxY); position = new.maxY + halfGap
            case .bottom:
                edgeMoved = moved(new.minY, old.minY); position = new.minY - halfGap
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
                gridProvider.setGrid(spaceGrid, space)
                changed = true
                log("resize win\(id) edge=\(edge) position=\(position) -> \(boundary) grid=\(spaceGrid)")
            }
        }
        if changed {
            // The splitter moved now, but the neighbors it will displace
            // wait for the release and its trailing ticks: pushing tiles
            // while the button is down fights the drag the user is still
            // steering, and pushing on the release itself can beat the
            // drag's final AX tick. A tick that lands while the button
            // is up re-arms the commit, so the grid settles as one move.
            pendingResizeApplies[context.spaceOf(id)] = id
            if !mouseIsDown {
                armCommit()
            }
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

    /// The user released the mouse button: schedule the pending neighbor
    /// re-pushes to commit once the drag's trailing AX ticks go quiet.
    /// Committing at once would race the drag's final tick — AX streams
    /// it after the release — and push the neighbors to a splitter the
    /// user already left behind, leaving a wrong (shrunk, grown, or
    /// overlapping) gap until some later click committed the tick. Each
    /// following resize tick re-arms the delay; a new press cancels it.
    func mouseLifted() {
        mouseIsDown = false
        armCommit()
    }

    /// The user pressed the mouse button: a pending trailing-tick commit
    /// belongs to the gesture that just ended, so it is dropped. The new
    /// drag's own release arms the next one.
    func mousePressed() {
        mouseIsDown = true
        cancelCommit()
    }

    /// (Re)arms the trailing-tick commit when splitters await a neighbor
    /// re-push; a no-op with nothing pending.
    private func armCommit() {
        cancelCommit()
        guard !pendingResizeApplies.isEmpty else { return }
        cancelPendingCommit = scheduleCommit { [weak self] in
            guard let self, self.cancelPendingCommit != nil else { return }
            self.cancelPendingCommit = nil
            self.commitPendingResizes()
        }
    }

    /// Drops the scheduled trailing-tick commit, if any.
    private func cancelCommit() {
        cancelPendingCommit?()
        cancelPendingCommit = nil
    }

    /// Commits every deferred neighbor re-push at once: the grid has
    /// settled (release plus trailing ticks), so the tiles around the
    /// resized window move together, never under a held button.
    private func commitPendingResizes() {
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
                for: slot, in: context.boundsOf(frame), gap: context.gap())
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
                WriteExpectations.close(
                    live, rect, tolerance: WriteExpectations.noOpWriteTolerance)
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
                // The push is scheduled, not written yet: prime the
                // owner's intent for the target the write policy is about
                // to push, and move the drag loop's baseline to it. The
                // write itself arms the expectation.
                self.expectations.noteIntent(id, rect)
                self.notePushed(id, rect)
            }
            // `excluding` names a window whose frame is the drag's source
            // of truth; nil is the snapback case (the dragged window itself
            // is the only rect). Either way the rects must be pushed.
            self.apply(rects, excluding)
        }
    }
}
