import CoreGraphics
import XCTest

@testable import tiled

/// The Re-house rule's step-aside, pinned where the audit found it
/// untested: the one overlap that is not a containment — a left
/// two-thirds blocking a right two-thirds request steps aside into the
/// left third — and the mirror. Containment variants live in
/// `ReflowTests`; this file pins the crossing in both directions, at the
/// pure rule (`rehousingHome`) and through the canvas.
final class StepAsideTests: XCTestCase {
    private let a = 1

    // MARK: The pure rule (TilingState)

    func testLeftTwoThirdsBlockingARightTwoThirdsRequestStepsIntoTheLeftThird() {
        var state = TilingState()
        state.commit(window: a, into: .sixthsLeftTwoThirds)
        XCTAssertEqual(
            state.rehousingHome(evicting: a, for: .sixthsRightTwoThirds),
            .sixthLeft,
            "the crossing blocker keeps its strip: the request leaves the left third clean")
    }

    func testRightTwoThirdsBlockingALeftTwoThirdsRequestStepsIntoTheRightThird() {
        var state = TilingState()
        state.commit(window: a, into: .sixthsRightTwoThirds)
        XCTAssertEqual(
            state.rehousingHome(evicting: a, for: .sixthsLeftTwoThirds),
            .sixthRight,
            "the same crossing in the other direction steps into the right third")
    }

    // MARK: Through the canvas

    func testCrossingBlockerStepsAsideThroughTheCanvas() {
        let harness = TilingSpaceHarness()
        let blocker = harness.addWindow()
        harness.apply(slot: .sixthsLeftTwoThirds, requester: blocker)
        let fresh = harness.addWindow()

        harness.apply(slot: .sixthsRightTwoThirds, requester: fresh)

        XCTAssertNil(harness.space.error)
        XCTAssertEqual(harness.space.state.slot(of: fresh), .sixthsRightTwoThirds)
        XCTAssertEqual(
            harness.space.state.slot(of: blocker), .sixthLeft,
            "the blocking two-thirds steps aside instead of losing its tiling")
        XCTAssertEqual(harness.frame(of: blocker), harness.rect(.sixthLeft))
        XCTAssertTrue(
            harness.space.notice?.contains("to make room") ?? false,
            "the crossing step-aside is narrated like any re-house")
    }

    func testMirrorCrossingBlockerStepsAsideThroughTheCanvas() {
        let harness = TilingSpaceHarness()
        let blocker = harness.addWindow()
        harness.apply(slot: .sixthsRightTwoThirds, requester: blocker)
        let fresh = harness.addWindow()

        harness.apply(slot: .sixthsLeftTwoThirds, requester: fresh)

        XCTAssertNil(harness.space.error)
        XCTAssertEqual(harness.space.state.slot(of: fresh), .sixthsLeftTwoThirds)
        XCTAssertEqual(
            harness.space.state.slot(of: blocker), .sixthRight,
            "the mirror crossing steps into the right third")
        XCTAssertEqual(harness.frame(of: blocker), harness.rect(.sixthRight))
    }
}
