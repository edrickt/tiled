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

    // MARK: The death standard's assembly

    func testAppWindowMatchScenarios() {
        // Geometry membership, not element identity: the raw app answer
        // (a frame per listed window, nil when a read failed) becomes
        // alive-consistent, absent, or undeterminable.
        let baseline = CGRect(x: 100, y: 100, width: 400, height: 300)
        let elsewhere = CGRect(x: 0, y: 0, width: 50, height: 50)
        XCTAssertEqual(
            LiveWindowGateway.appWindowMatch(
                baseline: baseline, listedFrames: [elsewhere, baseline]),
            true, "a listed frame matching the baseline means alive")
        XCTAssertEqual(
            LiveWindowGateway.appWindowMatch(
                baseline: baseline,
                listedFrames: [baseline.offsetBy(dx: 0.5, dy: -0.5)]),
            true, "reads round: a sub-point difference still matches")
        XCTAssertEqual(
            LiveWindowGateway.appWindowMatch(
                baseline: baseline, listedFrames: [elsewhere]),
            false, "the app answered, every frame read, none matched: gone")
        XCTAssertEqual(
            LiveWindowGateway.appWindowMatch(baseline: baseline, listedFrames: []),
            false, "the app lists nothing at all: gone")
        XCTAssertEqual(
            LiveWindowGateway.appWindowMatch(
                baseline: baseline, listedFrames: [nil]),
            nil, "a listed frame that would not read is undeterminable")
        XCTAssertEqual(
            LiveWindowGateway.appWindowMatch(
                baseline: baseline, listedFrames: [elsewhere, nil]),
            nil, "one unreadable listed frame keeps the check a maybe")
        XCTAssertEqual(
            LiveWindowGateway.appWindowMatch(
                baseline: nil, listedFrames: [elsewhere]),
            nil, "no baseline frame was ever read: undeterminable")
    }

    func testOnePassScenarios() {
        // The exact scenarios a prune pass meets, driven through the
        // assembly that turns gathered answers into verdicts.
        struct Scenario {
            let name: String
            let probe: AXError
            let processAlive: Bool
            let appError: AXError
            let listedFrames: [CGRect?]
            let baseline: CGRect?
            let expected: Liveness
        }
        let baseline = CGRect(x: 100, y: 100, width: 400, height: 300)
        let elsewhere = CGRect(x: 0, y: 0, width: 50, height: 50)
        let scenarios: [Scenario] = [
            Scenario(
                name: "a probe that answers is alive", probe: .success,
                processAlive: true, appError: .cannotComplete, listedFrames: [],
                baseline: baseline, expected: .alive),
            Scenario(
                name: "the app element itself is stale: dead", probe: .invalidUIElement,
                processAlive: true, appError: .invalidUIElement, listedFrames: [],
                baseline: baseline, expected: .dead),
            Scenario(
                name: "the owning process is gone: dead", probe: .cannotComplete,
                processAlive: false, appError: .success, listedFrames: [baseline],
                baseline: baseline, expected: .dead),
            Scenario(
                name: "app answers, no listed frame matches: dead",
                probe: .invalidUIElement, processAlive: true, appError: .success,
                listedFrames: [elsewhere], baseline: baseline, expected: .dead),
            Scenario(
                name: "app answers with an empty list: dead", probe: .attributeUnsupported,
                processAlive: true, appError: .success, listedFrames: [],
                baseline: baseline, expected: .dead),
            Scenario(
                name: "a matching listed frame is element churn: maybe",
                probe: .invalidUIElement, processAlive: true, appError: .success,
                listedFrames: [elsewhere, baseline], baseline: baseline,
                expected: .unknown),
            Scenario(
                name: "an unreadable listed frame is a maybe", probe: .invalidUIElement,
                processAlive: true, appError: .success, listedFrames: [elsewhere, nil],
                baseline: baseline, expected: .unknown),
            Scenario(
                name: "no baseline frame is a maybe", probe: .invalidUIElement,
                processAlive: true, appError: .success, listedFrames: [elsewhere],
                baseline: nil, expected: .unknown),
            Scenario(
                name: "an unanswerable app is a maybe", probe: .cannotComplete,
                processAlive: true, appError: .cannotComplete, listedFrames: [],
                baseline: baseline, expected: .unknown),
        ]
        for scenario in scenarios {
            let verdicts = LiveWindowGateway.livenessVerdicts(
                failedProbes: [
                    LiveWindowGateway.FailedProbe(
                        handle: WindowHandle(id: 7), pid: 99, error: scenario.probe)
                ],
                baseline: { _ in scenario.baseline },
                appAnswer: { _ in
                    LiveWindowGateway.AppWindowAnswer(
                        processAlive: scenario.processAlive,
                        appWindowsError: scenario.appError,
                        listedFrames: scenario.listedFrames)
                })
            XCTAssertEqual(verdicts[WindowHandle(id: 7)], scenario.expected, scenario.name)
        }
    }

    func testOnePassAsksEachAppOnce() {
        // The defect-4 fix: however many of an app's windows failed
        // their probe, the pass walks that app's window list once. Two
        // handles of pid 42 and one of pid 43 are three verdicts and
        // two app asks.
        var asked: [pid_t] = []
        let verdicts = LiveWindowGateway.livenessVerdicts(
            failedProbes: [
                LiveWindowGateway.FailedProbe(
                    handle: WindowHandle(id: 1), pid: 42, error: .cannotComplete),
                LiveWindowGateway.FailedProbe(
                    handle: WindowHandle(id: 2), pid: 42, error: .invalidUIElement),
                LiveWindowGateway.FailedProbe(
                    handle: WindowHandle(id: 3), pid: 43, error: .cannotComplete),
            ],
            baseline: { _ in CGRect(x: 0, y: 0, width: 10, height: 10) },
            appAnswer: { pid in
                asked.append(pid)
                return LiveWindowGateway.AppWindowAnswer(
                    processAlive: true, appWindowsError: .success, listedFrames: [])
            })
        XCTAssertEqual(asked, [42, 43], "each app is asked once for the whole pass")
        XCTAssertEqual(
            verdicts,
            [
                WindowHandle(id: 1): .dead,
                WindowHandle(id: 2): .dead,
                WindowHandle(id: 3): .dead,
            ])
    }
}
