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

    func testSilentIgnoreRecordsTheAttemptedWrite() {
        // The fake reports success but must not hide that a write was
        // issued: a "no write issued" assertion over a silent-ignore
        // window would otherwise pass for the wrong reason.
        let handle = gateway.addWindow(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        gateway.silentIgnore.insert(handle)
        let target = CGRect(x: 10, y: 10, width: 200, height: 150)

        XCTAssertTrue(gateway.setFrame(handle, to: target))
        XCTAssertEqual(gateway.writes.count, 1)
        XCTAssertEqual(gateway.writes.first?.1, target)
        XCTAssertEqual(
            gateway.frame(of: handle), CGRect(x: 0, y: 0, width: 400, height: 300),
            "the app swallowed it, so the live frame did not move")
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

    // MARK: Release forgets the window

    /// F20: release is the adapter's forget path, so a released handle
    /// must read as gone on every seam. The fake used to keep the window
    /// readable and writable, letting release-on-a-released-handle bugs
    /// pass where the live adapter would answer nil.
    func testReleaseForgetsTheWindowFrameAndHandlers() {
        let a = gateway.addWindow(
            frame: CGRect(x: 10, y: 20, width: 200, height: 100))
        var changes = 0
        var destroys = 0
        gateway.observe(
            a, onChange: { changes += 1 }, onDestroyed: { destroys += 1 })
        gateway.focused = a

        gateway.release(a)

        XCTAssertNil(gateway.frame(of: a), "a released window has no readable frame")
        XCTAssertFalse(
            gateway.setFrame(a, to: CGRect(x: 0, y: 0, width: 1, height: 1)),
            "a released handle is not writable")
        XCTAssertEqual(gateway.liveness(of: a), .dead)
        XCTAssertNil(gateway.focusedWindow(), "a released window cannot stay focused")
        XCTAssertFalse(gateway.zOrder.contains(a), "a released window leaves the z-order")
        XCTAssertFalse(
            gateway.observedHandles().contains(a),
            "release drops the observation")
        gateway.simulateChange(a, to: CGRect(x: 0, y: 0, width: 1, height: 1))
        gateway.simulateDestroyed(a)
        XCTAssertEqual(changes, 0, "a released handle's change handler is gone")
        XCTAssertEqual(destroys, 0, "a released handle's destroy handler is gone")
    }
}
