import XCTest
@testable import tiled

/// Reflow: when a tiled window leaves the layout (eviction, untile,
/// drag-out, close) or moves, its freed cells merge with exactly one
/// adjacent survivor into a whole slot, and that survivor grows into it.
/// Freed cells no survivor can absorb stay empty. Pure `TilingState`
/// rules here; controller wiring in the second half of the file.
final class ReflowTests: XCTestCase {
    private let a = 1
    private let b = 2
    private let c = 3
    private let d = 4

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        controller = TilingController(gateway: gateway, pruneInterval: nil)
    }

    // MARK: Pure reflow rules (TilingState)

    func testEvictBottomLeftGrowsTopLeftDown() {
        // The report's example: two left corner sixths; the bottom one
        // leaves, the top one expands down into the left third.
        var state = TilingState()
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: b, into: .sixthBottomLeft)
        state.remove(window: b)
        XCTAssertEqual(
            state.reflow(freed: Slot.sixthBottomLeft.cells, excluding: [b]),
            [a: .sixthLeft])
    }

    func testEvictMiddleThirdGrowsRightThirdLeftwards() {
        var state = TilingState()
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: b, into: .sixthBottomLeft)
        state.commit(window: c, into: .sixthMiddle)
        state.commit(window: d, into: .sixthRight)
        state.remove(window: c)
        XCTAssertEqual(
            state.reflow(freed: Slot.sixthMiddle.cells, excluding: [c]),
            [d: .sixthsRightTwoThirds])
    }

    func testRightFlankPreferredWhenBothThirdsCouldGrow() {
        // Left, middle, and right thirds; the middle leaves. Both flanks
        // could become two-thirds, and they overlap each other: right
        // preferred, so the right third wins the freed cells.
        var state = TilingState()
        state.commit(window: a, into: .sixthLeft)
        state.commit(window: b, into: .sixthMiddle)
        state.commit(window: c, into: .sixthRight)
        state.remove(window: b)
        XCTAssertEqual(
            state.reflow(freed: Slot.sixthMiddle.cells, excluding: [b]),
            [c: .sixthsRightTwoThirds])
    }

    func testMoveFreesVacatedCellsToTheRightNeighbor() {
        // Middle and right thirds; the middle third window moves to the
        // free bottom-left sixth. Its vacated cells flow right: the right
        // third becomes the right two-thirds.
        var state = TilingState()
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: b, into: .sixthMiddle)
        state.commit(window: c, into: .sixthRight)
        // The move already committed: b sits at its target, its old slot
        // is the freed region.
        state.commit(window: b, into: .sixthBottomLeft)
        XCTAssertEqual(
            state.reflow(freed: Slot.sixthMiddle.cells, excluding: [b]),
            [c: .sixthsRightTwoThirds])
    }

    func testRequesterNeverAbsorbsItsOwnFreedCells() {
        // Left half moving to top left frees the bottom-left quarter, and
        // the left half is the only slot covering both: the requester must
        // be excluded or it would undo the move it just made.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(
            state.reflow(freed: Slot.bottomLeft.cells, excluding: [a]),
            [:])
    }

    func testEvictTopLeftGrowsBottomLeftUp() {
        var state = TilingState()
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: b, into: .sixthBottomLeft)
        state.remove(window: a)
        XCTAssertEqual(
            state.reflow(freed: Slot.sixthTopLeft.cells, excluding: [a]),
            [b: .sixthLeft])
    }

    func testEvictTopMiddleGrowsBottomMiddleUp() {
        var state = TilingState()
        state.commit(window: a, into: .sixthTopMiddle)
        state.commit(window: b, into: .sixthBottomMiddle)
        state.remove(window: a)
        XCTAssertEqual(
            state.reflow(freed: Slot.sixthTopMiddle.cells, excluding: [a]),
            [b: .sixthMiddle])
    }

    func testQuartersColumnMateGrowsIntoHalf() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        state.remove(window: b)
        XCTAssertEqual(
            state.reflow(freed: Slot.bottomLeft.cells, excluding: [b]),
            [a: .leftHalf])
    }

    func testQuartersEvictTopRightGrowsBottomRightUp() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)
        state.commit(window: c, into: .bottomRight)
        state.remove(window: b)
        XCTAssertEqual(
            state.reflow(freed: Slot.topRight.cells, excluding: [b]),
            [c: .rightHalf])
    }

    func testNoMergeableSurvivorLeavesTheHole() {
        // Left corner sixth and right third: freeing the top-left cell
        // leaves a hole — the right third cannot reach it, and a
        // two-thirds would have to swallow the middle the requester now
        // occupies... nothing merges, nothing moves.
        var state = TilingState()
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: c, into: .sixthRight)
        state.remove(window: a)
        XCTAssertEqual(
            state.reflow(freed: Slot.sixthTopLeft.cells, excluding: [a]),
            [:])
    }

    func testPreExistingEmptySpaceIsNeverAbsorbed() {
        // The freed-only rule: with only the top-left and bottom-right
        // quads tiled, evicting the top-left frees its quarter — and the
        // bottom-right cannot merge with it without covering the
        // top-right quarter nobody vacated. Nothing grows.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: c, into: .bottomRight)
        state.remove(window: a)
        XCTAssertEqual(
            state.reflow(freed: Slot.topLeft.cells),
            [:])
    }

    func testLeaversCellsStayFreedAfterRemoval() {
        // Callers remove the leaver before reflowing; its cells arrive
        // as the freed region and no longer block as occupied.
        var state = TilingState()
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: b, into: .sixthBottomLeft)
        state.remove(window: b)
        XCTAssertEqual(
            state.reflow(freed: Slot.sixthBottomLeft.cells),
            [a: .sixthLeft])
    }

    func testExpandedExclusionIsTheCallersJob() {
        // Pure state knows nothing about expansion; `excluding` is the
        // single exclusion mechanism (requesters and expanded windows).
        var state = TilingState()
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: b, into: .sixthBottomLeft)
        state.remove(window: b)
        XCTAssertEqual(
            state.reflow(freed: Slot.sixthBottomLeft.cells, excluding: [a]),
            [:])
    }
}

// MARK: Controller wiring (through the fake gateway)

extension ReflowTests {
    /// Sixths session: a at top-left sixth, b at bottom-left sixth,
    /// c at right third (ids 1, 2, 3 in tiling order).
    private func tileLeftColumnAndRightThird() -> (a: WindowHandle, b: WindowHandle, c: WindowHandle) {
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .sixthTopLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .sixthBottomLeft)
        let c = gateway.addWindow(frame: CGRect(x: 1200, y: 100, width: 500, height: 400))
        gateway.focused = c
        controller.handle(slot: .sixthRight)
        return (a, b, c)
    }

    private func expectedRect(_ slot: Slot, for handle: WindowHandle) -> CGRect {
        let frame = gateway.frame(of: handle)!
        let screens = NSScreen.screens
        let index = TilingController.owningScreenIndex(frames: screens.map(\.frame), for: frame) ?? 0
        return controller.grid.rect(for: slot, in: screens[index].visibleFrame)
    }

    func testEvictHotkeyGrowsColumnSurvivorDown() {
        let (a, b, _) = tileLeftColumnAndRightThird()

        gateway.focused = a
        controller.handleEvict()

        XCTAssertEqual(controller.state.slot(of: 2), .sixthLeft, "the survivor expands down")
        XCTAssertEqual(gateway.frame(of: b), expectedRect(.sixthLeft, for: b))
        XCTAssertTrue(controller.state.slot(of: 1) == nil, "the evicted window is untiled")
        XCTAssertEqual(gateway.frame(of: a), CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    func testEvictHotkeyPrefersRightFlank() {
        // Left, middle, right thirds tiled in order.
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .sixthLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .sixthMiddle)
        let c = gateway.addWindow(frame: CGRect(x: 1200, y: 100, width: 500, height: 400))
        gateway.focused = c
        controller.handle(slot: .sixthRight)

        // The middle third leaves: both flanks could become two-thirds,
        // and right wins.
        gateway.focused = b
        controller.handleEvict()

        XCTAssertEqual(
            controller.state.slot(of: 3), .sixthsRightTwoThirds,
            "right flank preferred over growing the left third")
        XCTAssertEqual(gateway.frame(of: c), expectedRect(.sixthsRightTwoThirds, for: c))
    }

    func testEvictWithReflowPushesUndoChapter() {
        let (a, b, _) = tileLeftColumnAndRightThird()

        gateway.focused = a
        controller.handleEvict()
        XCTAssertTrue(controller.canUndoDisplacement, "the reflow is its own chapter")

        controller.undoLastDisplacement()

        XCTAssertEqual(
            controller.state.slot(of: 2), .sixthBottomLeft,
            "the survivor returns to the slot it held before the reflow")
        XCTAssertEqual(gateway.frame(of: b), expectedRect(.sixthBottomLeft, for: b))
        XCTAssertTrue(controller.state.slot(of: 1) == nil, "the evicted window stays untiled")
        XCTAssertEqual(gateway.frame(of: a), CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    func testMoveToFreeSlotReflowsVacatedCells() {
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .sixthTopLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .sixthMiddle)
        let c = gateway.addWindow(frame: CGRect(x: 1200, y: 100, width: 500, height: 400))
        gateway.focused = c
        controller.handle(slot: .sixthRight)

        // The middle third window tiles into the free bottom-left sixth:
        // its vacated cells flow right, tiling the right third as the
        // right two-thirds.
        gateway.focused = b
        controller.handle(slot: .sixthBottomLeft)

        XCTAssertEqual(controller.state.slot(of: 2), .sixthBottomLeft)
        XCTAssertEqual(controller.state.slot(of: 3), .sixthsRightTwoThirds)
        XCTAssertEqual(gateway.frame(of: c), expectedRect(.sixthsRightTwoThirds, for: c))
    }

    func testMoveReflowIsUndoableWithoutMovingTheRequester() {
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .sixthTopLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .sixthMiddle)
        let c = gateway.addWindow(frame: CGRect(x: 1200, y: 100, width: 500, height: 400))
        gateway.focused = c
        controller.handle(slot: .sixthRight)
        gateway.focused = b
        controller.handle(slot: .sixthBottomLeft)

        controller.undoLastDisplacement()

        XCTAssertEqual(controller.state.slot(of: 3), .sixthRight, "the survivor returns")
        XCTAssertEqual(gateway.frame(of: c), expectedRect(.sixthRight, for: c))
        XCTAssertEqual(
            controller.state.slot(of: 2), .sixthBottomLeft,
            "the requester keeps the slot it chose")
    }

    func testUntileReflows() {
        let (a, _, _) = tileLeftColumnAndRightThird()

        controller.untile(window: 2)

        XCTAssertEqual(controller.state.slot(of: 1), .sixthLeft)
        XCTAssertEqual(gateway.frame(of: a), expectedRect(.sixthLeft, for: a))
    }

    func testDragOutReflows() {
        let (a, _, _) = tileLeftColumnAndRightThird()

        controller.untileFromDrag(2)

        XCTAssertEqual(controller.state.slot(of: 1), .sixthLeft)
        XCTAssertEqual(gateway.frame(of: a), expectedRect(.sixthLeft, for: a))
    }

    func testClosedWindowReflows() {
        let (_, b, _) = tileLeftColumnAndRightThird()

        gateway.kill(b)
        controller.pruneDeadWindows()

        XCTAssertEqual(controller.state.slot(of: 1), .sixthLeft)
    }

    func testExpandedSurvivorNeverGrows() {
        let (a, b, _) = tileLeftColumnAndRightThird()
        gateway.focused = b
        controller.handleExpandToggle()
        let expandedFrame = gateway.frame(of: b)

        gateway.focused = a
        controller.handleEvict()

        XCTAssertEqual(
            controller.state.slot(of: 2), .sixthBottomLeft,
            "the expanded survivor keeps its slot")
        XCTAssertEqual(
            gateway.frame(of: b), expandedFrame,
            "the expanded survivor keeps covering the layout")
        XCTAssertTrue(controller.state.slot(of: 1) == nil)
    }
}
