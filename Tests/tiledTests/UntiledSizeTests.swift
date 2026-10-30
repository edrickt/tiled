import CoreGraphics
import XCTest
@testable import tiled

/// The pure sizing every untile exit shares: the layout's regular
/// even-split footprint, hung from the window's top edge, kept inside
/// the visible frame.
final class UntiledSizeTests: XCTestCase {
    func testSizedUntileFrameKeepsTopEdgeAndMatchesTileSize() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let source = CGRect(x: 100, y: 100, width: 700, height: 900)
        XCTAssertEqual(
            GridLayout().sizedUntileFrame(
                keepingTopOf: source, for: .quarters, in: bounds),
            CGRect(x: 100, y: 500, width: 800, height: 500))
        // A sixth's width is 1600 x (1/3) in the grid, one ulp away from
        // 1600 / 3, so it is read at the suite's sixth-width tolerance.
        let sixths = GridLayout().sizedUntileFrame(
            keepingTopOf: source, for: .sixths, in: bounds)
        XCTAssertEqual(sixths.minX, 100)
        XCTAssertEqual(sixths.maxY, 1000, "the top edge stays, the bottom rises")
        XCTAssertEqual(sixths.height, 500)
        XCTAssertEqual(sixths.width, 1600.0 / 3.0, accuracy: 0.0001)
    }

    func testSizedUntileFrameRepinsInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(
            GridLayout().sizedUntileFrame(
                keepingTopOf: CGRect(x: 1500, y: 900, width: 200, height: 200),
                for: .quarters, in: bounds),
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
                for: .quarters, in: bounds),
            CGRect(x: 12, y: 434, width: 800, height: 500))
        let sixths = edited.sizedUntileFrame(
            keepingTopOf: CGRect(x: 12, y: 34, width: 700, height: 900),
            for: .sixths, in: bounds)
        XCTAssertEqual(sixths.maxY, 934, "the top edge stays, the bottom rises")
        XCTAssertEqual(sixths.height, 500)
        XCTAssertEqual(sixths.width, 1600.0 / 3.0, accuracy: 0.0001)
    }

    func testSizedUntileFrameDegenerateBoundsSkips() {
        let frame = GridLayout().sizedUntileFrame(
            keepingTopOf: CGRect(x: 12, y: 34, width: 0, height: 0),
            for: .quarters, in: .zero)
        XCTAssertEqual(frame.origin, CGPoint(x: 12, y: 34))
        XCTAssertEqual(frame.size, .zero)
        XCTAssertTrue(
            [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite))
    }
}

/// Windows are sized to the birth canvas's layout at creation: the
/// cursor display's canvas decides the footprint, the window stays
/// floating, and only a landed write claims state. A sixth's width is
/// 1600 x (1/3) in the grid, one ulp off the 1600 / 3 literal, so every
/// sixths width below reads at the suite's sixth-width tolerance.
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

    func testNewWindowIsSizedToCanvasLayoutAtBirth() {
        controller.handleSwitchLayout(to: .sixths)
        let handle = gateway.simulateWindowCreated(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))

        let landed = gateway.frame(of: handle)!
        XCTAssertEqual(landed.origin, CGPoint(x: 10, y: 110))
        XCTAssertEqual(landed.height, 500)
        XCTAssertEqual(landed.width, 1600.0 / 3.0, accuracy: 0.0001)
        let id = controller.registeredID(for: handle)
        XCTAssertNotNil(id)
        XCTAssertNil(
            canvas.state.slot(of: id!), "a birth sizes, never tiles")
        XCTAssertEqual(gateway.writes.count, 1, "one birth, one write")
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
            gateway.frame(of: handle)!.width, 1600.0 / 3.0, accuracy: 0.0001,
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

    func testDragOutDropIsSizedToLayout() {
        // Two stacked sixths; b is dragged out and dropped at (300, 400).
        // The drop's top edge takes the sixth footprint, the freed cells
        // still reflow into the survivor, and the growth still shares one
        // undo chapter. A sixth's width is 1600 x (1/3) in the grid, one
        // ulp off the 1600 / 3 literal.
        let a = harness.addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        controller.handle(slot: .sixthTopLeft)
        let b = harness.addFocusedWindow(frame: CGRect(x: 40, y: 500, width: 600, height: 300))
        controller.handle(slot: .sixthBottomLeft)
        let aID = controller.registeredID(for: a)!
        let bID = controller.registeredID(for: b)!
        _ = gateway.setFrame(b, to: CGRect(x: 300, y: 400, width: 500, height: 300))

        controller.untileFromDrag(bID)

        let landed = gateway.frame(of: b)!
        XCTAssertEqual(landed.origin, CGPoint(x: 300, y: 200))
        XCTAssertEqual(landed.height, 500)
        XCTAssertEqual(landed.width, 1600.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(
            canvas.state.slot(of: aID), .sixthLeft, "the freed cells still reflow")
        XCTAssertEqual(canvas.undoStack.count, 1, "the reflow still shares one chapter")
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
        XCTAssertEqual(landed.origin, CGPoint(x: 12, y: 0))
        XCTAssertEqual(landed.height, 500)
        XCTAssertEqual(
            landed.width, 1600.0 / 3.0, accuracy: 0.0001,
            "the deferred restore lands sized on return")
    }
}
