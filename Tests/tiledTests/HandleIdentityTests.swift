import XCTest
import CoreGraphics
@testable import tiled

/// The live adapter's element-churn recovery rule, extracted as pure
/// functions so handle adoption is testable without AX elements.
///
/// Regression context, Firefox tab tear-out: a detached tab's window
/// opens at (within a point of) the source window's frame, and in any
/// app two *different* windows can share a frame (duplicates, cascades).
/// The old geometry fallback adopted the fresh element onto the tiled
/// window's handle whenever the frames matched, so tiling the detached
/// window silently unseated the original: the canvas read the newcomer
/// as the tiled window (a self-move), the original lost its record, and
/// it vanished from the menu mid-layout. Reproduced live on Firefox and
/// on the host app (`tools/repro/handle-collision-repro.swift`).
///
/// Adoption is only sound when the held element is *provably stale*
/// (the display-teardown churn the fallback exists for): the app's own
/// fresh window list no longer contains it. A held element the app
/// still lists is a live window; a newcomer sharing its frame is a
/// different window and must get its own handle.
final class HandleIdentityTests: XCTestCase {
    // MARK: heldElementIsStale

    func testListedElementIsNotStale() {
        // The app's fresh list names the held element: it is a live
        // window, whatever its frame or probe say. The probe must not
        // even be needed — membership already answered.
        XCTAssertFalse(
            LiveWindowGateway.heldElementIsStale(
                listedByApp: true,
                probeAnswers: {
                    XCTFail("the probe must not run when the list answered: it is an AX round-trip")
                    return false
                }))
    }

    func testUnlistedElementIsStale() {
        // The app answered, lists its windows, and the held element is
        // not among them: the reference churned (display teardown), so
        // the fresh element at the same frame is the same window.
        XCTAssertTrue(
            LiveWindowGateway.heldElementIsStale(
                listedByApp: false,
                probeAnswers: {
                    XCTFail("the probe must not run when the list answered")
                    return false
                }))
    }

    func testUnreadableListFallsBackToTheElementsOwnProbe() {
        // Membership undeterminable: an element that still answers its
        // own position is a live window, not a stale reference.
        XCTAssertFalse(
            LiveWindowGateway.heldElementIsStale(
                listedByApp: nil, probeAnswers: { true }))
        XCTAssertTrue(
            LiveWindowGateway.heldElementIsStale(
                listedByApp: nil, probeAnswers: { false }))
    }

    // MARK: inheritedHandle

    func testNoCandidatesMeansAFreshHandle() {
        XCTAssertNil(LiveWindowGateway.inheritedHandle([]))
    }

    func testLiveCandidatesAreNeverInherited() {
        // The Firefox collision: a different window of the same app at
        // the tiled window's frame. The held window is live (the app
        // still lists it), so the newcomer must not take its handle.
        XCTAssertNil(
            LiveWindowGateway.inheritedHandle([
                .init(handle: WindowHandle(id: 7), heldIsStale: false)
            ]))
    }

    func testAStaleCandidateIsInherited() {
        let stale = WindowHandle(id: 9)
        XCTAssertEqual(
            LiveWindowGateway.inheritedHandle([
                .init(handle: WindowHandle(id: 7), heldIsStale: false),
                .init(handle: stale, heldIsStale: true),
            ]),
            stale)
    }

    func testFirstStaleCandidateWins() {
        // Several same-pid windows can share a frame (stacked windows);
        // any *stale* one is the churned reference, and one of them is
        // the best available answer. Live windows never take priority.
        let first = WindowHandle(id: 3), second = WindowHandle(id: 4)
        XCTAssertEqual(
            LiveWindowGateway.inheritedHandle([
                .init(handle: first, heldIsStale: true),
                .init(handle: second, heldIsStale: true),
            ]),
            first)
    }
}
