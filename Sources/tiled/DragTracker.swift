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
/// (`mousePressed`/`mouseLifted`, wired by the controller's global event
/// monitors). Resizing the tiles under a held button fights the user's
/// drag; on release the canvas reasserts the whole layout at once — a
/// screen edge the drag pulled away included. A resize tick
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
/// A single far jump with no recent hand press on the window is never a
/// hand drag, so it snaps back too — even when an unrelated click lifts
/// the button before the debounce.
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

    /// What one axis's two edge deltas say about a tick. The tracker sees
    /// only where the two edges of an axis landed, never the hand that moved
    /// them, so the shape comes from the pair of deltas: one edge moving with
    /// the opposite pinned is a grab; both moving together is a translation;
    /// both moving apart, or one far outrunning the other, is a resize.
    enum TickShape: Equatable {
        /// Neither edge moved beyond the noise bound in a recognizable way.
        case none
        /// Both edges moved together: the window translated on this axis.
        case translation
        /// One edge moved while the opposite stayed pinned: an edge grab.
        case grab
        /// Both edges moved apart, or one far outran the other: a resize.
        case resize

        /// Classifies one axis from its two edge deltas.
        ///
        /// `noise` absorbs the first tick after a placement: an app can
        /// silently round a written frame, and that absorbed size must not
        /// read as an edge grab — the residual that yanked a splitter by the
        /// whole origin delta (F23). `dominance` keeps a drifty grab from
        /// reading as a translation: when one edge leads the other by more
        /// than this ratio, the tick resizes even though both edges moved
        /// the same way. `pinned` is the opposite-edge jitter floor.
        static func classify(
            _ first: CGFloat,
            _ second: CGFloat,
            noise: CGFloat,
            dominance: CGFloat,
            pinned: CGFloat
        ) -> TickShape {
            let firstMoved = abs(first) > noise
            let secondMoved = abs(second) > noise
            if firstMoved && secondMoved {
                guard first.sign == second.sign else { return .resize }
                let larger = max(abs(first), abs(second))
                let smaller = min(abs(first), abs(second))
                return larger > dominance * smaller ? .resize : .translation
            }
            if firstMoved || secondMoved { return .grab }

            // Both edges under the noise bound: absorption and jitter. A
            // same-direction pair that travelled together is still a tiny
            // translation (a small title-bar drag); one pinned edge and one
            // moving is a tiny grab. Opposing sub-noise edges are
            // absorption, not a resize.
            let larger = max(abs(first), abs(second))
            guard larger > pinned, first.sign == second.sign else {
                return .none
            }
            return min(abs(first), abs(second)) <= pinned ? .grab : .translation
        }

        /// What one tick asks the tracker to do: which path `handleChange`
        /// takes. The aggregate is never one of the per-axis shapes: an edge
        /// move on either axis is a resize even when the other axis
        /// translated.
        enum Intent: Equatable {
            /// A title-bar drag: both axes translated, nothing reaches a
            /// splitter.
            case translation
            /// An edge move on either axis: commit the splitters, and mark
            /// the canvas's resize pending.
            case resize
        }

        /// Aggregates the axes: any grab or resize wins, because an edge move
        /// on either axis must reach the splitters even when the other axis
        /// absorbed cleanly; otherwise a translation moves the window. No
        /// recognizable shape keeps the conservative resize fallback.
        static func intent(_ horizontal: TickShape, _ vertical: TickShape) -> Intent {
            if horizontal == .grab || horizontal == .resize
                || vertical == .grab || vertical == .resize
            {
                return .resize
            }
            if horizontal == .translation || vertical == .translation {
                return .translation
            }
            return .resize
        }
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
        /// Whether a recent hand press/drag landed inside this window's
        /// start frame. A single far tick is a hand drag only with that
        /// per-window evidence; a programmatic jump followed by an
        /// unrelated click must not borrow the click's mouse-up.
        let beganUnderHandPress: Bool
        var cancelDragEnd: (() -> Void)?
    }
    private var drags: [WindowID: DragState] = [:]
    /// The last hand-press evidence: where the left button went down,
    /// and when it was last refreshed by a drag. A programmatic AX jump
    /// carries no such signal. The press point must fall inside the
    /// dragged window's start frame, so a press elsewhere cannot
    /// authorize it. The point is deliberately not moved to the drag's
    /// latest location: a coalesced drag's last point is the drop,
    /// normally outside the start frame. The point is an approximation
    /// for overlapping windows (the tracker has no z-order): a press on
    /// one window lying over another can authorize the lower one.
    private var handPressPoint: CGPoint?
    private var handPressAt: Date?
    /// How fresh the hand evidence must be. Mouse drags stream alongside
    /// AX ticks; a press held still for longer only becomes a drag when
    /// the drag event refreshes this stamp.
    private static let handPressWindow: TimeInterval = 0.5

    /// Windows whose edge drags await mouse-up. The splitter fractions (if
    /// any) already committed; the reassert the movement implies waits for
    /// the click to lift (see `mouseLifted`). A drag that moved only a
    /// fixed screen edge commits no fraction but still marks: the release
    /// reassert is what pulls the edge back. One set entry per window, not
    /// one per canvas: two windows can edge-drag on the same canvas before
    /// the button lifts, and each needs its own achieved-frame reconcile.
    private var pendingReasserts: Set<WindowID> = []

    /// The frame the app's own resize session lands over our reassert
    /// write, keyed by window: the gesture's final frame, and how many
    /// consecutive ticks have re-reported it. A departing animation matches
    /// that frame once and moves on, so the repeated-frame shape needs two
    /// sightings, while a settled write that escapes straight back to it is
    /// proof by itself (see `echoMatch`).
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
    /// Per-edge travel below this is noise: app absorption, rounding, and
    /// jitter. One edge over it starts a gesture; the opposite edge still
    /// under it means a grab rather than a translation.
    private static let tickNoiseBound: CGFloat = 8
    /// How much farther one edge may travel than the other before a
    /// same-direction tick reads as a resize rather than a translation.
    /// Above 1:1 so an absorbed translation (both edges travelling the same
    /// way) stays a move, while a led edge still resizes.
    private static let tickDominanceRatio: CGFloat = 2
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

    /// Drops an expectation armed for a write the gateway refused. The
    /// pending convergence check must find nothing to judge, not the
    /// frame the app never accepted; the caller reseeds the diff baseline
    /// with the frame the gateway still reports.
    func cancelExpected(_ id: WindowID) {
        expectedFrames[id] = nil
    }

    /// Drops a pending edge reassert for `id`: a landed expand or collapse
    /// supersedes the gesture that never reached mouse-up, so the next
    /// release must not reconcile the splitters from the frame that action
    /// imposed. Other windows' pending reasserts stand.
    func clearPendingReassert(_ id: WindowID) {
        pendingReasserts.remove(id)
    }

    /// Seeds only the diff baseline for `id`, without arming an echo
    /// expectation. The write policy calls it for every write that lands
    /// nowhere (an off-Space deferral, a no-op skip, a refusal): none of
    /// them reaches `markExpected`, and without a baseline the first
    /// drag after that write diffs against a stale frame and is misread.
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
        pendingReasserts.remove(id)
    }

    // MARK: Change entry point

    /// Feeds one gateway change callback through echo suppression and edge
    /// detection. `slotOf` returning nil means untiled: ignored, since
    /// observation registrations outlive records.
    func handleChange(id: WindowID, frame: CGRect) {
        guard context.slotOf(id) != nil else { return }
        log("notif win\(id) frame=\(frame)")
        guard !recordSettleSighting(id: id, frame: frame) else { return }

        switch echoMatch(id: id, frame: frame) {
        case .overridden:
            reissueSettle(id: id, frame: frame)
        case .echo(let tracksOrigin):
            let previous = lastKnownFrames[id]
            lastKnownFrames[id] = frame
            // A pure-origin drift is a hand on the title bar, not animation
            // settling, which moves edges; track it, or a grab that starts
            // the instant a write lands leaves the window offset from its
            // tile with no drag to snap back.
            if tracksOrigin, let previous, previous.size == frame.size,
                previous.origin != frame.origin
            {
                processMove(windowID: id, from: previous, to: frame)
            }
        case .live:
            // Diff against the previous frame of ANY kind. Drags that change
            // a window's origin arrive as Moved+Resized pairs with identical
            // frames; comparing Resized against the paired Moved would
            // silently drop every left/top/corner drag. Origin-only changes
            // are title-bar moves: left off-grid until the next layout
            // assertion.
            let previous = lastKnownFrames[id]
            lastKnownFrames[id] = frame
            guard let previous, previous != frame else { return }
            // Classify each axis by its two edge deltas, then aggregate. A
            // size change alone is not proof of a grab: apps absorb writes
            // silently, rounding frames to their own grid, so the first live
            // tick after a placement can carry an absorbed size. The noise
            // bound keeps that absorption out of the decision, and the
            // dominance ratio keeps a genuinely led edge a resize even when
            // the opposite edge drifts.
            let horizontal = TickShape.classify(
                frame.minX - previous.minX,
                frame.maxX - previous.maxX,
                noise: Self.tickNoiseBound,
                dominance: Self.tickDominanceRatio,
                pinned: Self.edgeMoveThreshold)
            let vertical = TickShape.classify(
                frame.minY - previous.minY,
                frame.maxY - previous.maxY,
                noise: Self.tickNoiseBound,
                dominance: Self.tickDominanceRatio,
                pinned: Self.edgeMoveThreshold)
            switch TickShape.intent(horizontal, vertical) {
            case .translation:
                processMove(windowID: id, from: previous, to: frame)
            case .resize:
                clearDrag(id)
                processResize(windowID: id, from: previous, to: frame)
            }
        }
    }

    // MARK: Echo suppression

    /// What one incoming frame means for the tracker.
    private enum EchoMatch {
        /// Our own write or its animation tail: record the frame and decide
        /// nothing. `tracksOrigin` marks a pure-origin drift inside the
        /// target radius, which no settling animation produces.
        case echo(tracksOrigin: Bool)
        /// The frame reverted to a settled write's gesture frame, so the
        /// app's own resize session landed over the write.
        case overridden
        /// No write explains the frame, so it is the user's.
        case live
    }

    /// Counts one sighting of a frame that reverted to the settle's gesture
    /// frame, and returns true when it re-issues the settle. One sighting is
    /// not proof, because a departing animation matches the gesture frame on
    /// its first step, so this waits for the second.
    private func recordSettleSighting(id: WindowID, frame: CGRect) -> Bool {
        guard var arm = settleOverrides[id] else { return false }
        guard Self.framesClose(arm.gesture, frame, tolerance: Self.settleOverrideTolerance)
        else {
            // A match followed by a different frame is a departing animation,
            // not a stuck session: start the count over.
            arm.sightings = 0
            settleOverrides[id] = arm
            return false
        }
        arm.sightings += 1
        guard arm.sightings >= 2 else {
            settleOverrides[id] = arm
            return false
        }
        reissueSettle(id: id, frame: frame)
        return true
    }

    /// Re-issues a settle that the app's own resize session overrode, once.
    /// The override is consumed here, so a further reversion cannot loop.
    private func reissueSettle(id: WindowID, frame: CGRect) {
        expectedFrames[id] = nil
        settleOverrides[id] = nil
        lastKnownFrames[id] = frame
        log("echo win\(id) settle OVERRIDDEN; re-issuing")
        onDragEnd(.snapback(id))
    }

    /// Matches one incoming frame against the write the tracker waits for.
    /// Order matters: a tick inside the target radius is an echo even when
    /// the write has gone stale, and only a tick that moves away from the
    /// target can escape.
    private func echoMatch(id: WindowID, frame: CGRect) -> EchoMatch {
        guard var entry = expectedFrames[id] else { return .live }

        if Self.framesClose(entry.frame, frame, tolerance: Self.echoTolerance) {
            if entry.settled, context.now().timeIntervalSince(entry.date) > Self.settleWindow {
                // Settling is over, but this tick already proved close:
                // swallow it against the target rather than falling into the
                // escape check below, whose stale lastDistance would misread
                // any tail offset as a takeover.
                expectedFrames[id] = nil
                log("echo win\(id) settle-expired")
                return .echo(tracksOrigin: true)
            }
            let wasSettled = entry.settled
            if wasSettled {
                log("echo win\(id) settling")
            } else {
                // Write converged: keep swallowing close ticks through the
                // settle window instead of going live, because the animation
                // tail is still in flight and its absolute positions must
                // never reach the splitters.
                entry.settled = true
                entry.date = context.now()
                entry.lastDistance = 0
                expectedFrames[id] = entry
                log("echo win\(id) consumed")
            }
            return .echo(tracksOrigin: wasSettled)
        }

        if entry.settled {
            expectedFrames[id] = nil // left the radius; live below
            log("echo win\(id) settle-end")
        }
        let distance = Self.frameDistance(entry.frame, frame)
        if distance > entry.lastDistance + 1 {
            expectedFrames[id] = nil // user took over
            log("echo win\(id) ESCAPE dist=\(distance) last=\(entry.lastDistance)")
            if entry.settled, let arm = settleOverrides[id],
                Self.framesClose(arm.gesture, frame, tolerance: Self.settleOverrideTolerance)
            {
                return .overridden
            }
            return .live
        }
        if context.now().timeIntervalSince(entry.date) > Self.staleWrite {
            expectedFrames[id] = nil // write never applied; stop waiting
            log("echo win\(id) stale")
            return .live
        }
        entry.lastDistance = distance
        expectedFrames[id] = entry
        log("echo win\(id) converging dist=\(distance)")
        return .echo(tracksOrigin: false)
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
            let handPress = handPressPoint.map { previous.contains($0) } == true
                && handPressAt.map {
                    context.now().timeIntervalSince($0) <= Self.handPressWindow
                } == true
            drags[id] = DragState(
                startFrame: previous, lastFrame: frame,
                beganUnderHandPress: handPress)
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
    /// only when it began with fresh hand evidence inside the window:
    /// programmatic jumps carry no press, and an unrelated click — even
    /// one on another window — cannot decide their far tick as a
    /// drag-out. Such a hand drag may arrive as exactly one coalesced
    /// tick — a fast drag does. The silence-debounce fallback has no
    /// button signal and keeps the two-tick rule: a single far jump there
    /// is a programmatic move, and snaps back.
    private func endDrag(id: WindowID, decidedAtMouseUp: Bool) {
        guard context.slotOf(id) != nil, let drag = drags[id] else { return }
        drags[id] = nil
        if drags.isEmpty {
            // A debounce fallback can end the gesture without a mouse-up;
            // drop its evidence so a later programmatic jump cannot use it.
            handPressPoint = nil
            handPressAt = nil
        }
        let distance = hypot(
            drag.lastFrame.origin.x - drag.startFrame.origin.x,
            drag.lastFrame.origin.y - drag.startFrame.origin.y)
        log("dragend win\(id) ticks=\(drag.ticks) distance=\(distance) mouseUp=\(decidedAtMouseUp)")
        let handDrag = decidedAtMouseUp
            ? drag.beganUnderHandPress
            : drag.ticks >= 2
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
        let occupied = occupiedSlots(in: space)
        var spaceGrid = grid(for: space)
        var committed = false
        for edge in TileEdge.allCases {
            let position = edge.position(in: new)
            guard moved(position, edge.position(in: old)) else { continue }
            anyEdgeMoved = true
            // The dragged window's own edge is the source of truth; skip it
            // below so we never fight an in-progress native drag.
            guard let boundary = GridLayout.boundary(edge: edge, slot: slot) else { continue }
            if spaceGrid.update(
                edge: edge, of: slot, toPosition: position, in: bounds,
                occupants: occupied)
            {
                committed = true
                log("resize win\(id) edge=\(edge) position=\(position) -> \(boundary) grid=\(spaceGrid)")
            }
        }
        if committed { gridProvider.setGrid(spaceGrid, space) }
        if anyEdgeMoved {
            // The movement is committed live where it can be (a splitter
            // fraction, clamped; a fixed screen edge commits nothing),
            // but the reassert it implies waits for mouse-up:
            // reasserting tiles while the button is down fights the drag
            // the user is still steering.
            pendingReasserts.insert(id)
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

    /// The user pressed the left button at `point`, in the same AppKit
    /// global coordinates as the frames this tracker compares. Records
    /// the hand evidence a move tick cannot carry: a programmatic AX jump
    /// and a real drag can both arrive as a single far tick, and only a
    /// recent press inside the window tells them apart when an unrelated
    /// click lifts the button.
    func mousePressed(at point: CGPoint) {
        handPressPoint = point
        handPressAt = context.now()
    }

    /// The user moved the mouse with the button down. Refreshes the
    /// freshness of the press evidence so a press held still before the
    /// drag does not go stale. The press point stays put: it is the
    /// containment witness, and a coalesced drag's latest point is the
    /// drop, outside the window's start frame.
    func mouseDragged() {
        handPressAt = context.now()
    }

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
        handPressPoint = nil
        handPressAt = nil
        let pending = pendingReasserts
        pendingReasserts = []
        for id in pending.sorted() {
            // The settle about to be committed can be overridden by the
            // app's own resize session ending just after it; remember the
            // gesture frame so `handleChange` can recognize the override.
            if let gesture = lastKnownFrames[id] {
                settleOverrides[id] = SettleOverride(gesture: gesture, sightings: 0)
            }
            onDragEnd(.resize(id))
        }
        let inFlight = drags.keys.sorted()
        for id in inFlight {
            endDrag(id: id, decidedAtMouseUp: true)
        }
    }

    // MARK: Geometry helpers

    /// True when `a` and `b` differ by at most `tolerance` per edge.
    static func framesClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.maxX - b.maxX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    /// Sum of per-edge deltas between two frames.
    private static func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.maxX - b.maxX)
            + abs(a.minY - b.minY) + abs(a.maxY - b.maxY)
    }
}
