import XCTest
@testable import tiled

/// DragTracker through its own interface: echo suppression, edge-to-
/// splitter mapping, and apply coalescing, driven by direct `handleChange`
/// calls. No controller, no AX — the loop tested where it lives.
final class DragTrackerTests: XCTestCase {
    private var gateway: FakeWindowGateway!
    private var pushed: [(rects: [WindowID: CGRect], excluding: WindowID)]!
    private var tracker: DragTracker!
    private var slots: [WindowID: Slot]!
    private var handles: [WindowID: WindowHandle]!
    private var occupants: [Slot: WindowID]!

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        pushed = []
        slots = [:]
        handles = [:]
        occupants = [:]
        tracker = DragTracker(
            context: DragTracker.Context(
                slotOf: { [weak self] in self?.slots[$0] },
                frameOf: { [weak self] in
                    guard let handle = self?.handles[$0] else { return nil }
                    return self?.gateway.frame(of: handle)
                },
                boundsOf: { $0 },
                occupants: { [weak self] in self?.occupants ?? [:] }),
            apply: { [weak self] rects, excluding in
                self?.pushed.append((rects, excluding))
                return 0
            })
    }

    private func tile(_ id: WindowID, _ slot: Slot, frame: CGRect) {
        handles[id] = gateway.addWindow(frame: frame)
        slots[id] = slot
        occupants[slot] = id
        tracker.markExpected(id, frame)
    }

    // MARK: Echo suppression

    func testConvergingTickIsSwallowed() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))

        var echo = CGRect(x: 0, y: 500, width: 840, height: 500)
        echo.origin.x += 10 // within tolerance on every edge
        tracker.handleChange(id: 1, frame: echo)

        XCTAssertTrue(pushed.isEmpty)
        XCTAssertEqual(tracker.grid, GridLayout())
    }

    func testDivergingTickMovesSplitter() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tile(2, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 840, height: 500))

        // Converge first (like an animated write), then escape: the top
        // edge of TopLeft drops 100px, moving leftRowSplit.
        var first = CGRect(x: 0, y: 500, width: 840, height: 500)
        first.origin.x += 10
        tracker.handleChange(id: 1, frame: first)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 400, width: 840, height: 600))

        XCTAssertNotEqual(tracker.grid.leftRowSplit, 0.5)
    }

    func testOriginOnlyMoveIsIgnored() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tracker.forget(1)

        // Same size, shifted origin across two ticks: a title-bar move.
        // The first tick seeds the baseline (no echo entry after forget).
        tracker.handleChange(id: 1, frame: CGRect(x: 50, y: 550, width: 840, height: 500))
        tracker.handleChange(id: 1, frame: CGRect(x: 100, y: 600, width: 840, height: 500))

        XCTAssertEqual(tracker.grid, GridLayout())
        XCTAssertTrue(pushed.isEmpty)
    }

    func testUntrackedWindowIsIgnored() {
        tracker.handleChange(id: 99, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(pushed.isEmpty)
    }

    // MARK: Coalescing

    func testNeighborPushExcludesDraggedWindow() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tile(2, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 840, height: 500))

        var first = CGRect(x: 0, y: 0, width: 840, height: 500)
        first.size.height -= 10
        tracker.handleChange(id: 2, frame: first)
        var moved = CGRect(x: 0, y: 0, width: 840, height: 500)
        moved.size.height -= 80
        tracker.handleChange(id: 2, frame: moved)

        let expectation = XCTestExpectation(description: "coalesced push")
        DispatchQueue.main.async {
            XCTAssertEqual(self.pushed.count, 1)
            XCTAssertNil(self.pushed.first?.rects[2], "dragged window never re-pushed")
            XCTAssertNotNil(self.pushed.first?.rects[1], "neighbor gets the new rect")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: Lifecycle

    func testForgetClearsEchoEntry() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        tracker.forget(1)
        slots[1] = nil

        // No crash, no push, no splitter move for a forgotten window.
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(pushed.isEmpty)
    }

    func testResetDividersRestoresDefaults() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))
        var first = CGRect(x: 0, y: 500, width: 840, height: 500)
        first.origin.x += 10
        tracker.handleChange(id: 1, frame: first)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 400, width: 840, height: 600))
        XCTAssertNotEqual(tracker.grid.leftRowSplit, 0.5)

        tracker.resetDividers()
        XCTAssertEqual(tracker.grid, GridLayout())
    }
}
