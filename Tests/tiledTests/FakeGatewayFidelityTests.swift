import XCTest

@testable import tiled

/// Fidelity tests for the shapes the fake models that its siblings
/// don't: an environment that ignores focus requests, and writes that
/// succeed but land somewhere other than the target (a real app clamps
/// or rounds while still reporting success). Each pins the contract the
/// fake's convenient defaults used to shield.
final class FakeGatewayFidelityTests: XCTestCase {
    /// One synthetic screen: keeps tile rects off the host's real display
    /// so the drifted-frame rollback is asserted against known bounds.
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
        name: "Display 1")

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { _ in {} },
            scheduleVerify: { _ in {} },
            screens: { [Self.screen] })
    }

    // MARK: Environment-driven focus

    func testChainedHotkeyResolvesTheEnvironmentsFocusNotTheRequestedOne() {
        // The controller requests focus on the swap heir; if the system
        // ignores the activation (focusChangesFocused = false - the real
        // adapter's semantics), the next hotkey must act on the window
        // that actually still has focus.
        gateway.focusChangesFocused = false
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let b = gateway.addWindow(frame: CGRect(x: 400, y: 0, width: 400, height: 300))

        gateway.focused = a
        controller.handle(slot: .topLeft)
        gateway.focused = b
        controller.handle(slot: .topRight)

        // Swap: a (focused) requests b's slot; focus is requested on the
        // heir but the environment never applies it.
        gateway.focused = a
        controller.handle(slot: .topRight)
        XCTAssertEqual(controller.state.occupant(of: .topLeft), b.id)
        XCTAssertEqual(controller.state.occupant(of: .topRight), a.id)
        XCTAssertEqual(gateway.focusCalls.last, b, "the controller still requests the heir")

        // The next hotkey acts on a - the environment's actual focus -
        // not on b, the requested focus.
        controller.handle(slot: .bottomLeft)
        XCTAssertEqual(controller.state.occupant(of: .bottomLeft), a.id)
        XCTAssertNil(controller.state.occupant(of: .topRight))
        XCTAssertEqual(controller.state.occupant(of: .topLeft), b.id)
    }

    // MARK: Writes that succeed but land elsewhere

    func testClampedWriteCommitsStateWithTheLiveFrameDiverging() {
        // "Success" with a clamped frame: state trusts the write, the
        // live frame is what the app actually applied (the documented
        // pre-verification disagreement).
        let clamped = CGRect(x: 1, y: 1, width: 398, height: 298)
        gateway.writtenFrame = { _, target in clamped }
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a

        controller.handle(slot: .topLeft)

        XCTAssertEqual(controller.state.occupant(of: .topLeft), a.id)
        XCTAssertEqual(
            gateway.frame(of: a), clamped,
            "the live frame is the app's applied rect, not the tile target")
        XCTAssertEqual(controller.state.slot(of: a.id), .topLeft)
    }

    func testSwapRollbackRestoresTheLiveFrameNotTheTileTarget() {
        // A window whose live frame drifted off-grid (an earlier clamp
        // or a trusted user nudge). When the swap is refused, rollback
        // must restore the pre-swap live frame - not the tile rect it
        // was supposed to be at.
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let b = gateway.addWindow(frame: CGRect(x: 400, y: 0, width: 400, height: 300))
        gateway.focused = a
        controller.handle(slot: .topLeft)
        gateway.focused = b
        controller.handle(slot: .topRight)

        let drifted = CGRect(x: 2, y: 4, width: 396, height: 294)
        gateway.simulateSilentChange(a, to: drifted)

        gateway.focused = a
        gateway.refuseNextWrites(b)
        controller.handle(slot: .topRight)

        XCTAssertEqual(
            gateway.frame(of: a), drifted,
            "rollback restores the captured live frame, not the tile rect")
        // b's live frame was its top-right quad tile rect all along
        // (AppKit coords: top of a 600-high screen is y=300); rollback
        // puts it back exactly there.
        XCTAssertEqual(
            gateway.frame(of: b), CGRect(x: 400, y: 300, width: 400, height: 300))
        XCTAssertEqual(controller.state.occupant(of: .topLeft), a.id)
        XCTAssertEqual(controller.state.occupant(of: .topRight), b.id)
        XCTAssertNotNil(controller.lastTileError, "the refusal is reported")
    }
}
