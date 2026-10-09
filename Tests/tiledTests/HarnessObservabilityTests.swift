import CoreGraphics
import XCTest

@testable import tiled

/// The harness's own observability contract, where the audit found the
/// canvas suite blind: the drag loop's publish path is recorded and
/// performed (Q2), silent-ignore consequences are recorded (Q3), and
/// canvas coverage runs with a non-zero gap by default (the gap code is
/// exercised by every harness test, not only the gap tests).
final class HarnessObservabilityTests: XCTestCase {
    // MARK: The publish path (Q2)

    func testTheHarnessObservesTheDragsPublishPath() {
        let harness = TilingSpaceHarness()
        let top = harness.addWindow()
        let bottom = harness.addWindow()
        harness.apply(slot: .topLeft, requester: top)
        harness.apply(slot: .bottomLeft, requester: bottom)

        // Grab the bottom tile's top edge and pull it down past the echo
        // radius: the splitter moves live, and the release's trailing
        // commit re-pushes the neighbour — never the dragged window.
        let placed = harness.frame(of: bottom)!
        var nudged = placed
        nudged.size.height -= 10
        harness.tracker.handleChange(id: bottom, frame: nudged)
        var pulled = placed
        pulled.size.height -= 80
        harness.tracker.handleChange(id: bottom, frame: pulled)
        harness.tracker.mouseLifted()
        XCTAssertEqual(
            harness.commitFires.count, 1,
            "mouse-up arms the trailing-tick commit; the harness fires it by hand")
        harness.commitFires.last?()

        // The coalesced push lands on the next main-queue turn.
        let pushed = expectation(description: "the coalesced push is observed")
        DispatchQueue.main.async {
            guard let push = harness.published.first else {
                XCTFail("the coalesced push is swallowed, not observed")
                pushed.fulfill()
                return
            }
            XCTAssertEqual(harness.published.count, 1)
            XCTAssertEqual(push.excluding, bottom, "the dragged window is never re-pushed")
            XCTAssertNil(push.rects[bottom])
            XCTAssertEqual(
                push.rects, [top: harness.rect(.topLeft)],
                "the neighbour is pushed exactly its rect after the splitter drag")
            XCTAssertEqual(
                harness.frame(of: top), harness.rect(.topLeft),
                "the push performs its write through the canvas, like the controller's")
            pushed.fulfill()
        }
        wait(for: [pushed], timeout: 1)
    }

    // MARK: Silent-ignore consequences (Q3)

    func testTheHarnessObservesSilentIgnoreConsequences() {
        let harness = TilingSpaceHarness()

        // A layout write the app accepted and never moved: the late check
        // pays the slot-commit consequence.
        let tiled = harness.addWindow()
        harness.gateway.silentIgnore.insert(harness.handle(of: tiled)!)
        harness.apply(slot: .topLeft, requester: tiled)
        harness.checks.last?()
        XCTAssertEqual(harness.consequences.map(\.id), [tiled])
        XCTAssertEqual(harness.consequences.first?.consequence, .slotCommit)

        // A cover toggle the app accepted and never moved: the late check
        // pays the cover-toggle revert.
        let covering = harness.addWindow()
        harness.gateway.silentIgnore.insert(harness.handle(of: covering)!)
        harness.space.expandToggle(window: covering, context: harness.context())
        harness.checks.last?()
        XCTAssertEqual(harness.consequences.map(\.id), [tiled, covering])
        XCTAssertEqual(harness.consequences.last?.consequence, .coverToggle(revertTo: nil))
    }

    // MARK: A non-zero default gap

    func testCanvasCoverageRunsOnANonZeroGapByDefault() {
        let harness = TilingSpaceHarness()
        XCTAssertGreaterThan(
            harness.gap, 0,
            "the harness default is the app's real gap; gap tests opt out explicitly")
        let id = harness.addWindow()
        harness.apply(slot: .topLeft, requester: id)
        XCTAssertEqual(harness.frame(of: id), harness.rect(.topLeft))
        XCTAssertNotEqual(
            harness.frame(of: id),
            harness.space.grid.rect(for: .topLeft, in: harness.bounds),
            "the placed frame leaves the gap inside the box")
    }
}
