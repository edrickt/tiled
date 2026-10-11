import XCTest
@testable import tiled

/// Per-monitor independence: each display runs its own layout, occupancy,
/// and splitters. Tiling, switching, and drag-resize on one monitor never
/// disturb the other. Driven through `TilingController` with the fake
/// gateway and an injected two-screen provider (the same seam as the
/// other controller tests).
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
            gateway: gateway, pruneInterval: nil,
            screens: { [Self.left, Self.right] }, deathConfirmation: 0)
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

        XCTAssertEqual(controller.canvas(for: leftID).state.occupant(of: .topLeft), 1)
        XCTAssertEqual(controller.canvas(for: rightID).state.occupant(of: .topLeft), 2)
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

        XCTAssertEqual(controller.canvas(for: leftID).state.activeLayout, .quarters)
        XCTAssertEqual(controller.canvas(for: rightID).state.activeLayout, .sixths)
        // Focusing a monitor scopes the read: focusing left shows
        // quarters, focusing right shows sixths.
        XCTAssertEqual(
            controller.canvas(for: controller.focusedTilingSpace).state.activeLayout, .sixths)
        gateway.focused = gateway.issued[0]
        XCTAssertEqual(
            controller.canvas(for: controller.focusedTilingSpace).state.activeLayout, .quarters)
    }

    func testFocusedScreenScopesLayoutAndOccupancyToFocusedDisplay() {
        // The status icon is one glyph but two monitors can run different
        // layouts. Resolving the focused screen once and reading that
        // monitor's layout/occupancy is what keeps the glyph true to the
        // display the user is working on.
        let left = tileOnLeft()
        controller.handle(slot: .topLeft)
        let right = tileOnRight()
        controller.handle(slot: .sixthLeft)

        gateway.focused = left
        XCTAssertEqual(controller.focusedScreen, leftID)
        XCTAssertEqual(controller.canvas(for: controller.focusedScreen).state.activeLayout, .quarters)
        XCTAssertEqual(
            controller.canvas(for: controller.focusedScreen).state.occupants,
            [.topLeft: 1])

        gateway.focused = right
        XCTAssertEqual(controller.focusedScreen, rightID)
        XCTAssertEqual(controller.canvas(for: controller.focusedScreen).state.activeLayout, .sixths)
        XCTAssertEqual(
            controller.canvas(for: controller.focusedScreen).state.occupants,
            [.sixthLeft: 2])
    }

    func testFocusObserverReportsOnlyWhenFocusedDisplayMoves() {
        let left = tileOnLeft()
        controller.handle(slot: .topLeft)
        let right = tileOnRight()
        controller.handle(slot: .sixthLeft)

        var reports = 0
        controller.onFocusedSpaceChange = { reports += 1 }

        gateway.focused = left
        gateway.simulateFocusChange()
        XCTAssertEqual(reports, 1, "the first callback resolves the starting display")

        gateway.focused = right
        gateway.simulateFocusChange()
        XCTAssertEqual(reports, 2, "focus landing on another display redraws the glyph")

        // A different untiled window on the same display leaves the
        // glyph's layout and occupancy untouched, so no report.
        let sameDisplay = gateway.addWindow(
            frame: CGRect(x: 2100, y: 200, width: 300, height: 200))
        gateway.focused = sameDisplay
        gateway.simulateFocusChange()
        XCTAssertEqual(reports, 2)

        gateway.focused = left
        gateway.simulateFocusChange()
        XCTAssertEqual(reports, 3)
    }

    func testCrossLayoutRequestOnlySwitchesItsOwnMonitor() {
        tileOnLeft()
        controller.handle(slot: .topLeft)
        let leftSecond = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 500, height: 400))
        gateway.focused = leftSecond
        controller.handle(slot: .topRight)
        tileOnRight()
        controller.handle(slot: .sixthLeft)
        XCTAssertEqual(controller.canvas(for: rightID).state.activeLayout, .sixths)

        // The right monitor switches back to quarters: only its own window
        // is evicted, the left monitor's quarters session is untouched.
        gateway.focused = gateway.issued[2]
        controller.handle(slot: .topLeft)

        XCTAssertEqual(controller.canvas(for: rightID).state.activeLayout, .quarters)
        XCTAssertEqual(controller.canvas(for: rightID).state.occupant(of: .topLeft), 3)
        XCTAssertEqual(controller.canvas(for: leftID).state.activeLayout, .quarters)
        XCTAssertEqual(controller.canvas(for: leftID).state.occupant(of: .topLeft), 1)
        XCTAssertEqual(controller.canvas(for: leftID).state.occupant(of: .topRight), 2)
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
        XCTAssertEqual(controller.canvas(for: rightID).state.occupant(of: .topLeft), 3)
        XCTAssertFalse(controller.canvas(for: rightID).undoStack.isEmpty)

        controller.undoLastDisplacement()

        // The evicted window returns under a fresh id (its record was
        // pruned at eviction); the challenger is untiled. The left
        // monitor is untouched.
        XCTAssertNotNil(controller.canvas(for: rightID).state.occupant(of: .topLeft))
        XCTAssertNil(controller.canvas(for: rightID).state.slot(of: 3))
        XCTAssertEqual(
            gateway.frame(of: gateway.issued[1]),
            GridLayout().rect(for: .topLeft, in: Self.right.visibleFrame))
        XCTAssertEqual(controller.canvas(for: leftID).state.occupant(of: .topLeft), 1)
    }

    func testUndoOnEmptyMonitorAnswersInsteadOfStealingHistory() {
        tileOnLeft()
        controller.handle(slot: .topLeft)
        let challenger = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 500, height: 400))
        gateway.focused = challenger
        controller.handle(slot: .topLeft)
        XCTAssertFalse(controller.canvas(for: leftID).undoStack.isEmpty)

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
        XCTAssertNotNil(controller.canvas(for: leftID).state.occupant(of: .topLeft))
        XCTAssertNil(controller.canvas(for: leftID).state.slot(of: 2))
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

        XCTAssertNotEqual(controller.canvas(for: leftID).grid.columnSplit, 0.5)
        XCTAssertEqual(controller.canvas(for: rightID).grid, GridLayout())
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
        XCTAssertNotEqual(controller.canvas(for: leftID).grid.columnSplit, 0.5)
        XCTAssertNotEqual(controller.canvas(for: rightID).grid.columnSplit, 0.5)

        // Focus left and reset: left snaps even, right keeps its drag.
        gateway.focused = leftHandle
        controller.resetDividers()

        XCTAssertEqual(controller.canvas(for: leftID).grid, GridLayout())
        XCTAssertNotEqual(controller.canvas(for: rightID).grid.columnSplit, 0.5)
        XCTAssertTrue(controller.canvas(for: leftID).hasSplitterBackup)
        XCTAssertTrue(controller.restoreSplitters())
        XCTAssertNotEqual(controller.canvas(for: leftID).grid.columnSplit, 0.5)
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
        controller.mouseLifted()

        let expectation = XCTestExpectation(description: "neighbor re-push")
        DispatchQueue.main.async {
            // Positive side: the dragged monitor's splitter actually
            // moved and its neighbor re-pushed onto the dragged grid,
            // the isolation claim must be two-sided, or a mutant that
            // deletes the re-push entirely would pass.
            let grid = self.controller.canvas(for: self.leftID).grid
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

        XCTAssertNil(controller.canvas(for: leftID).state.occupant(of: .topLeft))
        XCTAssertEqual(controller.canvas(for: rightID).state.occupant(of: .topLeft), 2)
        XCTAssertNotNil(controller.canvas(for: leftID).notice)
        controller.undoLastDisplacement()
        XCTAssertNotNil(controller.canvas(for: leftID).state.occupant(of: .topLeft))
        XCTAssertEqual(controller.canvas(for: rightID).state.occupant(of: .topLeft), 2)
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
        XCTAssertNotEqual(controller.canvas(for: leftID).grid.columnSplit, 0.5)
        XCTAssertNotEqual(controller.canvas(for: rightID).grid.columnSplit, 0.5)

        // Focus stays right; everything below names the left screen.
        gateway.focused = rightHandle
        controller.untileAll(on: leftID)
        XCTAssertNil(controller.canvas(for: leftID).state.occupant(of: .topLeft))
        XCTAssertEqual(controller.canvas(for: rightID).state.occupant(of: .topLeft), 2)
        controller.undoLastDisplacement(on: leftID)
        XCTAssertNotNil(controller.canvas(for: leftID).state.occupant(of: .topLeft))
        XCTAssertEqual(controller.canvas(for: rightID).state.occupant(of: .topLeft), 2)

        controller.resetDividers(on: leftID)
        XCTAssertEqual(controller.canvas(for: leftID).grid, GridLayout())
        XCTAssertNotEqual(controller.canvas(for: rightID).grid.columnSplit, 0.5)
        XCTAssertTrue(controller.restoreSplitters(on: leftID))
        XCTAssertNotEqual(controller.canvas(for: leftID).grid.columnSplit, 0.5)
        XCTAssertFalse(controller.restoreSplitters(on: leftID))
    }

    func testClosedWindowOnOneMonitorLeavesTheOtherAlone() {
        let leftHandle = tileOnLeft()
        controller.handle(slot: .topLeft)
        tileOnRight()
        controller.handle(slot: .topLeft)

        gateway.kill(leftHandle)
        controller.pruneDeadWindows()

        XCTAssertNil(controller.canvas(for: leftID).state.occupant(of: .topLeft))
        XCTAssertEqual(controller.canvas(for: rightID).state.occupant(of: .topLeft), 2)
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

        XCTAssertEqual(controller.canvas(for: rightID).state.occupant(of: .topLeft), 3)
        XCTAssertNil(controller.canvas(for: rightID).state.slot(of: 2))
        XCTAssertEqual(controller.canvas(for: leftID).state.occupant(of: .topLeft), 1)
    }

    /// A screen-scoped action on the unfocused monitor dissolves that
    /// monitor's canvas and leaves the focused one alone. The read is
    /// explicit per canvas: no derived surface reports the actor.
    func testScreenScopedActionOnTheUnfocusedMonitorLeavesTheFocusedOneAlone() {
        let left = tileOnLeft()
        controller.handle(slot: .topLeft)
        tileOnRight()
        controller.handle(slot: .topLeft)
        gateway.focused = left

        controller.untileAll(on: rightID)

        XCTAssertTrue(
            controller.canvas(for: rightID).state.occupants.isEmpty,
            "the named canvas dissolved")
        XCTAssertEqual(
            controller.canvas(for: leftID).state.occupant(of: .topLeft), 1,
            "the focused canvas is untouched")
        XCTAssertNil(controller.canvas(for: rightID).state.occupant(of: .topLeft))
    }

    // MARK: One visible frame per canvas

    /// The canvas owns one visible frame: two occupants of one canvas
    /// derive their shared edge from that one frame, so their frames
    /// touch even when one window's own frame has drifted onto another
    /// display. Resolving bounds from each window's own frame would size
    /// the drifted window against the other display and open a gap at the
    /// shared edge.
    func testTwoOccupantsOfOneCanvasStayFlushAgainstOneFrame() {
        let a = tileOnLeft()
        controller.handle(slot: .leftHalf)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 100, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .rightHalf)

        // The right occupant's live frame drifts onto the second display
        // (an app that moved or rounded it) without a user drag.
        gateway.simulateSilentChange(
            b, to: CGRect(x: 1700, y: 100, width: 800, height: 600))

        // A splitter reset re-asserts the canvas under its own frame.
        controller.resetDividers(on: leftID)

        let leftBounds = Self.left.visibleFrame
        let leftFrame = GridLayout().rect(for: .leftHalf, in: leftBounds)
        let rightFrame = GridLayout().rect(for: .rightHalf, in: leftBounds)
        XCTAssertEqual(gateway.frame(of: a), leftFrame)
        XCTAssertEqual(
            gateway.frame(of: b), rightFrame,
            "the drifted occupant re-derives from the canvas's own frame")
        XCTAssertEqual(
            gateway.frame(of: a)!.maxX, gateway.frame(of: b)!.minX,
            "two occupants of one canvas share one bounds, so their frames touch")
    }
}
