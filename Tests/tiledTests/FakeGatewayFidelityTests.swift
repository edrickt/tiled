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

    // MARK: The death standard's liveness shapes

    func testStaleBaselineIsModelledNotSmoothedOver() {
        // The D13 hazard, reproduced in the fake: a move nobody notified
        // leaves the frame baseline stale, so a failing probe corroborated
        // by an app that lists the window at its NEW frame reads ABSENT —
        // the false death the probe-refresh fix prevents. The fake must
        // model the staleness (and the refresh that cures it), or the
        // regression hides behind its convenience.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        _ = gateway.frame(of: handle) // the read that puts the baseline on record
        gateway.simulateSilentChange(handle, to: CGRect(x: 300, y: 200, width: 400, height: 300))
        gateway.probeFailures.insert(handle)

        XCTAssertEqual(
            gateway.liveness(of: [handle])[handle], .dead,
            "a stale baseline condemns a moved window: the hazard is real here")

        // The routine successful probe between the move and the failure
        // refreshes the baseline, and the same corroboration reads the
        // window alive-consistent.
        gateway.probeFailures.remove(handle)
        _ = gateway.liveness(of: [handle])
        gateway.probeFailures.insert(handle)
        XCTAssertEqual(
            gateway.liveness(of: [handle])[handle], .unknown,
            "the refreshed baseline finds the window the app lists")
    }

    func testDeathStandardShapesBeyondTheHappyPath() {
        // The fake scripts raw inputs — probe outcomes, window lists,
        // frame reads — and the shared death standard judges them, so
        // the non-happy shapes are the live ones: a match is element
        // churn (a maybe), unreadable membership is undeterminable (a        // maybe), and a maybe never untiles.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        _ = gateway.frame(of: handle)
        gateway.probeFailures.insert(handle)

        XCTAssertEqual(
            gateway.liveness(of: [handle])[handle], .unknown,
            "the app lists the window where the baseline says it is: churn, not death")

        // A listed frame that will not read (the lid-close shape) keeps
        // membership undeterminable even once the window moved.
        gateway.hideFrames.insert(handle)
        gateway.simulateSilentChange(handle, to: CGRect(x: 300, y: 200, width: 400, height: 300))
        XCTAssertEqual(
            gateway.liveness(of: [handle])[handle], .unknown,
            "an unreadable listed frame is a maybe, never a death")
    }

    func testFailedRegistrationDeliversNothing() {
        // Live's failed registration keeps the handlers but the OS never
        // sends: moves and destroys alike arrive nowhere — which is why        // a drag can leave the baseline stale in the first place.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        gateway.registrationFailures.insert(handle)
        var delivered = 0
        gateway.observe(handle, onChange: { delivered += 1 }, onDestroyed: { delivered += 1 })

        gateway.simulateChange(handle, to: CGRect(x: 10, y: 10, width: 400, height: 300))
        gateway.simulateDestroyed(handle)

        XCTAssertEqual(
            delivered, 0,
            "a failed registration delivers nothing: moves and destroys alike")
    }

    func testReleaseDropsTheElementLikeLive() {
        // G6's shape: live's release drops the element, so later frame
        // reads go dark and liveness reads dead. A fake that keeps the
        // window lets undo-on-a-released-handle shapes pass.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))

        gateway.release(handle)

        XCTAssertNil(gateway.frame(of: handle), "the element is gone: frame reads go dark")
        XCTAssertEqual(
            gateway.liveness(of: [handle])[handle], .dead,
            "a dropped element reads dead, like live's released handle")
    }
}
