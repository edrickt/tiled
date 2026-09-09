import XCTest
import ApplicationServices
@testable import tiled

/// LiveWindowGateway's liveness classification, extracted as a pure
/// function so the death standard is testable without AX elements.
///
/// Regression context: while the display is asleep (lid closed, or the
/// display-sleep leg of a lid cycle), WindowServer answers position
/// reads with `.attributeUnsupported`. Classifying that as death made
/// the 5-second prune timer release every slot, so no tiling survived
/// a laptop lid close/open. Verified on live AX: a display-sleep cycle
/// turns `.success` probes into `.attributeUnsupported` for ~4 of 5
/// windows at t+2s.
final class AXLivenessTests: XCTestCase {
    func testSuccessIsAlive() {
        XCTAssertEqual(
            LiveWindowGateway.liveness(
                probeError: .success, appWindowsError: .success, appWindowMatch: true),
            .alive)
    }

    func testAppGoneIsDead() {
        // The app element itself is stale: the app quit, so its windows
        // are gone with it.
        for probeError: AXError in [.invalidUIElement, .attributeUnsupported] {
            XCTAssertEqual(
                LiveWindowGateway.liveness(
                    probeError: probeError, appWindowsError: .invalidUIElement,
                    appWindowMatch: nil),
                .dead, "\(probeError)")
        }
    }

    func testNoListedWindowMatchingTheLastFrameIsDead() {
        // The app answers, every listed window's frame reads, and none
        // matches the window's last read frame: it really closed.
        XCTAssertEqual(
            LiveWindowGateway.liveness(
                probeError: .invalidUIElement, appWindowsError: .success,
                appWindowMatch: false),
            .dead)
    }

    func testTransientProbeFailuresAreNeverDead() {
        // The lid-cycle evidence: while window-level probes fail
        // (.invalidUIElement on held refs, .attributeUnsupported on fresh
        // refs), the app element keeps answering `.success` — but element
        // identity is useless there (a held ref stops comparing equal to
        // the app's fresh ref for the same window, observed live as
        // `listed=no`), so confirmation is geometric: a listed frame
        // matching the last read frame means alive, and undeterminable
        // membership (frame reads failing mid-teardown) is a maybe. A
        // maybe never untiles.
        let probeErrors: [AXError] = [
            .invalidUIElement, .attributeUnsupported, .cannotComplete,
            .failure, .apiDisabled, .noValue, .notImplemented,
        ]
        for probeError in probeErrors {
            XCTAssertEqual(
                LiveWindowGateway.liveness(
                    probeError: probeError, appWindowsError: .success,
                    appWindowMatch: true),
                .unknown, "\(probeError): matching frame is alive")
            XCTAssertEqual(
                LiveWindowGateway.liveness(
                    probeError: probeError, appWindowsError: .success,
                    appWindowMatch: nil),
                .unknown, "\(probeError): undeterminable match is a maybe")
            XCTAssertEqual(
                LiveWindowGateway.liveness(
                    probeError: probeError, appWindowsError: .cannotComplete,
                    appWindowMatch: nil),
                .unknown, "\(probeError): unanswerable app is a maybe")
        }
    }
}
