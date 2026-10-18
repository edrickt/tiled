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
/// release the canvas reasserts the whole layout at once — a screen
/// edge the drag pulled away included. A resize tick
/// that trails the mouse-up (AX streams the drag's final frame) re-arms
/// its canvas's pending resize, and the next mouse-up anywhere commits
/// it.
///
/// Title-bar drags (origin-only changes) are tracked separately from
/// edge drags: moved ticks stream in, and the drag ends at the mouse-up
/// — past the untile distance the window untiles where dropped,
/// otherwise it snaps back into its slot (the canvas reasserts with its
/// existing splitters). The move-silence debounce is the fallback for a
/// mouse-up that never arrives (a missed monitor, a drag the OS cancels).
/// A single far jump is never a hand drag, so it snaps back too.
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
        /// A short title-bar drag ended, or a settle write the app's own
        /// resize session overrode: reassert the window's canvas under
        /// its existing splitters, so the window snaps back into its
        /// tile.
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

    /// Edge drags awaiting mouse-up, keyed by canvas. The splitter
    /// fractions (if any) already committed; the reassert the movement
    /// implies waits for the click to lift (see `mouseLifted`). A drag
    /// that moved only a fixed screen edge commits no fraction but still
    /// marks: the release reassert is what pulls the edge back.
    private var pendingReasserts: [TilingSpaceKey?: WindowID] = [:]

    /// A settle awaiting proof that the app accepted it, keyed by window:
    /// the gesture's final frame, and how many consecutive ticks have
    /// re-reported that frame since. A settle write can lose a race with
    /// the app's own resize session, two ways, both observed live: the
    /// session's finale lands over a write that never took (the gesture
    /// frame repeats while the echo trail never settles), or it reverts a
    /// write that applied (a single escape from the settled trail). A
    /// departing animation matches the gesture frame once and moves on,
    /// so the repeated-frame shape needs two sightings; the
    /// settled-revert shape is proof by itself. Either way the settle is
    /// re-issued once as a grid re-write (see `handleChange`).
    private struct SettleOverride {
        let gesture: CGRect
        var sightings: Int
    }
    private var settleOverrides: [WindowID: SettleOverride] = [:]

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
    /// Above this travel an edge counts as genuinely moved for the
    /// grab/translation signatures; below it the edge reads as pinned.
    private static let translationMargin: CGFloat = 8
    /// How close a tick must be to the settle's gesture frame to read as
    /// the app's own resize-session override of the write: coalesced AX
    /// ticks can lag the true final frame by a few points.
    private static let settleOverrideTolerance: CGFloat = 8
    /// Origin drag distance past which a title-bar drag untiles the window.
    private static let untileDragDistance: CGFloat = 50
    /// Move silence after which a title-bar drag counts as finished: the
    /// fallback end for a mouse-up that never fired (`mouseLifted` ends
    /// an in-progress drag immediately).
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

    /// Drops a pending edge reassert for `id`: a landed expand or collapse
    /// supersedes the gesture that never reached mouse-up, so the next
    /// release must not reconcile the splitters from the frame that action
    /// imposed. Other windows' pending reasserts stand.
    func clearPendingReassert(_ id: WindowID) {
        pendingReasserts = pendingReasserts.filter { $0.value != id }
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
    /// The echo entry and diff baseline are dropped together; a fresh
    /// `markExpected` on a recycled id re-marks it on its first new write.
    func forget(_ id: WindowID) {
        lastKnownFrames[id] = nil
        expectedFrames[id] = nil
        settleOverrides[id] = nil
        clearDrag(id)
    }

    // MARK: Change entry point

    /// Feeds one gateway change callback through echo suppression and edge
    /// detection. `slotOf` returning nil means untiled: ignored, since
    /// observation registrations outlive records.
    func handleChange(id: WindowID, frame: CGRect) {
        guard context.slotOf(id) != nil else { return }
        log("notif win\(id) frame=\(frame)")

        // A tick back at the frame the settle was decided at, right after
        // that settle: the app's resize session's finale landing over our
        // reassert write (the write is not refused; the frame just
        // reverts). One sighting is not proof — a departing animation
        // matches the gesture frame on its first step — so this shape
        // waits for the second; then the session has demonstrably ended
        // and the settle is re-issued as a plain grid re-write. One shot:
        // the arm is consumed here.
        if var arm = settleOverrides[id] {
            if Self.framesClose(arm.gesture, frame, tolerance: Self.settleOverrideTolerance) {
                arm.sightings += 1
                if arm.sightings >= 2 {
                    settleOverrides[id] = nil
                    expectedFrames[id] = nil
                    lastKnownFrames[id] = frame
                    log("echo win\(id) settle OVERRIDDEN; re-issuing")
                    onDragEnd(.snapback(id))
                    return
                }
                // fall through to the echo trail: the first sighting is
                // swallowed (or read live when the write has not
                // registered yet)
            } else {
                // A match followed by a different frame is a departing
                // animation, not a stuck session: start the count over.
                arm.sightings = 0
            }
            settleOverrides[id] = arm
        }

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
                    // takeover. A pure-origin drift is still a hand on
                    // the title bar (a tiny drag can arrive as exactly
                    // one tick, so "the next tick goes live" never
                    // comes): track it, or the mouse-up finds no drag
                    // and the window is left offset from its tile.
                    expectedFrames[id] = nil
                    let previous = lastKnownFrames[id]
                    lastKnownFrames[id] = frame
                    if let previous, previous.size == frame.size,
                        previous.origin != frame.origin
                    {
                        processMove(windowID: id, from: previous, to: frame)
                    }
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
                // A settled write whose frame then reverts to the
                // settle's gesture frame is the app's own resize session
                // overriding it (observed live: the revert lands ~10 ms
                // after the applied write). The session has now ended;
                // re-issue the settle once as a grid re-write.
                if entry.settled, let arm = settleOverrides[id],
                    Self.framesClose(arm.gesture, frame, tolerance: Self.settleOverrideTolerance)
                {
                    settleOverrides[id] = nil
                    lastKnownFrames[id] = frame
                    log("echo win\(id) settle OVERRIDDEN; re-issuing")
                    onDragEnd(.snapback(id))
                    return
                }
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
        // Classify the tick by what a hand can do. Windows do not resize
        // during a title-bar drag — the size stays put while both edges of
        // each axis travel together — so a size change beyond the
        // absorption-noise bound is user intent: an edge or corner grab,
        // whose opposite edges stay pinned. Apps DO absorb writes
        // silently, rounding frames to their own grid, so the first live
        // tick after a placement can carry a slightly different size than
        // the target it was written against; judging size alone misreads
        // that absorption as an edge grab and yanks a splitter by the full
        // origin delta (observed: an 82pt title drag expanded the tile it
        // was dragged out of). Residual: an app absorbing more than
        // `translationMargin` still misroutes its first tick.
        let sizeDelta = abs(frame.width - previous.width) + abs(frame.height - previous.height)
        if sizeDelta > Self.translationMargin {
            clearDrag(id)
            processResize(windowID: id, from: previous, to: frame)
            return
        }
        let dMinX = frame.minX - previous.minX
        let dMaxX = frame.maxX - previous.maxX
        let dMinY = frame.minY - previous.minY
        let dMaxY = frame.maxY - previous.maxY

        // One edge travelled, the opposite stayed pinned: a grab too small
        // to trip the size bound (per-axis, so a corner grab on one axis
        // is not drowned out by noise on the other).
        func clearGrab(_ a: CGFloat, _ b: CGFloat) -> Bool {
            (abs(a) > Self.translationMargin && abs(b) <= Self.edgeMoveThreshold)
                || (abs(b) > Self.translationMargin && abs(a) <= Self.edgeMoveThreshold)
        }
        // Both edges of the axis travelled together: a translation.
        func clearTranslation(_ a: CGFloat, _ b: CGFloat) -> Bool {
            abs(a) > Self.edgeMoveThreshold && abs(b) > Self.edgeMoveThreshold
                && abs(a - b) <= Self.translationMargin
        }

        if clearGrab(dMinX, dMaxX) || clearGrab(dMinY, dMaxY) {
            clearDrag(id)
            processResize(windowID: id, from: previous, to: frame)
            return
        }
        if clearTranslation(dMinX, dMaxX) || clearTranslation(dMinY, dMaxY)
            || originMovedMoreThanSize(previous, frame)
        {
            processMove(windowID: id, from: previous, to: frame)
            return
        }
        clearDrag(id)
        processResize(windowID: id, from: previous, to: frame)
    }

    /// The sub-noise fallback: the origin outpaced the size, so the tick
    /// reads as a move wearing a rounding error.
    private func originMovedMoreThanSize(_ previous: CGRect, _ frame: CGRect) -> Bool {
        let originDelta = abs(frame.minX - previous.minX) + abs(frame.minY - previous.minY)
        let sizeDelta = abs(frame.width - previous.width) + abs(frame.height - previous.height)
        return originDelta > sizeDelta
    }

    // MARK: Drag-out untile

    /// Tracks a title-bar drag: origin-only changes stream in as the user
    /// moves the window. The mouse-up ends the drag immediately (see
    /// `mouseLifted`); each tick also reschedules the debounce fallback,
    /// so a drag whose mouse-up was missed still ends when the ticks go
    /// silent, and a mid-drag pause longer than the debounce ends it
    /// early (snapback or untile); continuing the drag re-tracks from the
    /// new frame. Hand drags stream ticks, so this only bites on real
    /// pauses.
    private func processMove(windowID id: WindowID, from previous: CGRect, to frame: CGRect) {
        if drags[id] == nil {
            drags[id] = DragState(startFrame: previous, lastFrame: frame)
        }
        drags[id]?.lastFrame = frame
        drags[id]?.ticks += 1
        log("move win\(id) dragging tick=\(drags[id]?.ticks ?? 0) frame=\(frame)")
        drags[id]?.cancelDragEnd?()
        drags[id]?.cancelDragEnd = scheduleDragEnd { [weak self] in
            self?.endDrag(id: id, decidedAtMouseUp: false)
        }
    }

    /// A drag just ended: untile past the untile distance, snap back
    /// otherwise. A drag decided at the physical mouse-up is a hand drag
    /// by definition (the button was down the whole time; programmatic
    /// jumps do not click), so a single coalesced tick counts — a fast
    /// fling can arrive as exactly one far AX tick. The silence-debounce
    /// fallback has no such signal and keeps the two-tick rule: a single
    /// far jump there is a programmatic move, and snaps back.
    private func endDrag(id: WindowID, decidedAtMouseUp: Bool) {
        guard context.slotOf(id) != nil, let drag = drags[id] else { return }
        drags[id] = nil
        let distance = hypot(
            drag.lastFrame.origin.x - drag.startFrame.origin.x,
            drag.lastFrame.origin.y - drag.startFrame.origin.y)
        log("dragend win\(id) ticks=\(drag.ticks) distance=\(distance) mouseUp=\(decidedAtMouseUp)")
        let handDrag = decidedAtMouseUp || drag.ticks >= 2
        guard distance > Self.untileDragDistance, handDrag else {
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
    /// fraction live; any edge movement — a movable splitter or a fixed
    /// screen edge — marks the canvas's resize pending, so mouse-up
    /// reasserts and a pulled-away screen edge snaps back.
    private func processResize(windowID id: WindowID, from old: CGRect, to new: CGRect) {
        settleOverrides[id] = nil // a new edge movement supersedes a stale arm
        guard let slot = context.slotOf(id) else { return }
        let space = context.spaceOf(id)
        let bounds = gridProvider.visibleFrame(space)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let threshold = Self.edgeMoveThreshold

        func moved(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > threshold }

        var anyEdgeMoved = false
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
            anyEdgeMoved = true
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
                log("resize win\(id) edge=\(edge) position=\(position) -> \(boundary) grid=\(spaceGrid)")
            }
        }
        if anyEdgeMoved {
            // The movement is committed live where it can be (a splitter
            // fraction, clamped; a fixed screen edge commits nothing),
            // but the reassert it implies waits for mouse-up:
            // reasserting tiles while the button is down fights the drag
            // the user is still steering.
            pendingReasserts[space] = id
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
    /// settle is now due, and every in-progress title-bar drag ends now —
    /// the drop decides (snapback or untile) instead of waiting out the
    /// move-silence debounce, which reads as a second of occupied slot
    /// and un-reflowed neighbours after a drag-out. A trailing AX frame
    /// that arrives after this re-tracks its drag; the next mouse-up (or
    /// the debounce fallback) decides it. The tracker decides only; the
    /// coordinator reads each dragged window's achieved frame and
    /// reasserts or untiles through the owning canvas.
    func mouseLifted() {
        let pending = pendingReasserts
        pendingReasserts = [:]
        for id in pending.values {
            // The settle about to be committed can be overridden by the
            // app's own resize session ending just after it; remember the
            // gesture frame so `handleChange` can recognize the override.
            if let gesture = lastKnownFrames[id] {
                settleOverrides[id] = SettleOverride(gesture: gesture, sightings: 0)
            }
            onDragEnd(.resize(id))
        }
        let inFlight = drags.keys.sorted()
        for id in inFlight where drags[id] != nil {
            endDrag(id: id, decidedAtMouseUp: true)
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
