import CoreGraphics
import Foundation

/// Owns the live drag-resize loop (observe & decide): gateway change
/// callbacks in, splitter moves and one drag-end decision out.
///
/// The tracker decides; the coordinator acts. It never computes a rect
/// and never schedules a write: at a drag's end it names the window and
/// the gesture (`resize` / `snapback` / `untile`) through `onDragEnd`,
/// and the coordinator routes that to the owning canvas's reassert. The
/// canvas owns the rect math and the one write path, so the tracker can
/// no longer disagree with it about where a tile is.
///
/// Protocol: the controller feeds each gateway callback to
/// `handleChange`. Echo suppression swallows our own writes, edge
/// detection maps a dragged edge onto the canvas's splitters and commits
/// the fraction live (the only mutation the tracker performs), and a
/// title-bar drag is tracked to its end. The dragged window's own frame
/// is the source of truth for the splitter it moves; the tracker never
/// re-pushes it mid-drag.
///
/// Edge drags resize only the dragged window while the button is down:
/// splitter fractions commit live, but the settle waits for mouse-up
/// (`mouseLifted`, wired by the controller's global event monitor).
/// Resizing the tiles under a held button fights the user's drag; on
/// release the canvas reasserts the whole layout at once. A resize tick
/// that trails the mouse-up (AX streams the drag's final frame) re-arms
/// its canvas's pending resize, and the next mouse-up anywhere commits
/// it.
///
/// Title-bar drags (origin-only changes) are tracked separately from
/// edge drags: moved ticks stream in, and when they go silent the drag
/// ended: past the untile distance the window untiles where dropped,
/// otherwise it snaps back into its slot (the canvas reasserts with its
/// existing splitters). A single far jump is never a hand drag, so it
/// snaps back too.
final class DragTracker {
    /// Reads and writes splitter fractions, and reads the canvas's one
    /// stored visible frame. The canvas owns them; the tracker only
    /// moves the splitters. Nil keys are the display-less fallback
    /// (headless tests and windows whose canvas is unknown). Injected at
    /// construction so a tracker never keeps a second copy of a canvas's
    /// grid, and never resolves a frame from a window's own geometry.
    struct GridProvider {
        var grid: (TilingSpaceKey?) -> GridLayout
        var setGrid: (GridLayout, TilingSpaceKey?) -> Void
        /// The canvas's one visible frame: the frame the live splitter
        /// commit divides against. Deriving a per-drag frame from the
        /// window's own geometry is exactly the bug the canvas's stored
        /// frame replaced.
        var visibleFrame: (TilingSpaceKey?) -> CGRect
    }

    /// What a drag's end asks the coordinator to do. The tracker decides
    /// only: it names the window, and the coordinator performs the one
    /// effect the pure core cannot (reading the achieved frame) and
    /// routes the decision to the owning canvas.
    enum DragDecision: Equatable {
        /// An edge drag settled: reassert the window's canvas, with the
        /// splitters reconciled to the dragged window's achieved frame.
        case resize(WindowID)
        /// A short title-bar drag ended: reassert the window's canvas
        /// under its existing splitters, so the window snaps back into
        /// its tile.
        case snapback(WindowID)
        /// A title-bar drag passed the untile distance: release the slot
        /// and leave the window where it was dropped.
        case untile(WindowID)
    }

    /// Reads live frames and resolves occupancy for the tracker.
    struct Context {
        var slotOf: (WindowID) -> Slot?
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
        /// Occupants of one canvas, for the two-thirds centering rule
        /// when a drag resizes a two-thirds window. Nil falls back to
        /// `occupants()`.
        var occupantsOf: ((TilingSpaceKey) -> [Slot: WindowID])? = nil
        /// The window's live frame, as the app reports it: the silent-
        /// convergence check consults it before calling echo silence an
        /// ignore.
        var liveFrameOf: (WindowID) -> CGRect? = { _ in nil }
    }

    private let gridProvider: GridProvider

    /// Splitter set for `space` (defaults when the canvas has none).
    func grid(for space: TilingSpaceKey?) -> GridLayout {
        gridProvider.grid(space)
    }

    private let context: Context
    /// One drag-end decision, routed by the coordinator to the owning
    /// canvas. The tracker computes no rect and schedules no write.
    private let onDragEnd: (DragDecision) -> Void
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

    /// Edge drags with splitter moves awaiting mouse-up, keyed by canvas.
    /// The splitter fractions already committed; only the reassert they
    /// imply waits for the click to lift (see `mouseLifted`).
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
        gridProvider: GridProvider,
        onDragEnd: @escaping (DragDecision) -> Void,
        scheduleDragEnd: @escaping DragEndScheduler = DragTracker.scheduleDragEndOnMain,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.context = context
        self.gridProvider = gridProvider
        self.onDragEnd = onDragEnd
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

    /// Seeds only the diff baseline for `id`, without arming an echo
    /// expectation. The canvas's reassert stores the frame it is about
    /// to write, and must seed the baseline even for occupants whose
    /// write the policy skips (already correct) or defers (off-Space):
    /// those never reach `markExpected`, and without a baseline the
    /// first drag after the reassert diffs against a stale frame and is
    /// misread.
    func seedBaseline(_ id: WindowID, _ frame: CGRect) {
        lastKnownFrames[id] = frame
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
        guard let entry = expectedFrames[id] else { return nil }
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
        guard context.slotOf(id) != nil, let drag = drags[id] else { return }
        drags[id] = nil
        let distance = hypot(
            drag.lastFrame.origin.x - drag.startFrame.origin.x,
            drag.lastFrame.origin.y - drag.startFrame.origin.y)
        log("dragend win\(id) ticks=\(drag.ticks) distance=\(distance)")
        guard distance > Self.untileDragDistance, drag.ticks >= 2 else {
            log("dragend win\(id) snapback")
            onDragEnd(.snapback(id))
            return
        }
        log("dragend win\(id) untile")
        onDragEnd(.untile(id))
    }

    /// Drops all drag state for `id`, cancelling any pending drag end.
    private func clearDrag(_ id: WindowID) {
        drags[id]?.cancelDragEnd?()
        drags[id] = nil
    }

    /// Detects which edges moved, maps them to grid boundaries, and
    /// updates the splitters from the dragged window's *actual* frame,
    /// divided against the canvas's one stored visible frame. Commits the
    /// fraction live and marks the canvas's resize pending for mouse-up.
    private func processResize(windowID id: WindowID, from old: CGRect, to new: CGRect) {
        guard let slot = context.slotOf(id) else { return }
        let space = context.spaceOf(id)
        let bounds = gridProvider.visibleFrame(space)
        guard bounds.width > 0, bounds.height > 0 else { return }
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
            let centered = GridLayout.centeringTwoThirds(
                on: boundary, draggedSlot: slot, occupants: occupiedSlots(in: space))
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
            // The splitter moved now, but the settle it implies waits for
            // mouse-up: reasserting tiles while the button is down fights
            // the drag the user is still steering.
            pendingResizeApplies[space] = id
        }
    }

    /// The occupied slots of the canvas a drag is resizing, for the
    /// grid's occupant-aware two-thirds rule. Falls back to the shared
    /// occupant map when the canvas cannot be resolved (legacy mode).
    private func occupiedSlots(in space: TilingSpaceKey?) -> Set<Slot> {
        if let space, let occupantsOf = context.occupantsOf {
            return Set(occupantsOf(space).keys)
        }
        return Set(context.occupants().keys)
    }

    // MARK: Mouse-up commit

    /// The user released the mouse button: every deferred edge drag's
    /// settle is now due. The tracker decides only; the coordinator reads
    /// each dragged window's achieved frame and reasserts its canvas. A
    /// trailing resize tick re-arms its canvas's entry; the next mouse-up
    /// anywhere commits it.
    func mouseLifted() {
        guard !pendingResizeApplies.isEmpty else { return }
        let pending = pendingResizeApplies
        pendingResizeApplies = [:]
        for id in pending.values {
            onDragEnd(.resize(id))
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
