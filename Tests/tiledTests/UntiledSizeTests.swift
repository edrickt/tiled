import CoreGraphics
import XCTest
@testable import tiled

/// The pure sizing every untile exit shares: the canvas's smallest slot
/// footprint, at the window's own origin, kept inside the visible frame.
final class UntiledSizeTests: XCTestCase {
    func testSizedUntileFrameKeepsOriginAndMatchesTileSize() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(
            GridLayout().sizedUntileFrame(
                keeping: CGPoint(x: 12, y: 34), for: .quarters, in: bounds),
            CGRect(x: 12, y: 34, width: 800, height: 500))
        // A sixth's width is 1600 x (1/3) in the grid, one ulp away from
        // 1600 / 3, so it is read at the suite's sixth-width tolerance.
        let sixths = GridLayout().sizedUntileFrame(
            keeping: CGPoint(x: 12, y: 34), for: .sixths, in: bounds)
        XCTAssertEqual(sixths.origin, CGPoint(x: 12, y: 34))
        XCTAssertEqual(sixths.height, 500)
        XCTAssertEqual(sixths.width, 1600.0 / 3.0, accuracy: 0.0001)
    }

    func testSizedUntileFrameRepinsInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(
            GridLayout().sizedUntileFrame(
                keeping: CGPoint(x: 1500, y: 900), for: .quarters, in: bounds),
            CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testSizedUntileFrameDegenerateBoundsSkips() {
        let frame = GridLayout().sizedUntileFrame(
            keeping: CGPoint(x: 12, y: 34), for: .quarters, in: .zero)
        XCTAssertEqual(frame.origin, CGPoint(x: 12, y: 34))
        XCTAssertEqual(frame.size, .zero)
        XCTAssertTrue(
            [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite))
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
        // The drop origin takes the sixth footprint, the freed cells
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
        XCTAssertEqual(landed.origin, CGPoint(x: 300, y: 400))
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
        XCTAssertEqual(landed.origin, CGPoint(x: 12, y: 34))
        XCTAssertEqual(landed.height, 500)
        XCTAssertEqual(
            landed.width, 1600.0 / 3.0, accuracy: 0.0001,
            "the deferred restore lands sized on return")
    }
}
