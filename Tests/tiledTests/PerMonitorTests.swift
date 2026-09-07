import XCTest
@testable import tiled

/// Per-monitor independence: each display runs its own layout, occupancy,
/// and splitters. Tiling, switching, swapping, and drag-resize on one
/// monitor never disturb the other. Driven through `TilingController` with
/// the fake gateway and an injected two-screen provider — the same seam
/// as the other controller tests.
final class PerMonitorTests: XCTestCase {
    private static let left = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        name: "Display 1")
    private static let right = ScreenInfo(
        id: ScreenID(rawValue: 2),
        frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        name: "Display 2")

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        controller = TilingController(
            gateway: gateway, pruneInterval: nil, screens: { [Self.left, Self.right] })
    }

    private var leftID: ScreenID { Self.left.id }
    private var rightID: ScreenID { Self.right.id }

    @discardableResult
    private func tileOnLeft(frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600)) -> WindowHandle {
        let handle = gateway.addWindow(frame: frame)
        gateway.focused = handle
        return handle
    }

    @discardableResult
    private func tileOnRight(frame: CGRect = CGRect(x: 2000, y: 100, width: 800, height: 600)) -> WindowHandle {
        let handle = gateway.addWindow(frame: frame)
        gateway.focused = handle
        return handle
    }

    // MARK: Independent occupancy and layouts

    func testSameSlotCoexistsOnBothMonitors() {
        let a = tileOnLeft()
        controller.handle(slot: .topLeft)
        let b = tileOnRight()
        controller.handle(slot: .topLeft)

        XCTAssertEqual(controller.occupant(of: .topLeft, on: leftID), 1)
        XCTAssertEqual(controller.occupant(of: .topLeft, on: rightID), 2)
        XCTAssertEqual(
            gateway.frame(of: a), GridLayout().rect(for: .topLeft, in: Self.left.visibleFrame))
        XCTAssertEqual(
            gateway.frame(of: b), GridLayout().rect(for: .topLeft, in: Self.right.visibleFrame))
    }

    func testEachMonitorRunsItsOwnLayout() {
        tileOnLeft()
        controller.handle(slot: .topLeft)
        tileOnRight()
        controller.handle(slot: .sixthLeft)

        XCTAssertEqual(controller.activeLayout(on: leftID), .quarters)
        XCTAssertEqual(controller.activeLayout(on: rightID), .sixths)
        // The focused monitor drives the shared surface: focusing left
        // shows quarters, focusing right shows sixths.
        XCTAssertEqual(controller.activeLayout, .sixths)
        gateway.focused = gateway.issued[0]
        XCTAssertEqual(controller.activeLayout, .quarters)
    }

    func testCrossLayoutRequestOnlySwitchesItsOwnMonitor() {
        tileOnLeft()
        controller.handle(slot: .topLeft)
        let leftSecond = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 500, height: 400))
        gateway.focused = leftSecond
        controller.handle(slot: .topRight)
        tileOnRight()
        controller.handle(slot: .sixthLeft)
        XCTAssertEqual(controller.activeLayout(on: rightID), .sixths)

        // The right monitor switches back to quarters: only its own window
        // is evicted, the left monitor's quarters session is untouched.
        gateway.focused = gateway.issued[2]
        controller.handle(slot: .topLeft)

        XCTAssertEqual(controller.activeLayout(on: rightID), .quarters)
        XCTAssertEqual(controller.occupant(of: .topLeft, on: rightID), 3)
        XCTAssertEqual(controller.activeLayout(on: leftID), .quarters)
        XCTAssertEqual(controller.occupant(of: .topLeft, on: leftID), 1)
        XCTAssertEqual(controller.occupant(of: .topRight, on: leftID), 2)
    }

    func testSwapStaysOnItsOwnMonitor() {
        // Left runs a two-window column; right runs one window.
        let a = tileOnLeft()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 500, height: 400))
        gateway.focused = b
        controller.handle(slot: .bottomLeft)
        tileOnRight()
        controller.handle(slot: .topLeft)
        XCTAssertEqual(controller.occupant(of: .topLeft, on: rightID), 3)

        // The left top window takes the left bottom: a swap within the
        // left space. The right monitor is untouched.
        gateway.focused = a
        controller.handle(slot: .bottomLeft)

        XCTAssertEqual(controller.occupant(of: .bottomLeft, on: leftID), 1)
        XCTAssertEqual(controller.occupant(of: .topLeft, on: leftID), 2)
        XCTAssertEqual(controller.occupant(of: .topLeft, on: rightID), 3)
        XCTAssertEqual(controller.activeLayout(on: leftID), .quarters)
        XCTAssertEqual(controller.activeLayout(on: rightID), .quarters)
    }

    func testUndoRestoresOnlyItsOwnMonitor() {
        tileOnLeft()
        controller.handle(slot: .topLeft)
        tileOnRight()
        controller.handle(slot: .topLeft)
        // Evict on the right: the left occupant is restored there.
        let challenger = gateway.addWindow(frame: CGRect(x: 2100, y: 100, width: 500, height: 400))
        gateway.focused = challenger
        controller.handle(slot: .topLeft)
        XCTAssertEqual(controller.occupant(of: .topLeft, on: rightID), 3)
        XCTAssertTrue(controller.canUndoDisplacement)

        controller.undoLastDisplacement()

        // The evicted window returns under a fresh id (its record was
        // pruned at eviction); the challenger is untiled. The left
        // monitor is untouched.
        XCTAssertNotNil(controller.occupant(of: .topLeft, on: rightID))
        XCTAssertNil(controller.state(on: rightID).slot(of: 3))
        XCTAssertEqual(
            gateway.frame(of: gateway.issued[1]),
            GridLayout().rect(for: .topLeft, in: Self.right.visibleFrame))
        XCTAssertEqual(controller.occupant(of: .topLeft, on: leftID), 1)
    }

    func testUndoOnEmptyMonitorAnswersInsteadOfStealingHistory() {
        tileOnLeft()
        controller.handle(slot: .topLeft)
        let challenger = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 500, height: 400))
        gateway.focused = challenger
        controller.handle(slot: .topLeft)
        XCTAssertTrue(controller.canUndoDisplacement)

        // Focus the untouched right monitor: nothing destructive happened
        // there, so undo answers instead of reaching into the left
        // monitor's history.
        var feedbacks: [TilingController.Feedback] = []
        controller.onFeedback = { feedbacks.append($0) }
        let probe = gateway.addWindow(frame: CGRect(x: 2100, y: 100, width: 500, height: 400))
        gateway.focused = probe
        controller.undoLastDisplacement()

        guard case .nothingToUndo = feedbacks.first else {
            return XCTFail("expected .nothingToUndo, got \(feedbacks)")
        }
        // The left monitor's history survives for its own undo: the
        // evicted window returns (under a fresh id) and the challenger
        // untiles.
        gateway.focused = challenger
        controller.undoLastDisplacement()
        XCTAssertNotNil(controller.occupant(of: .topLeft, on: leftID))
        XCTAssertNil(controller.state(on: leftID).slot(of: 2))
    }

    func testSplittersAreIndependentPerMonitor() {
        tileOnLeft()
        controller.handle(slot: .topLeft)
        tileOnRight()
        controller.handle(slot: .topLeft)

        // Drag the left top-left's right edge: only the left column split
        // moves; the right monitor's grid stays even.
        let leftHandle = gateway.issued[0]
        var echo = gateway.frame(of: leftHandle)!
        echo.size.width -= 10
        gateway.simulateChange(leftHandle, to: echo)
        var dragged = gateway.frame(of: leftHandle)!
        dragged.size.width -= 60
        gateway.simulateChange(leftHandle, to: dragged)

        XCTAssertNotEqual(controller.grid(on: leftID).columnSplit, 0.5)
        XCTAssertEqual(controller.grid(on: rightID), GridLayout())
    }

    func testResetDividersOnlyResetsTheFocusedMonitor() {
        tileOnLeft()
        controller.handle(slot: .topLeft)
        tileOnRight()
        controller.handle(slot: .topLeft)
        let leftHandle = gateway.issued[0]
        let rightHandle = gateway.issued[1]
        for handle in [leftHandle, rightHandle] {
            var echo = gateway.frame(of: handle)!
            echo.size.width -= 10
            gateway.simulateChange(handle, to: echo)
            var dragged = gateway.frame(of: handle)!
            dragged.size.width -= 60
            gateway.simulateChange(handle, to: dragged)
        }
        XCTAssertNotEqual(controller.grid(on: leftID).columnSplit, 0.5)
        XCTAssertNotEqual(controller.grid(on: rightID).columnSplit, 0.5)

        // Focus left and reset: left snaps even, right keeps its drag.
        gateway.focused = leftHandle
        controller.resetDividers()

        XCTAssertEqual(controller.grid(on: leftID), GridLayout())
        XCTAssertNotEqual(controller.grid(on: rightID).columnSplit, 0.5)
        XCTAssertTrue(controller.hasSplitterBackup)
        XCTAssertTrue(controller.restoreSplitters())
        XCTAssertNotEqual(controller.grid(on: leftID).columnSplit, 0.5)
    }

    // MARK: Swaps under dragged splitters

    func testSwapUsesTheDraggedSplitterGrid() {
        // Tile two left-column quads, drag the column split, then swap the
        // top window into the bottom slot. Every placement write must
        // derive from the dragged grid — a swap must never snap tiles back
        // to default splitters (the executor used to read the legacy nil-
        // screen grid, misplacing every window after any drag).
        let a = tileOnLeft()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 500, height: 400))
        gateway.focused = b
        controller.handle(slot: .bottomLeft)

        var echo = gateway.frame(of: a)!
        echo.size.width -= 10
        gateway.simulateChange(a, to: echo)
        var dragged = gateway.frame(of: a)!
        dragged.size.width -= 60
        gateway.simulateChange(a, to: dragged)
        XCTAssertNotEqual(controller.grid(on: leftID).columnSplit, 0.5)
        // Drain the tracker's coalesced re-push before acting further.
        // The re-push is enqueued with DispatchQueue.main.async, so one
        // async hop after it guarantees it landed (FIFO) — no runloop
        // spin needed.
        let drained = XCTestExpectation(description: "coalesced re-push drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        gateway.focused = a
        controller.handle(slot: .bottomLeft)

        XCTAssertEqual(controller.occupant(of: .bottomLeft, on: leftID), 1)
        XCTAssertEqual(controller.occupant(of: .topLeft, on: leftID), 2)
        let grid = controller.grid(on: leftID)
        XCTAssertEqual(
            gateway.frame(of: a), grid.rect(for: .bottomLeft, in: Self.left.visibleFrame),
            "the swapped window lands on the dragged grid, not the default")
        XCTAssertEqual(
            gateway.frame(of: b), grid.rect(for: .topLeft, in: Self.left.visibleFrame),
            "the blocker inherits the vacated slot on the dragged grid too")
    }

    func testDragResizeOnlyPushesItsOwnMonitor() {
        tileOnLeft()
        controller.handle(slot: .topLeft)
        let leftNeighbor = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 500, height: 400))
        gateway.focused = leftNeighbor
        controller.handle(slot: .bottomLeft)
        tileOnRight()
        controller.handle(slot: .topLeft)
        let rightHandle = gateway.issued[2]
        let rightBefore = gateway.frame(of: rightHandle)!

        // Drag the left column's row edge: the left neighbor re-pushes on
        // the next tick, the right monitor's window never moves.
        var echo = gateway.frame(of: leftNeighbor)!
        echo.size.height -= 10
        gateway.simulateChange(leftNeighbor, to: echo)
        var dragged = gateway.frame(of: leftNeighbor)!
        dragged.size.height -= 60
        gateway.simulateChange(leftNeighbor, to: dragged)

        let expectation = XCTestExpectation(description: "neighbor re-push")
        DispatchQueue.main.async {
            // Positive side: the dragged monitor's splitter actually
            // moved and its neighbor re-pushed onto the dragged grid —
            // the isolation claim must be two-sided, or a mutant that
            // deletes the re-push entirely would pass.
            let grid = self.controller.grid(on: self.leftID)
            XCTAssertNotEqual(
                grid.leftRowSplit, 0.5,
                "the drag moved the left monitor's row splitter")
            XCTAssertEqual(
                self.gateway.frame(of: leftNeighbor),
                grid.rect(for: .bottomLeft, in: Self.left.visibleFrame),
                "the dragged monitor's neighbor re-pushed onto the dragged grid")
            // Negative side: the other monitor's window never moves.
            XCTAssertEqual(self.gateway.frame(of: rightHandle), rightBefore)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testExpandFillsItsOwnMonitor() {
        let leftHandle = tileOnLeft()
        controller.handle(slot: .topLeft)
        tileOnRight()
        controller.handle(slot: .topLeft)

        gateway.focused = leftHandle
        controller.handleExpandToggle()

        XCTAssertEqual(gateway.frame(of: leftHandle), Self.left.visibleFrame)
        // The right monitor's tile is untouched by the expand.
        XCTAssertEqual(
            gateway.frame(of: gateway.issued[1]),
            GridLayout().rect(for: .topLeft, in: Self.right.visibleFrame))
    }

    func testUntileAllOnlyDissolvesTheFocusedMonitor() {
        tileOnLeft()
        controller.handle(slot: .topLeft)
        tileOnRight()
        controller.handle(slot: .topLeft)

        gateway.focused = gateway.issued[0]
        controller.untileAll()

        XCTAssertNil(controller.occupant(of: .topLeft, on: leftID))
        XCTAssertEqual(controller.occupant(of: .topLeft, on: rightID), 2)
        XCTAssertNotNil(controller.lastNotice)
        controller.undoLastDisplacement()
        XCTAssertNotNil(controller.occupant(of: .topLeft, on: leftID))
        XCTAssertEqual(controller.occupant(of: .topLeft, on: rightID), 2)
    }

    func testPerScreenBulkActionsBypassFocus() {
        // The on-screen overloads act on the named monitor directly:
        // focus stays wherever it is, and the untouched display keeps
        // its tiles, splitters, and undo history.
        tileOnLeft()
        controller.handle(slot: .topLeft)
        tileOnRight()
        controller.handle(slot: .topLeft)
        let leftHandle = gateway.issued[0]
        let rightHandle = gateway.issued[1]
        for handle in [leftHandle, rightHandle] {
            var echo = gateway.frame(of: handle)!
            echo.size.width -= 10
            gateway.simulateChange(handle, to: echo)
            var dragged = gateway.frame(of: handle)!
            dragged.size.width -= 60
            gateway.simulateChange(handle, to: dragged)
        }
        XCTAssertNotEqual(controller.grid(on: leftID).columnSplit, 0.5)
        XCTAssertNotEqual(controller.grid(on: rightID).columnSplit, 0.5)

        // Focus stays right; everything below names the left screen.
        gateway.focused = rightHandle
        controller.untileAll(on: leftID)
        XCTAssertNil(controller.occupant(of: .topLeft, on: leftID))
        XCTAssertEqual(controller.occupant(of: .topLeft, on: rightID), 2)
        controller.undoLastDisplacement(on: leftID)
        XCTAssertNotNil(controller.occupant(of: .topLeft, on: leftID))
        XCTAssertEqual(controller.occupant(of: .topLeft, on: rightID), 2)

        controller.resetDividers(on: leftID)
        XCTAssertEqual(controller.grid(on: leftID), GridLayout())
        XCTAssertNotEqual(controller.grid(on: rightID).columnSplit, 0.5)
        XCTAssertTrue(controller.restoreSplitters(on: leftID))
        XCTAssertNotEqual(controller.grid(on: leftID).columnSplit, 0.5)
        XCTAssertFalse(controller.restoreSplitters(on: leftID))
    }

    func testClosedWindowOnOneMonitorLeavesTheOtherAlone() {
        let leftHandle = tileOnLeft()
        controller.handle(slot: .topLeft)
        tileOnRight()
        controller.handle(slot: .topLeft)

        gateway.kill(leftHandle)
        controller.pruneDeadWindows()

        XCTAssertNil(controller.occupant(of: .topLeft, on: leftID))
        XCTAssertEqual(controller.occupant(of: .topLeft, on: rightID), 2)
    }

    func testEvictOnlyReflowsItsOwnMonitor() {
        // Both monitors run a two-window left column; evicting the left
        // top-left grows the left bottom-left, and the right monitor's
        // column is untouched.
        let leftTop = tileOnLeft()
        controller.handle(slot: .topLeft)
        let leftBottom = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 500, height: 400))
        gateway.focused = leftBottom
        controller.handle(slot: .bottomLeft)
        let rightTop = tileOnRight()
        controller.handle(slot: .topLeft)
        let rightBottom = gateway.addWindow(frame: CGRect(x: 2100, y: 100, width: 500, height: 400))
        gateway.focused = rightBottom
        controller.handle(slot: .bottomLeft)

        gateway.focused = leftTop
        controller.handleEvict()

        XCTAssertEqual(controller.occupant(of: .leftHalf, on: leftID), 2)
        XCTAssertNil(controller.state(on: leftID).slot(of: 1))
        XCTAssertEqual(
            gateway.frame(of: leftBottom),
            GridLayout().rect(for: .leftHalf, in: Self.left.visibleFrame))
        XCTAssertEqual(controller.occupant(of: .topLeft, on: rightID), 3)
        XCTAssertEqual(controller.occupant(of: .bottomLeft, on: rightID), 4)
        XCTAssertEqual(
            gateway.frame(of: rightTop),
            GridLayout().rect(for: .topLeft, in: Self.right.visibleFrame),
            "the other monitor's tiles never move")
    }

    func testEvictionNeverCrossesMonitors() {
        tileOnLeft()
        controller.handle(slot: .topLeft)
        tileOnRight()
        controller.handle(slot: .topLeft)

        // A fresh window on the right takes the right top-left: the right
        // occupant is evicted, the left occupant survives.
        let challenger = gateway.addWindow(frame: CGRect(x: 2100, y: 100, width: 500, height: 400))
        gateway.focused = challenger
        controller.handle(slot: .topLeft)

        XCTAssertEqual(controller.occupant(of: .topLeft, on: rightID), 3)
        XCTAssertNil(controller.state(on: rightID).slot(of: 2))
        XCTAssertEqual(controller.occupant(of: .topLeft, on: leftID), 1)
    }
}
