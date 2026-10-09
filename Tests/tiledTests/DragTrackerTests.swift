import XCTest
@testable import tiled

/// DragTracker through its own interface: echo suppression, edge-to-
/// splitter mapping, and apply coalescing, driven by direct `handleChange`
/// calls. No controller, no AX; the loop tested where it lives.
final class DragTrackerTests: XCTestCase {
    private var gateway: FakeWindowGateway!
    private var pushed: [(rects: [WindowID: CGRect], excluding: WindowID?)]!
    private var tracker: DragTracker!
    private var slots: [WindowID: Slot]!
    private var handles: [WindowID: WindowHandle]!
    private var occupants: [Slot: WindowID]!
    /// Injectable clock backing the expectation owner's echo timestamps.
    private var now = Date()
    /// The expectation owner paired with the tracker under test: armed
    /// echoes and intent live here, not in the tracker.
    private var expectations: WriteExpectations!
    /// Windows the tracker decided to untile via drag-out.
    private var untiled: [WindowID]!
    /// Drag-end fires captured from the injectable scheduler (latest wins).
    private var dragEndFires: [() -> Void]!
    /// Trailing-tick commit fires captured from the injectable scheduler
    /// (latest wins; a cancelled one is a no-op when fired).
    private var commitFires: [() -> Void]!
    /// The splitter fractions the tracker reads and writes, standing in
    /// for the canvas that owns them in production.
    private var grids: [TilingSpaceKey: GridLayout] = [:]

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
        commitFires = []
        grids = [:]
        expectations = WriteExpectations(
            gateway: gateway,
            notePushed: { [weak self] id, target in self?.tracker.notePushed(id, target) },
            now: { [weak self] in self?.now ?? Date() })
        tracker = DragTracker(
            expectations: expectations,
            context: DragTracker.Context(
                slotOf: { [weak self] in self?.slots[$0] },
                frameOf: { [weak self] in
                    guard let handle = self?.handles[$0] else { return nil }
                    return self?.gateway.frame(of: handle)
                },
                boundsOf: { $0 },
                occupants: { [weak self] in self?.occupants ?? [:] }),
            gridProvider: provider(),
            apply: { [weak self] rects, excluding in
                self?.pushed.append((rects, excluding))
            },
            onUntile: { [weak self] in self?.untiled.append($0) },
            scheduleDragEnd: { [weak self] fire in
                self?.dragEndFires.append(fire)
                return {}
            },
            scheduleCommit: { [weak self] fire in
                self?.commitFires.append(fire)
                return {}
            })
    }

    /// The grid store the tracker reads and writes through, standing in
    /// for the canvas provider production wires.
    private func provider() -> DragTracker.GridProvider {
        DragTracker.GridProvider(
            grid: { [weak self] key in
                self?.grids[key ?? .displayless] ?? GridLayout()
            },
            setGrid: { [weak self] updated, key in
                self?.grids[key ?? .displayless] = updated
            })
    }

    /// The current splitter set the tracker moved.
    private func grid(_ key: TilingSpaceKey? = nil) -> GridLayout {
        grids[key ?? .displayless] ?? GridLayout()
    }

    private func tile(_ id: WindowID, _ slot: Slot, frame: CGRect) {
        handles[id] = gateway.addWindow(frame: frame)
        slots[id] = slot
        occupants[slot] = id
        expectations.noteExpected(id, frame)
    }

    /// A tracker wired to a fixed screen rect, so absolute frames read as
    /// real splitter fractions instead of each frame becoming its own
    /// bounds like the default frame-as-bounds test rig. `gap` insets the
    /// frames the tracker sees, matching a placed frame.
    private func makeTracker(bounds: CGRect, gap: CGFloat = 0) -> DragTracker {
        DragTracker(
            expectations: expectations,
            context: DragTracker.Context(
                slotOf: { [weak self] in self?.slots[$0] },
                frameOf: { [weak self] in
                    guard let handle = self?.handles[$0] else { return nil }
                    return self?.gateway.frame(of: handle)
                },
                boundsOf: { _ in bounds },
                gap: { gap },
                occupants: { [weak self] in self?.occupants ?? [:] }),
            gridProvider: provider(),
            apply: { [weak self] rects, excluding in
                self?.pushed.append((rects, excluding))
            },
            onUntile: { [weak self] in self?.untiled.append($0) },
            scheduleDragEnd: { [weak self] fire in
                self?.dragEndFires.append(fire)
                return {}
            },
            scheduleCommit: { [weak self] fire in
                self?.commitFires.append(fire)
                return {}
            })
    }

    /// Fires the latest trailing-tick commit the tracker armed. A
    /// cancelled one is a no-op: its closure guards on its own pending
    /// state, so this may be called freely after a press cancelled it.
    private func fireCommit() {
        commitFires.last?()
    }

    /// Streams a real edge drag: a close echo tick is swallowed, then the
    /// far frame escapes the tolerance radius and reaches the splitters.
    private func drag(_ id: WindowID, from frame: CGRect, to target: CGRect, tracker: DragTracker) {
        var echo = frame
        echo.size.width += min(8, abs(target.width - frame.width))
        tracker.handleChange(id: id, frame: echo)
        tracker.handleChange(id: id, frame: target)
    }

    // MARK: Echo suppression

    func testConvergingTickIsSwallowed() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))

        var echo = CGRect(x: 0, y: 500, width: 840, height: 500)
        echo.origin.x += 10 // within tolerance on every edge
        tracker.handleChange(id: 1, frame: echo)

        XCTAssertTrue(pushed.isEmpty)
        XCTAssertTrue(dragEndFires.isEmpty, "the echo path is the only outcome that never schedules a drag end")
        XCTAssertEqual(grid(), GridLayout())
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
        XCTAssertEqual(grid().leftRowSplit, 0.2, accuracy: 0.001,
            "bottom edge at 400/600 clamps to the row-split minimum")
    }

    func testGapOffsetsARightEdgeDragToTheSplitterLine() {
        // The placed frame is inset half a gap, so the visible right edge
        // sits half a gap inside the splitter. Dragging it to 595 must land
        // the splitter at 600 (0.6), not on the visible edge (0.595).
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let tracker = makeTracker(bounds: screen, gap: 10)
        let tiled = GridLayout().rect(for: .leftHalf, in: screen, gap: 10)
        tile(1, .leftHalf, frame: tiled)

        var resized = tiled
        resized.size.width += 100 // visible right edge 495 -> 595
        drag(1, from: tiled, to: resized, tracker: tracker)

        XCTAssertEqual(
            grid().columnSplit, 0.6, accuracy: 0.001,
            "half a gap is added back so the splitter sits centred in the gap")
    }

    func testGapOffsetsALeftEdgeDragToTheSplitterLine() {
        // Mirror of the right-edge case: the visible left edge sits half a
        // gap right of the splitter, so dragging it to 405 lands the
        // splitter at 400 (0.4).
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let tracker = makeTracker(bounds: screen, gap: 10)
        let tiled = GridLayout().rect(for: .rightHalf, in: screen, gap: 10)
        tile(1, .rightHalf, frame: tiled)

        var resized = tiled
        resized.origin.x -= 100 // visible left edge 505 -> 405
        resized.size.width += 100
        drag(1, from: tiled, to: resized, tracker: tracker)

        XCTAssertEqual(
            grid().columnSplit, 0.4, accuracy: 0.001,
            "half a gap is subtracted so the splitter sits centred in the gap")
    }

    func testResizingLeftTwoThirdsCentersItsHiddenDivider() {
        let screen = CGRect(x: 0, y: 0, width: 1680, height: 1019)
        let tracker = makeTracker(bounds: screen)
        let tiled = GridLayout().rect(for: .sixthsLeftTwoThirds, in: screen)
        tile(1, .sixthsLeftTwoThirds, frame: tiled)

        var resized = tiled
        resized.size.width = 0.78 * screen.width
        drag(1, from: tiled, to: resized, tracker: tracker)

        XCTAssertEqual(
            grid().sixthsRightSplit, 0.78, accuracy: 0.001,
            "the dragged edge lands where the user put it")
        XCTAssertEqual(
            grid().sixthsLeftSplit, 0.39, accuracy: 0.001,
            "the hidden divider bisects the resized two-thirds window")
    }

    func testResizingRightTwoThirdsCentersItsHiddenDivider() {
        let screen = CGRect(x: 0, y: 0, width: 1680, height: 1019)
        let tracker = makeTracker(bounds: screen)
        let tiled = GridLayout().rect(for: .sixthsRightTwoThirds, in: screen)
        tile(1, .sixthsRightTwoThirds, frame: tiled)

        var resized = tiled
        resized.origin.x = 0.22 * screen.width
        resized.size.width = screen.maxX - resized.minX
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
        let screen = CGRect(x: 0, y: 0, width: 1680, height: 1019)
        let tracker = makeTracker(bounds: screen)
        let leftTwo = GridLayout().rect(for: .sixthsLeftTwoThirds, in: screen)
        let rightThird = GridLayout().rect(for: .sixthRight, in: screen)
        tile(1, .sixthsLeftTwoThirds, frame: leftTwo)
        tile(2, .sixthRight, frame: rightThird)

        var resized = rightThird
        resized.origin.x = 0.7 * screen.width
        resized.size.width = screen.maxX - resized.minX
        drag(2, from: rightThird, to: resized, tracker: tracker)

        XCTAssertEqual(grid().sixthsRightSplit, 0.7, accuracy: 0.001)
        XCTAssertEqual(
            grid().sixthsLeftSplit, 0.35, accuracy: 0.001,
            "the two-thirds window still reads as two equal thirds")
    }

    func testCornerDragMovesTwoBoundariesInOneChange() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))

        // Echo tick first (swallowed), then a corner drag: the right edge
        // moves +60 (columnSplit) and the bottom edge -60 (leftRowSplit)
        // in a single change; both boundaries must update.
        var echo = CGRect(x: 0, y: 500, width: 840, height: 500)
        echo.size.width += 10
        tracker.handleChange(id: 1, frame: echo)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 440, width: 900, height: 500))

        XCTAssertEqual(grid().columnSplit, 0.85, accuracy: 0.001,
            "right edge at 900/900 clamps to the column maximum")
        XCTAssertEqual(grid().leftRowSplit, 0.2, accuracy: 0.001,
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
        XCTAssertEqual(grid(), GridLayout())
        XCTAssertTrue(pushed.isEmpty)
        XCTAssertFalse(dragEndFires.isEmpty, "move ticks schedule a drag end")
    }

    func testUntrackedWindowIsIgnored() {
        tracker.handleChange(id: 99, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(pushed.isEmpty)
        XCTAssertTrue(untiled.isEmpty, "an untracked window is never untiled")
        XCTAssertTrue(dragEndFires.isEmpty, "no drag is tracked, so no drag end is scheduled")
        XCTAssertEqual(grid(), GridLayout(), "the grid is untouched")
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
        tracker.mouseLifted()
        fireCommit()

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

    // MARK: Deferred neighbor re-push

    func testResizeDefersNeighborPushUntilMouseUp() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tile(2, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 840, height: 500))

        var first = CGRect(x: 0, y: 0, width: 840, height: 500)
        first.size.height -= 10
        tracker.handleChange(id: 2, frame: first)
        var moved = CGRect(x: 0, y: 0, width: 840, height: 500)
        moved.size.height -= 80
        tracker.handleChange(id: 2, frame: moved)

        // The splitter commits live, but nothing pushes while the button
        // is down: the tiles wait for the click to lift.
        XCTAssertEqual(grid().leftRowSplit, 0.8, accuracy: 0.001)
        let duringDrag = XCTestExpectation(description: "no push mid-drag")
        DispatchQueue.main.async {
            XCTAssertTrue(
                self.pushed.isEmpty,
                "no tile resizes while the mouse button is down")
            XCTAssertTrue(
                self.commitFires.isEmpty,
                "a mid-drag tick arms no trailing-tick commit")
            duringDrag.fulfill()
        }
        wait(for: [duringDrag], timeout: 1.0)

        // Mouse-up schedules the commit; it fires once the trailing
        // ticks go quiet, so the grid commits as one move.
        tracker.mouseLifted()
        XCTAssertFalse(commitFires.isEmpty, "mouse-up arms a trailing-tick commit")
        fireCommit()
        let lifted = XCTestExpectation(description: "coalesced push on mouse-up")
        DispatchQueue.main.async {
            XCTAssertEqual(self.pushed.count, 1)
            XCTAssertNil(self.pushed.first?.rects[2], "dragged window never re-pushed")
            // Window 1's live frame (0,500,840,500) is its own bounds
            // (identity boundsOf). TopLeft under the dragged grid:
            // mid line at 500 + 0.8·500 = 900, left column 420 wide,
            // top strip 500·(1−0.8) = 100 tall.
            XCTAssertEqual(
                self.pushed.first?.rects[1], CGRect(x: 0, y: 900, width: 420, height: 100),
                "neighbor gets the exact new rect")
            lifted.fulfill()
        }
        wait(for: [lifted], timeout: 1.0)
    }

    func testMouseUpWithoutPendingResizeIsNoOp() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tracker.mouseLifted()

        XCTAssertTrue(commitFires.isEmpty, "a click arms no commit without a pending resize")
        let expectation = XCTestExpectation(description: "no push")
        DispatchQueue.main.async {
            XCTAssertTrue(self.pushed.isEmpty, "a click commits nothing on its own")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testTrailingTickAfterMouseUpCommitsViaDebounce() {
        // AX can stream the drag's final frame after the mouse-up fired:
        // the trailing tick moves the splitter further and re-arms the
        // trailing-tick commit, which lands the neighbor push on its own
        // — no second click needed. Needs a fixed boundsOf: with the
        // frame-as-bounds rig every drag position clamps to the same
        // splitter, and a trailing tick that produces no grid change
        // correctly re-arms nothing.
        let bounds = CGRect(x: 0, y: 0, width: 1680, height: 1019)
        let tracker = DragTracker(
            expectations: expectations,
            context: DragTracker.Context(
                slotOf: { [weak self] in self?.slots[$0] },
                frameOf: { [weak self] in
                    guard let handle = self?.handles[$0] else { return nil }
                    return self?.gateway.frame(of: handle)
                },
                boundsOf: { _ in bounds },
                occupants: { [weak self] in self?.occupants ?? [:] }),
            gridProvider: provider(),
            apply: { [weak self] rects, excluding in
                self?.pushed.append((rects, excluding))
            },
            onUntile: { [weak self] in self?.untiled.append($0) },
            scheduleDragEnd: { [weak self] fire in
                self?.dragEndFires.append(fire)
                return {}
            },
            scheduleCommit: { [weak self] fire in
                self?.commitFires.append(fire)
                return {}
            })
        tile(1, .topLeft, frame: CGRect(x: 0, y: 519, width: 840, height: 500))
        tile(2, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 840, height: 500))

        // Echo tick (swallowed), then a real edge drag: the top edge of
        // the bottom-left window drops to 450 in fixed screen bounds.
        var echo = CGRect(x: 0, y: 0, width: 840, height: 500)
        echo.size.height -= 10
        tracker.handleChange(id: 2, frame: echo)
        var dragged = CGRect(x: 0, y: 0, width: 840, height: 500)
        dragged.size.height -= 50
        tracker.handleChange(id: 2, frame: dragged)
        let firstSplit = grid().leftRowSplit
        XCTAssertGreaterThan(firstSplit, 0.4)
        tracker.mouseLifted()
        XCTAssertFalse(commitFires.isEmpty, "the release arms the commit")

        // The drag's final frame trails the mouse-up: a new splitter
        // fraction. It re-arms the commit (the open one is superseded).
        var trailing = CGRect(x: 0, y: 0, width: 840, height: 500)
        trailing.size.height -= 80
        tracker.handleChange(id: 2, frame: trailing)
        XCTAssertNotEqual(
            grid().leftRowSplit, firstSplit,
            "the trailing tick moved the splitter further")
        let afterTrailing = XCTestExpectation(description: "the trailing tick waits out its delay")
        DispatchQueue.main.async {
            XCTAssertEqual(
                self.pushed.count, 0,
                "nothing pushes before the trailing-tick commit fires")
            afterTrailing.fulfill()
        }
        wait(for: [afterTrailing], timeout: 1.0)

        fireCommit()
        let committed = XCTestExpectation(description: "the armed commit lands the trailing grid")
        DispatchQueue.main.async {
            XCTAssertEqual(self.pushed.count, 1, "exactly one push for the whole gesture")
            XCTAssertEqual(
                self.pushed[0].rects[1]?.maxY,
                self.grid().rect(for: .topLeft, in: bounds).maxY,
                "the neighbor lands on the trailing grid, not the pre-trailing one")
            committed.fulfill()
        }
        wait(for: [committed], timeout: 1.0)
    }

    func testLateTrailingTickAfterCommitArmsAnotherCommit() {
        // The final AX tick can even land after the commit fired: the
        // splitter moves again, and the tick arms a fresh commit instead
        // of needing a click. Correctness never depends on how late the
        // stream runs, only the delay does.
        let bounds = CGRect(x: 0, y: 0, width: 1680, height: 1019)
        let tracker = DragTracker(
            expectations: expectations,
            context: DragTracker.Context(
                slotOf: { [weak self] in self?.slots[$0] },
                frameOf: { [weak self] in
                    guard let handle = self?.handles[$0] else { return nil }
                    return self?.gateway.frame(of: handle)
                },
                boundsOf: { _ in bounds },
                occupants: { [weak self] in self?.occupants ?? [:] }),
            gridProvider: provider(),
            apply: { [weak self] rects, excluding in
                self?.pushed.append((rects, excluding))
            },
            onUntile: { [weak self] in self?.untiled.append($0) },
            scheduleDragEnd: { [weak self] fire in
                self?.dragEndFires.append(fire)
                return {}
            },
            scheduleCommit: { [weak self] fire in
                self?.commitFires.append(fire)
                return {}
            })
        tile(1, .topLeft, frame: CGRect(x: 0, y: 519, width: 840, height: 500))
        tile(2, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 840, height: 500))

        var echo = CGRect(x: 0, y: 0, width: 840, height: 490)
        tracker.handleChange(id: 2, frame: echo)
        var dragged = CGRect(x: 0, y: 0, width: 840, height: 450)
        tracker.handleChange(id: 2, frame: dragged)
        tracker.mouseLifted()
        fireCommit()
        let first = XCTestExpectation(description: "first commit")
        DispatchQueue.main.async {
            XCTAssertEqual(self.pushed.count, 1)
            first.fulfill()
        }
        wait(for: [first], timeout: 1.0)

        // A later tick lands after the commit: the splitter moves again
        // and a fresh commit is armed.
        var later = CGRect(x: 0, y: 0, width: 840, height: 400)
        tracker.handleChange(id: 2, frame: later)
        XCTAssertEqual(commitFires.count, 2, "the late tick armed a fresh commit")
        fireCommit()
        let second = XCTestExpectation(description: "late tick's commit")
        DispatchQueue.main.async {
            XCTAssertEqual(self.pushed.count, 2, "the late tick corrected the neighbor")
            XCTAssertNotEqual(
                self.pushed[0].rects[1], self.pushed[1].rects[1],
                "the second push carries the later grid")
            second.fulfill()
        }
        wait(for: [second], timeout: 1.0)
    }

    func testMousePressCancelsThePendingTrailingCommit() {
        // A fast second grab cancels the previous release's pending
        // commit: a stale trailing tick must never push neighbors under
        // the new drag. The new drag's own release commits.
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tile(2, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 840, height: 500))

        let echo = CGRect(x: 0, y: 0, width: 840, height: 490)
        tracker.handleChange(id: 2, frame: echo)
        let dragged = CGRect(x: 0, y: 0, width: 840, height: 420)
        tracker.handleChange(id: 2, frame: dragged)
        tracker.mouseLifted()
        XCTAssertFalse(commitFires.isEmpty, "the release armed a commit")

        // New grab before the delay elapsed: the armed commit is dropped.
        tracker.mousePressed()
        fireCommit()
        let cancelled = XCTestExpectation(description: "cancelled commit is a no-op")
        DispatchQueue.main.async {
            XCTAssertTrue(self.pushed.isEmpty, "the cancelled commit pushed nothing")
            cancelled.fulfill()
        }
        wait(for: [cancelled], timeout: 1.0)

        // The new drag ends: its own release commits.
        let moved = CGRect(x: 0, y: 0, width: 840, height: 380)
        tracker.handleChange(id: 2, frame: moved)
        tracker.mouseLifted()
        fireCommit()
        let committed = XCTestExpectation(description: "the new release commits")
        DispatchQueue.main.async {
            XCTAssertEqual(self.pushed.count, 1, "only the new release's grid committed")
            committed.fulfill()
        }
        wait(for: [committed], timeout: 1.0)
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
        tracker.mouseLifted()
        fireCommit()
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

    // MARK: A late check judges its own write (D3/D11 at the drag seam)

    /// A window occupying `frame` in `.topLeft`, with no echo entry or
    /// diff baseline primed (the write under test arms its own).
    private func tileFresh(_ id: WindowID, frame: CGRect) {
        handles[id] = gateway.addWindow(frame: frame)
        slots[id] = .topLeft
        occupants[.topLeft] = id
    }

    func testLaterUserDragAfterARefusedWriteUntilesInsteadOfSnappingBack() {
        // A refused placement leaves no echo entry and no phantom diff
        // baseline behind. Long after, a >100pt title-bar drag is
        // classified from its first tick and measured from where the
        // window is: it untiles. Anchored at the refused target it never
        // reached, the same gesture would measure ~42pt and snap back.
        let size = CGSize(width: 840, height: 500)
        let tileRect = CGRect(origin: CGPoint(x: 0, y: 500), size: size)
        tileFresh(1, frame: tileRect)
        gateway.refuseNextWrites(handles[1]!)
        // A same-size re-placement whose target lies by the drag's end:
        // the mis-anchor reads as "the gesture barely moved".
        let refused = CGRect(origin: CGPoint(x: 100, y: 600), size: size)
        XCTAssertEqual(
            expectations.write(
                1, handle: handles[1]!, to: refused, on: .displayless,
                consequence: .slotCommit),
            .refused)

        now += 4
        dragTicks(1, size: size, to: [(0, 500), (30, 530), (80, 580), (130, 630)])
        dragEndFires.last?()

        XCTAssertEqual(untiled, [1], "a >100pt drag untiles")
        XCTAssertTrue(pushed.isEmpty, "a long drag untiles; it does not snap back")
    }

    func testLaterUserDragAfterAClampRestoreFailureUntilesInsteadOfSnappingBack() {
        // A clamped write whose restore is refused leaves the expectation
        // pointed at the frame the window is actually in (the clamped
        // frame). Anchored at the restore target the window never
        // reached, the drag would measure short and snap back (L16).
        let size = CGSize(width: 500, height: 1000)
        let previous = CGRect(origin: CGPoint(x: 560, y: 560), size: size)
        tileFresh(1, frame: previous)
        let handle = handles[1]!
        let target = CGRect(x: 0, y: 0, width: 300, height: 1000)
        let applied = CGRect(origin: CGPoint(x: 400, y: 400), size: size)
        gateway.writtenFrame = { [weak self] _, requested in
            guard requested.width < 400 else { return requested }
            // The restore write back to `previous` is refused with it.
            self?.gateway.refuseNextWrites(handle)
            return applied
        }
        XCTAssertEqual(
            expectations.write(
                1, handle: handle, to: target, on: .displayless,
                consequence: .slotCommit),
            .refused)

        now += 4
        dragTicks(1, size: size, to: [(400, 400), (430, 430), (480, 480), (530, 530)])
        dragEndFires.last?()

        XCTAssertEqual(untiled, [1], "a >100pt drag untiles")
        XCTAssertTrue(pushed.isEmpty, "a long drag untiles; it does not snap back")
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
        XCTAssertEqual(grid(), GridLayout(), "the grid is untouched")
    }

    // MARK: Stale writes

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
        XCTAssertEqual(grid(), GridLayout())

        // Past the stale window, the next non-escaping tick is processed:
        // the echo entry clears and the resize moves the row splitter.
        now += TimeInterval(4)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 840, height: 330))
        // distance 170: not an escape, but the 4s-old entry is stale.

        XCTAssertEqual(
            grid().leftRowSplit, 0.8, accuracy: 0.001,
            "stale entry cleared; 330/330 clamps to the row-split maximum")
        tracker.mouseLifted()
        fireCommit()
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
        let defaultGrid = GridLayout()
        let tl = defaultGrid.rect(for: .sixthTopLeft, in: bounds)
        let r23 = defaultGrid.rect(for: .sixthsRightTwoThirds, in: bounds)
        handles[1] = gateway.addWindow(frame: tl)
        handles[2] = gateway.addWindow(frame: r23)
        handles[3] = gateway.addWindow(frame: defaultGrid.rect(for: .sixthBottomLeft, in: bounds))
        expectations.noteExpected(1, tl)
        expectations.noteExpected(2, r23)
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
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 440, width: 900, height: 500))
        XCTAssertEqual(grid().columnSplit, 0.85, accuracy: 0.001)
        XCTAssertEqual(grid().leftRowSplit, 0.2, accuracy: 0.001)
    }

    func testTitleBarGrabDuringSettleStillSnapsBack() {
        // A hand on the title bar the instant a write lands: origin-only
        // ticks inside the radius track a drag (splitters untouched), so
        // releasing short of the untile distance snaps back to the slot.
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tracker.handleChange(id: 1, frame: CGRect(x: 10, y: 510, width: 840, height: 500))
        tracker.handleChange(id: 1, frame: CGRect(x: 20, y: 520, width: 840, height: 500))
        XCTAssertEqual(grid(), GridLayout(), "drag tracking never moves splitters")
        XCTAssertFalse(dragEndFires.isEmpty, "settle must not swallow a title-bar grab")

        // Release (~28pt of drag, well inside the untile distance): the
        // pending drag end snaps the window back into its slot rect,
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
        XCTAssertEqual(grid().columnSplit, 0.85, accuracy: 0.001)
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
        XCTAssertEqual(grid(), GridLayout(), "no baseline: change dropped")

        // Restore/prune paths forget the window; the reassert that follows
        // must seed a fresh baseline from the live frame.
        tracker.forget(1)
        tracker.reassertAll(occupants: occupants)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 840, height: 440))
        XCTAssertEqual(
            grid().leftRowSplit, 0.8, accuracy: 0.001,
            "baseline seeded by reassert; 440/440 clamps to the row maximum")
    }
}
