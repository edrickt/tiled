import XCTest
@testable import tiled

/// DragTracker through its own interface: echo suppression, edge-to-
/// splitter mapping, and apply coalescing, driven by direct `handleChange`
/// calls. No controller, no AX — the loop tested where it lives.
final class DragTrackerTests: XCTestCase {
    private var gateway: FakeWindowGateway!
    private var pushed: [(rects: [WindowID: CGRect], excluding: WindowID?)]!
    private var tracker: DragTracker!
    private var slots: [WindowID: Slot]!
    private var handles: [WindowID: WindowHandle]!
    private var occupants: [Slot: WindowID]!
    /// Injectable clock backing the tracker's echo timestamps.
    private var now = Date()
    /// Windows the tracker decided to untile via drag-out.
    private var untiled: [WindowID]!
    /// Drag-end fires captured from the injectable scheduler (latest wins).
    private var dragEndFires: [() -> Void]!

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        pushed = []
        slots = [:]
        handles = [:]
        occupants = [:]
        now = Date()
        untiled = []
        dragEndFires = []
        tracker = DragTracker(
            context: DragTracker.Context(
                slotOf: { [weak self] in self?.slots[$0] },
                frameOf: { [weak self] in
                    guard let handle = self?.handles[$0] else { return nil }
                    return self?.gateway.frame(of: handle)
                },
                boundsOf: { $0 },
                occupants: { [weak self] in self?.occupants ?? [:] },
                now: { [weak self] in self?.now ?? Date() }),
            apply: { [weak self] rects, excluding in
                self?.pushed.append((rects, excluding))
                return 0
            },
            onUntile: { [weak self] in self?.untiled.append($0) },
            scheduleDragEnd: { [weak self] fire in
                self?.dragEndFires.append(fire)
                return {}
            })
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

    /// A tracker wired like the shared one but with an injectable
    /// `liveFrameOf` — the seam the no-op-write skip and the silent-
    /// convergence check read instead of intent.
    private func makeTracker(
        liveFrameOf: @escaping (WindowID) -> CGRect?
    ) -> DragTracker {
        DragTracker(
            context: DragTracker.Context(
                slotOf: { [weak self] in self?.slots[$0] },
                frameOf: { [weak self] in
                    guard let handle = self?.handles[$0] else { return nil }
                    return self?.gateway.frame(of: handle)
                },
                boundsOf: { $0 },
                occupants: { [weak self] in self?.occupants ?? [:] },
                now: { [weak self] in self?.now ?? Date() },
                liveFrameOf: liveFrameOf),
            apply: { [weak self] rects, excluding in
                self?.pushed.append((rects, excluding))
                return 0
            },
            onUntile: { [weak self] in self?.untiled.append($0) },
            scheduleDragEnd: { [weak self] fire in
                self?.dragEndFires.append(fire)
                return {}
            })
    }

    // MARK: Echo suppression

    func testConvergingTickIsSwallowed() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))

        var echo = CGRect(x: 0, y: 500, width: 840, height: 500)
        echo.origin.x += 10 // within tolerance on every edge
        tracker.handleChange(id: 1, frame: echo)

        XCTAssertTrue(pushed.isEmpty)
        XCTAssertTrue(dragEndFires.isEmpty, "the echo path is the only outcome that never schedules a drag end")
        XCTAssertEqual(tracker.grid, GridLayout())
    }

    func testDivergingTickMovesSplitter() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tile(2, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 840, height: 500))

        // Converge first (like an animated write), then escape: the top
        // edge of TopLeft drops 100px, moving leftRowSplit.
        var first = CGRect(x: 0, y: 500, width: 840, height: 500)
        first.origin.x += 10
        tracker.handleChange(id: 1, frame: first)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 400, width: 840, height: 600))

        // The bottom edge lands at 400 inside the dragged frame-as-bounds
        // (0,400,840,600): raw fraction 0, clamped to the row minimum.
        XCTAssertEqual(tracker.grid.leftRowSplit, 0.2, accuracy: 0.001,
            "bottom edge at 400/600 clamps to the row-split minimum")
    }

    func testCornerDragMovesTwoBoundariesInOneChange() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))

        // Echo tick first (swallowed), then a corner drag: the right edge
        // moves +60 (columnSplit) and the bottom edge -60 (leftRowSplit)
        // in a single change — both boundaries must update.
        var echo = CGRect(x: 0, y: 500, width: 840, height: 500)
        echo.size.width += 10
        tracker.handleChange(id: 1, frame: echo)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 440, width: 900, height: 500))

        XCTAssertEqual(tracker.grid.columnSplit, 0.85, accuracy: 0.001,
            "right edge at 900/900 clamps to the column maximum")
        XCTAssertEqual(tracker.grid.leftRowSplit, 0.2, accuracy: 0.001,
            "bottom edge at 440/500 clamps to the row minimum")
    }

    func testOriginOnlyMoveTracksDragWithoutMovingSplitter() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tracker.forget(1)

        // Same size, shifted origin across two ticks: a title-bar move.
        // The first tick seeds the baseline (no echo entry after forget).
        tracker.handleChange(id: 1, frame: CGRect(x: 50, y: 550, width: 840, height: 500))
        tracker.handleChange(id: 1, frame: CGRect(x: 100, y: 600, width: 840, height: 500))

        // Drag tracking never touches the grid, and nothing pushes until
        // the drag ends.
        XCTAssertEqual(tracker.grid, GridLayout())
        XCTAssertTrue(pushed.isEmpty)
        XCTAssertFalse(dragEndFires.isEmpty, "move ticks schedule a drag end")
    }

    func testUntrackedWindowIsIgnored() {
        tracker.handleChange(id: 99, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(pushed.isEmpty)
        XCTAssertTrue(untiled.isEmpty, "an untracked window is never untiled")
        XCTAssertTrue(dragEndFires.isEmpty, "no drag is tracked, so no drag end is scheduled")
        XCTAssertEqual(tracker.grid, GridLayout(), "the grid is untouched")
    }

    // MARK: Coalescing

    func testNeighborPushExcludesDraggedWindow() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tile(2, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 840, height: 500))

        var first = CGRect(x: 0, y: 0, width: 840, height: 500)
        first.size.height -= 10
        tracker.handleChange(id: 2, frame: first)
        var moved = CGRect(x: 0, y: 0, width: 840, height: 500)
        moved.size.height -= 80
        tracker.handleChange(id: 2, frame: moved)

        let expectation = XCTestExpectation(description: "coalesced push")
        DispatchQueue.main.async {
            XCTAssertEqual(self.pushed.count, 1)
            XCTAssertNil(self.pushed.first?.rects[2], "dragged window never re-pushed")
            // Window 1's live frame (0,500,840,500) is its own bounds
            // (identity boundsOf). Window 2's top edge escaped to maxY 420
            // inside its own frame-as-bounds (0,0,840,420): leftRowSplit =
            // 420/420 clamps to 0.8. TopLeft in window 1's bounds: mid
            // line at 500 + 0.8·500 = 900, left column = 420 wide, top
            // strip = 500·(1−0.8) = 100 tall.
            XCTAssertEqual(
                self.pushed.first?.rects[1], CGRect(x: 0, y: 900, width: 420, height: 100),
                "neighbor gets the exact new rect")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: Drag-out untile

    /// Streams a title-bar drag after clearing the echo entry: tick 1
    /// seeds the diff baseline, ticks 2+ register as drag movement.
    private func dragTicks(_ id: WindowID, size: CGSize, to origins: [(CGFloat, CGFloat)]) {
        for (x, y) in origins {
            tracker.handleChange(id: id, frame: CGRect(origin: CGPoint(x: x, y: y), size: size))
        }
    }

    func testDragPastUntileDistanceFiresUntile() {
        let size = CGSize(width: 840, height: 500)
        tile(1, .topLeft, frame: CGRect(origin: CGPoint(x: 0, y: 500), size: size))
        tracker.forget(1)

        dragTicks(1, size: size, to: [(0, 500), (40, 540), (100, 600)])
        dragEndFires.last?()

        XCTAssertEqual(untiled, [1], "drag distance ~141pt crosses the untile distance")
        XCTAssertTrue(pushed.isEmpty, "untile needs no snapback push")
    }

    func testShortDragSnapsBackIntoTile() {
        let size = CGSize(width: 840, height: 500)
        let tileRect = CGRect(origin: CGPoint(x: 0, y: 500), size: size)
        tile(1, .topLeft, frame: tileRect)
        tracker.forget(1)

        dragTicks(1, size: size, to: [(0, 500), (20, 520), (35, 535)])
        dragEndFires.last?()

        XCTAssertTrue(untiled.isEmpty, "~49pt of drag stays inside the tile")
        // Identity boundsOf: the window's own frame is its screen, so the
        // slot rect is the top-left quadrant of the dragged frame.
        let snapRect = CGRect(x: 35, y: 785, width: size.width / 2, height: size.height / 2)
        let expectation = XCTestExpectation(description: "snapback push")
        DispatchQueue.main.async {
            XCTAssertEqual(self.pushed.count, 1)
            XCTAssertEqual(self.pushed.first?.rects[1], snapRect, "window pushed back to its slot rect")
            XCTAssertNil(self.pushed.first?.excluding, "snapback pushes the dragged window itself")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testSingleFarJumpSnapsBackInsteadOfUntiling() {
        let size = CGSize(width: 840, height: 500)
        let tileRect = CGRect(origin: CGPoint(x: 0, y: 500), size: size)
        tile(1, .topLeft, frame: tileRect)
        tracker.forget(1)

        // One far tick: a programmatic move, not a hand drag (hand drags
        // stream). It must snap back, never untile.
        dragTicks(1, size: size, to: [(0, 500), (400, 800)])
        dragEndFires.last?()

        XCTAssertTrue(untiled.isEmpty)
        // Identity boundsOf: the slot rect is the top-left quadrant of the
        // final (jumped) frame.
        let snapRect = CGRect(x: 400, y: 1050, width: 420, height: 250)
        let expectation = XCTestExpectation(description: "snapback push")
        DispatchQueue.main.async {
            XCTAssertEqual(self.pushed.count, 1)
            XCTAssertEqual(self.pushed.first?.rects[1], snapRect)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testResizeCancelsPendingDrag() {
        let size = CGSize(width: 840, height: 500)
        tile(1, .topLeft, frame: CGRect(origin: CGPoint(x: 0, y: 500), size: size))
        tracker.forget(1)

        dragTicks(1, size: size, to: [(0, 500), (30, 530)])
        // The user switches to an edge drag: size changes mid-drag.
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 400, width: 840, height: 600))
        dragEndFires.last?()

        XCTAssertTrue(untiled.isEmpty, "the drag was abandoned for a resize")
        let expectation = XCTestExpectation(description: "resize push")
        DispatchQueue.main.async {
            // Only the resize's neighbor reassert may appear; no snapback
            // rect for the dragged window itself.
            for push in self.pushed where push.rects[1] != nil {
                XCTFail("unexpected snapback push for \(push.rects[1]!)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testForgetClearsPendingDrag() {
        let size = CGSize(width: 840, height: 500)
        tile(1, .topLeft, frame: CGRect(origin: CGPoint(x: 0, y: 500), size: size))
        tracker.forget(1)

        dragTicks(1, size: size, to: [(0, 500), (400, 800)])
        tracker.forget(1)
        dragEndFires.last?()

        XCTAssertTrue(untiled.isEmpty)
        XCTAssertTrue(pushed.isEmpty)
    }

    // MARK: Lifecycle

    func testForgetClearsEchoEntry() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tracker.forget(1)
        slots[1] = nil

        // No crash, no push, no splitter move, no drag tracking for a
        // forgotten window.
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(pushed.isEmpty)
        XCTAssertTrue(untiled.isEmpty, "a forgotten window is never untiled")
        XCTAssertTrue(dragEndFires.isEmpty, "a forgotten window tracks no drag")
        XCTAssertEqual(tracker.grid, GridLayout(), "the grid is untouched")
    }

    // MARK: Stale writes

    func testConvergenceVerdictReadsTheEchoTrail() {
        // No entry (consumed/takeover/superseded): inconclusive.
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        now += TimeInterval(5)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        XCTAssertNil(tracker.convergence(for: 1), "consumed entry: inconclusive")

        // Total silence: ignored.
        tile(2, .topRight, frame: CGRect(x: 840, y: 500, width: 840, height: 500))
        XCTAssertEqual(tracker.convergence(for: 2), .ignored)

        // A converging tick settles the entry: converged.
        tile(3, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 840, height: 500))
        var echo = CGRect(x: 0, y: 0, width: 840, height: 500)
        echo.origin.x += 10
        tracker.handleChange(id: 3, frame: echo)
        XCTAssertEqual(tracker.convergence(for: 3), .converged)

        // Frames that never approach the target: inconclusive (alive,
        // leave it alone) — the controller compares live frames.
        tile(4, .bottomRight, frame: CGRect(x: 840, y: 0, width: 840, height: 500))
        tracker.handleChange(id: 4, frame: CGRect(x: 0, y: 0, width: 840, height: 300))
        XCTAssertNil(tracker.convergence(for: 4))
    }

    func testStaleWriteStopsWaitingAndProcessesLaterTicks() {
        tile(1, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 840, height: 500))
        tile(2, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))

        // An animated write that converges slowly: each tick moves toward
        // the expected frame (so it is never an escape) but stays far
        // enough away that it is never within echo tolerance either.
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 840, height: 300))
        XCTAssertTrue(pushed.isEmpty) // distance 200, converging
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 840, height: 320))
        XCTAssertTrue(pushed.isEmpty, "still inside the stale window: swallowed") // distance 180
        XCTAssertEqual(tracker.grid, GridLayout())

        // Past the stale window, the next non-escaping tick is processed:
        // the echo entry clears and the resize moves the row splitter.
        now += TimeInterval(4)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 840, height: 330))
        // distance 170: not an escape, but the 4s-old entry is stale.

        XCTAssertEqual(
            tracker.grid.leftRowSplit, 0.8, accuracy: 0.001,
            "stale entry cleared; 330/330 clamps to the row-split maximum")
        let expectation = XCTestExpectation(description: "coalesced apply after stale")
        DispatchQueue.main.async {
            XCTAssertEqual(self.pushed.count, 1)
            XCTAssertNil(self.pushed.first?.rects[1], "dragged window excluded")
            // Window 2 (topLeft) keeps its live frame (0,500,840,500) as
            // its own bounds; the dragged window's top edge clamped
            // leftRowSplit to 0.8. TopLeft in those bounds: mid line at
            // 900, left column 420 wide, top strip 100 tall.
            XCTAssertEqual(
                self.pushed.first?.rects[2], CGRect(x: 0, y: 900, width: 420, height: 100),
                "neighbor re-pushed to the exact new rect")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testResetDividersRestoresDefaults() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        var first = CGRect(x: 0, y: 500, width: 840, height: 500)
        first.origin.x += 10
        tracker.handleChange(id: 1, frame: first)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 400, width: 840, height: 600))
        XCTAssertNotEqual(tracker.grid.leftRowSplit, 0.5)

        tracker.resetDividers()
        XCTAssertEqual(tracker.grid, GridLayout())
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
        slots = [1: .sixthTopLeft, 2: .sixthsRightTwoThirds, 3: .sixthBottomLeft]
        occupants = [.sixthTopLeft: 1, .sixthsRightTwoThirds: 2, .sixthBottomLeft: 3]
        let bounds = CGRect(x: 0, y: 0, width: 1680, height: 1019)
        let grid = GridLayout()
        let tl = grid.rect(for: .sixthTopLeft, in: bounds)
        let r23 = grid.rect(for: .sixthsRightTwoThirds, in: bounds)
        handles[1] = gateway.addWindow(frame: tl)
        handles[2] = gateway.addWindow(frame: r23)
        handles[3] = gateway.addWindow(frame: grid.rect(for: .sixthBottomLeft, in: bounds))
        tracker.markExpected(1, tl)
        tracker.markExpected(2, r23)
        tracker.handleChange(id: 1, frame: tl) // converges
        tracker.handleChange(id: 2, frame: r23) // converges
        // Tail stops 8pt narrow and the stream ends: swallowed, not a drag.
        var tail = tl
        tail.size.width -= 8
        tracker.handleChange(id: 1, frame: tail)
        XCTAssertEqual(tracker.grid, GridLayout(), "a settling tail must not move any splitter")
    }

    func testRealDragDuringSettleStillMovesSplitter() {
        // The guard must not blunt real input: a resize that leaves the
        // tolerance radius right after convergence lands on its absolute
        // position, settle window or not.
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 440, width: 900, height: 500))
        XCTAssertEqual(tracker.grid.columnSplit, 0.85, accuracy: 0.001)
        XCTAssertEqual(tracker.grid.leftRowSplit, 0.2, accuracy: 0.001)
    }

    func testTitleBarGrabDuringSettleStillSnapsBack() {
        // A hand on the title bar the instant a write lands: origin-only
        // ticks inside the radius track a drag (splitters untouched), so
        // releasing short of the untile distance snaps back to the slot.
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tracker.handleChange(id: 1, frame: CGRect(x: 10, y: 510, width: 840, height: 500))
        tracker.handleChange(id: 1, frame: CGRect(x: 20, y: 520, width: 840, height: 500))
        XCTAssertEqual(tracker.grid, GridLayout(), "drag tracking never moves splitters")
        XCTAssertFalse(dragEndFires.isEmpty, "settle must not swallow a title-bar grab")

        // Release (~28pt of drag, well inside the untile distance): the
        // pending drag end snaps the window back into its slot rect —
        // the top-left quadrant of the dragged frame (identity boundsOf).
        dragEndFires.last?()
        XCTAssertTrue(untiled.isEmpty, "~28pt of drag stays inside the tile")
        let expectation = XCTestExpectation(description: "snapback push after settle grab")
        DispatchQueue.main.async {
            XCTAssertEqual(self.pushed.count, 1)
            XCTAssertEqual(
                self.pushed.first?.rects[1], CGRect(x: 20, y: 770, width: 420, height: 250),
                "the grab snaps back into the slot rect")
            XCTAssertNil(self.pushed.first?.excluding, "snapback pushes the dragged window itself")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testExpiredSettleGoesLive() {
        // Past the settle window the entry is gone: the next tick diffs
        // live, so a slow follow-up resize still works.
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        now = now.addingTimeInterval(5)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 440, width: 900, height: 500))
        XCTAssertEqual(tracker.grid.columnSplit, 0.85, accuracy: 0.001)
    }

    // MARK: Reassert baseline seeding

    func testReassertSeedsBaselineSoTheFirstDragDiffsCorrectly() {
        // Occupant 1 was never marked expected (e.g. it re-appeared under
        // a fresh id after an undo): reassertAll must seed its diff
        // baseline, or the first drag after the reassert is dropped.
        occupants[.bottomLeft] = 1
        slots[1] = .bottomLeft
        handles[1] = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 840, height: 500))

        // Without a baseline, a first change has nothing to diff against.
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 840, height: 440))
        XCTAssertEqual(tracker.grid, GridLayout(), "no baseline: change dropped")

        // Restore/prune paths forget the window; the reassert that follows
        // must seed a fresh baseline from the live frame.
        tracker.forget(1)
        tracker.reassertAll(occupants: occupants)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 840, height: 440))
        XCTAssertEqual(
            tracker.grid.leftRowSplit, 0.8, accuracy: 0.001,
            "baseline seeded by reassert; 440/440 clamps to the row maximum")
    }

    // MARK: liveFrameOf seam

    func testNoOpWriteIsSkippedInsteadOfMarkedExpected() {
        // A write whose target sits within noOpWriteTolerance (1pt) of the
        // window's live frame is a no-op: pushing it would echo nothing,
        // and the late convergence check would read that silence as a
        // silent ignore and evict an already-correct window. So the rect
        // is dropped and no intent is recorded.
        var liveFrames: [WindowID: CGRect] = [:]
        let tracker = makeTracker(liveFrameOf: { liveFrames[$0] })
        // Window 1's live frame (0,500,840,500) is its own bounds; the
        // topLeft rect under the default grid is (0,750,420,250).
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500), tracker: tracker)
        liveFrames[1] = CGRect(x: 0, y: 750.5, width: 420, height: 249.5)

        tracker.reassertAll(occupants: occupants)
        let expectation = XCTestExpectation(description: "no-op write skipped")
        DispatchQueue.main.async {
            XCTAssertNil(
                self.pushed.first?.rects[1], "no rect for window 1 in any push")
            XCTAssertEqual(
                tracker.lastPushedTarget(for: 1), CGRect(x: 0, y: 500, width: 840, height: 500),
                "the skipped write records no new intent: the tile-frame intent survives")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Control: the same reassert with the live frame far from the
        // target pushes and marks intent — the skip is the live frame's
        // doing, not the reassert's.
        liveFrames[1] = CGRect(x: 600, y: 100, width: 50, height: 50)
        tracker.reassertAll(occupants: occupants)
        let pushedExpectation = XCTestExpectation(description: "real write pushed")
        DispatchQueue.main.async {
            XCTAssertEqual(
                self.pushed.last?.rects[1], CGRect(x: 0, y: 750, width: 420, height: 250))
            XCTAssertEqual(
                tracker.lastPushedTarget(for: 1), CGRect(x: 0, y: 750, width: 420, height: 250),
                "a real push records intent")
            pushedExpectation.fulfill()
        }
        wait(for: [pushedExpectation], timeout: 1.0)
    }

    func testSilentConvergenceChecksTheLiveFrameBeforeCallingItIgnored() {
        // Total echo silence is not automatically a silent ignore: apps
        // that round frames to an internal grid can absorb a write whose
        // target sits within their rounding distance, emitting no
        // notification. The live frame is the tiebreaker — within the
        // echo tolerance of the target means converged; far from it
        // means genuinely ignored.
        var liveFrames: [WindowID: CGRect] = [:]
        let tracker = makeTracker(liveFrameOf: { liveFrames[$0] })

        // Silent but at target: converged, and the entry is cleared.
        let target = CGRect(x: 0, y: 500, width: 840, height: 500)
        tile(1, .topLeft, frame: target, tracker: tracker)
        liveFrames[1] = CGRect(x: 5, y: 505, width: 840, height: 500)
        XCTAssertEqual(
            tracker.convergence(for: 1), .converged,
            "the live frame sits within tolerance of the target")
        XCTAssertNil(
            tracker.convergence(for: 1),
            "the entry is consumed by the convergence win")

        // Silent and far from target: the write never took effect.
        let farTarget = CGRect(x: 840, y: 500, width: 840, height: 500)
        tile(2, .topRight, frame: farTarget, tracker: tracker)
        liveFrames[2] = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(tracker.convergence(for: 2), .ignored)
    }
}
