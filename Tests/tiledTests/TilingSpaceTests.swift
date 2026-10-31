import XCTest
@testable import tiled

/// `TilingSpace` through its own interface: the canvas's suite. Every
/// action runs against a fake gateway with injected bounds and no
/// controller, so the assertions pin the canvas's contract (written
/// frames, notices, undo chapters, outcomes) rather than a coordinator's
/// routing. The placement, eviction, reflow, re-house, undo, expand,
/// splitter, and release paths all have their coverage here; this file
/// replaces `PlanExecutorTests` from the old pipeline arc.
final class TilingSpaceTests: XCTestCase {
    private var harness: TilingSpaceHarness!

    override func setUp() {
        super.setUp()
        harness = TilingSpaceHarness()
    }

    /// The canvas under test. A computed property so helper closures and
    /// assertions read like they write against `TilingSpace` directly.
    private var space: TilingSpace {
        get { harness.space }
        set { harness.space = newValue }
    }

    /// The canvas's grid, for expectations that mirror its rect math.
    private var grid: GridLayout { harness.space.grid }

    private var bounds: CGRect { harness.bounds }

    private func context() -> TilingSpace.Context { harness.context() }

    // MARK: Tile

    func testTilePlacesAndWritesFrame() {
        let id = harness.addWindow()
        let initialFrame = harness.frame(of: id)!
        let expected = CGRect(x: 0, y: 600, width: 800, height: 600)

        harness.apply(slot: .topLeft, requester: id)

        XCTAssertNil(space.error)
        XCTAssertEqual(space.state.slot(of: id), .topLeft)
        XCTAssertEqual(
            space.records[id]?.preTileFrame, initialFrame,
            "the pre-tile frame is where the window sat before the first tile")
        XCTAssertEqual(
            harness.frame(of: id), expected,
            "the tile writes the slot rect in the injected bounds")
    }

    func testSixthTileWritesTheLiteralSixthsRect() {
        let id = harness.addWindow()

        harness.apply(slot: .sixthTopLeft, requester: id)

        let frame = harness.frame(of: id)!
        XCTAssertEqual(frame.origin, CGPoint(x: 0, y: 600))
        XCTAssertEqual(
            frame.width, 1600.0 / 3.0, accuracy: 0.0001,
            "sixths divide the canvas into three literal columns")
        XCTAssertEqual(frame.height, 600)
    }

    func testSkippedPlacementWriteSeedsTheDragBaseline() {
        // A window already sitting at the target rect makes the placement
        // write a no-op skip. The skip still has to seed the drag
        // baseline: a one-tick title-bar drag straight afterwards must be
        // tracked and snap back, not be dropped and leave the window off
        // its tile.
        let target = harness.rect(.topLeft)
        let id = harness.addWindow(frame: target)

        harness.apply(slot: .topLeft, requester: id)

        XCTAssertTrue(harness.expectedWrites.isEmpty, "the placement write skipped")
        harness.tracker.mousePressed(at: CGPoint(x: target.midX, y: target.midY))
        harness.tracker.handleChange(id: id, frame: target.offsetBy(dx: 10, dy: 10))
        harness.tracker.mouseLifted()

        XCTAssertEqual(
            harness.decisions, [.snapback(id)],
            "the one-tick short drag is tracked after the skipped write")
        space.reassert(.grid, context: context())
        XCTAssertEqual(
            harness.frame(of: id), target, "the snapback returns the window to its tile")
    }

    func testTileRefusalRollsBackAndReports() {
        let id = harness.addWindow()
        harness.gateway.refuseNextWrites(harness.handle(of: id)!)

        let outcome = harness.apply(slot: .topLeft, requester: id)

        XCTAssertNil(space.state.slot(of: id), "occupancy rolled back so state and screen agree")
        XCTAssertNotNil(space.error)
        XCTAssertEqual(outcome.result, .refused(windowName: "TestApp"))
    }

    func testRefusedMoveOfTiledWindowKeepsItsOriginalSlot() {
        let id = harness.addWindow()
        harness.apply(slot: .topLeft, requester: id)
        let original = harness.frame(of: id)
        harness.gateway.refuseNextWrites(harness.handle(of: id)!)

        let outcome = harness.apply(slot: .bottomRight, requester: id)

        XCTAssertEqual(outcome.result, .refused(windowName: "TestApp"))
        XCTAssertEqual(
            space.state.slot(of: id), .topLeft,
            "a refused move keeps the slot the window still visibly holds")
        XCTAssertEqual(harness.frame(of: id), original, "the app never moved the window")
        XCTAssertNotNil(space.records[id], "the record survives with the occupancy")
        XCTAssertNotNil(space.error)
    }

    func testRefusedRestoreDuringLayoutSwitchIsAFailureButTheLayoutStillChanges() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .topRight, requester: b)
        XCTAssertEqual(space.state.layout, .quarters)
        harness.gateway.refuseNextWrites(harness.handle(of: a)!)

        let outcome = space.switchLayout(to: .sixths, context: harness.context())

        XCTAssertEqual(outcome.result, .switched(layout: .sixths, untiled: 2))
        XCTAssertEqual(space.state.layout, .sixths, "the layout changes despite the refusal")
        XCTAssertNil(space.state.slot(of: a), "the board empties even on a refused restore")
        XCTAssertNil(space.state.slot(of: b))
        XCTAssertNil(space.records[a], "every occupant's record is forgotten")
        XCTAssertNotNil(space.error, "the refused restore is narrated, not swallowed")
        XCTAssertEqual(space.undoStack.count, 1, "the captured chapter still offers the recovery")
    }

    func testTileOnAHiddenCanvasDefersAndStands() {
        let id = harness.addWindow()
        harness.canvasVisible = false

        let outcome = harness.apply(slot: .topLeft, requester: id)

        XCTAssertTrue(harness.gateway.writes.isEmpty, "a hidden canvas is never written blind")
        XCTAssertEqual(
            space.state.slot(of: id), .topLeft,
            "the deferred placement stands and reconciles when the canvas is visible")
        XCTAssertNil(space.error, "a deferral is not an app refusal")
        XCTAssertEqual(outcome.result, .deferred)
    }

    /// A deferred placement is retained and re-issued by the swipe-back
    /// reassert: the window lands in its requested slot with no second
    /// user action, matching the deferred reflow/restore reconciliation.
    func testDeferredPlacementLandsOnReassertWhenVisible() {
        let id = harness.addWindow()
        harness.canvasVisible = false

        let outcome = harness.apply(slot: .topLeft, requester: id)
        XCTAssertEqual(outcome.result, .deferred)
        XCTAssertTrue(harness.gateway.writes.isEmpty, "a hidden canvas is never written blind")

        harness.canvasVisible = true
        space.reassert(.grid, context: context())

        XCTAssertEqual(
            harness.frame(of: id), harness.rect(.topLeft),
            "the retained placement lands in its requested slot on return")
    }

    func testSameSlotRequestIsAStrictNoopThatPreservesTheNotice() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .leftHalf, requester: b) // evicts a, narrates
        let notice = space.notice
        XCTAssertNotNil(notice)

        let outcome = harness.apply(slot: .leftHalf, requester: b)

        XCTAssertEqual(outcome.result, .alreadyTiled)
        XCTAssertEqual(space.notice, notice, "a strict no-op clears nothing")
    }

    // MARK: Eviction

    func testEvictionRestoresSizedFrame() {
        let a = harness.addWindow()
        let original = CGRect(x: 10, y: 20, width: 300, height: 200)
        harness.gateway.setFrame(harness.handle(of: a)!, to: original)
        space.records[a]?.preTileFrame = original
        space.adoptLayout(.quarters)
        space.state.commit(window: a, into: .topLeft)
        let b = harness.addWindow()

        harness.apply(slot: .topLeft, requester: b)

        XCTAssertNil(space.error)
        XCTAssertNil(space.state.slot(of: a))
        XCTAssertEqual(
            harness.frame(of: a), CGRect(x: 10, y: 0, width: 800, height: 600),
            "eviction writes the quarter footprint hung from the pre-tile top edge")
    }

    func testPlainTileEvictionNoticesAndSnapshotsForUndo() {
        let a = harness.addWindow()
        space.adoptLayout(.quarters)
        space.state.commit(window: a, into: .topLeft)
        let b = harness.addWindow()

        harness.apply(slot: .topLeft, requester: b)

        // Ordinary eviction gets the same narrative as a layout switch:
        // a notice naming the displaced app (not a count), plus the
        // shared one-step undo.
        XCTAssertEqual(
            space.notice,
            "TestApp went back to where it was."
                + " Undo from the Tiled menu.")
        let chapter = space.undoStack.last
        XCTAssertNotNil(chapter, "the eviction is undoable like a switch")
        XCTAssertEqual(chapter?.snapshot.first?.slot, .topLeft)
        XCTAssertEqual(chapter?.requester, b)
    }

    func testPlainTileWithoutEvictionHasNoNoticeOrSnapshot() {
        let b = harness.addWindow()

        harness.apply(slot: .topLeft, requester: b)

        XCTAssertNil(space.notice, "nothing was displaced, nothing to narrate")
        XCTAssertTrue(space.undoStack.isEmpty)
    }

    // MARK: Swap

    func testSwapMovesBothWindowsAndKeepsThemTiled() {
        // The exact-slot swap: the top-left quad requests the top-right
        // quad its occupant holds. The blocker has no leftover of its
        // own, so it takes the requester's vacated tile; nobody is
        // untiled.
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .topRight, requester: b)

        let outcome = harness.apply(slot: .topRight, requester: a)

        XCTAssertNil(space.error)
        XCTAssertEqual(outcome.result, .placed)
        XCTAssertEqual(space.state.slot(of: a), .topRight)
        XCTAssertEqual(
            space.state.slot(of: b), .topLeft,
            "the displaced window takes the tile the requester vacated")
        XCTAssertEqual(harness.frame(of: a), harness.rect(.topRight))
        XCTAssertEqual(harness.frame(of: b), harness.rect(.topLeft))
    }

    func testTiledRequesterIntoAContainingBlockerStepsItAside() {
        // The report's example, now a step-aside: the top-left sixth
        // requests the middle third held inside the right two-thirds.
        // The two-thirds window shrinks into its own leftover — the
        // right third — instead of trading tiles across the screen.
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .sixthTopLeft, requester: a)
        harness.apply(slot: .sixthsRightTwoThirds, requester: b)

        let outcome = harness.apply(slot: .sixthMiddle, requester: a)

        XCTAssertNil(space.error)
        XCTAssertEqual(outcome.result, .placed)
        XCTAssertEqual(space.state.slot(of: a), .sixthMiddle)
        XCTAssertEqual(
            space.state.slot(of: b), .sixthRight,
            "the containing blocker steps into its own leftover")
        XCTAssertEqual(harness.frame(of: a), harness.rect(.sixthMiddle))
        XCTAssertEqual(harness.frame(of: b), harness.rect(.sixthRight))
    }

    func testStepAsideKeepsBothPreTileFrames() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        let aFrame = CGRect(x: 5, y: 6, width: 300, height: 200)
        let bFrame = CGRect(x: 7, y: 8, width: 280, height: 190)
        harness.gateway.setFrame(harness.handle(of: a)!, to: aFrame)
        harness.gateway.setFrame(harness.handle(of: b)!, to: bFrame)
        harness.apply(slot: .sixthTopLeft, requester: a)
        harness.apply(slot: .sixthsRightTwoThirds, requester: b)

        // The request now steps the blocker aside rather than swapping;
        // either way both windows keep the pre-tile frames they arrived
        // with.
        harness.apply(slot: .sixthMiddle, requester: a)

        XCTAssertEqual(space.records[a]?.preTileFrame, aFrame)
        XCTAssertEqual(space.records[b]?.preTileFrame, bFrame)
    }

    func testSwapRefusalByDisplacedMovesNothing() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .topRight, requester: b)
        harness.gateway.refuseNextWrites(harness.handle(of: b)!)

        harness.apply(slot: .topRight, requester: a)

        XCTAssertNotNil(space.error)
        XCTAssertEqual(space.state.slot(of: a), .topLeft, "the requester stays put")
        XCTAssertEqual(space.state.slot(of: b), .topRight, "the displaced window stays put")
        XCTAssertTrue(space.undoStack.isEmpty)
    }

    func testSwapRefusalByRequesterRollsDisplacedBack() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .topRight, requester: b)
        harness.gateway.refuseNextWrites(harness.handle(of: a)!)

        harness.apply(slot: .topRight, requester: a)

        XCTAssertNotNil(space.error)
        XCTAssertEqual(space.state.slot(of: a), .topLeft)
        XCTAssertEqual(space.state.slot(of: b), .topRight, "rolled back to its own tile")
        // The displaced window's first write succeeded, so it visibly sits
        // in the requester's vacated tile unless the rollback writes it
        // home. State alone cannot see that: an unwritten rollback leaves
        // screen and state disagreeing while this test stays green.
        XCTAssertEqual(
            harness.frame(of: b), harness.rect(.topRight),
            "the displaced window is written back to its own tile")
    }

    func testSwapRollbackNamesTheDisplacedHomeWriteRefusal() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .topRight, requester: b)
        let bHandle = harness.handle(of: b)!
        harness.gateway.refuseNextWrites(harness.handle(of: a)!)
        var bWrites = 0
        harness.gateway.willWrite = { handle in
            guard handle == bHandle else { return }
            bWrites += 1
            if bWrites == 2 {
                self.harness.gateway.refuseNextWrites(bHandle)
            }
        }

        harness.apply(slot: .topRight, requester: a)

        XCTAssertEqual(space.state.slot(of: a), .topLeft)
        XCTAssertEqual(space.state.slot(of: b), .topRight)
        let error = space.error ?? ""
        XCTAssertTrue(
            error.contains("Couldn't restore"),
            "the home-write refusal is named beside the requester refusal: \(error)")
    }

    func testStepAsideNoticesAndSnapshotsBothForUndo() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .sixthTopLeft, requester: a)
        harness.apply(slot: .sixthsRightTwoThirds, requester: b)

        harness.apply(slot: .sixthMiddle, requester: a)

        XCTAssertEqual(
            space.notice,
            "TestApp moved to Right Third to make room."
                + " Undo from the Tiled menu.")
        XCTAssertEqual(space.undoStack.last?.requester, a)
        let snapshot = try! XCTUnwrap(space.undoStack.last?.snapshot)
        XCTAssertEqual(snapshot.count, 2, "both windows are undoable")
        XCTAssertTrue(
            snapshot.contains { $0.slot == .sixthsRightTwoThirds },
            "the stepped-aside window's undo entry names its own former tile")
        XCTAssertTrue(
            snapshot.contains { $0.slot == .sixthTopLeft },
            "the requester's undo entry names its vacated tile")
    }

    /// A swap plan whose requester is not tiled degrades to a plain
    /// eviction. That fallback must carry the real expanded-window
    /// closure: with one that always answers false, a re-house would move
    /// an expanded evictee into the freed slot while it still covers the
    /// layout. Expanded windows come back to earth by untangling instead.
    func testDegenerateSwapNeverRehousesAnExpandedEvictee() {
        let blocker = harness.addWindow()
        let requester = harness.addWindow()
        harness.apply(slot: .topLeft, requester: blocker)

        // The requester holds no slot, so `.swap` is degenerate; the top
        // left overlaps the left half, so the blocker is evicted; and the
        // cells left free are exactly the right half, which is the slot a
        // re-house would have used. Marking the blocker expanded in the
        // canvas is the rule the fallback must honor.
        space.expanded[blocker] = .zero
        let outcome = harness.run(
            .swap(displaced: blocker), requester: requester, slot: .leftHalf)

        XCTAssertNil(
            space.state.slot(of: blocker),
            "an expanded evictee is never re-housed, degenerate swap or not")
        XCTAssertEqual(space.state.slot(of: requester), .leftHalf)
        XCTAssertTrue(
            outcome.forget.contains(blocker),
            "the degraded swap reports the window it untangled")
    }

    /// The same shape without the expansion: the lone evictee is re-housed
    /// into the one whole slot the request left free, so the assertion
    /// above is the expanded-window exclusion and not a broken re-house.
    func testDegenerateSwapRehousesAnUnexpandedEvictee() {
        let blocker = harness.addWindow()
        let requester = harness.addWindow()
        harness.apply(slot: .topLeft, requester: blocker)

        harness.run(.swap(displaced: blocker), requester: requester, slot: .leftHalf)

        XCTAssertEqual(space.state.slot(of: blocker), .rightHalf, "the lone evictee stays tiled")
        XCTAssertEqual(space.state.slot(of: requester), .leftHalf)
        XCTAssertEqual(
            space.notice,
            "TestApp moved to Right Half to make room." + MenuText.undoRecoveryHint,
            "the degraded swap still narrates where the window went")
    }

    // MARK: Switch

    func testSwitchNoticeNamesLayoutCountAndUndoOffer() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .topRight, requester: b)

        let outcome = space.switchLayout(to: .sixths, context: harness.context())

        XCTAssertEqual(outcome.result, .switched(layout: .sixths, untiled: 2))
        XCTAssertEqual(
            space.notice,
            "Switched to Sixths · 2 windows untiled. Undo from the Tiled menu.")
    }

    func testSwitchSnapshotsEveryOccupant() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .topRight, requester: b)

        space.switchLayout(to: .sixths, context: harness.context())

        XCTAssertNil(space.error)
        XCTAssertNotNil(space.notice)
        XCTAssertEqual(space.undoStack.last?.snapshot.count, 2, "the switch names every occupant")
        XCTAssertNil(space.undoStack.last?.requester, "a switch has no requester")
        XCTAssertEqual(space.state.layout, .sixths)
        XCTAssertNil(space.state.slot(of: a), "evicted window restored (untiled)")
        XCTAssertNil(space.state.slot(of: b), "evicted window restored (untiled)")
    }

    func testSwitchRestoreFailureSurfacesAndStillPushesTheChapter() {
        let a = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        // Poison a's pre-tile frame restore: the gateway refuses the write.
        space.records[a]?.preTileFrame = CGRect(x: 10, y: 10, width: 100, height: 100)
        harness.gateway.refuseNextWrites(harness.handle(of: a)!)
        let b = harness.addWindow()
        harness.apply(slot: .topRight, requester: b)

        space.switchLayout(to: .sixths, context: harness.context())

        XCTAssertNotNil(space.error, "failed restore surfaces instead of silence")
        XCTAssertNotNil(space.notice, "the layout change is still narrated")
        XCTAssertEqual(space.state.layout, .sixths)
        XCTAssertEqual(
            space.undoStack.last?.snapshot.count, 2,
            "the captured chapter still offers the recovery")
        XCTAssertTrue(space.state.occupants.isEmpty)
    }

    // MARK: Re-house

    func testRehouseKeepsTheEvicteeTiledInTheOneFreeSlot() {
        // Bottom-left sixth (b), middle third (m), right third (r); the
        // middle third requests the right two-thirds. The right third is
        // evicted, and the cells left free are exactly the top-left
        // sixth, so it re-tiles there instead of untangling.
        let b = harness.addWindow()
        let m = harness.addWindow()
        let r = harness.addWindow()
        harness.apply(slot: .sixthBottomLeft, requester: b)
        harness.apply(slot: .sixthMiddle, requester: m)
        harness.apply(slot: .sixthRight, requester: r)

        harness.apply(slot: .sixthsRightTwoThirds, requester: m)

        XCTAssertNil(space.error)
        XCTAssertEqual(space.state.slot(of: m), .sixthsRightTwoThirds)
        XCTAssertEqual(
            space.state.slot(of: r), .sixthTopLeft,
            "the evicted right third re-tiles into the free top-left sixth")
        XCTAssertEqual(space.state.slot(of: b), .sixthBottomLeft)
        XCTAssertEqual(harness.frame(of: r), harness.rect(.sixthTopLeft))
        XCTAssertEqual(space.undoStack.last?.requester, m)
    }

    func testRehouseWriteRefusalFallsBackToEviction() {
        let b = harness.addWindow()
        let m = harness.addWindow()
        let r = harness.addWindow()
        harness.apply(slot: .sixthBottomLeft, requester: b)
        harness.apply(slot: .sixthMiddle, requester: m)
        harness.apply(slot: .sixthRight, requester: r)
        harness.gateway.refuseNextWrites(harness.handle(of: r)!)

        harness.apply(slot: .sixthsRightTwoThirds, requester: m)

        XCTAssertEqual(space.state.slot(of: m), .sixthsRightTwoThirds)
        XCTAssertNil(
            space.state.slot(of: r),
            "a refused re-house write untangles the victim instead of diverging")
        XCTAssertNotNil(space.notice, "the fallback eviction is still narrated")
        XCTAssertNil(space.error, "the restore itself succeeded")
    }

    func testRefusedFallbackRestoreIsAFailureNotAFalseSuccess() {
        // The re-house write is refused, and the pre-tile restore that
        // falls back to it is refused too (an app that refuses programmatic
        // resizes). The window stays on screen in its old tile, so the
        // notice must not claim it went back and the menu must name the
        // refusal.
        let b = harness.addWindow()
        let m = harness.addWindow()
        let r = harness.addWindow()
        harness.apply(slot: .sixthBottomLeft, requester: b)
        harness.apply(slot: .sixthMiddle, requester: m)
        harness.apply(slot: .sixthRight, requester: r)
        harness.gateway.refuseSizeWrites.insert(harness.handle(of: r)!)

        harness.apply(slot: .sixthsRightTwoThirds, requester: m)

        XCTAssertNotNil(
            space.error,
            "a refused fallback restore names the app instead of silence")
        XCTAssertFalse(
            space.notice?.contains("went back") ?? false,
            "the notice must not claim a refused restore landed")
    }

    func testRefusedRequesterLeavesTheRehouseVictimAlone() {
        let b = harness.addWindow()
        let m = harness.addWindow()
        let r = harness.addWindow()
        harness.apply(slot: .sixthBottomLeft, requester: b)
        harness.apply(slot: .sixthMiddle, requester: m)
        harness.apply(slot: .sixthRight, requester: r)
        harness.gateway.refuseNextWrites(harness.handle(of: m)!)

        harness.apply(slot: .sixthsRightTwoThirds, requester: m)

        XCTAssertNotNil(space.error, "the requester's refusal is reported")
        XCTAssertEqual(
            space.state.slot(of: m), .sixthMiddle,
            "the refused requester keeps the slot it still visibly holds")
        XCTAssertEqual(
            harness.frame(of: m), harness.rect(.sixthMiddle),
            "the app never moved the requester")
        XCTAssertNotNil(space.records[m], "the record survives with the occupancy")
        XCTAssertNil(
            space.state.slot(of: r),
            "the victim untiles to its sized frame, not into a new tile")
        XCTAssertEqual(harness.frame(of: r)?.origin, .zero)
        XCTAssertEqual(harness.frame(of: r)?.height, 600)
        XCTAssertEqual(
            harness.frame(of: r)!.width, 800,
            "its quarter footprint sits at the pre-tile origin")
        XCTAssertFalse(
            space.notice?.contains("to make room") ?? false,
            "no re-house notice for a request that never landed")
        XCTAssertNotNil(space.undoStack.last, "the eviction itself is undoable")
        XCTAssertEqual(
            space.displacedCount, 1,
            "the refused requester never moved, so only the victim is displaced")
    }

    func testContainmentRehouseStepsTheBlockerAsideThroughTheCanvas() {
        // A left third blocks a fresh window's top-left sixth request:
        // the third steps down into its own leftover — the bottom-left
        // sixth — instead of untangling.
        let third = harness.addWindow()
        harness.apply(slot: .sixthLeft, requester: third)
        let fresh = harness.addWindow()

        harness.apply(slot: .sixthTopLeft, requester: fresh)

        XCTAssertNil(space.error)
        XCTAssertEqual(space.state.slot(of: fresh), .sixthTopLeft)
        XCTAssertEqual(
            space.state.slot(of: third), .sixthBottomLeft,
            "the blocking third steps aside instead of losing its tiling")
        XCTAssertEqual(harness.frame(of: third), harness.rect(.sixthBottomLeft))
        XCTAssertTrue(
            space.notice?.contains("to make room") ?? false,
            "the step-aside is narrated like any re-house")
        XCTAssertEqual(space.undoStack.last?.requester, fresh)
        XCTAssertEqual(
            space.undoStack.last?.snapshot.first?.slot, .sixthLeft,
            "undo returns the blocker to its full slot")
    }

    func testTwoBlockersEvictWithoutSteppingAside() {
        // Middle third AND right third block a right two-thirds
        // request. The middle third mirrors onto itself, and its own
        // slot overlaps the target, so the group has no home: everyone
        // untangles rather than half of them moving.
        let middle = harness.addWindow()
        harness.apply(slot: .sixthMiddle, requester: middle)
        let right = harness.addWindow()
        harness.apply(slot: .sixthRight, requester: right)
        let fresh = harness.addWindow()

        harness.apply(slot: .sixthsRightTwoThirds, requester: fresh)

        XCTAssertEqual(space.state.slot(of: fresh), .sixthsRightTwoThirds)
        XCTAssertNil(space.state.slot(of: middle))
        XCTAssertNil(space.state.slot(of: right))
    }

    func testStepAsideWinsOverSwap() {
        // A tiled requester whose target sits inside a containing
        // blocker steps the blocker aside instead of swapping: the left
        // third shrinks into its own bottom-left sixth rather than
        // teleporting into the vacated top-middle sixth.
        let third = harness.addWindow()
        harness.apply(slot: .sixthLeft, requester: third)
        let mover = harness.addWindow()
        harness.apply(slot: .sixthTopMiddle, requester: mover)

        harness.apply(slot: .sixthTopLeft, requester: mover)

        XCTAssertEqual(space.state.slot(of: mover), .sixthTopLeft)
        XCTAssertEqual(
            space.state.slot(of: third), .sixthBottomLeft,
            "the third steps aside into its own strip, not the vacated sixth")
    }

    // MARK: Reflow

    func testUntileGrowsTheSurvivorAndChapterHoldsTheMove() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .sixthTopLeft, requester: a)
        harness.apply(slot: .sixthBottomLeft, requester: b)

        let outcome = space.untile(window: b, reflowing: true, context: context())

        XCTAssertEqual(space.state.slot(of: a), .sixthLeft, "the survivor expands down")
        XCTAssertEqual(harness.frame(of: a), harness.rect(.sixthLeft))
        XCTAssertNil(space.state.slot(of: b), "the untiled window released its slot")
        XCTAssertEqual(harness.frame(of: b)?.origin, .zero)
        XCTAssertEqual(harness.frame(of: b)?.height, 600)
        XCTAssertEqual(
            harness.frame(of: b)!.width, 800,
            "the untiled window floats at the quarter footprint")
        XCTAssertEqual(outcome.forget, [b])
        XCTAssertTrue(outcome.raise)
        XCTAssertEqual(
            space.undoStack.last?.snapshot.first?.slot, .sixthTopLeft,
            "the reflow chapter returns the survivor to the slot it held")
    }

    func testSkippedReflowWriteSeedsTheDragBaseline() {
        // The survivor's live frame already equals the slot it grows
        // into, so the reflow write skips. The skip still seeds the drag
        // baseline: a one-tick short title-bar drag afterwards must be
        // tracked, not misread against the survivor's old tile.
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .bottomLeft, requester: b)
        let grown = harness.rect(.leftHalf)
        harness.gateway.simulateSilentChange(harness.handle(of: b)!, to: grown)

        space.untile(window: a, reflowing: true, context: context())

        XCTAssertEqual(space.state.slot(of: b), .leftHalf, "the survivor grows")
        harness.tracker.mousePressed(at: CGPoint(x: grown.midX, y: grown.midY))
        harness.tracker.handleChange(id: b, frame: grown.offsetBy(dx: 10, dy: 10))
        harness.tracker.mouseLifted()

        XCTAssertEqual(
            harness.decisions, [.snapback(b)],
            "the one-tick short drag is tracked after the skipped reflow write")
    }

    func testUntileRefusedRestoreReportsAndStillReleases() {
        let a = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.gateway.refuseNextWrites(harness.handle(of: a)!)

        space.untile(window: a, reflowing: true, context: context())

        XCTAssertEqual(
            space.error,
            "Couldn't restore \u{201C}TestApp\u{201D}: it may still be sitting in its old tile.")
        XCTAssertNil(space.state.slot(of: a), "slot released even though the restore was refused")
        XCTAssertNil(space.records[a])
    }

    func testUntileFromDragLeavesTheDropAndReflows() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .sixthTopLeft, requester: a)
        harness.apply(slot: .sixthBottomLeft, requester: b)
        // The drop moved b; drag-out never restores the pre-tile frame.
        // The drop's top edge takes the quarter footprint instead, repinned
        // where the taller footprint would spill off the canvas.
        let dropped = CGRect(x: 300, y: 700, width: 500, height: 300)
        harness.gateway.setFrame(harness.handle(of: b)!, to: dropped)

        let outcome = space.untileFromDrag(window: b, context: context())

        XCTAssertEqual(harness.frame(of: b)?.origin, CGPoint(x: 300, y: 400))
        XCTAssertEqual(harness.frame(of: b)?.height, 600)
        XCTAssertEqual(
            harness.frame(of: b)!.width, 800,
            "the drop is the placement, at the quarter footprint")
        XCTAssertEqual(space.state.slot(of: a), .sixthLeft, "the freed cells reflow")
        XCTAssertEqual(outcome.forget, [b])
        XCTAssertNil(space.error)
    }

    func testRefusedReflowRollsTheSurvivorBackAndReports() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .sixthTopLeft, requester: a)
        harness.apply(slot: .sixthBottomLeft, requester: b)
        let survivorFrame = harness.frame(of: a)!
        harness.gateway.refuseNextWrites(harness.handle(of: a)!)

        space.untile(window: b, reflowing: true, context: context())

        XCTAssertEqual(
            space.state.slot(of: a), .sixthTopLeft,
            "the survivor keeps its slot when its grow write is refused")
        XCTAssertEqual(harness.frame(of: a), survivorFrame)
        XCTAssertEqual(
            space.error, "Couldn't move that window: the app refused to resize it.")
        XCTAssertTrue(space.undoStack.isEmpty, "a reflow that did not happen writes no chapter")
        XCTAssertNil(space.state.slot(of: b), "the leave itself still stands")
    }

    func testMoveReflowsVacatedCellsToTheNeighbour() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        let c = harness.addWindow()
        harness.apply(slot: .sixthTopLeft, requester: a)
        harness.apply(slot: .sixthMiddle, requester: b)
        harness.apply(slot: .sixthRight, requester: c)

        // b moves to the free bottom-left sixth: its vacated cells flow
        // right, growing the right third into the right two-thirds.
        harness.apply(slot: .sixthBottomLeft, requester: b)

        XCTAssertEqual(space.state.slot(of: b), .sixthBottomLeft)
        XCTAssertEqual(space.state.slot(of: c), .sixthsRightTwoThirds)
        XCTAssertEqual(harness.frame(of: c), harness.rect(.sixthsRightTwoThirds))
        XCTAssertNil(
            space.undoStack.last?.requester,
            "the move's requester is excluded from the chapter; only the survivor moves")
        XCTAssertTrue(
            space.undoStack.last?.snapshot.contains { $0.slot == .sixthRight } ?? false,
            "the survivor's move shares the requester's chapter")
    }

    func testExpandedSurvivorNeverGrows() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .sixthTopLeft, requester: a)
        harness.apply(slot: .sixthBottomLeft, requester: b)
        space.expanded[b] = .zero
        let expandedFrame = harness.frame(of: b)!

        space.untile(window: a, reflowing: true, context: context())

        XCTAssertEqual(space.state.slot(of: b), .sixthBottomLeft, "the expanded survivor keeps its slot")
        XCTAssertEqual(harness.frame(of: b), expandedFrame, "and keeps covering the layout")
    }

    // MARK: Evict and release

    func testEvictUntiledWindowAnswersNothingToEvict() {
        let id = harness.addWindow()

        let outcome = space.evict(window: id, context: context())

        XCTAssertEqual(outcome.result, .nothingToEvict)
        XCTAssertTrue(harness.gateway.writes.isEmpty)
    }

    func testReleaseForgetsReflowsAndWritesNothingToTheDeadWindow() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .sixthTopLeft, requester: a)
        harness.apply(slot: .sixthBottomLeft, requester: b)
        harness.gateway.clearWrites()

        let outcome = space.release(window: a, context: context())

        XCTAssertNil(space.state.slot(of: a))
        XCTAssertEqual(space.state.slot(of: b), .sixthLeft, "the freed cells reflow")
        XCTAssertEqual(outcome.forget, [a])
        XCTAssertFalse(
            harness.gateway.writes.contains { $0.handle == harness.handle(of: a) },
            "a confirmed-dead window is never written")
    }

    func testDiscardDropsOccupancyAndRecordWithoutWriting() {
        let a = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.gateway.clearWrites()

        space.discard(window: a, context: context())

        XCTAssertNil(space.state.slot(of: a))
        XCTAssertNil(space.records[a])
        XCTAssertTrue(harness.gateway.writes.isEmpty, "the rollback itself writes nothing")
    }

    // MARK: Restore policy

    /// A sized restore on a hidden canvas defers too: the evicted
    /// window is not dragged through Mission Control, its slot is
    /// released, and the deferred sized restore lands on the swipe-back reassert —
    /// the same off-Space contract every other write obeys.
    func testHiddenCanvasEvictionDefersTheRestoreAndReconcilesOnReturn() {
        let original = CGRect(x: 10, y: 20, width: 300, height: 200)
        let a = harness.addWindow(frame: original)
        harness.apply(slot: .topLeft, requester: a)
        XCTAssertEqual(space.records[a]?.preTileFrame, original)
        harness.gateway.clearWrites()
        harness.clearExpectedWrites()
        let b = harness.addWindow()
        harness.canvasVisible = false

        harness.apply(slot: .topLeft, requester: b)

        XCTAssertTrue(
            harness.gateway.writes.isEmpty,
            "a hidden canvas never drags the evicted window through Mission Control")
        XCTAssertTrue(
            harness.expectedWrites.isEmpty,
            "a deferred restore arms no phantom expectation")
        XCTAssertNil(space.state.slot(of: a), "the eviction releases the slot")
        XCTAssertNil(space.error, "a deferral is not an app refusal")

        harness.canvasVisible = true
        space.reassert(.grid, context: context())

        XCTAssertEqual(
            harness.frame(of: a), CGRect(x: 10, y: 0, width: 800, height: 600),
            "the deferred sized restore lands when the canvas becomes visible")
    }

    /// A hidden untile-all defers every sized restore (its re-observation of the
    /// windows for the undo chapter must not discard them) and lands them
    /// all on the swipe back.
    func testHiddenCanvasUntileAllDefersEveryRestoreAndReconcilesOnReturn() {
        let aFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let bFrame = CGRect(x: 500, y: 40, width: 400, height: 300)
        let a = harness.addWindow(frame: aFrame)
        harness.apply(slot: .topLeft, requester: a)
        let b = harness.addWindow(frame: bFrame)
        harness.apply(slot: .topRight, requester: b)
        harness.gateway.clearWrites()
        harness.canvasVisible = false

        space.untileAll(context: context())

        XCTAssertTrue(harness.gateway.writes.isEmpty, "a hidden canvas is never written blind")
        XCTAssertEqual(space.deferredRestores.count, 2, "both restores are deferred")

        harness.canvasVisible = true
        space.reassert(.grid, context: context())

        XCTAssertEqual(harness.frame(of: a), CGRect(x: 10, y: 0, width: 800, height: 600))
        XCTAssertEqual(harness.frame(of: b), CGRect(x: 500, y: 0, width: 800, height: 600))
    }

    /// Re-tiling a window with a deferred restore before the canvas
    /// returns discards that stale restore, so the swipe-back cannot yank
    /// it out of the slot it just took.
    func testRetilingAWindowWithADeferredRestoreDiscardsIt() {
        let original = CGRect(x: 10, y: 20, width: 300, height: 200)
        let a = harness.addWindow(frame: original)
        harness.apply(slot: .topLeft, requester: a)
        let b = harness.addWindow()
        harness.canvasVisible = false
        harness.apply(slot: .topLeft, requester: b)
        XCTAssertNil(space.state.slot(of: a))
        XCTAssertFalse(space.deferredRestores.isEmpty, "the hidden restore is deferred")

        // Before the canvas returns, the user tiles the window again.
        harness.apply(slot: .bottomRight, requester: a)

        XCTAssertTrue(
            space.deferredRestores.isEmpty,
            "re-tiling the window discards its stale deferred restore")
    }

    /// The restore takes the same no-op skip as every other write: a
    /// window already sitting at its sized frame is not rewritten, so
    /// its settling app is never re-armed into a phantom drag.
    func testRestoreSkipsAnAlreadyCorrectFrame() {
        let original = CGRect(x: 10, y: 20, width: 300, height: 200)
        let a = harness.addWindow(frame: original)
        harness.apply(slot: .topLeft, requester: a)
        // The app already sits at the sized footprint the restore would write.
        let sized = CGRect(x: 10, y: 0, width: 800, height: 600)
        harness.gateway.simulateSilentChange(harness.handle(of: a)!, to: sized)
        harness.gateway.clearWrites()
        harness.clearExpectedWrites()

        space.untile(window: a, reflowing: false, context: context())

        XCTAssertTrue(
            harness.gateway.writes.isEmpty,
            "an already-correct restore issues no write")
        XCTAssertTrue(
            harness.expectedWrites.isEmpty,
            "and arms no echo for a frame that needs no write")
        XCTAssertNil(space.state.slot(of: a), "the slot is released regardless")
    }

    /// A restore on a visible canvas is unchanged: the sized frame is
    /// written and the slot released, with nothing deferred for later.
    func testVisibleRestoreWritesTheSizedFrameAndReleasesTheSlot() {
        let original = CGRect(x: 10, y: 20, width: 300, height: 200)
        let a = harness.addWindow(frame: original)
        harness.apply(slot: .topLeft, requester: a)
        harness.gateway.clearWrites()
        harness.clearExpectedWrites()

        space.untile(window: a, reflowing: false, context: context())

        XCTAssertEqual(harness.frame(of: a), CGRect(x: 10, y: 0, width: 800, height: 600))
        XCTAssertNil(space.state.slot(of: a))
        XCTAssertTrue(space.deferredRestores.isEmpty, "a visible restore is never deferred")
        XCTAssertEqual(
            harness.expectedWrites, [a],
            "the restore arms its echo like every other write")
        XCTAssertNil(
            harness.tracker.convergence(for: a),
            "and clears it when the window is untiled: no phantom expectation")
    }

    /// A pre-tile origin that straddles the canvas edge takes the quarter
    /// footprint and repins inside the visible frame: the sized frame is
    /// the canvas's own placement, not the app's, so it never spills
    /// off-screen.
    func testStraddlingPreTileRestoreRepinsInsideTheVisibleFrame() {
        let straddling = CGRect(x: 1500, y: 0, width: 300, height: 300)
        let a = harness.addWindow(frame: straddling)
        harness.apply(slot: .topLeft, requester: a)
        XCTAssertEqual(space.records[a]?.preTileFrame, straddling)

        space.untile(window: a, reflowing: false, context: context())

        XCTAssertEqual(
            harness.frame(of: a), CGRect(x: 800, y: 0, width: 800, height: 600),
            "the sized frame hugs the screen edge instead of spilling off it")
    }

    // MARK: Untile all

    func testUntileAllNoticesBuildsAChapterAndObservesTheRestored() {
        let aOriginal = CGRect(x: 0, y: 0, width: 800, height: 600)
        let bOriginal = CGRect(x: 900, y: 50, width: 600, height: 450)
        let a = harness.addWindow(frame: aOriginal)
        let b = harness.addWindow(frame: bOriginal)
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .topRight, requester: b)

        let outcome = space.untileAll(context: context())

        XCTAssertEqual(
            space.notice,
            "Untiled 2 windows. Undo from the Tiled menu.")
        XCTAssertEqual(space.state.occupants, [:])
        XCTAssertEqual(harness.frame(of: a), aOriginal)
        XCTAssertEqual(
            harness.frame(of: b), CGRect(x: 800, y: 0, width: 800, height: 600),
            "the taller footprint repins inside the visible frame")
        XCTAssertEqual(Set(outcome.forget), [a, b])
        XCTAssertEqual(outcome.observe.count, 2, "the chapter re-observes both windows")
        XCTAssertEqual(space.undoStack.last?.snapshot.count, 2)
    }

    func testUntileAllKeepsNoChapterWhenNoFramesRead() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .topRight, requester: b)
        harness.gateway.hideFrames = [harness.handle(of: a)!, harness.handle(of: b)!]

        let outcome = space.untileAll(context: context())

        XCTAssertTrue(space.state.occupants.isEmpty)
        XCTAssertTrue(space.undoStack.isEmpty, "no chapter can restore unreadable frames")
        XCTAssertTrue(outcome.observe.isEmpty)
        XCTAssertEqual(
            space.notice, "Untiled 2 windows.",
            "the notice must not offer a key with no chapter behind it")
    }

    // MARK: Undo

    func testRestoreEvicteesReturnsEvictedToItsSlot() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .topLeft, requester: b)
        guard let snapshot = space.undoStack.last?.snapshot else {
            return XCTFail("the eviction should snapshot")
        }

        let result = harness.restoreEvictees(snapshot)

        XCTAssertEqual(result.restored.count, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(
            space.state.occupant(of: .topLeft).flatMap { space.records[$0]?.handle },
            harness.handle(of: a),
            "evicted window returns to its slot under a fresh id")
    }

    func testRestoreEvicteesAttemptsRestoreForBusyWindows() {
        // A busy app answers the liveness probe with unknown, never dead:
        // undo must still attempt the restore rather than silently skip a
        // maybe-alive window. (With the pre-tri-state `isAlive`, a transient
        // probe failure read as dead and the window was skipped entirely.)
        let a = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: b)
        guard let snapshot = space.undoStack.last?.snapshot else {
            return XCTFail("the eviction should snapshot")
        }
        harness.gateway.busy.insert(harness.handle(of: a)!)

        let result = harness.restoreEvictees(snapshot)

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.restored.count, 1)
        XCTAssertEqual(
            space.state.occupant(of: .topLeft).flatMap { space.records[$0]?.handle },
            harness.handle(of: a),
            "unknown liveness still restores the window to its slot")
    }

    func testRestoreEvicteesSkipsDeadHandles() {
        let a = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: b)
        guard let snapshot = space.undoStack.last?.snapshot else {
            return XCTFail("the eviction should snapshot")
        }
        XCTAssertEqual(snapshot.count, 1, "the eviction names its one victim")
        harness.gateway.kill(harness.handle(of: a)!)

        let result = harness.restoreEvictees(snapshot)

        XCTAssertTrue(result.restored.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(space.state.occupant(of: .topLeft), b, "the dead evictee is skipped")
    }

    func testRestoreEvicteesRestoresEveryEvictee() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        let c = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .bottomLeft, requester: b)
        harness.apply(slot: .leftHalf, requester: c)
        guard let snapshot = space.undoStack.last?.snapshot else {
            return XCTFail("the eviction should snapshot")
        }
        XCTAssertEqual(snapshot.count, 2)

        let result = harness.restoreEvictees(snapshot)

        XCTAssertEqual(result.restored.count, 2)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testRestoreEvicteesRetileRefusalDropsTheWindow() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .topLeft, requester: b)
        guard let snapshot = space.undoStack.last?.snapshot else {
            return XCTFail("the eviction should snapshot")
        }
        harness.gateway.refuseNextWrites(harness.handle(of: a)!)

        let result = harness.restoreEvictees(snapshot)

        XCTAssertEqual(result.failures.map(\.name), ["TestApp"])
        XCTAssertTrue(result.restored.isEmpty)
        XCTAssertEqual(result.forget.count, 1)
        XCTAssertNil(space.state.occupant(of: .topLeft),
            "a refused re-tile releases the slot it briefly claimed")
        XCTAssertFalse(
            space.records.values.contains { $0.handle == harness.handle(of: a) },
            "the refused window's fresh record is dropped, not left dangling")
    }

    func testRestoreEvicteesRetilesEvictedUnderCurrentGrid() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .topLeft, requester: b)
        guard let snapshot = space.undoStack.last?.snapshot else {
            return XCTFail("the eviction should snapshot")
        }
        // At undo time a's live frame is its restored pre-tile frame; the
        // re-tile target derives from the grid evaluated in the injected
        // bounds.
        let expected = grid.rect(for: .topLeft, in: bounds)

        let result = harness.restoreEvictees(snapshot)

        XCTAssertEqual(result.restored.count, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(
            harness.frame(of: a), expected,
            "undo writes the slot rect computed from the restored frame")
    }

    func testSkippedUndoRetileSeedsTheDragBaseline() {
        // The chapter's evictee already sits exactly on its slot rect, so
        // restoreEvictees takes its explicit skip branch instead of
        // writing. The skip must seed the baseline: a one-tick short
        // title-bar drag after the undo must snap back, not be dropped
        // and leave the window offset.
        let topLeft = harness.rect(.topLeft)
        let a = harness.addWindow(frame: topLeft)
        harness.apply(slot: .topLeft, requester: a)
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: b)
        guard let snapshot = space.undoStack.last?.snapshot else {
            return XCTFail("the eviction should snapshot")
        }

        // Put the evictee back exactly where the undo will retile it:
        // the current frame equals the target slot rect.
        harness.gateway.simulateSilentChange(
            harness.handle(of: a)!, to: harness.rect(.topLeft))
        harness.clearExpectedWrites()

        let result = harness.restoreEvictees(snapshot)

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(
            harness.expectedWrites.isEmpty,
            "the undo re-tile skipped because the live frame already matched")
        guard let restored = result.restored.first else {
            return XCTFail("the evictee returns to its slot")
        }

        let target = harness.rect(.topLeft)
        harness.tracker.mousePressed(at: CGPoint(x: target.midX, y: target.midY))
        harness.tracker.handleChange(id: restored, frame: target.offsetBy(dx: 10, dy: 10))
        harness.tracker.mouseLifted()

        XCTAssertEqual(
            harness.decisions, [.snapback(restored)],
            "the one-tick short drag is tracked after the skipped undo write")
    }

    // MARK: Expand toggle

    func testExpandFillsTheInjectedBoundsWithoutTiling() {
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let id = harness.addWindow(frame: original)

        space.expandToggle(window: id, context: context())

        XCTAssertEqual(harness.frame(of: id), bounds)
        XCTAssertTrue(space.isExpanded(id))
        XCTAssertTrue(space.state.occupants.isEmpty, "expanding never tiles")

        space.expandToggle(window: id, context: context())
        XCTAssertEqual(harness.frame(of: id), original, "a second press restores the frame")
        XCTAssertFalse(space.isExpanded(id))
    }

    func testSkippedExpansionWriteSeedsTheDragBaseline() {
        // A tiled window already at the screen frame makes the expand
        // write a no-op skip. The skip still seeds the drag baseline: a
        // one-tick title-bar drag afterwards must be tracked, not
        // misread as an edge grab against the old tile.
        let id = harness.addWindow()
        harness.apply(slot: .topLeft, requester: id)
        let tiled = harness.rect(.topLeft)
        harness.tracker.handleChange(id: id, frame: tiled) // settle the placement echo
        harness.gateway.simulateSilentChange(harness.handle(of: id)!, to: bounds)
        harness.clearExpectedWrites()

        space.expandToggle(window: id, context: context())

        XCTAssertTrue(space.isExpanded(id))
        XCTAssertTrue(harness.expectedWrites.isEmpty, "the expand write skipped")
        harness.tracker.mousePressed(at: CGPoint(x: bounds.midX, y: bounds.midY))
        harness.tracker.handleChange(id: id, frame: bounds.offsetBy(dx: 10, dy: 10))
        harness.tracker.mouseLifted()

        XCTAssertEqual(
            harness.decisions, [.snapback(id)],
            "the one-tick short drag is tracked after the skipped expand write")
    }

    func testExpandedTiledWindowKeepsItsSlotAndCollapseRetiles() {
        let id = harness.addWindow()
        harness.apply(slot: .topLeft, requester: id)

        space.expandToggle(window: id, context: context())
        XCTAssertEqual(space.state.slot(of: id), .topLeft, "expanding acts like focusing")
        XCTAssertEqual(harness.frame(of: id), bounds)

        space.expandToggle(window: id, context: context())
        XCTAssertEqual(space.state.slot(of: id), .topLeft)
        XCTAssertEqual(harness.frame(of: id), harness.rect(.topLeft), "collapse retiles")
        XCTAssertFalse(space.isExpanded(id))
    }

    func testExpandRefusalRecordsErrorAndAnswersExpandRefused() {
        let original = CGRect(x: 0, y: 0, width: 800, height: 600)
        let id = harness.addWindow(frame: original)
        harness.gateway.refuseNextWrites(harness.handle(of: id)!)

        let outcome = space.expandToggle(window: id, context: context())

        XCTAssertEqual(harness.frame(of: id), original)
        XCTAssertEqual(outcome.result, .expandRefused(windowName: "TestApp"))
        XCTAssertEqual(space.error, "Couldn't move that window: the app refused to resize it.")
        XCTAssertFalse(space.isExpanded(id), "a refused expand stays out of state")
    }

    func testHiddenCanvasExpandDefersAndStaysOutOfState() {
        let id = harness.addWindow()
        harness.canvasVisible = false

        let outcome = space.expandToggle(window: id, context: context())

        XCTAssertEqual(
            outcome.result, .deferred,
            "a deferral is narrated as a deferral, never an app refusal")
        XCTAssertFalse(space.isExpanded(id), "the expansion lands only when the canvas is visible")
        XCTAssertTrue(harness.gateway.writes.isEmpty)
    }

    /// A deferred expand is retained: the toggle is re-issued by the
    /// swipe-back reassert, so the window is expanded on return rather
    /// than left merely tiled.
    func testDeferredExpandLandsOnReassertWhenVisible() {
        let id = harness.addWindow()
        harness.apply(slot: .topLeft, requester: id)
        harness.gateway.clearWrites()
        harness.canvasVisible = false

        let outcome = space.expandToggle(window: id, context: context())
        XCTAssertEqual(outcome.result, .deferred)
        XCTAssertTrue(harness.gateway.writes.isEmpty, "a hidden canvas is never written blind")

        harness.canvasVisible = true
        space.reassert(.grid, context: context())

        XCTAssertEqual(harness.frame(of: id), bounds, "the retained expand lands on return")
        XCTAssertTrue(space.isExpanded(id))
        XCTAssertEqual(
            space.state.slot(of: id), .topLeft,
            "expanding acts like focusing: the slot survives")
    }

    /// A deferred collapse of an untiled expanded window is retained too:
    /// the saved frame lands on return instead of the window keeping the
    /// screen-covering frame.
    func testDeferredCollapseOfAnUntiledWindowLandsOnReassert() {
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let id = harness.addWindow(frame: original)
        _ = space.expandToggle(window: id, context: context())
        XCTAssertTrue(space.isExpanded(id))

        harness.gateway.clearWrites()
        harness.canvasVisible = false
        let outcome = space.expandToggle(window: id, context: context())
        XCTAssertEqual(outcome.result, .deferred)
        XCTAssertTrue(harness.gateway.writes.isEmpty)

        harness.canvasVisible = true
        space.reassert(.grid, context: context())

        XCTAssertEqual(harness.frame(of: id), original, "the retained collapse lands on return")
        XCTAssertFalse(space.isExpanded(id))
    }

    func testExpandWithNoReadableFrameRefusesToGuess() {
        let id = harness.addWindow(frame: .zero)

        let outcome = space.expandToggle(window: id, context: context())

        XCTAssertEqual(outcome.result, .placed)
        XCTAssertFalse(space.isExpanded(id))
        XCTAssertNil(space.error, "there is no sane screen to expand onto: silent no-op")
    }

    // MARK: Splitter reset / restore

    func testResetSplittersParksTheBackupAndReasserts() {
        let a = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        space.grid.columnSplit = 0.4

        let outcome = space.resetSplitters(context: context())

        XCTAssertEqual(outcome.result, .placed)
        XCTAssertEqual(space.grid, GridLayout())
        XCTAssertEqual(harness.frame(of: a), harness.rect(.topLeft), "occupants re-tile at defaults")
        XCTAssertTrue(space.hasSplitterBackup, "the displaced fractions are parked")
        XCTAssertNil(space.error)
    }

    func testRestoreSplittersBringsBackTheParkedGrid() {
        let a = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        space.grid.columnSplit = 0.4
        space.resetSplitters(context: context())

        let outcome = space.restoreSplitters(context: context())

        XCTAssertEqual(outcome.result, .placed)
        XCTAssertEqual(space.grid.columnSplit, 0.4, accuracy: 0.001)
        XCTAssertEqual(
            space.notice, "Splitters restored to their pre-reset positions.")
        XCTAssertFalse(space.hasSplitterBackup, "restoring consumes the backup")
        let target = space.grid.rect(for: .topLeft, in: bounds)
        XCTAssertEqual(harness.frame(of: a), target, "occupants re-tile at the restored grid")

        // Nil backup (already restored once) is a no-op.
        let again = space.restoreSplitters(context: context())
        XCTAssertEqual(again.result, .placed)
        XCTAssertEqual(space.grid.columnSplit, 0.4, accuracy: 0.001)
    }

    func testResetSplitterRefusalLandsOnTheCanvas() {
        let a = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        // Park the window off its rect: the re-assert must be a real
        // write for the refusal to land.
        harness.gateway.setFrame(
            harness.handle(of: a)!, to: CGRect(x: -9_999, y: -9_999, width: 1, height: 1))
        harness.gateway.refuseNextWrites(harness.handle(of: a)!)

        space.resetSplitters(context: context())

        XCTAssertEqual(
            space.error, "Couldn't move that window: the app refused to resize it.")
        XCTAssertTrue(space.hasSplitterBackup, "the reset still counts as the receipt")
    }

    // MARK: Reassert

    func testReassertWritesEveryOccupantUnderItsSlot() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .bottomRight, requester: b)
        harness.gateway.clearWrites()

        let outcome = space.reassert(.grid, context: context())

        XCTAssertEqual(outcome.result, .placed)
        XCTAssertEqual(harness.frame(of: a), harness.rect(.topLeft))
        XCTAssertEqual(harness.frame(of: b), harness.rect(.bottomRight))
    }

    func testReassertSkipsExpandedWindows() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .bottomRight, requester: b)
        space.expanded[a] = .zero
        // Park the expanded window off its slot: it covers the layout, so
        // the reassert must leave it where it is, not drag it into its
        // slot. Non-expanded b re-derives (a no-op here, already right).
        harness.gateway.setFrame(
            harness.handle(of: a)!, to: CGRect(x: 5, y: 5, width: 100, height: 100))
        let aBefore = harness.frame(of: a)!

        space.reassert(.grid, context: context())

        XCTAssertEqual(harness.frame(of: a), aBefore, "an expanded occupant is not written")
    }

    func testReassertReportsPluralRefusalsOnTheCanvas() {
        let a = harness.addWindow()
        let b = harness.addWindow()
        harness.apply(slot: .topLeft, requester: a)
        harness.apply(slot: .bottomRight, requester: b)
        let far = CGRect(x: -9_999, y: -9_999, width: 1, height: 1)
        harness.gateway.setFrame(harness.handle(of: a)!, to: far)
        harness.gateway.setFrame(harness.handle(of: b)!, to: far)
        harness.gateway.refuseNextWrites(harness.handle(of: a)!)
        harness.gateway.refuseNextWrites(harness.handle(of: b)!)

        space.reassert(.grid, context: context())

        XCTAssertEqual(
            space.error, "Couldn't move 2 windows: an app refused to resize.")
    }

    // MARK: Sequences

    func testPingPongAlternatesExactlyOneWindow() {
        // Every switch leaves exactly the requester; ping-ponging layouts
        // never accumulates strays.
        let w1 = harness.addWindow()
        let w2 = harness.addWindow()
        let w3 = harness.addWindow()
        let w4 = harness.addWindow()
        let script: [(WindowID, Slot)] = [
            (w1, .topLeft),
            (w2, .bottomRight),
            (w3, .sixthMiddle), // reset to sixths
            (w4, .sixthLeft),
            (w1, .rightHalf), // reset to quarters
            (w1, .sixthTopLeft), // reset to sixths (tiled requester)
            (w1, .topLeft), // reset to quarters (tiled requester)
        ]
        let expected: [[Slot: WindowID]] = [
            [.topLeft: w1],
            [.topLeft: w1, .bottomRight: w2],
            [.sixthMiddle: w3],
            [.sixthMiddle: w3, .sixthLeft: w4],
            [.rightHalf: w1],
            [.sixthTopLeft: w1],
            [.topLeft: w1],
        ]
        for ((window, slot), want) in zip(script, expected) {
            harness.apply(slot: slot, requester: window)
            XCTAssertEqual(space.state.occupants, want, "after win\(window) -> \(slot.rawValue)")
            XCTAssertEqual(space.state.layout, slot.layout)
            assertHealthy("win\(window) -> \(slot.rawValue)")
        }
    }

    func testQuartersSessionSwitchSixthsSessionSwitchBack() {
        let w1 = harness.addWindow()
        let w2 = harness.addWindow()
        let w3 = harness.addWindow()
        let w4 = harness.addWindow()
        let w5 = harness.addWindow()
        let w6 = harness.addWindow()
        for (id, slot) in [(w1, Slot.topLeft), (w2, .topRight), (w3, .bottomLeft)] {
            harness.apply(slot: slot, requester: id)
        }
        XCTAssertEqual(space.state.layout, .quarters)
        XCTAssertEqual(space.state.tiledWindows.sorted(), [w1, w2, w3])

        harness.apply(slot: .sixthLeft, requester: w4)
        XCTAssertEqual(space.state.occupants, [.sixthLeft: w4])
        XCTAssertEqual(space.state.layout, .sixths)
        for evicted in [w1, w2, w3] { XCTAssertNil(space.state.slot(of: evicted)) }

        for (id, slot) in [(w5, Slot.sixthMiddle), (w6, .sixthRight)] {
            harness.apply(slot: slot, requester: id)
        }
        XCTAssertEqual(
            space.state.occupants, [.sixthLeft: w4, .sixthMiddle: w5, .sixthRight: w6])

        harness.apply(slot: .leftHalf, requester: w5)
        XCTAssertEqual(space.state.occupants, [.leftHalf: w5])
        XCTAssertEqual(space.state.layout, .quarters)
        XCTAssertNil(space.state.slot(of: w4))
        XCTAssertNil(space.state.slot(of: w6))

        harness.apply(slot: .rightHalf, requester: w6)
        XCTAssertEqual(space.state.occupants, [.leftHalf: w5, .rightHalf: w6])
        assertHealthy("rebuilt quarters")
    }

    func testTiledWindowCarriesAcrossSwitchesButLosesItsOldTile() {
        let w1 = harness.addWindow()
        let w2 = harness.addWindow()
        harness.apply(slot: .topLeft, requester: w1)
        harness.apply(slot: .bottomRight, requester: w2)

        harness.apply(slot: .sixthRight, requester: w1)

        XCTAssertEqual(space.state.occupants, [.sixthRight: w1])
        XCTAssertNil(space.state.slot(of: w2))

        harness.apply(slot: .bottomLeft, requester: w1)

        XCTAssertEqual(space.state.occupants, [.bottomLeft: w1])
        XCTAssertEqual(space.state.layout, .quarters)
        XCTAssertEqual(
            space.records[w1]?.preTileFrame,
            CGRect(x: 0, y: 0, width: 800, height: 600),
            "its pre-tile frame survives every switch")
    }

    func testSwitchImmediatelyAfterSwitch() {
        let w1 = harness.addWindow()
        let w2 = harness.addWindow()
        let w3 = harness.addWindow()
        let w4 = harness.addWindow()
        harness.apply(slot: .leftHalf, requester: w1)
        harness.apply(slot: .rightHalf, requester: w2)
        harness.apply(slot: .sixthMiddle, requester: w3)
        XCTAssertEqual(space.state.occupants, [.sixthMiddle: w3])

        harness.apply(slot: .topLeft, requester: w4)

        XCTAssertEqual(space.state.occupants, [.topLeft: w4])
        assertHealthy("double switch")
    }

    func testAfterSwitchSameLayoutRequestsDoNotReset() {
        let ids = (0..<7).map { _ in harness.addWindow() }
        let corners: [Slot] = [
            .sixthTopLeft, .sixthTopMiddle, .sixthTopRight,
            .sixthBottomLeft, .sixthBottomMiddle, .sixthBottomRight,
        ]
        // Fill the sixths layout, one corner at a time.
        for (id, slot) in zip(ids, corners) {
            harness.apply(slot: slot, requester: id)
        }
        XCTAssertEqual(space.state.layout, .sixths)

        // Occupied corner takeover by a fresh window: the blocker is
        // evicted (its cells are the requester's new tile, so no whole
        // slot is left free), never a layout reset.
        harness.apply(slot: .sixthTopLeft, requester: ids[6])
        XCTAssertEqual(space.state.layout, .sixths, "no reset for a same-layout request")
        XCTAssertEqual(space.state.occupant(of: .sixthTopLeft), ids[6])
        XCTAssertNil(space.state.slot(of: ids[0]))

        // Tiled window moving between same-layout slots: a tile, not a reset.
        harness.apply(slot: .sixthMiddle, requester: ids[1])
        XCTAssertEqual(space.state.layout, .sixths)
        XCTAssertEqual(space.state.slot(of: ids[1]), .sixthMiddle)
        XCTAssertNil(space.state.slot(of: ids[4]), "the bottom-middle blocker was evicted")
        assertHealthy("same-layout session")
    }

    /// Structural health after any transition: no ghosts, at most one
    /// layout on screen, no cell double-booked, layout agrees.
    private func assertHealthy(
        _ context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let state = space.state
        XCTAssertEqual(
            Set(state.tiledWindows), Set(state.occupants.values),
            "\(context): ghost occupant", file: file, line: line)
        let layouts = Set(state.occupants.keys.map(\.layout))
        XCTAssertLessThanOrEqual(
            layouts.count, 1, "\(context): mixed layouts on screen",
            file: file, line: line)
        if let only = state.occupants.keys.first {
            XCTAssertEqual(
                state.layout, only.layout,
                "\(context): layout disagrees", file: file, line: line)
        }
        var seen: Set<TileCell> = []
        for slot in state.occupants.keys {
            for cell in slot.cells {
                XCTAssertFalse(
                    seen.contains(cell), "\(context): cell \(cell) double-booked",
                    file: file, line: line)
                seen.insert(cell)
            }
        }
    }
}
