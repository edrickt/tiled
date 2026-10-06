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

    func testClampedWriteCommitsStateWithTheLiveFrameDiverging() {
        // "Success" with a clamped frame: state trusts the write, the
        // live frame is what the app actually applied.
        let clamped = CGRect(x: 1, y: 1, width: 398, height: 298)
        gateway.writtenFrame = { _, target in clamped }
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a

        controller.handle(slot: .topLeft)

        XCTAssertEqual(canvas.state.occupant(of: .topLeft), a.id)
        XCTAssertEqual(
            gateway.frame(of: a), clamped,
            "the live frame is the app's applied rect, not the tile target")
        XCTAssertEqual(canvas.state.slot(of: a.id), .topLeft)
    }
}
