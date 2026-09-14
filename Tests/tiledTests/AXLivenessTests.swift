import XCTest
import ApplicationServices
@testable import tiled

/// LiveWindowGateway's liveness classification, extracted as a pure
/// function so the death standard is testable without AX elements.
///
/// Regression context, lid close/open: while the display is asleep
/// (lid closed, or the display-sleep leg of a lid cycle), WindowServer
/// answers position reads with `.attributeUnsupported`. Classifying
/// that as death made the 5-second prune timer release every slot, so
/// no tiling survived a laptop lid close/open. Verified on live AX: a
/// display-sleep cycle turns `.success` probes into
/// `.attributeUnsupported` for ~4 of 5 windows at t+2s.
///
/// Regression context, app death: a killed app's windows answer
/// `.cannotComplete` (not `.invalidUIElement`) and used to classify as
/// `.unknown` — which never prunes — so a ghost kept its slot and the
/// status icon kept showing it. Verified live on macOS 26 with the
/// throwaway host app in `tools/repro/dead-app-liveness-probe.swift`.
final class AXLivenessTests: XCTestCase {
    func testSuccessIsAlive() {
        XCTAssertEqual(
            LiveWindowGateway.liveness(
                probeError: .success, appWindowsError: .success, appWindowMatch: true,
                processAlive: true),
            .alive)
        // A window probe that succeeds outranks any process bookkeeping: a
        // pid we cannot resolve is still not evidence against a window
        // that just answered.
        XCTAssertEqual(
            LiveWindowGateway.liveness(
                probeError: .success, appWindowsError: .cannotComplete, appWindowMatch: nil,
                processAlive: false),
            .alive)
    }

    func testAppGoneIsDead() {
        // The app element itself is stale: the app quit, so its windows
        // are gone with it.
        for probeError: AXError in [.invalidUIElement, .attributeUnsupported] {
            XCTAssertEqual(
                LiveWindowGateway.liveness(
                    probeError: probeError, appWindowsError: .invalidUIElement,
                    appWindowMatch: nil, processAlive: false),
                .dead, "\(probeError)")
        }
    }

    func testDeadProcessIsDead() {
        // Regression: a tiled window whose whole application is gone
        // used to keep its slot forever. AX answers for a dead process
        // read `.cannotComplete` — not `.invalidUIElement` — and the old
        // classifier mapped that to `.unknown`, which never prunes, so
        // the status icon kept showing the ghost. A process that no
        // longer exists owns no live window: dead, whatever AX says.
        //
        // Seen live (macOS 26): after SIGKILL of the window's app both
        // the held element and the app's window list returned
        // kAXErrorCannotComplete (-25204) indefinitely, the prune timer
        // ticked every 5s with verdict unknown, and the icon stayed lit
        // for the whole 40s watch.
        for probeError: AXError in [.cannotComplete, .invalidUIElement, .failure] {
            XCTAssertEqual(
                LiveWindowGateway.liveness(
                    probeError: probeError, appWindowsError: .cannotComplete,
                    appWindowMatch: nil, processAlive: false),
                .dead, "\(probeError)")
        }
        // Even the strongest positive app answer cannot resurrect a
        // process that does not exist.
        XCTAssertEqual(
            LiveWindowGateway.liveness(
                probeError: .cannotComplete, appWindowsError: .success,
                appWindowMatch: true, processAlive: false),
            .dead)
    }

    func testNoListedWindowMatchingTheLastFrameIsDead() {
        // The app answers, every listed window's frame reads, and none
        // matches the window's last read frame: it really closed.
        XCTAssertEqual(
            LiveWindowGateway.liveness(
                probeError: .invalidUIElement, appWindowsError: .success,
                appWindowMatch: false, processAlive: true),
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
                    appWindowMatch: true, processAlive: true),
                .unknown, "\(probeError): matching frame is alive")
            XCTAssertEqual(
                LiveWindowGateway.liveness(
                    probeError: probeError, appWindowsError: .success,
                    appWindowMatch: nil, processAlive: true),
                .unknown, "\(probeError): undeterminable match is a maybe")
            XCTAssertEqual(
                LiveWindowGateway.liveness(
                    probeError: probeError, appWindowsError: .cannotComplete,
                    appWindowMatch: nil, processAlive: true),
                .unknown, "\(probeError): unanswerable app is a maybe")
        }
    }

    func testProcessProbe() {
        // The live signal behind `processAlive`: our own pid exists, a
        // pid past the system's pid space does not, and launchd exists
        // but refuses the signal (EPERM) — which must not read as death.
        XCTAssertTrue(LiveWindowGateway.processExists(getpid()))
        XCTAssertFalse(
            LiveWindowGateway.processExists(999_999),
            "a pid past the system's pid space is not a live process")
        XCTAssertTrue(
            LiveWindowGateway.processExists(1), "launchd exists but is not signallable: EPERM is not death")
    }
}
