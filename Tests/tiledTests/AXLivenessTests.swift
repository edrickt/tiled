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
            LiveWindowGateway.liveness(forProbeError: .success), .alive)
    }

    func testInvalidElementIsDead() {
        // The real death signal: the element reference is gone because
        // the window closed or the app quit.
        XCTAssertEqual(
            LiveWindowGateway.liveness(forProbeError: .invalidUIElement), .dead)
    }

    func testDisplaySleepErrorsAreNeverDead() {
        // .attributeUnsupported is what a sleeping display actually
        // returns (observed on live AX); it must read as "unknown",
        // never as death.
        let transient: [AXError] = [
            .attributeUnsupported, .cannotComplete,
            .failure, .apiDisabled, .noValue, .notImplemented,
        ]
        for error in transient {
            XCTAssertEqual(
                LiveWindowGateway.liveness(forProbeError: error), .unknown,
                "\(error) is transient or unprovable: a maybe never untiles")
        }
    }
}
