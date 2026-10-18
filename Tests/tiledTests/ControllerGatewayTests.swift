import XCTest
@testable import tiled

/// TilingController through the `WindowGateway` seam: the first tests that
/// drive `handle(slot:)` itself instead of re-implementing its plan/commit
/// dance in the test (cf. LayoutSwitchTests' "commits a plan exactly like
/// handle does" helpers). The fake stands in for AX.
final class ControllerGatewayTests: XCTestCase {
    /// Deterministic display: tile geometry comes from this rect, never
    /// the host Mac's screen.
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Display 1")

    /// Screen the fake tiles onto. Every window frame stays inside the
    /// injected rect, so state + written frames are checked against known
    /// bounds, never absolute host pixels.
    private var gateway: FakeWindowGateway!
    private var controller: TilingController!
    /// Drag-end fires captured from the injectable scheduler (latest wins).
    private var dragEndFires: [() -> Void] = []
    /// Convergence verifications captured from the injectable scheduler.
    private var verifyFires: [() -> Void] = []
    /// How many scheduled verifications were cancelled (superseded).
    private var verifyCancels = 0
    /// Injectable clock for the death-confirmation window (the transient
    /// tests advance it instead of waiting on real time).
    private var clock: Date = Date()
    /// Injectable monotonic awake clock: what the confirmation window
    /// actually measures (sleep excluded).
    private var awake: TimeInterval = 0

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        dragEndFires = []
        verifyFires = []
        verifyCancels = 0
        clock = Date()
        awake = 0
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
            },
            screens: { [Self.screen] },
            // Tests drive death directly: no confirmation window, so a
            // killed handle prunes on the first call (the transient-death
            // tests build their own controller with the real window).
            deathConfirmation: 0,
            now: { [self] in clock })
    }

    /// The canvas the test's single display tiles onto.
    private var canvas: TilingSpace { controller.canvas(for: controller.focusedTilingSpace) }

    /// One canvas of a controller built inside a test (the setup
    /// controller is not always the one acting).
    private func localCanvas(_ controller: TilingController) -> TilingSpace {
        controller.canvas(for: controller.focusedTilingSpace)
    }

    // MARK: Hotkey entry point

    func testHandleTilesFocusedWindow() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle

        controller.handle(slot: .topLeft)

        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)
        XCTAssertEqual(canvas.state.occupant(of: .topLeft), 1)
    }

    func testHandleWithNoFocusedWindowIsSafeNoop() {
        gateway.focused = nil

        controller.handle(slot: .topLeft)

        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertNil(canvas.error)
    }

    func testRetileOwnSlotIsNoop() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)

        controller.handle(slot: .topLeft)

        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)
        XCTAssertNil(canvas.error)
    }

    func testRefusedResizeRollsBackAndReports() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        gateway.refuseNextWrites(handle)

        controller.handle(slot: .topLeft)

        XCTAssertNil(canvas.state.slot(of: 1))
        XCTAssertNotNil(canvas.error)
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
            canvas.grid.columnSplit, 0.5,
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

        // The splitter commits live; the neighbor re-push waits for the
        // mouse-up the real loop gets from the global event monitor.
        controller.mouseLifted()

        let expectation = XCTestExpectation(description: "coalesced apply")
        DispatchQueue.main.async {
            // The dragged window keeps its frame (source of truth); the
            // grid moved, so a re-tile would now use the new splitter.
            XCTAssertEqual(self.gateway.frame(of: bottom), moved)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        // The grid runs in the injected screen's visible-frame
        // coordinates: the dragged top edge moved down 70pt from its pre-drag
        // position (a swallowed 10pt echo, then a 60pt escape), so the row
        // split must equal (final top edge - bounds.minY) / height.
        // Pure splitter math belongs to GridLayoutTests.
        let final = gateway.frame(of: bottom)!
        let bounds = Self.screen.visibleFrame
        let expectedSplit = (final.maxY - bounds.minY) / bounds.height
        XCTAssertEqual(self.canvas.grid.leftRowSplit, expectedSplit, accuracy: 0.01)
    }

    func testResizingTwoThirdsThroughItsAdjacentThirdCentersHiddenDivider() {
        // A left two-thirds window and the right third share the right
        // splitter. Dragging the third's left edge resizes the two-thirds
        // too, so the hidden divider inside it still has to bisect the
        // resized two-thirds span.
        let twoThirds = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = twoThirds
        controller.handle(slot: .sixthsLeftTwoThirds)
        let third = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        gateway.focused = third
        controller.handle(slot: .sixthRight)

        var echo = gateway.frame(of: third)!
        echo.origin.x += 5
        echo.size.width -= 5
        gateway.simulateChange(third, to: echo)
        var moved = echo
        moved.origin.x -= 80
        moved.size.width += 80
        gateway.simulateChange(third, to: moved)

        XCTAssertEqual(
            canvas.grid.sixthsLeftSplit,
            canvas.grid.sixthsRightSplit / 2,
            accuracy: 0.01,
            "the hidden divider stays at the midpoint of the resized two-thirds window")
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

        XCTAssertNil(canvas.state.slot(of: 1), "long drag releases the slot")
        XCTAssertNil(canvas.state.occupant(of: .topLeft))
        XCTAssertEqual(
            gateway.frame(of: drag.handle), drag.finalFrame,
            "the untiled window stays where the user dropped it")
    }

    func testSingleTickHandDragAtMouseUpUntiles() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        let tiled = CGRect(x: 0, y: 500, width: 800, height: 500)
        XCTAssertEqual(gateway.frame(of: handle), tiled)
        gateway.simulateChange(handle, to: tiled) // settle the placement echo

        // The whole hand drag coalesces into one far tick. The button
        // was down on the window when it arrived, so the mouse-up decides
        // it as a drag-out.
        controller.mousePressed(at: CGPoint(x: tiled.midX, y: tiled.midY))
        var far = tiled
        far.origin.x += 200
        far.origin.y += 200
        gateway.simulateChange(handle, to: far)
        controller.mouseLifted()

        XCTAssertNil(canvas.state.slot(of: 1), "a one-tick hand drag still untiles")
        XCTAssertEqual(gateway.frame(of: handle), far)
    }

    func testProgrammaticJumpThenUnrelatedClickSnapsBack() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        let tiled = CGRect(x: 0, y: 500, width: 800, height: 500)
        XCTAssertEqual(gateway.frame(of: handle), tiled)
        gateway.simulateChange(handle, to: tiled) // settle the placement echo

        // A programmatic move arrives as one far tick with no hand
        // evidence; the click that follows is elsewhere. Its mouse-up
        // must snap the window back, not decide the jump as a drag-out.
        var far = tiled
        far.origin.x += 200
        far.origin.y += 200
        gateway.simulateChange(handle, to: far)
        controller.mousePressed(at: CGPoint(x: 1400, y: 100))
        controller.mouseLifted()

        XCTAssertEqual(
            canvas.state.slot(of: 1), .topLeft,
            "an unrelated click does not untile a programmatically moved window")
        XCTAssertEqual(gateway.frame(of: handle), tiled, "the snapback reasserts the tile")
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
        XCTAssertNil(canvas.state.slot(of: 1), "prune released the slot")
        dragEndFires.last?()
        XCTAssertNil(canvas.state.slot(of: 1))
        XCTAssertTrue(canvas.state.occupants.isEmpty)
    }

    func testPruneKeepsBusyWindows() {
        // A busy app cannot answer the liveness probe: unknown, not dead.
        // Pruning on that maybe would untile a live window and drop its
        // record; only a confirmed death releases the slot.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        XCTAssertNotNil(canvas.state.slot(of: 1))
        gateway.busy.insert(handle)

        controller.pruneDeadWindows()

        XCTAssertEqual(
            canvas.state.slot(of: 1), .topLeft,
            "an unanswerable probe must never prune a live window")
    }

    func testUnreadableFrameIsNotASilentIgnore() {
        // The lid-close transition: a placement lands, then the frame
        // read starts failing for the live window (observed on live AX:
        // `verify FAILED … rolled back` fired 3.5s after placement, mid
        // lid cycle). An unreadable live frame is can't-judge, never a
        // silent ignore — the rollback untiled the window.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)
        gateway.hideFrames.insert(handle)

        verifyFires.forEach { $0() }

        XCTAssertEqual(
            canvas.state.slot(of: 1), .topLeft,
            "an unreadable frame must not roll the placement back")
    }

    func testTransientDeathDoesNotPruneTiledWindows() {
        // The lid-close transient: AX answers `.invalidUIElement` for live
        // windows during display teardown (observed on live AX: three
        // tiled windows all pruned by one tick during a lid cycle). One
        // dead probe is a maybe; the slot only releases once death is
        // confirmed across the confirmation window.
        let transient = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { _ in {} }, scheduleVerify: { _ in {} },
            now: { [self] in clock },
            uptime: { [self] in awake })
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        transient.handle(slot: .topLeft)
        gateway.probeDead.insert(handle)

        transient.pruneDeadWindows()
        XCTAssertEqual(
            localCanvas(transient).state.slot(of: 1), .topLeft,
            "one dead probe is a maybe, never an eviction")

        // Still dead but inside the window: still a maybe.
        clock = clock.addingTimeInterval(1)
        awake += 1
        transient.pruneDeadWindows()
        XCTAssertEqual(
            localCanvas(transient).state.slot(of: 1), .topLeft,
            "death inside the confirmation window does not release the slot")

        // The transient recovers (the lid reopens, probes answer again).
        gateway.probeDead.remove(handle)
        transient.pruneDeadWindows()
        XCTAssertEqual(
            localCanvas(transient).state.slot(of: 1), .topLeft,
            "a recovered probe clears the pending death")
    }

    func testConfirmedDeathPrunes() {
        // A probe that stays dead across the confirmation window is a
        // real death: the slot releases on the next tick.
        let timed = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { _ in {} }, scheduleVerify: { _ in {} },
            now: { [self] in clock },
            uptime: { [self] in awake })
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        timed.handle(slot: .topLeft)
        gateway.probeDead.insert(handle)

        timed.pruneDeadWindows()
        XCTAssertEqual(localCanvas(timed).state.slot(of: 1), .topLeft, "first sighting only marks")

        clock = clock.addingTimeInterval(4)
        awake += 4
        timed.pruneDeadWindows()
        XCTAssertNil(
            localCanvas(timed).state.slot(of: 1),
            "death confirmed across the window releases the slot")
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
            canvas.state.occupant(of: .topLeft),
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
            canvas.state.occupant(of: .topLeft),
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
        controller.mouseLifted()

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
            canvas.state.slot(of: 3), .topRight,
            "a no-op re-push must never evict the uninvolved window")
        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft, "echoed re-push keeps the window tiled")
        XCTAssertEqual(canvas.state.slot(of: 2), .bottomLeft, "dragged window stays tiled")
    }

    // MARK: Resize reassert (the drag's end)

    func testMouseUpReassertsTheNeighbourFlushAgainstTheDraggedWindow() {
        // The user-facing fix: an edge drag's mouse-up reasserts the
        // canvas, the dragged window ends in its reconciled tile, and the
        // neighbour abuts it. No gap, no overlap.
        let middle = tileFocused(.sixthMiddle)
        let right = tileFocused(.sixthRight)
        let bounds = Self.screen.visibleFrame

        // A real edge drag of the middle third's right edge out to 0.8 of
        // the canvas frame: echo tick, then the escape.
        var echo = gateway.frame(of: middle)!
        echo.size.width -= 10
        gateway.simulateChange(middle, to: echo)
        var dragged = gateway.frame(of: middle)!
        dragged.size.width = bounds.minX + 0.8 * bounds.width - dragged.minX
        gateway.simulateChange(middle, to: dragged)

        controller.mouseLifted()

        let edge = bounds.minX + 0.8 * bounds.width
        XCTAssertEqual(
            gateway.frame(of: middle)!.maxX, edge, accuracy: 0.5,
            "the dragged window ends in its reconciled tile")
        XCTAssertEqual(
            gateway.frame(of: right)!.minX, edge, accuracy: 0.5,
            "the neighbour abuts the dragged window")
        XCTAssertEqual(
            gateway.frame(of: middle)!.maxX, gateway.frame(of: right)!.minX,
            "flush: no gap, no overlap")
    }

    func testResizeThatEndsOnTheTileIssuesNoWrites() {
        let middle = tileFocused(.sixthMiddle)
        _ = tileFocused(.sixthRight)
        let tile = gateway.frame(of: middle)!
        gateway.clearWrites()

        // A drag out and back onto the tile: the splitter moves live,
        // then the window returns to its starting frame before release.
        // Every occupant is already correct, so the reassert writes
        // nothing: a clean drag costs nothing.
        var echo = tile
        echo.size.width -= 10
        gateway.simulateChange(middle, to: echo)
        var far = tile
        far.size.width += 100
        gateway.simulateChange(middle, to: far)
        gateway.simulateSilentChange(middle, to: tile)

        controller.mouseLifted()

        XCTAssertTrue(
            gateway.writes.isEmpty,
            "a drag that ended on the tile asserts every occupant as already correct")
    }

    func testRefusedReassertWriteLandsOnTheCanvas() {
        let middle = tileFocused(.sixthMiddle)
        let right = tileFocused(.sixthRight)

        // The neighbour refuses the reassert's resize write.
        gateway.refuseNextWrites(right, count: 1)
        gateway.clearWrites()

        var echo = gateway.frame(of: middle)!
        echo.size.width -= 10
        gateway.simulateChange(middle, to: echo)
        var dragged = gateway.frame(of: middle)!
        dragged.size.width += 100
        gateway.simulateChange(middle, to: dragged)

        controller.mouseLifted()

        XCTAssertEqual(
            canvas.error, "Couldn't move that window: the app refused to resize it.",
            "a refused reassert write lands the standard message on the canvas")
    }

    func testExpandedTwoThirdsDoesNotDriveTheHiddenDivider() {
        // An expanded window covers the layout: it no longer occupies its
        // slot for the two-thirds divider rule. Dragging an adjacent
        // third's edge must move only that splitter, never a hidden
        // divider inside a covering window that is not on the grid.
        let covering = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = covering
        controller.handle(slot: .sixthsLeftTwoThirds)
        controller.handleExpandToggle()
        let third = tileFocused(.sixthRight)
        let bounds = Self.screen.visibleFrame

        var echo = gateway.frame(of: third)!
        echo.origin.x += 5
        echo.size.width -= 5
        gateway.simulateChange(third, to: echo)
        var dragged = echo
        dragged.origin.x = 0.5 * bounds.width
        dragged.size.width = bounds.maxX - dragged.minX
        gateway.simulateChange(third, to: dragged)

        XCTAssertEqual(canvas.grid.sixthsRightSplit, 0.5, accuracy: 0.01)
        XCTAssertEqual(
            canvas.grid.sixthsLeftSplit, 1.0 / 3.0, accuracy: 0.01,
            "an expanded covering window does not drive the hidden divider")
    }

    func testShortDragSnapsBackIntoTile() {
        let drag = tileAndDrag(10, 10) // net displacement ~28pt
        let expectation = XCTestExpectation(description: "snapback")
        DispatchQueue.main.async {
            XCTAssertEqual(self.canvas.state.slot(of: 1), .topLeft, "still tiled")
            XCTAssertEqual(
                self.gateway.frame(of: drag.handle), drag.tiledFrame,
                "the window snapped back to its slot rect")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
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
        XCTAssertEqual(canvas.state.occupant(of: .topLeft), 3)

        controller.undoLastDisplacement() // d returns (fresh id 4)
        XCTAssertEqual(canvas.state.slot(of: 4), .topLeft, "d reissued under a fresh id")

        controller.undoLastDisplacement() // a returns; d must yield
        XCTAssertEqual(canvas.state.occupant(of: .topLeft), 5, "a reissued under a fresh id")
        XCTAssertNil(canvas.state.slot(of: 4), "d stepped aside, not silently clobbered")
        XCTAssertEqual(
            gateway.frame(of: d), CGRect(x: 50, y: 50, width: 700, height: 500),
            "d restored to its pre-tile frame, not left overlapping a's tile")
        XCTAssertEqual(
            gateway.frame(of: e), CGRect(x: 60, y: 60, width: 600, height: 400),
            "e stayed untiled at its pre-tile frame")
        XCTAssertEqual(canvas.state.tiledWindows.count, 1)
    }

    // MARK: Expansion vs. tiling

    func testTilingOverAnExpandedWindowEvictsIt() {
        // a holds top left and is expanded over the screen; tiling b into
        // left half must honor the tile. a is evicted: its pre-tile frame
        // is restored and its expansion dies with the restore write.
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .topLeft)
        controller.handleExpandToggle()
        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft, "expansion keeps the slot")
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .leftHalf)

        XCTAssertEqual(canvas.state.slot(of: 2), .leftHalf)
        XCTAssertNil(canvas.state.slot(of: 1), "the blocker was evicted")
        XCTAssertEqual(
            gateway.frame(of: a), CGRect(x: 0, y: 0, width: 800, height: 600),
            "a was restored to its pre-tile frame, not left expanded")
    }

    // MARK: Ghost cleanup

    func testClosedWindowPrunesOnNextHandle() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        XCTAssertEqual(canvas.state.occupant(of: .topLeft), 1)

        gateway.kill(handle)
        let other = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        gateway.focused = other
        controller.handle(slot: .topRight)

        XCTAssertNil(canvas.state.slot(of: 1))
        XCTAssertEqual(canvas.state.occupant(of: .topRight), 2)
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

        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)
        XCTAssertNil(canvas.error)
    }

    func testSilentIgnoreRollsBackAtVerification() {
        // The gateway reports success but the app never moves: total AX
        // silence past the check, so the tile rolls back exactly like a
        // refused write: slot released, standard refusal surfaced.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        gateway.silentIgnore.insert(handle)
        controller.handle(slot: .topLeft)
        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft, "commits at write time")

        verifyFires.last?()

        XCTAssertNil(canvas.state.slot(of: 1), "rolled back like a refusal")
        XCTAssertNotNil(canvas.error)
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

        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)
        XCTAssertNil(canvas.error)
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
            canvas.state.slot(of: 1), .topRight,
            "the superseded check rolls back nothing")
        verifyFires.last?()
        XCTAssertNil(
            canvas.state.slot(of: 1),
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
        XCTAssertTrue(canvas.state.occupants.isEmpty)

        verifyFires.last?()

        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertNil(canvas.error)
    }


}
