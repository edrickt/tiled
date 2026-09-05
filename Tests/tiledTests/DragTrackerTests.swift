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
    /// Injectable clock backing the tracker's echo timestamps.
    private var now = Date()

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        pushed = []
        slots = [:]
        handles = [:]
        occupants = [:]
        now = Date()
        tracker = DragTracker(
            context: DragTracker.Context(
                slotOf: { [weak self] in self?.slots[$0] },
                frameOf: { [weak self] in
                    guard let handle = self?.handles[$0] else { return nil }
                    return self?.gateway.frame(of: handle)
                },
                boundsOf: { $0 },
                occupants: { [weak self] in self?.occupants ?? [:] },
                now: { [weak self] in self?.now ?? Date() }),
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

    func testCornerDragMovesTwoBoundariesInOneChange() {
        tile(1, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))

        // Echo tick first (swallowed), then a corner drag: the right edge
        // moves +60 (columnSplit) and the bottom edge -60 (leftRowSplit)
        // in a single change — both boundaries must update.
        var echo = CGRect(x: 0, y: 500, width: 840, height: 500)
        echo.size.width += 10
        tracker.handleChange(id: 1, frame: echo)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 440, width: 900, height: 500))

        XCTAssertEqual(tracker.grid.columnSplit, 0.85, accuracy: 0.001,
            "right edge at 900/900 clamps to the column maximum")
        XCTAssertEqual(tracker.grid.leftRowSplit, 0.2, accuracy: 0.001,
            "bottom edge at 440/500 clamps to the row minimum")
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

    // MARK: Stale writes

    func testStaleWriteStopsWaitingAndProcessesLaterTicks() {
        tile(1, .bottomLeft, frame: CGRect(x: 0, y: 0, width: 840, height: 500))
        tile(2, .topLeft, frame: CGRect(x: 0, y: 500, width: 840, height: 500))

        // An animated write that converges slowly: each tick moves toward
        // the expected frame (so it is never an escape) but stays far
        // enough away that it is never within echo tolerance either.
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 840, height: 300))
        XCTAssertTrue(pushed.isEmpty) // distance 200, converging
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 840, height: 320))
        XCTAssertTrue(pushed.isEmpty, "still inside the stale window: swallowed") // distance 180
        XCTAssertEqual(tracker.grid, GridLayout())

        // Past the stale window, the next non-escaping tick is processed:
        // the echo entry clears and the resize moves the row splitter.
        now += TimeInterval(4)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 840, height: 330))
        // distance 170: not an escape, but the 4s-old entry is stale.

        XCTAssertEqual(
            tracker.grid.leftRowSplit, 0.8, accuracy: 0.001,
            "stale entry cleared; 330/330 clamps to the row-split maximum")
        let expectation = XCTestExpectation(description: "coalesced apply after stale")
        DispatchQueue.main.async {
            XCTAssertEqual(self.pushed.count, 1)
            XCTAssertNotNil(self.pushed.first?.rects[2], "neighbor re-pushed")
            XCTAssertNil(self.pushed.first?.rects[1], "dragged window excluded")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
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

    // MARK: Reassert baseline seeding

    func testReassertSeedsBaselineSoTheFirstDragDiffsCorrectly() {
        // Occupant 1 was never marked expected (e.g. it re-appeared under
        // a fresh id after an undo): reassertAll must seed its diff
        // baseline, or the first drag after the reassert is dropped.
        occupants[.bottomLeft] = 1
        slots[1] = .bottomLeft
        handles[1] = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 840, height: 500))

        // Without a baseline, a first change has nothing to diff against.
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 840, height: 440))
        XCTAssertEqual(tracker.grid, GridLayout(), "no baseline: change dropped")

        // Restore/prune paths forget the window; the reassert that follows
        // must seed a fresh baseline from the live frame.
        tracker.forget(1)
        tracker.reassertAll(occupants: occupants)
        tracker.handleChange(id: 1, frame: CGRect(x: 0, y: 0, width: 840, height: 440))
        XCTAssertEqual(
            tracker.grid.leftRowSplit, 0.8, accuracy: 0.001,
            "baseline seeded by reassert; 440/440 clamps to the row maximum")
    }
}
