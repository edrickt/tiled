import CoreGraphics
import Foundation

/// Owns the live drag-resize loop (observe & compensate): gateway change
/// callbacks in, splitter moves and neighbor re-pushes out.
///
/// Previously interleaved with placement records inside TilingController;
/// the real bugs hid in how echo entries interacted with edge diffs, not
/// in either alone. Now the whole loop — echo suppression, edge
/// detection, splitter updates, apply coalescing — lives behind one
/// interface and is testable through it with a fake gateway.
///
/// Protocol: the controller feeds each gateway callback to
/// `handleChange`, and every rect the tracker computes via
/// `rect(for:in:)`; the dragged window's own edge is the source of truth
/// and is skipped on re-push so the tracker never fights an in-progress
/// native drag. Writes are bookkept as expected frames so our own echoes
/// don't recurse.
///
/// Title-bar drags (origin-only changes) are tracked separately from
/// edge drags: moved ticks stream in, and when they go silent the drag
/// ended — past the untile distance the window untiles where dropped
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
    }

    private(set) var grid = GridLayout()
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

    private static let echoTolerance: CGFloat = 32
    private static let staleWrite: TimeInterval = 3
    private static let edgeMoveThreshold: CGFloat = 1
    /// Origin drag distance past which a title-bar drag untiles the window.
    private static let untileDragDistance: CGFloat = 100
    /// Move silence after which a title-bar drag counts as finished.
    private static let dragEndDebounce: TimeInterval = 1

    /// Schedules the drag-end debounce; returns a canceller. Injectable
    /// so tests fire drag ends manually instead of waiting on the runloop.
    typealias DragEndScheduler = (_ fire: @escaping () -> Void) -> () -> Void

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
        let date: Date
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
        expectedFrames[id] = ExpectedWrite(frame: frame, lastDistance: .infinity, date: context.now())
        lastKnownFrames[id] = frame
        clearDrag(id)
    }

    /// Forgets a window: untile, restore, and prune paths call this so
    /// stale echo entries never swallow a future drag on a recycled id.
    func forget(_ id: WindowID) {
        lastKnownFrames[id] = nil
        expectedFrames[id] = nil
        clearDrag(id)
    }

    /// Snaps all splitters back to defaults. Callers re-push occupants.
    func resetDividers() {
        grid = GridLayout()
    }

    /// Rect for `id`'s slot under the current grid. Nil when the window has
    /// no slot (untiled) or no readable frame.
    func rect(for id: WindowID) -> CGRect? {
        guard let slot = context.slotOf(id), let frame = context.frameOf(id) else { return nil }
        return grid.rect(for: slot, in: context.boundsOf(frame))
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
                expectedFrames[id] = nil // write fully applied
                lastKnownFrames[id] = frame
                log("echo win\(id) consumed")
                return
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
    /// moves the window. Each tick reschedules the drag-end debounce — so
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
    /// back too — hand drags stream, one-shot programmatic jumps don't.
    /// (Residual exposure: a programmatic move that arrives as several
    /// ticks and travels far enough untiles — accepted, since such moves
    /// are rare and the window ends up untiled where it was put.)
    private func endDrag(id: WindowID) {
        guard let slot = context.slotOf(id), let drag = drags[id] else { return }
        drags[id] = nil
        let distance = hypot(
            drag.lastFrame.origin.x - drag.startFrame.origin.x,
            drag.lastFrame.origin.y - drag.startFrame.origin.y)
        log("dragend win\(id) ticks=\(drag.ticks) distance=\(distance)")
        guard distance > Self.untileDragDistance, drag.ticks >= 2 else {
            let rect = grid.rect(for: slot, in: context.boundsOf(drag.lastFrame))
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
            if grid.update(boundary: boundary, toPosition: position, in: bounds) {
                changed = true
                log("resize win\(id) edge=\(edge) position=\(position) -> \(boundary) grid=\(grid)")
            }
        }
        if changed {
            scheduleApply(excluding: id)
        }
    }

    // MARK: Coalescing

    /// Recomputes every occupant's rect under the current grid, except the
    /// dragged window, and schedules one push per runloop tick.
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
            rects[occupant] = grid.rect(for: slot, in: context.boundsOf(frame))
        }
        schedule(rects: rects, excluding: excluding)
    }

    private func scheduleApply(excluding id: WindowID) {
        // Neighbor rects are computed now, pushed on the next tick: the
        // dragged window keeps moving under the user's hand meanwhile.
        reassertAll(occupants: context.occupants(), excluding: id)
    }

    private func schedule(rects: [WindowID: CGRect], excluding: WindowID?) {
        for (id, rect) in rects {
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

    /// Sum of per-edge deltas between two frames.
    private static func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.maxX - b.maxX)
            + abs(a.minY - b.minY) + abs(a.maxY - b.maxY)
    }
}
