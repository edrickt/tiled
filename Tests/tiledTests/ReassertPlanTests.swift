import CoreGraphics
import XCTest
@testable import tiled

/// The reassert through its two layers: the pure plan (reconcile a
/// clamped edge, then map every tiled, non-expanded occupant's rect
/// under the canvas's one visible frame) and the thin effectful wrapper
/// (store the grid, seed the drag baselines, write every rect). The
/// pure layer takes no gateway, clock, or scheduler, so most of this
/// suite is a value function pinned by values; the wrapper runs through
/// the fake gateway like the rest of the canvas's suite.
final class ReassertPlanTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1200)

    /// A canvas with the given occupancy committed: no gateway, no
    /// handles, just the pure state and geometry the plan reads.
    private func canvas(
        _ occupants: [(Slot, WindowID)], expanded: Set<WindowID> = [],
        grid: GridLayout = GridLayout()
    ) -> TilingSpace {
        var canvas = TilingSpace()
        canvas.visibleFrame = bounds
        canvas.grid = grid
        // The canvas's layout is stored: seed it from the occupancy the
        // test is building, so the commit precondition is satisfied.
        canvas.state = TilingState(layout: occupants.first?.0.layout ?? .sixths)
        for (slot, id) in occupants { canvas.state.commit(window: id, into: slot) }
        for id in expanded { canvas.expanded[id] = .zero }
        return canvas
    }

    private func position(_ fraction: CGFloat) -> CGFloat {
        bounds.minX + fraction * bounds.width
    }

    /// Screen-space y (AppKit, y grows upward) of a row fraction. The
    /// horizontal splitters divide against the canvas's height; the
    /// vertical ones against its width.
    private func rowPosition(_ fraction: CGFloat) -> CGFloat {
        bounds.minY + fraction * bounds.height
    }

    // MARK: Reconcile: the clamp gap

    func testUnreadableAchievedFrameKeepsTheStoredSplittersAndMapsRects() {
        var grid = GridLayout()
        grid.sixthsRightSplit = 0.8
        let canvas = canvas(
            [(.sixthLeft, 1), (.sixthMiddle, 2), (.sixthRight, 3)], grid: grid)

        let plan = canvas.reassertPlan(.resize(dragged: 2, achieved: nil))

        XCTAssertEqual(
            plan.grid.sixthsRightSplit, 0.8, accuracy: 0.001,
            "an unreadable frame leaves the stored splitter alone")
        XCTAssertEqual(plan.rects.count, 3, "every occupant is still mapped")
        XCTAssertEqual(plan.rects[3]!.minX, position(0.8), accuracy: 0.5)
        XCTAssertEqual(plan.rects[2]!.maxX, plan.rects[3]!.minX)
    }

    func testResizeReconcileClosesTheClampedGap() {
        // The middle third was dragged right and the drag committed the
        // splitter at 0.8, but the app refused to shrink below its floor
        // and its achieved right edge landed at 0.7. The reassert must
        // trust the achieved frame: the splitter moves back to 0.7, and
        // the right third abuts the window itself, never the phantom
        // splitter.
        var grid = GridLayout()
        grid.sixthsRightSplit = 0.8
        let canvas = canvas(
            [(.sixthLeft, 1), (.sixthMiddle, 2), (.sixthRight, 3)], grid: grid)
        var achieved = canvas.grid.rect(for: .sixthMiddle, in: bounds)
        achieved.size.width = position(0.7) - achieved.minX

        let plan = canvas.reassertPlan(.resize(dragged: 2, achieved: achieved))

        XCTAssertEqual(
            plan.grid.sixthsRightSplit, 0.7, accuracy: 0.001,
            "the splitter moves back to the edge the app actually achieved")
        XCTAssertEqual(
            plan.grid.sixthsLeftSplit, 1.0 / 3.0, accuracy: 0.001,
            "the untouched edge does not move")

        let left = plan.rects[1]!
        let middle = plan.rects[2]!
        let right = plan.rects[3]!
        XCTAssertEqual(middle.maxX, position(0.7), accuracy: 0.5)
        XCTAssertEqual(middle, achieved, "the dragged window lands exactly in its reconciled tile")
        XCTAssertEqual(left.maxX, middle.minX, "the left neighbour abuts the window")
        XCTAssertEqual(
            right.minX, middle.maxX,
            "the right neighbour abuts the window's real edge: no gap, no overlap")
    }

    func testResizePlanDerivesEveryRectFromTheReconciledGrid() {
        // The canvas's stored grid still holds the phantom 0.8 splitter.
        // The plan must return the reconciled grid AND rects that agree
        // with it: mapping against the stored grid would leave the right
        // third at 0.8 and re-open the gap.
        var grid = GridLayout()
        grid.sixthsRightSplit = 0.8
        let canvas = canvas(
            [(.sixthLeft, 1), (.sixthMiddle, 2), (.sixthRight, 3)], grid: grid)
        var achieved = grid.rect(for: .sixthMiddle, in: bounds)
        achieved.size.width = position(0.7) - achieved.minX

        let plan = canvas.reassertPlan(.resize(dragged: 2, achieved: achieved))

        XCTAssertEqual(plan.rects[3], plan.grid.rect(for: .sixthRight, in: bounds))
        XCTAssertNotEqual(
            plan.rects[3], grid.rect(for: .sixthRight, in: bounds),
            "rects are mapped after the reconcile, not from the phantom splitter")
    }

    func testResizeReconcileMovesTheDraggedHorizontalSplitter() {
        // The quarters' left row splitter is dragged by either left-column
        // window's facing edge. The reconcile must take the achieved
        // frame's own edge — its bottom for the top window, its top for
        // the bottom window — never the far screen edge, or the splitter
        // jumps to 0 / 1 and the neighbour is dragged across the canvas.
        let top = canvas([(.topLeft, 1), (.bottomLeft, 2)])
        var topAchieved = top.grid.rect(for: .topLeft, in: bounds)
        topAchieved.origin.y = rowPosition(0.4)
        topAchieved.size.height = bounds.maxY - topAchieved.minY
        let topPlan = top.reassertPlan(.resize(dragged: 1, achieved: topAchieved))

        XCTAssertEqual(
            topPlan.grid.leftRowSplit, 0.4, accuracy: 0.001,
            "a top window's bottom edge reconciles the row splitter")
        XCTAssertEqual(topPlan.rects[1]!.minY, rowPosition(0.4), accuracy: 0.5)
        XCTAssertEqual(
            topPlan.rects[2]!.maxY, rowPosition(0.4), accuracy: 0.5,
            "the bottom neighbour abuts the window's real edge")

        let bottom = canvas([(.topLeft, 1), (.bottomLeft, 2)])
        var bottomAchieved = bottom.grid.rect(for: .bottomLeft, in: bounds)
        bottomAchieved.size.height = rowPosition(0.6) - bottomAchieved.minY
        let bottomPlan = bottom.reassertPlan(.resize(dragged: 2, achieved: bottomAchieved))

        XCTAssertEqual(
            bottomPlan.grid.leftRowSplit, 0.6, accuracy: 0.001,
            "a bottom window's top edge reconciles the row splitter")
        XCTAssertEqual(
            bottomPlan.rects[1]!.minY, rowPosition(0.6), accuracy: 0.5,
            "the top neighbour abuts the window's real edge")
    }

    // MARK: Source `.grid`

    func testGridSourceLeavesTheSplittersAlone() {
        var grid = GridLayout()
        grid.columnSplit = 0.42
        grid.leftRowSplit = 0.31
        let canvas = canvas([(.topLeft, 1), (.bottomRight, 2)], grid: grid)

        let plan = canvas.reassertPlan(.grid)

        XCTAssertEqual(plan.grid, grid, "a grid reassert moves no splitter")
        XCTAssertEqual(plan.rects[1], grid.rect(for: .topLeft, in: bounds))
        XCTAssertEqual(plan.rects[2], grid.rect(for: .bottomRight, in: bounds))
    }

    // MARK: Two-thirds centering

    func testResizeReconcileCentersTheTwoThirdsHiddenDivider() {
        // A left two-thirds window dragged its outer edge to 0.78: its
        // hidden divider must stay at the midpoint, so it still reads as
        // two equal thirds.
        let canvas = canvas([(.sixthsLeftTwoThirds, 1), (.sixthRight, 2)])
        var achieved = canvas.grid.rect(for: .sixthsLeftTwoThirds, in: bounds)
        achieved.size.width = position(0.78) - achieved.minX

        let plan = canvas.reassertPlan(.resize(dragged: 1, achieved: achieved))

        XCTAssertEqual(plan.grid.sixthsRightSplit, 0.78, accuracy: 0.001)
        XCTAssertEqual(plan.grid.sixthsLeftSplit, 0.39, accuracy: 0.001)
        let twoThirds = plan.rects[1]!
        let divider = plan.grid.position(of: .sixthsLeftSplit, in: bounds)
        XCTAssertEqual(
            divider - twoThirds.minX, twoThirds.maxX - divider, accuracy: 0.5,
            "the hidden divider bisects the resized two-thirds window")
    }

    func testResizeReconcileFollowsAnAdjacentThirdIntoTheTwoThirdsDivider() {
        // The right third's facing edge and the left two-thirds window's
        // outer edge are the same splitter: dragging the third resizes
        // the two-thirds window too, whose hidden divider must stay
        // centered. This is the occupant-aware half of the rule, shared
        // with the live drag loop.
        let canvas = canvas([(.sixthsLeftTwoThirds, 1), (.sixthRight, 2)])
        var achieved = canvas.grid.rect(for: .sixthRight, in: bounds)
        achieved.origin.x = position(0.7)
        achieved.size.width = bounds.maxX - achieved.minX

        let plan = canvas.reassertPlan(.resize(dragged: 2, achieved: achieved))

        XCTAssertEqual(plan.grid.sixthsRightSplit, 0.7, accuracy: 0.001)
        XCTAssertEqual(
            plan.grid.sixthsLeftSplit, 0.35, accuracy: 0.001,
            "the two-thirds window still reads as two equal thirds")
    }

    // MARK: Expanded

    func testReassertPlanSkipsExpandedOccupants() {
        let canvas = canvas([(.topLeft, 1), (.bottomRight, 2)], expanded: [2])

        let plan = canvas.reassertPlan(.grid)

        XCTAssertNil(plan.rects[2], "an expanded window covers the layout, not its slot")
        XCTAssertEqual(plan.rects[1], canvas.grid.rect(for: .topLeft, in: bounds))
    }

    func testResizeReassertFromAnExpandedWindowLeavesTheSplittersAlone() {
        // An expanded window covers the layout but keeps its slot. A
        // `.resize` source naming it is a stale edge drag that survived
        // the expand; its screen-sized achieved frame must never move
        // the splitters or re-lay-out the neighbours.
        var grid = GridLayout()
        grid.columnSplit = 0.42
        grid.leftRowSplit = 0.31
        let canvas = canvas(
            [(.topLeft, 1), (.bottomRight, 2)], expanded: [1], grid: grid)

        let plan = canvas.reassertPlan(
            .resize(dragged: 1, achieved: bounds))

        XCTAssertEqual(
            plan.grid, grid,
            "an expanded window's screen frame never reconciles a splitter")
        XCTAssertNil(plan.rects[1], "the expanded window is still skipped")
        XCTAssertEqual(
            plan.rects[2], grid.rect(for: .bottomRight, in: bounds),
            "non-expanded occupants still map under the untouched grid")
    }

    // MARK: Neighbour achieved edge

    /// A harness whose written windows keep their top edge and round
    /// their height down to a whole 16pt row, like Terminal: the app
    /// model behind the reported gap.
    private func rowRoundingHarness() -> TilingSpaceHarness {
        let harness = TilingSpaceHarness()
        harness.gateway.writtenFrame = { _, target in
            let height = (target.height / 16).rounded(.down) * 16
            return CGRect(
                x: target.minX, y: target.maxY - height,
                width: target.width, height: height)
        }
        return harness
    }

    /// The reported live case at the canvas seam: the resize settle
    /// writes the top neighbour to the splitter, the app rounds its
    /// height down, its bottom edge falls short, and the corrective
    /// readback pulls the splitter to the neighbour's achieved edge so
    /// the stacked tiles abut.
    func testNeighbourAchievedEdgePullsTheSplitterAndTheTilesAbut() {
        let harness = rowRoundingHarness()
        let top = harness.addWindow()
        let bottom = harness.addWindow()
        harness.apply(slot: .sixthTopLeft, requester: top)
        harness.apply(slot: .sixthBottomLeft, requester: bottom)
        // A drag of the bottom window's top edge to 0.62 of the canvas.
        harness.space.grid.sixthsLeftRowSplit = 0.62
        var achieved = harness.space.grid.rect(for: .sixthBottomLeft, in: harness.bounds)
        achieved.size.height = 0.62 * harness.bounds.height - achieved.minY

        harness.space.reassert(
            .resize(dragged: bottom, achieved: achieved), context: harness.context())

        let topFrame = harness.frame(of: top)!
        let bottomFrame = harness.frame(of: bottom)!
        XCTAssertEqual(
            bottomFrame.maxY, topFrame.minY, accuracy: 0.5,
            "the stacked tiles abut: no gap, no overlap")
        XCTAssertEqual(
            harness.space.grid.sixthsLeftRowSplit,
            topFrame.minY / harness.bounds.height, accuracy: 0.001,
            "the splitter followed the neighbour's achieved edge")
    }

    /// The corrective pass is a fixed point: once the splitter sits on
    /// the neighbour's achieved edge, a second settle writes nothing.
    /// The harness canvas is a whole number of rows tall, so the app can
    /// apply every target exactly and the residual that a non-row screen
    /// leaves lands nowhere.
    func testSecondReassertAfterCorrectingTheNeighbourWritesNothing() {
        let harness = rowRoundingHarness()
        let top = harness.addWindow()
        let bottom = harness.addWindow()
        harness.apply(slot: .sixthTopLeft, requester: top)
        harness.apply(slot: .sixthBottomLeft, requester: bottom)
        harness.space.grid.sixthsLeftRowSplit = 0.62
        var achieved = harness.space.grid.rect(for: .sixthBottomLeft, in: harness.bounds)
        achieved.size.height = 0.62 * harness.bounds.height - achieved.minY
        harness.space.reassert(
            .resize(dragged: bottom, achieved: achieved), context: harness.context())

        harness.gateway.clearWrites()
        harness.space.reassert(.grid, context: harness.context())

        XCTAssertTrue(
            harness.gateway.writes.isEmpty,
            "a second settle after the corrective pass issues no extra writes")
    }

    // MARK: Effectful wrapper

    func testSecondIdenticalReassertWritesNothing() {
        let harness = TilingSpaceHarness()
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .bottomRight, requester: b)
        // Park both windows off their tiles: the first reassert is a real
        // write for each, so the second is judged against a settled grid.
        let far = CGRect(x: -9_999, y: -9_999, width: 1, height: 1)
        harness.gateway.setFrame(harness.handle(of: a)!, to: far)
        harness.gateway.setFrame(harness.handle(of: b)!, to: far)
        harness.space.reassert(.grid, context: harness.context())
        XCTAssertFalse(harness.gateway.writes.isEmpty, "the first reassert restores the tiles")

        harness.gateway.clearWrites()
        harness.space.reassert(.grid, context: harness.context())

        XCTAssertTrue(
            harness.gateway.writes.isEmpty,
            "a second identical reassert is a provable no-op: nothing to write")
    }

    func testResizeReassertWritesTheDraggedWindowIntoItsClampedTile() {
        // The effectful path with the clamp: the dragged window's own
        // tile is asserted, its neighbour is pulled flush, and the
        // canvas's stored splitters end reconciled.
        let harness = TilingSpaceHarness()
        let left = harness.addWindow()
        let middle = harness.addWindow()
        let right = harness.addWindow()
        harness.apply(slot: .sixthLeft, requester: left)
        harness.apply(slot: .sixthMiddle, requester: middle)
        harness.apply(slot: .sixthRight, requester: right)
        // The drag committed a phantom splitter at 0.8 and left the
        // middle window (clamped by its app) short at 0.7.
        harness.space.grid.sixthsRightSplit = 0.8
        var achieved = harness.space.grid.rect(for: .sixthMiddle, in: harness.bounds)
        achieved.size.width = harness.bounds.minX + 0.7 * harness.bounds.width - achieved.minX

        harness.space.reassert(
            .resize(dragged: middle, achieved: achieved), context: harness.context())

        XCTAssertEqual(harness.space.grid.sixthsRightSplit, 0.7, accuracy: 0.001)
        XCTAssertEqual(harness.frame(of: middle)!.maxX, achieved.maxX, accuracy: 0.5)
        XCTAssertEqual(
            harness.frame(of: right)!.minX, achieved.maxX, accuracy: 0.5,
            "the neighbour abuts the window's real edge")
    }

    func testReassertSeedsBaselineForASkippedWrite() {
        // Every occupant is already at its rect, so the reassert's write
        // is skipped and never reaches markExpected. The reassert must
        // still seed the diff baseline, or the first drag after it is
        // dropped (no previous frame to diff against).
        let harness = TilingSpaceHarness()
        let a = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.tracker.forget(a)
        harness.space.reassert(.grid, context: harness.context())

        let rect = harness.rect(.topLeft)
        var resized = rect
        resized.size.width = rect.width * 1.3
        harness.tracker.handleChange(id: a, frame: resized)

        XCTAssertGreaterThan(
            harness.space.grid.columnSplit, 0.5,
            "the reassert seeded the diff baseline for the skipped write")
    }

    func testDeferredReassertSeedsTheDragBaseline() {
        // A reassert on a hidden canvas defers every write, so neither
        // markExpected nor writeRects' skip branch can seed the diff
        // baseline; only the reassert's own seeding does. Without it the
        // first one-tick drag after the swipe back is dropped.
        let harness = TilingSpaceHarness()
        let a = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.tracker.forget(a)
        harness.canvasVisible = false
        harness.space.grid.columnSplit = 0.7

        harness.space.reassert(.grid, context: harness.context())

        harness.canvasVisible = true
        let rect = harness.rect(.topLeft)
        harness.tracker.mousePressed(at: CGPoint(x: rect.midX, y: rect.midY))
        harness.tracker.handleChange(id: a, frame: rect.offsetBy(dx: 30, dy: 30))
        harness.tracker.mouseLifted()

        XCTAssertEqual(
            harness.decisions, [.snapback(a)],
            "the deferred reassert seeded the drag baseline")
    }

    func testClampedReassertRepinsAgainstTheCanvasFrameNotTheWindow() {
        // A window drifted off-canvas before the reassert. Its clamped
        // write must be pulled back inside the canvas's one visible frame
        // - the frame its target derived from - not inside the window's
        // own (drifted) frame.
        let harness = TilingSpaceHarness()
        let w = harness.addWindow()
        harness.apply(slot: .sixthRight, requester: w)
        // A tile narrower than the app's floor, so the write clamps.
        harness.space.grid.sixthsRightSplit = 0.9
        // Drift the live frame off-canvas: judging the clamp against it
        // would strand the window at the wrong x.
        harness.gateway.setFrame(
            harness.handle(of: w)!, to: CGRect(x: 1200, y: 0, width: 500, height: 100))
        harness.gateway.clearWrites()
        // The app refuses to shrink below 500 wide and keeps the origin.
        harness.gateway.writtenFrame = { _, target in
            CGRect(
                origin: target.origin,
                size: CGSize(width: max(target.width, 500), height: target.height))
        }
        let target = harness.space.grid.rect(for: .sixthRight, in: harness.bounds)

        harness.space.reassert(.grid, context: harness.context())

        XCTAssertEqual(
            harness.frame(of: w),
            CGRect(x: target.maxX - 500, y: target.minY, width: 500, height: target.height),
            "the clamped window is repinned against the canvas's frame, holding its right edge")
    }
}
