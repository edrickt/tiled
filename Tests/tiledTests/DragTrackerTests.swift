import XCTest
@testable import tiled

/// DragTracker through its own interface: echo suppression, edge-to-
/// splitter mapping against the canvas's visible frame, and the drag-end
/// decision it hands the coordinator. Driven by direct `handleChange`
/// calls. No controller, no AX; the loop tested where it lives. The
/// tracker computes no rect: the rect assertions live with the canvas.
final class DragTrackerTests: XCTestCase {
    private var gateway: FakeWindowGateway!
    /// The drag-end decisions the tracker emitted, in order.
    private var decisions: [DragTracker.DragDecision]!
    private var tracker: DragTracker!
    private var slots: [WindowID: Slot]!
    private var handles: [WindowID: WindowHandle]!
    private var occupants: [Slot: WindowID]!
    /// Injectable clock backing the tracker's echo timestamps.
    private var now = Date()
    /// Drag-end fires captured from the injectable scheduler (latest wins).
    private var dragEndFires: [() -> Void]!
    /// The splitter fractions the tracker reads and writes, standing in
    /// for the canvas that owns them in production.
    private var grids: [TilingSpaceKey: GridLayout] = [:]
    /// The canvas's stored visible frame the live splitter commit divides
    /// against. The tracker never resolves one from a window's geometry.
    private var visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        decisions = []
        slots = [:]
        handles = [:]
        occupants = [:]
        now = Date()
        dragEndFires = []
        grids = [:]
        visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        tracker = configuredTracker()
    }

    /// The shared rig: every grid and visible frame is served from the
    /// test's stores, and every drag-end decision is recorded.
    private func configuredTracker() -> DragTracker {
        DragTracker(
            context: DragTracker.Context(
                slotOf: { [weak self] in self?.slots[$0] },
                occupants: { [weak self] in self?.occupants ?? [:] },
                now: { [weak self] in self?.now ?? Date() }),
            gridProvider: provider(),
            onDragEnd: { [weak self] in self?.decisions.append($0) },
            scheduleDragEnd: { [weak self] fire in
                self?.dragEndFires.append(fire)
                return {}
            })
    }

    /// A tracker wired like the shared one but with an injectable
    /// `liveFrameOf` (the seam the silent-convergence check reads).
    private func makeTracker(
        liveFrameOf: @escaping (WindowID) -> CGRect?
    ) -> DragTracker {
        DragTracker(
            context: DragTracker.Context(
                slotOf: { [weak self] in self?.slots[$0] },
                occupants: { [weak self] in self?.occupants ?? [:] },
                now: { [weak self] in self?.now ?? Date() },
                liveFrameOf: liveFrameOf),
            gridProvider: provider(),
            onDragEnd: { [weak self] in self?.decisions.append($0) },
            scheduleDragEnd: { [weak self] fire in
                self?.dragEndFires.append(fire)
                return {}
            })
    }

    /// The grid store the tracker reads and writes through, standing in
    /// for the canvas provider production wires, plus the canvas's one
    /// stored visible frame.
    private func provider() -> DragTracker.GridProvider {
        DragTracker.GridProvider(
            grid: { [weak self] key in
                self?.grids[key ?? .displayless] ?? GridLayout()
            },
            setGrid: { [weak self] updated, key in
                self?.grids[key ?? .displayless] = updated
            },
            visibleFrame: { [weak self] _ in self?.visibleFrame ?? .zero })
    }

    /// The current splitter set the tracker moved.
    private func grid(_ key: TilingSpaceKey? = nil) -> GridLayout {
        grids[key ?? .displayless] ?? GridLayout()
    }

    private func tile(_ id: WindowID, _ slot: Slot, frame: CGRect) {
        tile(id, slot, frame: frame, tracker: tracker)
    }

    private func tile(
        _ id: WindowID, _ slot: Slot, frame: CGRect, tracker: DragTracker
    ) {
        handles[id] = gateway.addWindow(frame: frame)
        slots[id] = slot
        occupants[slot] = id
        tracker.markExpected(id, frame)
    }

    /// Streams a real edge drag: a close echo tick is swallowed, then the
    /// far frame escapes the tolerance radius and reaches the splitters.
    private func drag(_ id: WindowID, from frame: CGRect, to target: CGRect, tracker: DragTracker) {
        var echo = frame
        echo.size.width += min(8, abs(target.width - frame.width))
        tracker.handleChange(id: id, frame: echo)
        tracker.handleChange(id: id, frame: target)
    }

    /// Streams a title-bar drag after clearing the echo entry: tick 1
    /// seeds the diff baseline, ticks 2+ register as drag movement.
    private func dragTicks(_ id: WindowID, size: CGSize, to origins: [(CGFloat, CGFloat)]) {
        for (x, y) in origins {
            tracker.handleChange(id: id, frame: CGRect(origin: CGPoint(x: x, y: y), size: size))
        }
    }

    // MARK: Echo suppression

    func testConvergingTickIsSwallowed() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 400, width: 500, height: 400))

        var echo = CGRect(x: 0, y: 400, width: 500, height: 400)
        echo.origin.x += 10 // within tolerance on every edge
        tracker.handleChange(id: 1, frame: echo)

        XCTAssertTrue(decisions.isEmpty)
        XCTAssertTrue(dragEndFires.isEmpty, "the echo path is the only outcome that never schedules a drag end")
        XCTAssertEqual(grid(), GridLayout())
    }

    func testDivergingTickMovesSplitterAgainstTheCanvasFrame() {
        // Both windows sit in the canvas frame's own quarter tiles: an
        // edge drag divides the edge against the canvas's stored visible
        // frame (height 800), never the window's own geometry.
        tile(1, .topLeft, frame: CGRect(x: 0, y: 400, width: 500, height: 400))
        tile(2, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 500, height: 400))

        // Converge first (like an animated write), then escape: the top
        // edge of BottomLeft drops to y=240.
        var first = CGRect(x: 0, y: 0, width: 500, height: 400)
        first.size.height += 8
        tracker.handleChange(id: 2, frame: first)
        tracker.handleChange(id: 2, frame: CGRect(x: 0, y: 0, width: 500, height: 240))

        // 240 / 800 = 0.3: the canvas frame's fraction, not the window's.
        XCTAssertEqual(grid().leftRowSplit, 0.3, accuracy: 0.001,
            "the dragged edge divides against the canvas frame")
    }

    func testResizingLeftTwoThirdsCentersItsHiddenDivider() {
        let tiled = GridLayout().rect(for: .sixthsLeftTwoThirds, in: visibleFrame)
        tile(1, .sixthsLeftTwoThirds, frame: tiled)

        var resized = tiled
        resized.size.width = 0.78 * visibleFrame.width
        drag(1, from: tiled, to: resized, tracker: tracker)

        XCTAssertEqual(
            grid().sixthsRightSplit, 0.78, accuracy: 0.001,
            "the dragged edge lands where the user put it")
        XCTAssertEqual(
            grid().sixthsLeftSplit, 0.39, accuracy: 0.001,
            "the hidden divider bisects the resized two-thirds window")
    }

    func testResizingRightTwoThirdsCentersItsHiddenDivider() {
        let tiled = GridLayout().rect(for: .sixthsRightTwoThirds, in: visibleFrame)
        tile(1, .sixthsRightTwoThirds, frame: tiled)

        var resized = tiled
        resized.origin.x = 0.22 * visibleFrame.width
        resized.size.width = visibleFrame.maxX - resized.minX
        drag(1, from: tiled, to: resized, tracker: tracker)

        XCTAssertEqual(grid().sixthsLeftSplit, 0.22, accuracy: 0.001)
        XCTAssertEqual(
            grid().sixthsRightSplit, 0.61, accuracy: 0.001,
            "the hidden divider bisects the resized right two-thirds window")
    }

    func testResizingTheAdjacentThirdAlsoCentersTheTwoThirdsHiddenDivider() {
        // The third's edge and the two-thirds window's edge are the same
        // splitter; grabbing either one resizes both windows and must keep
        // the two-thirds window's hidden divider centered.
        let leftTwo = GridLayout().rect(for: .sixthsLeftTwoThirds, in: visibleFrame)
        let rightThird = GridLayout().rect(for: .sixthRight, in: visibleFrame)
        tile(1, .sixthsLeftTwoThirds, frame: leftTwo)
        tile(2, .sixthRight, frame: rightThird)

        var resized = rightThird
        resized.origin.x = 0.7 * visibleFrame.width
        resized.size.width = visibleFrame.maxX - resized.minX
        drag(2, from: rightThird, to: resized, tracker: tracker)

        XCTAssertEqual(grid().sixthsRightSplit, 0.7, accuracy: 0.001)
        XCTAssertEqual(
            grid().sixthsLeftSplit, 0.35, accuracy: 0.001,
            "the two-thirds window still reads as two equal thirds")
    }

    func testCornerDragMovesTwoBoundariesInOneChange() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 400, width: 500, height: 400))

        // Echo tick first (swallowed), then a corner drag: the right edge
        // moves to 600 (columnSplit) and the bottom edge to 300
        // (leftRowSplit) in a single change; both boundaries must update.
        var echo = CGRect(x: 0, y: 400, width: 500, height: 400)
        echo.size.width += 8
        tracker.handleChange(id: 1, frame: echo)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 300, width: 600, height: 500))

        XCTAssertEqual(grid().columnSplit, 0.6, accuracy: 0.001,
            "right edge at 600/1000")
        XCTAssertEqual(grid().leftRowSplit, 0.375, accuracy: 0.001,
            "bottom edge at 300/800")
    }

    func testOriginOnlyMoveTracksDragWithoutMovingSplitter() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 400, width: 500, height: 400))
        tracker.forget(1)

        // Same size, shifted origin across two ticks: a title-bar move.
        // The first tick seeds the baseline (no echo entry after forget).
        tracker.handleChange(id: 1, frame: CGRect(x: 50, y: 450, width: 500, height: 400))
        tracker.handleChange(id: 1, frame: CGRect(x: 100, y: 500, width: 500, height: 400))

        // Drag tracking never touches the grid and decides nothing until
        // the drag end fires.
        XCTAssertEqual(grid(), GridLayout())
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertFalse(dragEndFires.isEmpty, "move ticks schedule a drag end")
    }

    func testUntrackedWindowIsIgnored() {
        tracker.handleChange(id: 99, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertTrue(dragEndFires.isEmpty, "no drag is tracked, so no drag end is scheduled")
        XCTAssertEqual(grid(), GridLayout(), "the grid is untouched")
    }

    // MARK: Drag-end decisions

    func testEdgeDragEmitsResizeOnMouseUp() {
        // The tracker decides only: an edge drag commits the splitter
        // live, then names the window on mouse-up. It computes no rect
        // and schedules no write.
        tile(1, .topLeft, frame: CGRect(x: 0, y: 400, width: 500, height: 400))
        tile(2, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 500, height: 400))

        drag(2, from: CGRect(x: 0, y: 0, width: 500, height: 400),
             to: CGRect(x: 0, y: 0, width: 500, height: 240), tracker: tracker)
        XCTAssertEqual(grid().leftRowSplit, 0.3, accuracy: 0.001)
        XCTAssertTrue(decisions.isEmpty, "an edge drag decides nothing until mouse-up")

        tracker.mouseLifted()

        XCTAssertEqual(decisions, [.resize(2)])
    }

    func testMouseUpWithoutPendingResizeDecidesNothing() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 400, width: 500, height: 400))

        tracker.mouseLifted()

        XCTAssertTrue(decisions.isEmpty, "a click commits nothing on its own")
    }

    func testTrailingTickAfterMouseUpDecidesAgainOnTheNextMouseUp() {
        // AX can stream the drag's final frame after the mouse-up fired:
        // that tick re-arms the pending resize (splitter already moved),
        // and the next mouse-up anywhere decides again. Documented
        // residual: one stale neighbor layout between the trailing tick
        // and the next click.
        tile(1, .topLeft, frame: CGRect(x: 0, y: 400, width: 500, height: 400))
        tile(2, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 500, height: 400))

        drag(2, from: CGRect(x: 0, y: 0, width: 500, height: 400),
             to: CGRect(x: 0, y: 0, width: 500, height: 320), tracker: tracker)
        let firstSplit = grid().leftRowSplit
        XCTAssertNotEqual(firstSplit, 0.5)
        tracker.mouseLifted()
        XCTAssertEqual(decisions, [.resize(2)])

        // The drag's final frame trails the mouse-up: a new splitter
        // fraction, no decision of its own.
        tracker.handleChange(id: 2, frame: CGRect(x: 0, y: 0, width: 500, height: 240))
        XCTAssertNotEqual(
            grid().leftRowSplit, firstSplit,
            "the trailing tick moved the splitter further")
        XCTAssertEqual(
            decisions, [.resize(2)],
            "the trailing tick waits for the next mouse-up")

        tracker.mouseLifted()
        XCTAssertEqual(decisions, [.resize(2), .resize(2)], "the next mouse-up commits the trailing tick")
    }

    func testShortDragEmitsSnapback() {
        let size = CGSize(width: 500, height: 400)
        let tileRect = CGRect(origin: CGPoint(x: 0, y: 400), size: size)
        tile(1, .topLeft, frame: tileRect)
        tracker.forget(1)

        dragTicks(1, size: size, to: [(0, 400), (20, 420), (30, 430)])
        dragEndFires.last?()

        XCTAssertEqual(decisions, [.snapback(1)], "a short title-bar drag snaps back")
    }

    func testDragPastUntileDistanceEmitsUntile() {
        let size = CGSize(width: 500, height: 400)
        tile(1, .topLeft, frame: CGRect(origin: CGPoint(x: 0, y: 400), size: size))
        tracker.forget(1)

        dragTicks(1, size: size, to: [(0, 400), (40, 440), (100, 500)])
        dragEndFires.last?()

        XCTAssertEqual(decisions, [.untile(1)], "drag distance ~141pt crosses the untile distance")
    }

    func testMouseUpEndsAnInProgressTitleBarDragImmediately() {
        // The reported lag: dragging a tiled window out of its tile (far
        // enough to untile, even out of its Space) left the slot occupied
        // and the neighbours un-reflowed for ~1s after the drop, because
        // the untile waited for the 0.5s move-silence debounce. The
        // mouse-up must end an in-progress title-bar drag the way it ends
        // an edge drag.
        let size = CGSize(width: 500, height: 400)
        tile(1, .topLeft, frame: CGRect(origin: CGPoint(x: 0, y: 400), size: size))
        tracker.forget(1)

        dragTicks(1, size: size, to: [(0, 400), (40, 440), (100, 500)])
        XCTAssertTrue(decisions.isEmpty, "streaming ticks decide nothing on their own")

        tracker.mouseLifted()

        XCTAssertEqual(
            decisions, [.untile(1)],
            "the mouse-up decides the title-bar drag immediately, no debounce")
    }

    func testMouseUpEndsAShortTitleBarDragWithSnapback() {
        let size = CGSize(width: 500, height: 400)
        tile(1, .topLeft, frame: CGRect(origin: CGPoint(x: 0, y: 400), size: size))
        tracker.forget(1)

        dragTicks(1, size: size, to: [(0, 400), (20, 420), (30, 430)])
        tracker.mouseLifted()

        XCTAssertEqual(decisions, [.snapback(1)], "a short drag snaps back at mouse-up")
    }

    func testTrailingTickAfterTitleBarMouseUpWaitsForTheNextMouseUpOrDebounce() {
        // AX can stream the drag's final frame after the mouse-up: the
        // tracker re-tracks it and the next mouse-up (or the fallback
        // debounce) decides, mirroring the resize path's documented
        // residual.
        let size = CGSize(width: 500, height: 400)
        tile(1, .topLeft, frame: CGRect(origin: CGPoint(x: 0, y: 400), size: size))
        tracker.forget(1)

        dragTicks(1, size: size, to: [(0, 400), (40, 440), (100, 500)])
        tracker.mouseLifted()
        XCTAssertEqual(decisions, [.untile(1)])

        // The final frame trails the mouse-up, far from the drop: a new
        // drag the tracker re-tracks, deciding nothing on its own.
        tracker.handleChange(id: 1, frame: CGRect(x: 300, y: 800, width: 500, height: 400))
        XCTAssertEqual(
            decisions, [.untile(1)],
            "a trailing tick after the mouse-up does not decide on its own")

        tracker.mouseLifted()
        XCTAssertEqual(
            decisions, [.untile(1), .untile(1)],
            "the next mouse-up decides the trailing tick; a single far tick "
                + "is a hand gesture there, and the second untile is a no-op upstream")
    }

    func testAbsorbedSizeTickDuringTitleDragTracksAsAMove() {
        // Captured live: the app absorbed the placement write (its true
        // frame 559x505 vs the 560x509.5 target, no notification), then
        // the user's first title-drag tick arrived as (82, 510, 559, 505).
        // The 5.5pt size delta against the phantom baseline misread as an
        // edge drag and yanked sixthsLeftSplit by the full 82pt origin
        // delta — the reported "expand the tile". A hand on the title bar
        // translates the window; an edge grab pins the opposite edge. The
        // origin moved farther than the size: it is a move.
        tile(1, .sixthTopLeft, frame: CGRect(x: 0, y: 509.5, width: 560, height: 509.5))
        // The placement echo expires un-consumed: the app emitted nothing
        // for it (silent absorption), as on live AX.
        now += TimeInterval(4)

        tracker.handleChange(id: 1, frame: CGRect(x: 82, y: 510, width: 559, height: 505))

        XCTAssertEqual(
            grid(), GridLayout(),
            "an origin-dominant tick is a translation, never a splitter yank")

        // The drag tracks: the drop untiles.
        tracker.handleChange(id: 1, frame: CGRect(x: 200, y: 520, width: 559, height: 505))
        tracker.mouseLifted()
        XCTAssertEqual(decisions, [.untile(1)])
    }

    func testSizeDominantTickStillResizes() {
        // An edge grab pins the opposite edge: the size moves at least as
        // far as the origin. That stays a resize.
        tile(1, .topLeft, frame: CGRect(x: 0, y: 400, width: 500, height: 400))

        // Close tick first (a fresh echo entry swallows the first tick by
        // design), then the grab: origin pinned, width grows 100.
        var echo = CGRect(x: 0, y: 400, width: 500, height: 400)
        echo.size.width += 8
        tracker.handleChange(id: 1, frame: echo)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 400, width: 600, height: 400))
        XCTAssertEqual(grid().columnSplit, 0.6, accuracy: 0.001)
    }

    func testSingleFarJumpEmitsSnapback() {
        let size = CGSize(width: 500, height: 400)
        tile(1, .topLeft, frame: CGRect(origin: CGPoint(x: 0, y: 400), size: size))
        tracker.forget(1)

        // One far tick: a programmatic move, not a hand drag (hand drags
        // stream). It must snap back, never untile.
        dragTicks(1, size: size, to: [(0, 400), (400, 800)])
        dragEndFires.last?()

        XCTAssertEqual(decisions, [.snapback(1)])
    }

    func testSingleFarTickAtMouseUpUntiles() {
        // A fast hand fling coalesces in AX: the whole drag can arrive as
        // ONE far tick (observed live: ticks=1, distance=748). The
        // single-tick rule exists to reject programmatic jumps, but a
        // decision at the physical mouse-up has the signal the debounce
        // never had: the button was down the whole time, and programmatic
        // jumps do not click. The mouse-up must untile the fling.
        let size = CGSize(width: 500, height: 400)
        tile(1, .topLeft, frame: CGRect(origin: CGPoint(x: 0, y: 400), size: size))
        tracker.forget(1)

        dragTicks(1, size: size, to: [(0, 400), (400, 800)])
        tracker.mouseLifted()

        XCTAssertEqual(decisions, [.untile(1)])
    }

    func testResizeCancelsPendingDrag() {
        let size = CGSize(width: 500, height: 400)
        tile(1, .topLeft, frame: CGRect(origin: CGPoint(x: 0, y: 400), size: size))
        tracker.forget(1)

        dragTicks(1, size: size, to: [(0, 400), (30, 430)])
        // The user switches to an edge drag: size changes mid-drag.
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 300, width: 500, height: 500))
        tracker.mouseLifted()
        dragEndFires.last?()

        XCTAssertEqual(
            decisions, [.resize(1)],
            "the abandoned title-bar drag emits no snapback; only the resize decides")
    }

    func testForgetClearsPendingDrag() {
        let size = CGSize(width: 500, height: 400)
        tile(1, .topLeft, frame: CGRect(origin: CGPoint(x: 0, y: 400), size: size))
        tracker.forget(1)

        dragTicks(1, size: size, to: [(0, 400), (400, 800)])
        tracker.forget(1)
        dragEndFires.last?()

        XCTAssertTrue(decisions.isEmpty)
    }

    // MARK: Lifecycle

    func testForgetClearsEchoEntry() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 400, width: 500, height: 400))
        tracker.forget(1)
        slots[1] = nil

        // No crash, no decision, no splitter move, no drag tracking for a
        // forgotten window.
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertTrue(dragEndFires.isEmpty, "a forgotten window tracks no drag")
        XCTAssertEqual(grid(), GridLayout(), "the grid is untouched")
    }

    // MARK: Stale writes

    func testConvergenceVerdictReadsTheEchoTrail() {
        // No entry (consumed/takeover/superseded): inconclusive.
        tile(1, .topLeft, frame: CGRect(x: 0, y: 400, width: 500, height: 400))
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 400, width: 500, height: 400))
        now += TimeInterval(5)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 400, width: 500, height: 400))
        XCTAssertNil(tracker.convergence(for: 1), "consumed entry: inconclusive")

        // Total silence with an answerable live frame far from target:
        // ignored — the write never took effect.
        let ignoring = makeTracker(liveFrameOf: { _ in
            CGRect(x: 4000, y: 4000, width: 500, height: 400)
        })
        tile(2, .topRight, frame: CGRect(x: 500, y: 400, width: 500, height: 400),
             tracker: ignoring)
        XCTAssertEqual(ignoring.convergence(for: 2), .ignored)

        // Total silence with an UNREADABLE live frame: inconclusive.
        // During a lid close/open the frame read fails for live windows;
        // judging that as ignored rolled fresh placements back
        // (observed on live AX).
        tile(4, .bottomRight, frame: CGRect(x: 500, y: 0, width: 500, height: 400))
        XCTAssertNil(
            tracker.convergence(for: 4),
            "an unreadable live frame is can't-judge, not ignored")

        // A converging tick settles the entry: converged.
        tile(3, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        var echo = CGRect(x: 0, y: 0, width: 500, height: 400)
        echo.origin.x += 10
        tracker.handleChange(id: 3, frame: echo)
        XCTAssertEqual(tracker.convergence(for: 3), .converged)

        // Frames that never approach the target: inconclusive (alive,
        // leave it alone); the controller compares live frames.
        tile(4, .bottomRight, frame: CGRect(x: 500, y: 0, width: 500, height: 400))
        tracker.handleChange(id: 4, frame: CGRect(x: 0, y: 0, width: 500, height: 200))
        XCTAssertNil(tracker.convergence(for: 4))
    }

    func testStaleWriteStopsWaitingAndProcessesLaterTicks() {
        tile(1, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        tile(2, .topLeft, frame: CGRect(x: 0, y: 400, width: 500, height: 400))

        // An animated write that converges slowly: each tick moves toward
        // the expected frame (so it is never an escape) but stays far
        // enough away that it is never within echo tolerance either.
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 200))
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 220))
        XCTAssertEqual(grid(), GridLayout())

        // Past the stale window, the next non-escaping tick is processed:
        // the echo entry clears and the resize moves the row splitter.
        now += TimeInterval(4)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 240))

        XCTAssertEqual(
            grid().leftRowSplit, 0.3, accuracy: 0.001,
            "stale entry cleared; 240/800 is the dragged fraction")
        XCTAssertTrue(decisions.isEmpty, "the resize only decides at mouse-up")
        tracker.mouseLifted()
        XCTAssertEqual(decisions, [.resize(1)])
    }

    // MARK: Post-converge settling

    func testSettlingTailAfterConvergeNeverMovesSplitters() {
        // The reported bug: sixths R2/3 + TL + BL tiled, the R2/3 window
        // retiled into TL. The swap writes converge, then macOS streams
        // an animation tail that stops a few points off target and ends.
        // Those tail frames must never reach the splitters: before the
        // settle guard, the tail's absolute positions yanked
        // sixthsLeftSplit and the BL window was re-pushed smaller,
        // leaving empty space.
        visibleFrame = CGRect(x: 0, y: 0, width: 1680, height: 1019)
        slots = [1: .sixthTopLeft, 2: .sixthsRightTwoThirds, 3: .sixthBottomLeft]
        occupants = [.sixthTopLeft: 1, .sixthsRightTwoThirds: 2, .sixthBottomLeft: 3]
        let defaultGrid = GridLayout()
        let tl = defaultGrid.rect(for: .sixthTopLeft, in: visibleFrame)
        let r23 = defaultGrid.rect(for: .sixthsRightTwoThirds, in: visibleFrame)
        handles[1] = gateway.addWindow(frame: tl)
        handles[2] = gateway.addWindow(frame: r23)
        handles[3] = gateway.addWindow(frame: defaultGrid.rect(for: .sixthBottomLeft, in: visibleFrame))
        tracker.markExpected(1, tl)
        tracker.markExpected(2, r23)
        tracker.handleChange(id: 1, frame: tl) // converges
        tracker.handleChange(id: 2, frame: r23) // converges
        // Tail stops 8pt narrow and the stream ends: swallowed, not a drag.
        var tail = tl
        tail.size.width -= 8
        tracker.handleChange(id: 1, frame: tail)
        XCTAssertEqual(grid(), GridLayout(), "a settling tail must not move any splitter")
    }

    func testRealDragDuringSettleStillMovesSplitter() {
        // The guard must not blunt real input: a resize that leaves the
        // tolerance radius right after convergence lands on its absolute
        // position, settle window or not.
        tile(1, .topLeft, frame: CGRect(x: 0, y: 400, width: 500, height: 400))
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 400, width: 500, height: 400))
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 300, width: 600, height: 500))
        XCTAssertEqual(grid().columnSplit, 0.6, accuracy: 0.001)
        XCTAssertEqual(grid().leftRowSplit, 0.375, accuracy: 0.001)
    }

    func testTitleBarGrabDuringSettleStillSnapsBack() {
        // A hand on the title bar the instant a write lands: origin-only
        // ticks inside the radius track a drag (splitters untouched), so
        // releasing short of the untile distance snaps back to the slot.
        tile(1, .topLeft, frame: CGRect(x: 0, y: 400, width: 500, height: 400))
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 400, width: 500, height: 400))
        tracker.handleChange(id: 1, frame: CGRect(x: 10, y: 410, width: 500, height: 400))
        tracker.handleChange(id: 1, frame: CGRect(x: 20, y: 420, width: 500, height: 400))
        XCTAssertEqual(grid(), GridLayout(), "drag tracking never moves splitters")
        XCTAssertFalse(dragEndFires.isEmpty, "settle must not swallow a title-bar grab")

        // Release (~28pt of drag, well inside the untile distance): the
        // pending drag end snaps the window back into its slot.
        dragEndFires.last?()
        XCTAssertEqual(decisions, [.snapback(1)])
    }

    func testTinyTitleBarDragAfterSettleExpiresSnapsBack() {
        // The reported bug: a very small whole-window drag (a few points,
        // one AX tick, still inside the 32pt echo tolerance) leaves the
        // window offset from its tile until the next reflow. Every tiled
        // window carries a settled echo entry after its placement write;
        // past the settle window the first close tick hits the
        // settle-expired branch, which swallows it without tracking a
        // drag — so the mouse-up finds no drag and no snapback fires.
        tile(1, .topLeft, frame: CGRect(x: 0, y: 400, width: 500, height: 400))
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 400, width: 500, height: 400)) // converges
        now = now.addingTimeInterval(5) // the user returns later

        // A tiny hand drag: one origin-only tick 6pt off the tile.
        tracker.handleChange(id: 1, frame: CGRect(x: 6, y: 406, width: 500, height: 400))
        tracker.mouseLifted()

        XCTAssertEqual(decisions, [.snapback(1)], "a tiny drag must still snap back")
    }

    func testExpiredSettleGoesLive() {
        // Past the settle window the entry is gone: the next tick diffs
        // live, so a slow follow-up resize still works.
        tile(1, .topLeft, frame: CGRect(x: 0, y: 400, width: 500, height: 400))
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 400, width: 500, height: 400))
        now = now.addingTimeInterval(5)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 300, width: 600, height: 500))
        XCTAssertEqual(grid().columnSplit, 0.6, accuracy: 0.001)
    }

    // MARK: liveFrameOf seam

    func testSilentConvergenceChecksTheLiveFrameBeforeCallingItIgnored() {
        // Total echo silence is not automatically a silent ignore: apps
        // that round frames to an internal grid can absorb a write whose
        // target sits within their rounding distance, emitting no
        // notification. The live frame is the tiebreaker: within the
        // echo tolerance of the target means converged; far from it
        // means genuinely ignored.
        var liveFrames: [WindowID: CGRect] = [:]
        let tracker = makeTracker(liveFrameOf: { liveFrames[$0] })

        // Silent but at target: converged, and the entry is cleared.
        let target = CGRect(x: 0, y: 400, width: 500, height: 400)
        tile(1, .topLeft, frame: target, tracker: tracker)
        liveFrames[1] = CGRect(x: 5, y: 405, width: 500, height: 400)
        XCTAssertEqual(
            tracker.convergence(for: 1), .converged,
            "the live frame sits within tolerance of the target")
        XCTAssertNil(
            tracker.convergence(for: 1),
            "the entry is consumed by the convergence win")

        // Silent and far from target: the write never took effect.
        let farTarget = CGRect(x: 500, y: 400, width: 500, height: 400)
        tile(2, .topRight, frame: farTarget, tracker: tracker)
        liveFrames[2] = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(tracker.convergence(for: 2), .ignored)
    }
}
