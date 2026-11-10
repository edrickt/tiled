import CoreGraphics
import XCTest
@testable import tiled

/// The pure sizing every untile exit shares: the quarters regular
/// even-split footprint, hung from the window's top edge, kept inside
/// the visible frame.
final class UntiledSizeTests: XCTestCase {
    func testSizedUntileFrameKeepsTopEdgeAndMatchesTileSize() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let source = CGRect(x: 100, y: 100, width: 700, height: 900)
        XCTAssertEqual(
            GridLayout().sizedUntileFrame(keepingTopOf: source, in: bounds),
            CGRect(x: 100, y: 500, width: 800, height: 500))
    }

    func testSizedUntileFrameRepinsInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(
            GridLayout().sizedUntileFrame(
                keepingTopOf: CGRect(x: 1500, y: 900, width: 200, height: 200),
                in: bounds),
            CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testSizedUntileFrameIgnoresDragEditedSplits() {
        // A canvas whose splitters were drag-edited still untile-births
        // the regular even-split footprint, never the edited one.
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        var edited = GridLayout()
        edited.columnSplit = 0.1
        edited.sixthsLeftSplit = 0.1
        XCTAssertEqual(
            edited.sizedUntileFrame(
                keepingTopOf: CGRect(x: 12, y: 34, width: 700, height: 900),
                in: bounds),
            CGRect(x: 12, y: 434, width: 800, height: 500))
    }

    func testSizedUntileFrameDegenerateBoundsSkips() {
        let frame = GridLayout().sizedUntileFrame(
            keepingTopOf: CGRect(x: 12, y: 34, width: 0, height: 0),
            in: .zero)
        XCTAssertEqual(frame.origin, CGPoint(x: 12, y: 34))
        XCTAssertEqual(frame.size, .zero)
        XCTAssertTrue(
            [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite))
    }

    func testQuarterOnlyHelperAlwaysUsesTopLeft() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(
            GridLayout().sizedUntileFrame(
                keepingTopOf: CGRect(x: 10, y: 10, width: 800, height: 600),
                in: bounds),
            CGRect(x: 10, y: 110, width: 800, height: 500))
    }
}

/// Windows are always sized to a quarter at creation: the cursor
/// display's canvas decides where, never how big. The window stays
/// floating, and only a landed write claims state.
final class WindowBirthTests: XCTestCase {
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Display 1",
        displayID: CGDirectDisplayID(42))

    private static let spaceA = SpaceID(rawValue: 101)

    private var harness: ControllerHarness!
    private var gateway: FakeWindowGateway { harness.gateway }
    private var controller: TilingController { harness.controller }
    private var canvas: TilingSpace { harness.canvas }

    override func setUp() {
        super.setUp()
        harness = ControllerHarness(
            screens: [Self.screen],
            activeSpaces: [Self.screen.displayID: Self.spaceA],
            deathConfirmation: 0)
        harness.fireCursorMove(to: CGPoint(x: 500, y: 500))
    }

    func testNewWindowIsSizedToQuarterRegardlessOfLayout() {
        // A Sixths canvas still births a quarter: the layout never decides
        // the floating size.
        controller.handleSwitchLayout(to: .sixths)
        let handle = gateway.simulateWindowCreated(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))

        let landed = gateway.frame(of: handle)!
        XCTAssertEqual(landed, CGRect(x: 10, y: 110, width: 800, height: 500))
        let id = controller.registeredID(for: handle)
        XCTAssertNotNil(id)
        XCTAssertNil(
            canvas.state.slot(of: id!), "a birth sizes, never tiles")
        XCTAssertEqual(gateway.writes.count, 1, "one birth, one write")
    }

    func testBirthNearScreenEdgeRepinsInsideAtQuarterSize() {
        // A Sixths-canvas birth spilling off the canvas repins inside at
        // quarter size, hugging the screen edge instead of spilling off.
        controller.handleSwitchLayout(to: .sixths)
        let handle = gateway.simulateWindowCreated(
            frame: CGRect(x: 1500, y: 900, width: 200, height: 200))

        XCTAssertEqual(
            gateway.frame(of: handle),
            CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testZeroFrameBirthDrawsNoWrite() {
        gateway.clearWrites()

        let handle = gateway.simulateWindowCreated(frame: .zero)

        XCTAssertTrue(
            gateway.writes.isEmpty,
            "a window with no readable geometry draws no birth write")
        XCTAssertNil(
            controller.registeredID(for: handle),
            "a window with no readable geometry claims no record")
    }

    func testUnreadableBirthDrawsNoWriteAndClaimsNothing() {
        let handle = gateway.addWindow(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))
        gateway.hideFrames.insert(handle)
        gateway.clearWrites()

        controller.handleWindowCreated(handle)

        XCTAssertTrue(
            gateway.writes.isEmpty,
            "an unreadable birth draws no birth write")
        XCTAssertNil(
            controller.registeredID(for: handle),
            "an unreadable birth claims no record")
    }

    func testBirthOnQuartersCanvasUsesQuarterSize() {
        controller.handleSwitchLayout(to: .quarters)
        let handle = gateway.simulateWindowCreated(
            frame: CGRect(x: 20, y: 30, width: 900, height: 700))

        XCTAssertEqual(
            gateway.frame(of: handle),
            CGRect(x: 20, y: 230, width: 800, height: 500))
    }

    func testBirthWriteRefusalLeavesWindowAlone() {
        gateway.willWrite = { self.gateway.refuseNextWrites($0) }
        let birth = CGRect(x: 10, y: 10, width: 800, height: 600)

        let handle = gateway.simulateWindowCreated(frame: birth)

        XCTAssertEqual(
            gateway.frame(of: handle), birth,
            "a refused birth leaves the window alone")
        XCTAssertNil(
            controller.registeredID(for: handle),
            "a refused birth claims no record")
        XCTAssertEqual(
            canvas.error, TilingSpace.refusalMessage(count: 1),
            "a refused birth narrates the refusal")
        gateway.willWrite = nil
    }

    func testBirthThenCloseDropsWithoutGhostWrite() {
        let handle = gateway.addWindow(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))
        gateway.kill(handle)
        gateway.clearWrites()

        controller.handleWindowCreated(handle)

        XCTAssertTrue(
            gateway.writes.isEmpty,
            "a window dead on arrival draws no birth write")
        XCTAssertNil(controller.registeredID(for: handle))
    }

    func testBirthSubscriptionResubscribesOnTrustGrant() {
        controller.handleSwitchLayout(to: .sixths)
        XCTAssertEqual(
            gateway.creationSubscriptions, 1,
            "init subscribes the birth hook once")

        controller.observeWindowCreations()

        XCTAssertEqual(
            gateway.creationSubscriptions, 2,
            "a trust grant re-subscribes already-running apps")
        let handle = gateway.simulateWindowCreated(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))
        XCTAssertEqual(
            gateway.frame(of: handle), CGRect(x: 10, y: 110, width: 800, height: 500),
            "the latest subscription still sizes births")
    }

    func testRetileAfterBirthDiscardsBirthSizing() {
        controller.handleSwitchLayout(to: .sixths)
        let handle = gateway.simulateWindowCreated(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))
        let birthFrame = gateway.frame(of: handle)!
        gateway.focused = handle
        controller.handle(slot: .sixthTopLeft)
        let id = controller.registeredID(for: handle)!

        XCTAssertEqual(canvas.state.slot(of: id), .sixthTopLeft)
        XCTAssertEqual(
            canvas.record(of: id)?.preTileFrame, birthFrame,
            "the tile reads the sized frame as its pre-tile frame")
        XCTAssertNil(
            canvas.deferredRestores[handle],
            "tiling a birth leaves no stale restore behind")
        XCTAssertTrue(controller.untile(window: id).performed)
        XCTAssertEqual(
            gateway.frame(of: handle), birthFrame,
            "untile restores the sized frame, not a stale one")
    }

    func testBirthMidDragParksUnsizedUntilMouseUp() {
        // Tearing a tab off Firefox delivers the birth while the button
        // is down: nothing is written mid-gesture, so the resize never
        // fights the drag.
        controller.isMouseDown = { true }
        let birth = CGRect(x: 10, y: 10, width: 800, height: 600)

        let handle = gateway.simulateWindowCreated(frame: birth)

        XCTAssertEqual(
            gateway.frame(of: handle), birth,
            "a mid-drag birth leaves the window where the app put it")
        XCTAssertTrue(
            gateway.writes.isEmpty,
            "a mid-drag birth draws no write until the drop")
        XCTAssertNotNil(controller.registeredID(for: handle))
    }

    func testBirthMidDragSizesAtDropPointOnMouseUp() {
        // The parked birth lands at the drop point's quarter footprint
        // on mouse-up: the drag decides where, Tiled decides how big.
        controller.isMouseDown = { true }
        let handle = gateway.simulateWindowCreated(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))
        gateway.clearWrites()
        gateway.simulateSilentChange(
            handle, to: CGRect(x: 300, y: 400, width: 800, height: 600))
        controller.isMouseDown = { false }

        controller.mouseLifted()

        XCTAssertEqual(
            gateway.frame(of: handle), CGRect(x: 300, y: 500, width: 800, height: 500),
            "the parked birth sizes hung from the drop frame's top edge")
        XCTAssertEqual(gateway.writes.count, 1, "one drop, one write")
        let id = controller.registeredID(for: handle)!
        XCTAssertNil(
            canvas.state.slot(of: id), "a sized birth still never tiles")
        XCTAssertEqual(
            canvas.record(of: id)?.preTileFrame, gateway.frame(of: handle),
            "the record reads the sized drop frame as its pre-tile frame")
    }

    func testBirthTiledMidDragKeepsTileOnMouseUp() {
        // A hotkey while holding the button tiles the parked birth: the
        // mouse-up flush must never yank it back to the quarter size.
        controller.isMouseDown = { true }
        let handle = gateway.simulateWindowCreated(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        let id = controller.registeredID(for: handle)!
        let tiled = gateway.frame(of: handle)!
        XCTAssertEqual(canvas.state.slot(of: id), .topLeft)
        gateway.clearWrites()
        controller.isMouseDown = { false }

        controller.mouseLifted()

        XCTAssertEqual(
            gateway.frame(of: handle), tiled,
            "a birth tiled mid-drag keeps its tile on mouse-up")
        XCTAssertTrue(
            gateway.writes.isEmpty,
            "the flush writes nothing for a window that already tiled")
    }

    func testBirthSizesOnTheWindowsOwnDisplay() {
        // Cursor on display 1, window opens on display 2: the birth is
        // sized from display 2's visible frame and recorded there — never
        // pinned into the cursor's display.
        let second = ScreenInfo(
            id: ScreenID(rawValue: 2),
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            name: "Display 2",
            displayID: CGDirectDisplayID(43))
        let secondSpace = SpaceID(rawValue: 102)
        harness = ControllerHarness(
            screens: [Self.screen, second],
            activeSpaces: [
                Self.screen.displayID: Self.spaceA,
                second.displayID: secondSpace,
            ],
            deathConfirmation: 0)
        harness.fireCursorMove(to: CGPoint(x: 500, y: 500))
        gateway.clearWrites()

        let handle = gateway.simulateWindowCreated(
            frame: CGRect(x: 1700, y: 100, width: 800, height: 600))

        XCTAssertEqual(
            gateway.frame(of: handle),
            CGRect(x: 1700, y: 200, width: 800, height: 500),
            "a birth sizes in place, on the window's own display")
        let id = controller.registeredID(for: handle)!
        XCTAssertNotNil(
            controller.canvas(
                for: TilingSpaceKey(screen: second.id, space: secondSpace)
            ).record(of: id),
            "the birth record lives on the window's canvas")
        XCTAssertNil(
            controller.canvas(
                for: TilingSpaceKey(screen: Self.screen.id, space: Self.spaceA)
            ).record(of: id),
            "the cursor's canvas claims nothing")
    }

    func testAnOffDisplayBirthFallsToTheCursorDisplayNotTheMainOne() {
        // Cursor on display 2, frame owned by no display: the birth sizes
        // on the cursor's canvas, never on the main display by policy.
        let second = ScreenInfo(
            id: ScreenID(rawValue: 2),
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            name: "Display 2",
            displayID: CGDirectDisplayID(43))
        let secondSpace = SpaceID(rawValue: 102)
        harness = ControllerHarness(
            screens: [Self.screen, second],
            activeSpaces: [
                Self.screen.displayID: Self.spaceA,
                second.displayID: secondSpace,
            ],
            deathConfirmation: 0)
        harness.fireCursorMove(to: CGPoint(x: 2000, y: 500))
        gateway.clearWrites()

        let handle = gateway.simulateWindowCreated(
            frame: CGRect(x: 4000, y: 3000, width: 800, height: 600))

        XCTAssertEqual(
            gateway.frame(of: handle),
            CGRect(x: 2400, y: 500, width: 800, height: 500),
            "an unowned birth takes the cursor display's quarter, not main's")
        let id = controller.registeredID(for: handle)!
        XCTAssertNotNil(
            controller.canvas(
                for: TilingSpaceKey(screen: second.id, space: secondSpace)
            ).record(of: id),
            "the birth record lives on the cursor display's canvas")
        XCTAssertNil(
            controller.canvas(
                for: TilingSpaceKey(screen: Self.screen.id, space: Self.spaceA)
            ).record(of: id),
            "the main display's canvas claims nothing")
    }

    func testBirthRefreshesStaleCanvasGeometry() {
        // The canvas was established, then the visible frame shrank with
        // no display-change notification (Dock shown): the next birth
        // sizes from the live geometry, not the stored one.
        let shrunk = ScreenInfo(
            id: Self.screen.id,
            frame: Self.screen.frame,
            visibleFrame: CGRect(x: 0, y: 50, width: 1600, height: 950),
            name: Self.screen.name,
            displayID: Self.screen.displayID)
        _ = gateway.simulateWindowCreated(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))
        gateway.clearWrites()
        harness.screens = [shrunk]

        let handle = gateway.simulateWindowCreated(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))

        XCTAssertEqual(
            gateway.frame(of: handle),
            CGRect(x: 10, y: 135, width: 800, height: 475),
            "a birth sizes from the live visible frame")
    }

    func testBirthAfterSwipeSizesOnTheActiveCanvas() {
        // Swiped to Space B, a window opens: the birth targets the active
        // canvas and writes immediately — no deferral, no stale restore.
        let secondSpace = SpaceID(rawValue: 102)
        gateway.activeSpaces[Self.screen.displayID] = secondSpace
        gateway.simulateSpaceChange()
        gateway.clearWrites()

        let handle = gateway.simulateWindowCreated(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))

        XCTAssertEqual(
            gateway.frame(of: handle),
            CGRect(x: 10, y: 110, width: 800, height: 500),
            "a birth on the active Space sizes at once")
        let id = controller.registeredID(for: handle)!
        XCTAssertNotNil(
            controller.canvas(
                for: TilingSpaceKey(screen: Self.screen.id, space: secondSpace)
            ).record(of: id))
        XCTAssertTrue(
            controller.canvas(
                for: TilingSpaceKey(screen: Self.screen.id, space: secondSpace)
            ).deferredRestores.isEmpty,
            "an active-Space birth parks no restore")
    }

    func testParkedBirthFlushesOnTheDropDisplay() {
        // Mid-drag birth on display 2 while the cursor sits on display 1:
        // the mouse-up sizes from the drop frame's display, not the
        // cursor's.
        let second = ScreenInfo(
            id: ScreenID(rawValue: 2),
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            name: "Display 2",
            displayID: CGDirectDisplayID(43))
        let secondSpace = SpaceID(rawValue: 102)
        harness = ControllerHarness(
            screens: [Self.screen, second],
            activeSpaces: [
                Self.screen.displayID: Self.spaceA,
                second.displayID: secondSpace,
            ],
            deathConfirmation: 0)
        harness.fireCursorMove(to: CGPoint(x: 500, y: 500))
        controller.isMouseDown = { true }
        let handle = gateway.simulateWindowCreated(
            frame: CGRect(x: 1700, y: 100, width: 800, height: 600))
        gateway.clearWrites()
        gateway.simulateSilentChange(
            handle, to: CGRect(x: 2000, y: 400, width: 800, height: 600))
        controller.isMouseDown = { false }

        controller.mouseLifted()

        XCTAssertEqual(
            gateway.frame(of: handle),
            CGRect(x: 2000, y: 500, width: 800, height: 500),
            "the parked birth lands on the drop display's quarter")
    }

    // MARK: Immediate landing

    func testBirthWriteLandsBeforeAnyFurtherFrameRead() {
        // The delivered frame is the birth's one read: nothing looks at the
        // window between the creation notification and the quarter write,
        // so the app's own opening animation is retargeted about a display
        // refresh earlier instead of the app's size being shown first.
        let birth = CGRect(x: 10, y: 10, width: 800, height: 600)
        var readsAtWrite: Int?
        gateway.willWrite = { _ in readsAtWrite = self.gateway.frameReads }

        let handle = gateway.simulateWindowCreated(frame: birth)

        XCTAssertEqual(
            readsAtWrite, 0,
            "no frame read sits between the delivered birth and its write")
        XCTAssertEqual(gateway.writes.count, 1, "one birth, one write")
        XCTAssertEqual(
            gateway.frame(of: handle),
            CGRect(x: 10, y: 110, width: 800, height: 500))
    }

    func testAGivenBirthWriteDoesNotProbeLiveness() {
        // The frame read already proved the window answered, so a birth
        // that writes never pays the death probe first.
        _ = gateway.simulateWindowCreated(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))

        XCTAssertEqual(
            gateway.livenessProbes, 0,
            "a delivered birth sizes without a pre-write liveness probe")
    }

    func testRefusedBirthProbesLivenessBeforeNarrating() {
        // A given window that refuses is still a refusal: the death probe
        // runs only after the write fails, and its alive answer narrates.
        gateway.willWrite = { self.gateway.refuseNextWrites($0) }
        let birth = CGRect(x: 10, y: 10, width: 800, height: 600)

        let handle = gateway.simulateWindowCreated(frame: birth)

        XCTAssertEqual(gateway.frame(of: handle), birth, "a refused birth leaves the window alone")
        XCTAssertEqual(gateway.livenessProbes, 1, "the failed write asks whether the window died")
        XCTAssertNil(controller.registeredID(for: handle))
        XCTAssertEqual(
            canvas.error, TilingSpace.refusalMessage(count: 1),
            "an alive window that refused narrates the refusal")
    }

    func testBirthDyingBetweenDeliveryAndWriteDropsSilently() {
        // The frame was read, then the window died before the write: that is
        // still the silent dead-on-arrival the birth contract never
        // narrates, and its binding is released.
        gateway.willWrite = { self.gateway.kill($0) }

        let handle = gateway.simulateWindowCreated(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))

        XCTAssertTrue(gateway.writes.isEmpty, "a window that died draws no birth write")
        XCTAssertNil(controller.registeredID(for: handle))
        XCTAssertNil(canvas.error, "a dead delivery is never a refusal")
        XCTAssertEqual(gateway.releaseCalls, [handle], "the confirmed-dead binding is released")
    }
}

/// The canvas exits that share the sizing: drag-out and hidden-Space
/// untile leave the sized footprint through the same write policy.
final class UntiledExitTests: XCTestCase {
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Display 1",
        displayID: CGDirectDisplayID(42))

    private static let secondScreen = ScreenInfo(
        id: ScreenID(rawValue: 2),
        frame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
        name: "Display 2",
        displayID: CGDirectDisplayID(43))

    private static let spaceA = SpaceID(rawValue: 101)
    private static let spaceB = SpaceID(rawValue: 102)
    private static let secondDisplaySpace = SpaceID(rawValue: 202)

    private var harness: ControllerHarness!
    private var gateway: FakeWindowGateway { harness.gateway }
    private var controller: TilingController { harness.controller }
    private var canvas: TilingSpace { harness.canvas }

    override func setUp() {
        super.setUp()
        harness = ControllerHarness(
            screens: [Self.screen],
            activeSpaces: [Self.screen.displayID: Self.spaceA],
            deathConfirmation: 0)
    }

    func testDragOutDropIsSizedToQuarter() {
        // Two stacked sixths; b is dragged out and dropped at (300, 400).
        // The drop's top edge takes the quarter footprint, the freed cells
        // still reflow into the survivor, and the growth still shares one
        // undo chapter.
        let a = harness.addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        controller.handle(slot: .sixthTopLeft)
        let b = harness.addFocusedWindow(frame: CGRect(x: 40, y: 500, width: 600, height: 300))
        controller.handle(slot: .sixthBottomLeft)
        let aID = controller.registeredID(for: a)!
        let bID = controller.registeredID(for: b)!
        _ = gateway.setFrame(b, to: CGRect(x: 300, y: 400, width: 500, height: 300))

        controller.untileFromDrag(bID)

        let landed = gateway.frame(of: b)!
        XCTAssertEqual(landed, CGRect(x: 300, y: 200, width: 800, height: 500))
        XCTAssertEqual(
            canvas.state.slot(of: aID), .sixthLeft, "the freed cells still reflow")
        XCTAssertEqual(canvas.undoStack.count, 1, "the reflow still shares one chapter")
    }

    func testDragOutDroppedOnAnotherDisplayKeepsTheDropOrigin() {
        // The audited A5: a window tiled on display 1, dragged to display
        // 2, and dropped at x≈1700 was pinned back to display 1's right
        // edge (x≈800) and sized against display 1. The drop display owns
        // the floating frame: the window keeps its drop origin and takes
        // that display's quarter, while the slot release, reflow, and undo
        // chapter stay on the canvas that owned the window.
        harness = ControllerHarness(
            screens: [Self.screen, Self.secondScreen],
            activeSpaces: [
                Self.screen.displayID: Self.spaceA,
                Self.secondScreen.displayID: Self.secondDisplaySpace,
            ],
            deathConfirmation: 0)
        let a = harness.addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        controller.handle(slot: .sixthTopLeft)
        let b = harness.addFocusedWindow(frame: CGRect(x: 40, y: 500, width: 600, height: 300))
        controller.handle(slot: .sixthBottomLeft)
        let aID = controller.registeredID(for: a)!
        let bID = controller.registeredID(for: b)!

        // The drop lands on display 2, past display 1's right edge.
        _ = gateway.setFrame(b, to: CGRect(x: 1700, y: 100, width: 800, height: 600))
        gateway.clearWrites()

        controller.untileFromDrag(bID)

        XCTAssertEqual(
            gateway.frame(of: b),
            CGRect(x: 1700, y: 200, width: 800, height: 500),
            "the drop display's quarter at the drop origin, not display 1's edge")
        let origin = TilingSpaceKey(screen: Self.screen.id, space: Self.spaceA)
        let drop = TilingSpaceKey(
            screen: Self.secondScreen.id, space: Self.secondDisplaySpace)
        XCTAssertNil(
            controller.canvas(for: origin).state.slot(of: bID),
            "the slot releases on the origin canvas")
        XCTAssertEqual(
            controller.canvas(for: origin).state.slot(of: aID), .sixthLeft,
            "the freed cells still reflow on the origin canvas")
        XCTAssertEqual(
            controller.canvas(for: origin).undoStack.count, 1,
            "the undo chapter stays on the origin canvas")
        XCTAssertNil(
            controller.canvas(for: drop).record(of: bID),
            "the drop canvas holds no record: the window is not migrated")
        XCTAssertTrue(
            controller.canvas(for: drop).state.occupants.isEmpty,
            "the drop canvas gains no occupancy")
        XCTAssertEqual(
            gateway.writes.filter { $0.handle == b }.count, 1,
            "one drag-out, one floating write: the window is not emitted twice")
    }

    func testSwitchToSixthsFloatsAtQuarterSize() {
        // Quarters -> sixths: every window still lands at the quarter
        // footprint, and one undo restores the windows and the layout.
        let a = harness.addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        controller.handle(slot: .topLeft)
        let b = harness.addFocusedWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        controller.handle(slot: .topRight)

        controller.handleSwitchLayout(to: .sixths)

        XCTAssertEqual(canvas.state.layout, .sixths)
        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertEqual(
            gateway.frame(of: a), CGRect(x: 12, y: 0, width: 800, height: 500))
        XCTAssertEqual(
            gateway.frame(of: b), CGRect(x: 800, y: 0, width: 800, height: 500))

        XCTAssertTrue(controller.undoLastDisplacement())
        XCTAssertEqual(canvas.state.layout, .quarters, "undo restores the layout")
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft), "a returns to its quad")
        XCTAssertNotNil(canvas.state.occupant(of: .topRight), "b returns to its quad")
        XCTAssertEqual(canvas.state.tiledWindows.count, 2)
    }

    func testUntileRefreshesStaleCanvasGeometry() {
        // Tiled on the old geometry, then the visible frame shrank with
        // no display-change notification: untiling restores from the live
        // frame, not the stored one.
        let handle = harness.addFocusedWindow(
            frame: CGRect(x: 100, y: 100, width: 700, height: 900))
        controller.handle(slot: .sixthTopLeft)
        let id = controller.registeredID(for: handle)!
        harness.screens = [ScreenInfo(
            id: Self.screen.id,
            frame: Self.screen.frame,
            visibleFrame: CGRect(x: 0, y: 50, width: 1600, height: 950),
            name: Self.screen.name,
            displayID: Self.screen.displayID)]

        _ = controller.untile(window: id)

        XCTAssertEqual(
            gateway.frame(of: handle),
            CGRect(x: 100, y: 525, width: 800, height: 475),
            "an untile restores from the live visible frame")
    }

    func testSizedUntileOnHiddenSpaceDefers() {
        // Tiled on Space A, then swiped to B: untiling defers the sized
        // restore instead of dragging the window through Mission Control.
        // The deferral stands (never a refusal), and the sized frame
        // lands on the swipe back.
        let handle = harness.addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        controller.handle(slot: .sixthTopLeft)
        let id = controller.registeredID(for: handle)!
        let tiled = gateway.frame(of: handle)!
        gateway.activeSpaces[Self.screen.displayID] = Self.spaceB
        gateway.simulateSpaceChange()
        gateway.clearWrites()

        let receipt = controller.untile(window: id)

        XCTAssertFalse(
            gateway.writes.contains { $0.handle == handle },
            "a hidden Space is never written blind")
        XCTAssertEqual(
            gateway.frame(of: handle), tiled,
            "a deferred restore leaves the window where it was")
        XCTAssertTrue(receipt.performed, "a deferral stands, never a refusal")
        XCTAssertNil(
            controller.canvas(for: TilingSpaceKey(screen: Self.screen.id, space: Self.spaceA)).error)

        gateway.activeSpaces[Self.screen.displayID] = Self.spaceA
        gateway.simulateSpaceChange()

        let landed = gateway.frame(of: handle)!
        XCTAssertEqual(landed, CGRect(x: 12, y: 0, width: 800, height: 500),
            "the deferred restore lands sized on return")
    }
}
