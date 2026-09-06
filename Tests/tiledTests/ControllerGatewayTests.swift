import AppKit
import XCTest
@testable import tiled

/// TilingController through the `WindowGateway` seam: the first tests that
/// drive `handle(slot:)` itself instead of re-implementing its plan/commit
/// dance in the test (cf. LayoutSwitchTests' "commits a plan exactly like
/// handle does" helpers). The fake stands in for AX.
final class ControllerGatewayTests: XCTestCase {
    /// Screen the fake tiles onto. `owningScreenIndex` falls back to
    /// midpoint-then-main with no screens, so tests assert state + frames
    /// written to the fake, never absolute screen pixels.
    private var gateway: FakeWindowGateway!
    private var controller: TilingController!
    /// Drag-end fires captured from the injectable scheduler (latest wins).
    private var dragEndFires: [() -> Void] = []

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        dragEndFires = []
        // No runloop timer: tests drive pruneDeadWindows directly so a
        // live 5-second timer can't fire mid-test. Drag ends fire via the
        // captured scheduler instead of the runloop.
        controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { [weak self] fire in
                self?.dragEndFires.append(fire)
                return {}
            })
    }

    // MARK: Hotkey entry point

    func testHandleTilesFocusedWindow() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle

        controller.handle(slot: .topLeft)

        XCTAssertEqual(controller.state.slot(of: 1), .topLeft)
        XCTAssertEqual(controller.state.occupant(of: .topLeft), 1)
    }

    func testHandleWithNoFocusedWindowIsSafeNoop() {
        gateway.focused = nil

        controller.handle(slot: .topLeft)

        XCTAssertTrue(controller.state.occupants.isEmpty)
        XCTAssertNil(controller.lastTileError)
    }

    func testRetileOwnSlotIsNoop() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)

        controller.handle(slot: .topLeft)

        XCTAssertEqual(controller.state.slot(of: 1), .topLeft)
        XCTAssertNil(controller.lastTileError)
    }

    func testRefusedResizeRollsBackAndReports() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        gateway.refuseNextWrites(handle)

        controller.handle(slot: .topLeft)

        XCTAssertNil(controller.state.slot(of: 1))
        XCTAssertNotNil(controller.lastTileError)
    }

    // MARK: Observation wiring

    func testTilingRegistersObservation() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle

        controller.handle(slot: .topLeft)

        XCTAssertEqual(gateway.observedHandles(), [handle])
    }

    func testUserDragMovesSplitterAndNeighbors() {
        // Tile two left-column quads, then drag the shared row edge down:
        // the splitter follows the dragged window's actual frame, and the
        // neighbor is re-pushed on the next runloop tick.
        let top = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let bottom = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        gateway.focused = top
        controller.handle(slot: .topLeft)
        gateway.focused = bottom
        controller.handle(slot: .bottomLeft)

        // Simulate the user grabbing BL's *top* edge (the row divider;
        // the bottom edge is a fixed screen edge): an echo-converging
        // tick first (swallowed, like an animated write), then a larger
        // move away — the escape the echo logic treats as a real drag.
        var first = gateway.frame(of: bottom)!
        first.size.height -= 10
        gateway.simulateChange(bottom, to: first)
        var moved = gateway.frame(of: bottom)!
        moved.size.height -= 60
        gateway.focused = bottom
        gateway.simulateChange(bottom, to: moved)

        let expectation = XCTestExpectation(description: "coalesced apply")
        DispatchQueue.main.async {
            // The dragged window keeps its frame (source of truth); the
            // grid moved, so a re-tile would now use the new splitter.
            XCTAssertEqual(self.gateway.frame(of: bottom), moved)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        // A real screen exists in the test process, so the grid runs in
        // real visible-frame coordinates: the expectation is derived from
        // the screen that owns the dragged window, not from one author's
        // display height. The dragged top edge ended 70pt above its pre-drag
        // position (a swallowed 10pt echo, then a 60pt escape), so the row
        // split must equal (final top edge - bounds.minY) / height.
        // Pure splitter math belongs to GridLayoutTests.
        let final = gateway.frame(of: bottom)!
        let screens = NSScreen.screens
        let owner = TilingController.owningScreenIndex(frames: screens.map(\.frame), for: final) ?? 0
        let bounds = screens[owner].visibleFrame
        let expectedSplit = (final.maxY - bounds.minY) / bounds.height
        XCTAssertEqual(self.controller.grid.leftRowSplit, expectedSplit, accuracy: 0.01)
    }

    // MARK: Drag-out untile

    /// Tiles the window and streams a title-bar drag: an echo seed tick,
    /// then `dx`/`dy` per drag tick (two ticks, like a streamed hand drag).
    @discardableResult
    private func tileAndDrag(
        _ dx: CGFloat, _ dy: CGFloat
    ) -> (handle: WindowHandle, tiledFrame: CGRect, finalFrame: CGRect) {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        let tiledFrame = gateway.frame(of: handle)!

        gateway.simulateChange(handle, to: tiledFrame) // echo seed
        var mid = tiledFrame
        mid.origin.x += dx
        mid.origin.y += dy
        gateway.simulateChange(handle, to: mid)
        var far = mid
        far.origin.x += dx
        far.origin.y += dy
        gateway.simulateChange(handle, to: far)
        dragEndFires.last?()
        return (handle, tiledFrame, far)
    }

    func testDragPastUntileDistanceUntilesWhereDropped() {
        let drag = tileAndDrag(60, 60) // net displacement ~170pt

        XCTAssertNil(controller.state.slot(of: 1), "long drag releases the slot")
        XCTAssertNil(controller.state.occupant(of: .topLeft))
        XCTAssertEqual(
            gateway.frame(of: drag.handle), drag.finalFrame,
            "the untiled window stays where the user dropped it")
    }

    func testShortDragSnapsBackIntoTile() {
        let drag = tileAndDrag(10, 10) // net displacement ~28pt
        let expectation = XCTestExpectation(description: "snapback")
        DispatchQueue.main.async {
            XCTAssertEqual(self.controller.state.slot(of: 1), .topLeft, "still tiled")
            XCTAssertEqual(
                self.gateway.frame(of: drag.handle), drag.tiledFrame,
                "the window snapped back to its slot rect")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: Swap focus

    func testSwapKeepsFocusOnOriginalTile() {
        // TL + BL tiled, right half tiled; tiling the right-half window
        // into top left swaps it with the TL window, which inherits the
        // whole right half. Focus must stay on the original tile — the
        // heir now in right half — not follow the requester to top left.
        // Chaining then works with no manual refocus: the next hotkey
        // acts on the heir still sitting in the original tile.
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .bottomLeft)
        let c = gateway.addWindow(frame: CGRect(x: 0, y: 700, width: 800, height: 600))
        gateway.focused = c
        controller.handle(slot: .rightHalf)
        XCTAssertEqual(controller.state.slot(of: 3), .rightHalf)

        gateway.focused = c
        controller.handle(slot: .topLeft)

        XCTAssertEqual(controller.state.slot(of: 3), .topLeft, "requester swapped in")
        XCTAssertEqual(controller.state.slot(of: 1), .rightHalf, "blocker relocated, not evicted")
        XCTAssertEqual(
            gateway.focusCalls.last, a,
            "focus stays on the original tile: the heir now in right half")

        // No manual refocus: the heir holds focus, so the next hotkey
        // moves the original tile's current window again.
        controller.handle(slot: .bottomLeft)

        XCTAssertEqual(controller.state.slot(of: 1), .bottomLeft, "heir swapped onward")
        XCTAssertEqual(controller.state.slot(of: 2), .rightHalf, "next heir inherits the tile")
        XCTAssertEqual(controller.state.slot(of: 3), .topLeft, "first requester undisturbed")
        XCTAssertEqual(
            gateway.focusCalls.last, b,
            "focus still on the original tile after the chained swap")
    }

    func testSwapSplitFocusesTopmostPiece() {
        // RH -> LH splits the vacated right half between the two left
        // quads (TR + BR): no single heir holds the old tile, so focus
        // takes the first overlapping piece in slot order rather than
        // following the requester.
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .bottomLeft)
        let c = gateway.addWindow(frame: CGRect(x: 0, y: 700, width: 800, height: 600))
        gateway.focused = c
        controller.handle(slot: .rightHalf)
        XCTAssertEqual(controller.state.slot(of: 3), .rightHalf)

        gateway.focused = c
        controller.handle(slot: .leftHalf)

        XCTAssertEqual(controller.state.slot(of: 3), .leftHalf)
        XCTAssertEqual(controller.state.slot(of: 1), .topRight)
        XCTAssertEqual(controller.state.slot(of: 2), .bottomRight)
        // No piece IS the old tile (RH holds no single heir), so the
        // first-overlapping-piece rule applies in reading order — the
        // same spatial order the solver deals in, hence the TL heir now
        // in top-right. The pin is determinism matching the shuffle,
        // not which corner wins.
        XCTAssertEqual(
            gateway.focusCalls.last, a,
            "split tile: focus the solver's first piece, not the requester")
    }

    func testReflowRetilesThroughControllerWithoutEviction() {
        // Thirds L/M/R tiled through the real controller; the middle
        // window takes the right two-thirds. The tile is honored, both
        // neighbors survive in the left corners, and real frames are
        // written for all three windows.
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .sixthLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .sixthMiddle)
        let c = gateway.addWindow(frame: CGRect(x: 0, y: 700, width: 800, height: 600))
        gateway.focused = c
        controller.handle(slot: .sixthRight)
        XCTAssertEqual(controller.state.activeLayout, .sixths)

        gateway.focused = b
        controller.handle(slot: .sixthsRightTwoThirds)

        XCTAssertEqual(controller.state.slot(of: 2), .sixthsRightTwoThirds)
        XCTAssertEqual(controller.state.slot(of: 1), .sixthTopLeft)
        XCTAssertEqual(controller.state.slot(of: 3), .sixthBottomLeft)
        XCTAssertEqual(Set(controller.state.tiledWindows), [1, 2, 3])
        for handle in [a, b, c] {
            XCTAssertNotEqual(
                gateway.frame(of: handle), CGRect(x: 0, y: 0, width: 800, height: 600),
                "reflow writes a real tile rect")
        }
        XCTAssertNil(controller.lastTileError)
    }

    func testPlainTileIssuesNoFocusCall() {
        // Only the swap path refocuses: resizing the already-focused
        // window never moves focus, so a plain tile must not activate.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle

        controller.handle(slot: .topLeft)

        XCTAssertEqual(controller.state.slot(of: 1), .topLeft)
        XCTAssertTrue(gateway.focusCalls.isEmpty, "plain tile must not refocus")
    }

    // MARK: Undo integrity

    func testUndoDoesNotClobberAWindowThatRetookTheSlot() {
        // A evicted, then D evicted from the same slot, then two undos:
        // the second undo restores A into a slot D (just restored by the
        // first undo) holds again. The restoration is honored like any
        // tile: D steps aside to its pre-tile frame instead of being
        // silently clobbered into a ghost that overlaps A on screen.
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .topLeft)
        let d = gateway.addWindow(frame: CGRect(x: 50, y: 50, width: 700, height: 500))
        gateway.focused = d
        controller.handle(slot: .topLeft) // evicts a
        let e = gateway.addWindow(frame: CGRect(x: 60, y: 60, width: 600, height: 400))
        gateway.focused = e
        controller.handle(slot: .topLeft) // evicts d
        XCTAssertEqual(controller.state.occupant(of: .topLeft), 3)

        controller.undoLastDisplacement() // d returns (fresh id 4)
        XCTAssertEqual(controller.state.slot(of: 4), .topLeft, "d reissued under a fresh id")

        controller.undoLastDisplacement() // a returns; d must yield
        XCTAssertEqual(controller.state.occupant(of: .topLeft), 5, "a reissued under a fresh id")
        XCTAssertNil(controller.state.slot(of: 4), "d stepped aside, not silently clobbered")
        XCTAssertEqual(
            gateway.frame(of: d), CGRect(x: 50, y: 50, width: 700, height: 500),
            "d restored to its pre-tile frame, not left overlapping a's tile")
        XCTAssertEqual(
            gateway.frame(of: e), CGRect(x: 60, y: 60, width: 600, height: 400),
            "e stayed untiled at its pre-tile frame")
        XCTAssertEqual(controller.state.tiledWindows.count, 1)
    }

    // MARK: Expansion vs. tiling

    func testTilingOverAnExpandedWindowCollapsesItFirst() {
        // a holds top left and is expanded over the screen; tiling b into
        // left half must honor the tile. a's expansion dies first so the
        // reflow moves a as an ordinary tracked window — an expanded window
        // moved with its expansion entry lingering would drop out of drag
        // tracking entirely.
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .topLeft)
        controller.handleExpandToggle()
        XCTAssertEqual(controller.state.slot(of: 1), .topLeft, "expansion keeps the slot")
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .leftHalf)

        XCTAssertEqual(controller.state.slot(of: 2), .leftHalf)
        XCTAssertEqual(controller.state.slot(of: 1), .rightHalf, "blocker reflowed, not evicted")
        gateway.focused = gateway.issued[0]
        XCTAssertNil(
            controller.expandedFocusedSlot,
            "the shuffled window is an ordinary tracked tile, no expansion left")
        // Bounds resolve to the owning display's visible frame, the same
        // chain the controller uses for the write.
        let bounds = controller.screen(for: gateway.frame(of: a)!)!.visibleFrame
        XCTAssertEqual(
            gateway.frame(of: a),
            controller.grid.rect(for: .rightHalf, in: bounds),
            "a sits in its reflowed slot, not its full-screen expansion")
    }

    // MARK: Ghost cleanup

    func testClosedWindowPrunesOnNextHandle() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        XCTAssertEqual(controller.state.occupant(of: .topLeft), 1)

        gateway.kill(handle)
        let other = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        gateway.focused = other
        controller.handle(slot: .topRight)

        XCTAssertNil(controller.state.slot(of: 1))
        XCTAssertEqual(controller.state.occupant(of: .topRight), 2)
    }
}
