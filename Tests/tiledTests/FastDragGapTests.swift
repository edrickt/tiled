import XCTest
@testable import tiled

/// The reported instability: dragging a shared edge fast (down and up)
/// leaves the neighbour at the wrong distance — the gap shrinks,
/// disappears, or grows — until the next click happens to commit the
/// trailing tick.
///
/// The loop models the race AX actually produces: the drag's final
/// resize notification trails the mouse-up. The tracker must commit the
/// neighbours only after the trailing ticks go quiet, so the grid
/// settles as one move no matter how fast the gesture was.
final class FastDragGapTests: XCTestCase {
    private var gateway: FakeWindowGateway!
    private var expectations: WriteExpectations!
    private var tracker: DragTracker!
    private var handles: [WindowID: WindowHandle] = [:]
    private var slots: [WindowID: Slot] = [:]
    private var grids: [TilingSpaceKey: GridLayout] = [:]
    /// Trailing-tick commit fires captured from the injectable scheduler.
    private var commitFires: [() -> Void] = []

    private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let gap: CGFloat = 10

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        expectations = WriteExpectations(gateway: gateway)
        handles = [:]
        slots = [1: .sixthTopLeft, 2: .sixthBottomLeft]
        grids = [:]
        commitFires = []
        tracker = DragTracker(
            expectations: expectations,
            context: DragTracker.Context(
                slotOf: { [weak self] in self?.slots[$0] },
                frameOf: { [weak self] id in
                    guard let self, let handle = self.handles[id] else { return nil }
                    return self.gateway.frame(of: handle)
                },
                boundsOf: { [weak self] _ in self?.bounds ?? .zero },
                gap: { [weak self] in self?.gap ?? 0 },
                occupants: { [.sixthTopLeft: 1, .sixthBottomLeft: 2] }),
            gridProvider: DragTracker.GridProvider(
                grid: { [weak self] key in
                    self?.grids[key ?? .displayless] ?? GridLayout()
                },
                setGrid: { [weak self] updated, key in
                    self?.grids[key ?? .displayless] = updated
                }),
            apply: { [weak self] rects, _ in
                guard let self else { return }
                for (id, rect) in rects {
                    guard let handle = self.handles[id] else { continue }
                    self.gateway.setFrame(handle, to: rect)
                }
            },
            scheduleCommit: { [weak self] fire in
                self?.commitFires.append(fire)
                return {}
            })
    }

    /// One user gesture: a fast drag of the top sixth's bottom edge
    /// downward, released before the drag's final AX tick arrives.
    func testFastEdgeDragWithTrailingTickLeavesTheConfiguredGap() {
        placeStackedSixths()
        let top = GridLayout().rect(for: .sixthTopLeft, in: bounds, gap: gap)

        // Fast ticks: the bottom edge moves down 30, then 120.
        dragTop(to: top, movedDown: 30)
        dragTop(to: top, movedDown: 120)
        // The button lifts before the final tick lands.
        tracker.mouseLifted()
        // The trailing tick: the edge ends 220 down.
        dragTop(to: top, movedDown: 220)

        fireCommit()
        drainMainQueue()

        assertGapIsConfigured()
    }

    /// The same gesture oscillating down and back up — the shape from
    /// the report — then a trailing tick that lands the final position
    /// after the release.
    func testFastDownAndUpDragWithTrailingTickLeavesTheConfiguredGap() {
        placeStackedSixths()
        let top = GridLayout().rect(for: .sixthTopLeft, in: bounds, gap: gap)

        dragTop(to: top, movedDown: 140)
        dragTop(to: top, movedDown: 220)
        dragTop(to: top, movedDown: 40) // back up fast, past where it started
        tracker.mouseLifted()
        dragTop(to: top, movedDown: 60) // the final tick trails the release

        fireCommit()
        drainMainQueue()

        assertGapIsConfigured()
    }

    /// Two grabs back to back: the first release's commit is still
    /// waiting when the second grab starts, and the first drag's final
    /// tick interleaves the second drag. The second release is the only
    /// commit; it must carry the second drag's final grid.
    func testBackToBackFastDragsCommitOnlyTheLastGrid() {
        placeStackedSixths()
        let top = GridLayout().rect(for: .sixthTopLeft, in: bounds, gap: gap)

        dragTop(to: top, movedDown: 80)
        dragTop(to: top, movedDown: 140)
        tracker.mouseLifted() // first release: commit armed

        // The user grabs again before the delay elapsed: the armed
        // commit must be dropped, never fired under the new drag.
        tracker.mousePressed()
        dragTop(to: top, movedDown: 180) // first drag's trailing tick
        dragTop(to: top, movedDown: 190) // second drag proper
        tracker.mouseLifted()
        dragTop(to: top, movedDown: 220) // second drag's trailing tick

        // The first release's cancelled commit never fires in production
        // (its work item is cancelled); the second release's commit is
        // the only one left armed.
        fireCommit()
        drainMainQueue()

        assertGapIsConfigured()
    }

    // MARK: Harness

    private func placeStackedSixths() {
        let top = GridLayout().rect(for: .sixthTopLeft, in: bounds, gap: gap)
        let bottom = GridLayout().rect(for: .sixthBottomLeft, in: bounds, gap: gap)
        handles[1] = gateway.addWindow(frame: top)
        handles[2] = gateway.addWindow(frame: bottom)
    }

    /// Moves the top window's bottom edge `down` points via a synthetic
    /// AX frame change, then feeds it to the tracker.
    private func dragTop(to original: CGRect, movedDown down: CGFloat) {
        var frame = original
        frame.origin.y -= down
        frame.size.height += down
        gateway.setFrame(handles[1]!, to: frame)
        tracker.handleChange(id: 1, frame: frame)
    }

    /// The gesture is over. The visible gap between the dragged window's
    /// final bottom edge and the neighbour's top edge must be the
    /// configured gap.
    private func assertGapIsConfigured() {
        let dragged = gateway.frame(of: handles[1]!)!
        let neighbour = gateway.frame(of: handles[2]!)!
        let visibleGap = dragged.minY - neighbour.maxY
        XCTAssertEqual(
            visibleGap, gap, accuracy: 0.5,
            "after a fast drag the neighbour must be committed to the "
                + "drag's final splitter, leaving the configured gap "
                + "(got \(visibleGap))")
    }

    /// Fires the latest trailing-tick commit the tracker armed (a
    /// cancelled one is a no-op: its closure guards on its own state).
    private func fireCommit() {
        commitFires.last?()
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }
}
