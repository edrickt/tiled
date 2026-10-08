import XCTest

@testable import tiled

/// Fidelity tests for the shapes the fake models that its siblings
/// don't: writes that succeed but land somewhere other than the target
/// (a real app clamps or rounds while still reporting success). Each
/// pins the contract the fake's convenient defaults used to shield.
final class FakeGatewayFidelityTests: XCTestCase {
    /// One synthetic screen: keeps tile rects off the host's real display
    /// so drifted frames are asserted against known bounds.
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
        name: "Display 1")

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!

    /// The canvas the test's single display tiles onto: reads go through
    /// the same accessor actions do.
    private var canvas: TilingSpace { controller.canvas(for: controller.focusedTilingSpace) }

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [Self.screen] })
    }

    // MARK: Writes that succeed but land elsewhere

    func testMinimumSizeClampIsRefusedAndTheWindowStaysPut() {
        // Firefox's minimum width: the position lands, the size holds at
        // the app's floor, and the AX write reports success. Committing
        // that half-applied frame would leave the window with its right
        // edge past the screen edge; the write policy restores the
        // pre-write frame and reports the refusal instead. The pre-tile
        // origin differs from the target, so the floor frame cannot be
        // mistaken for an animation step (see WriteExpectationsTests for
        // the ambiguous width-only case).
        let previous = CGRect(x: 500, y: 0, width: 600, height: 600)
        gateway.writtenFrame = { _, target in
            guard target.width < 500 else { return target }
            return CGRect(
                x: target.minX, y: target.minY, width: 500, height: target.height)
        }
        let a = gateway.addWindow(frame: previous)
        gateway.focused = a

        controller.handle(slot: .topLeft) // 400 wide: below the app's floor

        XCTAssertNil(canvas.state.occupant(of: .topLeft), "the placement rolled back")
        XCTAssertEqual(gateway.frame(of: a), previous, "left where it was, not half-placed")
        XCTAssertNotNil(canvas.error, "the refusal surfaces on the canvas")
    }

    func testGridRoundedWriteCommitsStateWithTheLiveFrameDiverging() {
        // "Success" with a few points of grid rounding (Terminal-style):
        // within tolerance, state trusts the write and the live frame is
        // what the app actually applied.
        let tiled = GridLayout().rect(
            for: .topLeft, in: Self.screen.visibleFrame)
        let rounded = tiled.insetBy(dx: 1, dy: 1)
        gateway.writtenFrame = { _, _ in rounded }
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a

        controller.handle(slot: .topLeft)

        XCTAssertEqual(canvas.state.occupant(of: .topLeft), a.id)
        XCTAssertEqual(
            gateway.frame(of: a), rounded,
            "the live frame is the app's applied rect, not the tile target")
        XCTAssertEqual(canvas.state.slot(of: a.id), .topLeft)
    }
}
