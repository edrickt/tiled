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
    /// Convergence verifications captured from the injectable scheduler.
    private var verifyFires: [() -> Void] = []
    /// How many scheduled verifications were cancelled (superseded).
    private var verifyCancels = 0

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        dragEndFires = []
        verifyFires = []
        verifyCancels = 0
        // No runloop timer: tests drive pruneDeadWindows directly so a
        // live 5-second timer can't fire mid-test. Drag ends and
        // convergence checks fire via the captured schedulers instead
        // of the runloop.
        controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { [weak self] fire in
                self?.dragEndFires.append(fire)
                return {}
            },
            scheduleVerify: { [weak self] fire in
                self?.verifyFires.append(fire)
                return { self?.verifyCancels += 1 }
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

    func testRetilingKeepsASingleObservation() {
        // Every placement re-registers (place calls observe unconditionally).
        // The gateway must collapse that to one live handler per window:
        // the fake overwrites like the live gateway's dedupe, so a second
        // registration replaces instead of stacking, and callbacks still
        // reach the tracker (a drag after the retile moves the splitter).
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        controller.handle(slot: .topRight)
        controller.handle(slot: .bottomLeft)

        XCTAssertEqual(gateway.observedHandles(), [handle])
        // An echo-converging tick first (swallowed, like the retile's own
        // animated write), then an escape the echo logic treats as a drag.
        var echo = gateway.frame(of: handle)!
        echo.size.width -= 10
        gateway.simulateChange(handle, to: echo)
        var moved = gateway.frame(of: handle)!
        moved.size.width -= 60
        gateway.simulateChange(handle, to: moved)
        XCTAssertNotEqual(
            controller.grid.columnSplit, 0.5,
            "the surviving handler still routes drags after two retiles")
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
        // move away: the escape the echo logic treats as a real drag.
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

    func testPruneDuringDragDropsTheDragWithoutUntiling() {
        // A title-bar drag is in flight (ticks streamed, drag-end
        // pending) when the window dies: pruning releases the slot and
        // clears the tracker's drag state, so the late drag-end finds
        // no slot and fires no untile, and nothing crashes.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        let tiledFrame = gateway.frame(of: handle)!
        gateway.simulateChange(handle, to: tiledFrame) // echo seed
        var mid = tiledFrame
        mid.origin.x += 60
        mid.origin.y += 60
        gateway.simulateChange(handle, to: mid)
        XCTAssertFalse(dragEndFires.isEmpty, "a drag is in flight")

        gateway.kill(handle)
        controller.pruneDeadWindows()
        XCTAssertNil(controller.state.slot(of: 1), "prune released the slot")
        dragEndFires.last?()
        XCTAssertNil(controller.state.slot(of: 1))
        XCTAssertTrue(controller.state.occupants.isEmpty)
    }

    func testPruneKeepsBusyWindows() {
        // A busy app cannot answer the liveness probe: unknown, not dead.
        // Pruning on that maybe would untile a live window and drop its
        // record; only a confirmed death releases the slot.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        XCTAssertNotNil(controller.state.slot(of: 1))
        gateway.busy.insert(handle)

        controller.pruneDeadWindows()

        XCTAssertEqual(
            controller.state.slot(of: 1), .topLeft,
            "an unanswerable probe must never prune a live window")
    }

    // MARK: No-op re-push convergence

    /// Tiles the focused window into `slot` and returns its handle.
    /// The placement write echoes (a real app moves and emits AX
    /// notifications), so the placement's echo entry is consumed here;
    /// otherwise the fake's silence swallows the drag below as a
    /// "converging echo" and the test never reaches the re-push.
    @discardableResult
    private func tileFocused(_ slot: Slot) -> WindowHandle {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: slot)
        if let frame = gateway.frame(of: handle) {
            gateway.simulateChange(handle, to: frame)
        }
        return handle
    }

    func testNoOpPlacementDoesNotEvictOnVerification() {
        // The placement flavor of the same bug: tiling a window whose
        // frame already equals the slot rect writes nothing observable:
        // no echo can follow, and the placement's own late convergence
        // check evicted it.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        let tileRect = gateway.frame(of: handle)!
        verifyFires.removeAll()

        controller.untile(window: 1)
        // Silently park the untiled window exactly at the tile rect.
        gateway.simulateSilentChange(handle, to: tileRect)
        gateway.focused = handle
        controller.handle(slot: .topLeft)

        for fire in verifyFires { fire() }

        // Untiling cleared the record, so the re-tile runs under a fresh
        // window id; resolve it from the occupancy, not the old id.
        XCTAssertNotNil(
            controller.state.occupant(of: .topLeft),
            "a no-op placement write must not read as a silent ignore")
        XCTAssertEqual(gateway.frame(of: handle), tileRect)
    }

    func testGridRoundedPlacementStaysTiled() {
        // Terminal-style grid rounding: the app applies the write, but its
        // frame lands ~5pt off the target (rounded to its own internal
        // grid) and it emits no notification for the absorbed write. The
        // late convergence check must consult the live frame before
        // calling that silence a silent ignore; the window is tiled.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        let target = gateway.frame(of: handle)!
        verifyFires.removeAll()

        // Re-place from an untiled state parked at the rounded frame:
        // the write goes out (5pt off target: a real write, not skipped),
        // the app absorbs it back to the same rounded frame, no echo.
        controller.untile(window: 1)
        // Park the untiled window at the grid-rounded frame it had in the
        // previous session: 5pt off the target, outside the no-op skip,
        // so the placement write is real.
        let rounded = CGRect(x: target.minX, y: target.minY + 5,
                             width: target.width - 1, height: target.height)
        gateway.simulateSilentChange(handle, to: rounded)
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        // The app absorbs the write back to its rounded frame; no echo.
        gateway.simulateSilentChange(handle, to: rounded)

        for fire in verifyFires { fire() }

        XCTAssertNotNil(
            controller.state.occupant(of: .topLeft),
            "a grid-rounded placement must not read as a silent ignore")
    }

    func testNoOpRepushDoesNotEvictUnchangedNeighbor() {
        // THE random-eviction bug: every resize drag re-pushes every
        // occupant of the screen, and a push whose target equals the
        // window's current frame is a no-op write: the app emits no AX
        // notification for it, so the late convergence check read total
        // silence as a silent ignore and rolled the UNINVOLVED window
        // back (evicted ~3.5s after a drag it wasn't part of).
        let a = tileFocused(.topLeft)    // win 1
        let b = tileFocused(.bottomLeft) // win 2
        _ = tileFocused(.topRight)       // win 3, untouched by the drag below
        verifyFires.removeAll()

        // Resize-drag B's top edge up 100: B changes, its re-push changes
        // A (shares the left row splitter), and C is re-pushed at its
        // already-correct rect: a no-op write with no echo.
        let bFrame = gateway.frame(of: b)!
        var dragged = bFrame
        dragged.size.height += 100 // top edge (maxY) rises; bottom stays
        gateway.simulateChange(b, to: dragged)

        // The re-push is coalesced onto the next runloop tick.
        let pushed = XCTestExpectation(description: "coalesced push")
        DispatchQueue.main.async { pushed.fulfill() }
        wait(for: [pushed], timeout: 1.0)

        // The apps echo their real frame changes (A and B really moved);
        // C emitted nothing; its write changed nothing.
        gateway.simulateChange(a, to: gateway.frame(of: a)!)
        gateway.simulateChange(b, to: gateway.frame(of: b)!)

        // The convergence checks fire one verify-delay later.
        for fire in verifyFires { fire() }

        XCTAssertEqual(
            controller.state.slot(of: 3), .topRight,
            "a no-op re-push must never evict the uninvolved window")
        XCTAssertEqual(controller.state.slot(of: 1), .topLeft, "echoed re-push keeps the window tiled")
        XCTAssertEqual(controller.state.slot(of: 2), .bottomLeft, "dragged window stays tiled")
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
        // whole right half. Focus must stay on the original tile (the
        // heir now in right half), not follow the requester to top left.
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
        // first-overlapping-piece rule applies in reading order: the
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
        // Exact rects, not just "a real rect": each window sits in its
        // slot's geometry over the owning display's visible frame, the
        // same bounds chain the controller's write uses.
        let bounds = controller.screen(for: gateway.frame(of: a)!)!.visibleFrame
        XCTAssertEqual(
            gateway.frame(of: a),
            controller.grid.rect(for: .sixthTopLeft, in: bounds),
            "the surviving top-left sixth is exact")
        XCTAssertEqual(
            gateway.frame(of: b),
            controller.grid.rect(for: .sixthsRightTwoThirds, in: bounds),
            "the requester covers the right two-thirds exactly")
        XCTAssertEqual(
            gateway.frame(of: c),
            controller.grid.rect(for: .sixthBottomLeft, in: bounds),
            "the surviving bottom-left sixth is exact")
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
        // reflow moves a as an ordinary tracked window; an expanded window
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

    // MARK: Growth after uncontended moves

    func testMoveGrowsTheNeighborAndWritesRealFrames() {
        // Two left sixths; the top window takes the middle third. The
        // bottom window grows into the left third and both frames are
        // written; focus follows the grown survivor covering the vacated
        // tile (the same perch ethic as the evict reflow).
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .sixthTopLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .sixthBottomLeft)
        XCTAssertEqual(controller.state.occupant(of: .sixthBottomLeft), 2)

        gateway.focused = a
        controller.handle(slot: .sixthMiddle)

        XCTAssertEqual(controller.state.slot(of: 1), .sixthMiddle)
        XCTAssertEqual(controller.state.slot(of: 2), .sixthLeft, "the bottom sixth grew upwards")
        XCTAssertEqual(
            gateway.focusCalls.last, b,
            "focus lands on the grown survivor covering the vacated tile")
        XCTAssertNil(controller.lastTileError)
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

    // MARK: Convergence verification (silent ignores)

    func testConvergedWriteSurvivesVerification() {
        // The app applies the write (echo tick converges): the late
        // check sees a settled entry and leaves the tile alone.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        let tiledFrame = gateway.frame(of: handle)!
        gateway.simulateChange(handle, to: tiledFrame) // echo converges
        XCTAssertFalse(verifyFires.isEmpty, "placements schedule a check")

        verifyFires.last?()

        XCTAssertEqual(controller.state.slot(of: 1), .topLeft)
        XCTAssertNil(controller.lastTileError)
    }

    func testSilentIgnoreRollsBackAtVerification() {
        // The gateway reports success but the app never moves: total AX
        // silence past the check, so the tile rolls back exactly like a
        // refused write: slot released, standard refusal surfaced.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        gateway.silentIgnore.insert(handle)
        controller.handle(slot: .topLeft)
        XCTAssertEqual(controller.state.slot(of: 1), .topLeft, "commits at write time")

        verifyFires.last?()

        XCTAssertNil(controller.state.slot(of: 1), "rolled back like a refusal")
        XCTAssertNotNil(controller.lastTileError)
    }

    func testUserDragBeforeVerificationLeavesTheWindowAlone() {
        // The app produces frames (user grabbed the window mid-flight):
        // inconclusive, never a rollback: a takeover is activity, not
        // an ignore.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        var dragged = gateway.frame(of: handle)!
        dragged.origin.x += 200
        dragged.origin.y += 200
        gateway.simulateChange(handle, to: dragged) // escapes: takeover

        verifyFires.last?()

        XCTAssertEqual(controller.state.slot(of: 1), .topLeft)
        XCTAssertNil(controller.lastTileError)
    }

    func testNewerPlacementSupersedesItsVerification() {
        // A second placement cancels the first check: the stale fire
        // never runs in production, and the window keeps its new tile.
        // Firing the current (second) check rolls back the ignored
        // second write instead; each check judges only its own write.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        gateway.silentIgnore.insert(handle)
        controller.handle(slot: .topLeft)
        XCTAssertEqual(verifyFires.count, 1)
        controller.handle(slot: .topRight)
        XCTAssertEqual(verifyCancels, 1, "the first check was superseded")
        XCTAssertEqual(
            controller.state.slot(of: 1), .topRight,
            "the superseded check rolls back nothing")
        verifyFires.last?()
        XCTAssertNil(
            controller.state.slot(of: 1),
            "the second check judges the second (also ignored) write")
    }

    func testUntileBeforeVerificationCancelsTheCheck() {
        // The window is untiled before its check fires: the forget path
        // cancels, so the late fire is a safe no-op, not a stray error.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        gateway.silentIgnore.insert(handle)
        controller.handle(slot: .topLeft)
        controller.untile(window: 1)
        XCTAssertTrue(controller.state.occupants.isEmpty)

        verifyFires.last?()

        XCTAssertTrue(controller.state.occupants.isEmpty)
        XCTAssertNil(controller.lastTileError)
    }

    func testSwapRollsBackOnlyTheIgnoredPartner() {
        // Two windows exchange; the requester converges (echo tick) but
        // the partner never moves. Verification rolls back exactly the
        // silent window: the converged requester keeps its new tile.
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .topRight)
        verifyFires.removeAll()

        gateway.silentIgnore.insert(b)
        gateway.focused = a
        controller.handle(slot: .topRight)
        XCTAssertEqual(controller.state.slot(of: 1), .topRight)
        XCTAssertEqual(controller.state.slot(of: 2), .topLeft)
        // The requester's write converges; the partner stays silent.
        gateway.simulateChange(a, to: gateway.frame(of: a)!)
        XCTAssertEqual(verifyFires.count, 2)

        for fire in verifyFires { fire() }

        XCTAssertEqual(
            controller.state.slot(of: 1), .topRight,
            "the converged requester keeps its tile")
        XCTAssertNil(
            controller.state.slot(of: 2),
            "the silent partner rolls back like a refusal")
        XCTAssertNotNil(controller.lastTileError)
    }
}
