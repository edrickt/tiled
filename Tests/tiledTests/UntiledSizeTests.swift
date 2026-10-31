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

    private static let spaceA = SpaceID(rawValue: 101)
    private static let spaceB = SpaceID(rawValue: 102)

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
