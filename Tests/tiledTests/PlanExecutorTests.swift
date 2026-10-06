import XCTest
@testable import tiled

/// `TilingSpace` through its placement interface: branch execution
/// (tile, switch), refusal rollback, restore-failure precedence, and
/// undo, with a fake gateway and a real DragTracker. No controller, no
/// AX. (Named for the module it replaced; stage 4 dissolves it into the
/// canvas's own suite.)
final class PlanExecutorTests: XCTestCase {
    private var gateway: FakeWindowGateway!
    private var tracker: DragTracker!
    private var space: TilingSpace!
    private var writer: FrameWriter!
    private var handles: [WindowID: WindowHandle]!
    private var nextID: WindowID!
    /// Whether the writer's visibility policy sees the canvas. Tests that
    /// exercise deferral flip this; everyone else writes as on a visible
    /// canvas.
    private var canvasVisible = true

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        space = TilingSpace()
        handles = [:]
        nextID = 1
        canvasVisible = true
        tracker = DragTracker(
            context: DragTracker.Context(
                slotOf: { [weak self] in self?.space.state.slot(of: $0) ?? nil },
                frameOf: { [weak self] in
                    guard let self, let handle = self.handles[$0] else { return nil }
                    return self.gateway.frame(of: handle)
                        ?? self.space.records[$0]?.preTileFrame
                },
                boundsOf: { $0 },
                occupants: { [weak self] in self?.space.state.occupants ?? [:] }),
            gridProvider: DragTracker.GridProvider(
                grid: { [weak self] _ in self?.space.grid ?? GridLayout() },
                setGrid: { [weak self] updated, _ in self?.space.grid = updated }),
            apply: { _, _ in 0 })
        writer = FrameWriter(
            gateway: gateway,
            isVisible: { [weak self] _ in self?.canvasVisible ?? true },
            markStale: { _ in },
            markExpected: { [weak self] id, target in
                self?.tracker.markExpected(id, target)
            },
            scheduleCheck: { _, _ in },
            log: { _ in })
    }

    /// The canvas's grid, for expectations that mirror its rect math.
    private var grid: GridLayout { space.grid }

    /// The coordinator-side collaborators one placement needs. Records,
    /// expansion, and splitters live on the canvas now.
    private func context() -> TilingSpace.Context {
        TilingSpace.Context(
            gateway: gateway,
            frameWriter: writer,
            tracker: tracker,
            boundsOf: { $0 },
            space: .displayless,
            allocateID: { [weak self] _ in
                guard let self else { return 0 }
                let id: WindowID = self.nextID
                self.nextID += 1
                return id
            },
            log: { _ in })
    }

    @discardableResult
    private func addWindow(frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)) -> WindowID {
        let id: WindowID = nextID
        nextID += 1
        let handle = gateway.addWindow(frame: frame)
        handles[id] = handle
        space.attach(id, handle: handle)
        return id
    }

    /// Runs one decision through the canvas.
    private func run(
        _ decision: TilePlan, requester: WindowID, slot: Slot
    ) -> TilingSpace.Outcome {
        space.execute(
            decision: decision, requester: requester, slot: slot, context: context())
    }

    private func runUndo(
        snapshot: [EvictedWindow], requester: WindowID?
    ) -> TilingSpace.UndoOutcome {
        space.undo(snapshot: snapshot, requester: requester, context: context())
    }

    // MARK: Tile

    func testTilePlacesAndWritesFrame() {
        let id = addWindow()
        let initialFrame = gateway.frame(of: handles[id]!)!
        let expected = grid.rect(for: .topLeft, in: initialFrame)

        _ = run(.tile(evicting: []), requester: id, slot: .topLeft)

        XCTAssertNil(space.error)
        XCTAssertEqual(space.state.slot(of: id), .topLeft)
        XCTAssertNotEqual(space.records[id]?.preTileFrame, .zero)
        XCTAssertEqual(
            gateway.frame(of: handles[id]!), expected,
            "the tile writes the top-left quad of the window's own bounds")
    }

    func testTileRefusalRollsBackAndReports() {
        let id = addWindow()
        gateway.refuseNextWrites(handles[id]!)

        let outcome = run(.tile(evicting: []), requester: id, slot: .topLeft)

        XCTAssertNil(space.state.slot(of: id), "occupancy rolled back so state and screen agree")
        XCTAssertNotNil(space.error)
        XCTAssertEqual(outcome.result, .refused(windowName: "TestApp"))
    }

    func testTileOnAHiddenCanvasDefersTheWriteAndRollsBack() {
        let id = addWindow()
        canvasVisible = false

        let outcome = run(.tile(evicting: []), requester: id, slot: .topLeft)

        XCTAssertTrue(gateway.writes.isEmpty, "a hidden canvas is never written blind")
        XCTAssertNil(space.state.slot(of: id), "the placement rolls back rather than diverge")
        XCTAssertNotNil(space.error)
        XCTAssertEqual(outcome.result, .refused(windowName: "TestApp"))
    }

    func testEvictionRestoresPreTileFrame() {
        let a = addWindow()
        let original = CGRect(x: 10, y: 20, width: 300, height: 200)
        gateway.setFrame(handles[a]!, to: original)
        space.records[a]?.preTileFrame = original
        space.state.commit(window: a, into: .topLeft)
        let b = addWindow()

        _ = run(.tile(evicting: [a]), requester: b, slot: .topLeft)

        XCTAssertNil(space.error)
        XCTAssertNil(space.state.slot(of: a))
        XCTAssertEqual(
            gateway.frame(of: handles[a]!), original,
            "eviction writes the pre-tile frame back to the window")
    }

    func testPlainTileEvictionNoticesAndSnapshotsForUndo() {
        let a = addWindow()
        space.state.commit(window: a, into: .topLeft)
        let b = addWindow()

        _ = run(.tile(evicting: [a]), requester: b, slot: .topLeft)

        // Ordinary eviction gets the same narrative as a layout switch:
        // a notice naming the displaced app (not a count), plus the
        // shared one-step undo.
        XCTAssertEqual(
            space.notice,
            "TestApp went back to where it was. "
                + "Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo.")
        let chapter = space.undoStack.last
        XCTAssertNotNil(chapter, "the eviction is undoable like a switch")
        XCTAssertEqual(chapter?.snapshot.first?.slot, .topLeft)
        XCTAssertEqual(chapter?.requester, b)
    }

    func testPlainTileWithoutEvictionHasNoNoticeOrSnapshot() {
        let b = addWindow()

        _ = run(.tile(evicting: []), requester: b, slot: .topLeft)

        XCTAssertNil(space.notice, "nothing was displaced, nothing to narrate")
        XCTAssertTrue(space.undoStack.isEmpty)
    }

    // MARK: Swap

    func testSwapMovesBothWindowsAndKeepsThemTiled() {
        // The report's example: the top-left sixth swaps into the middle
        // third with the right two-thirds window; nobody is untiled.
        let a = addWindow()
        let b = addWindow()
        space.state.commit(window: a, into: .sixthTopLeft)
        space.state.commit(window: b, into: .sixthsRightTwoThirds)
        let aBounds = gateway.frame(of: handles[a]!)!
        let bBounds = gateway.frame(of: handles[b]!)!

        let outcome = run(.swap(displaced: b), requester: a, slot: .sixthMiddle)

        XCTAssertNil(space.error)
        XCTAssertEqual(outcome.result, .placed)
        XCTAssertEqual(space.state.slot(of: a), .sixthMiddle)
        XCTAssertEqual(
            space.state.slot(of: b), .sixthTopLeft,
            "the displaced window takes the tile the requester vacated")
        XCTAssertEqual(
            gateway.frame(of: handles[a]!),
            grid.rect(for: .sixthMiddle, in: aBounds))
        XCTAssertEqual(
            gateway.frame(of: handles[b]!),
            grid.rect(for: .sixthTopLeft, in: bBounds))
    }

    func testSwapKeepsBothPreTileFrames() {
        let a = addWindow()
        let b = addWindow()
        let aFrame = CGRect(x: 5, y: 6, width: 300, height: 200)
        let bFrame = CGRect(x: 7, y: 8, width: 280, height: 190)
        gateway.setFrame(handles[a]!, to: aFrame)
        gateway.setFrame(handles[b]!, to: bFrame)
        space.records[a]?.preTileFrame = aFrame
        space.records[b]?.preTileFrame = bFrame
        space.state.commit(window: a, into: .sixthTopLeft)
        space.state.commit(window: b, into: .sixthsRightTwoThirds)

        _ = run(.swap(displaced: b), requester: a, slot: .sixthMiddle)

        XCTAssertEqual(space.records[a]?.preTileFrame, aFrame)
        XCTAssertEqual(space.records[b]?.preTileFrame, bFrame)
    }

    func testSwapRefusalByDisplacedMovesNothing() {
        let a = addWindow()
        let b = addWindow()
        space.state.commit(window: a, into: .sixthTopLeft)
        space.state.commit(window: b, into: .sixthsRightTwoThirds)
        gateway.refuseNextWrites(handles[b]!)

        _ = run(.swap(displaced: b), requester: a, slot: .sixthMiddle)

        XCTAssertNotNil(space.error)
        XCTAssertEqual(space.state.slot(of: a), .sixthTopLeft, "the requester stays put")
        XCTAssertEqual(space.state.slot(of: b), .sixthsRightTwoThirds, "the displaced window stays put")
        XCTAssertTrue(space.undoStack.isEmpty)
    }

    func testSwapRefusalByRequesterRollsDisplacedBack() {
        let a = addWindow()
        let b = addWindow()
        space.state.commit(window: a, into: .sixthTopLeft)
        space.state.commit(window: b, into: .sixthsRightTwoThirds)
        gateway.refuseNextWrites(handles[a]!)

        _ = run(.swap(displaced: b), requester: a, slot: .sixthMiddle)

        XCTAssertNotNil(space.error)
        XCTAssertEqual(space.state.slot(of: a), .sixthTopLeft)
        XCTAssertEqual(space.state.slot(of: b), .sixthsRightTwoThirds, "rolled back to its own tile")
        // The displaced window's first write succeeded, so it visibly sits
        // in the requester's vacated tile unless the rollback writes it
        // home. State alone cannot see that: an unwritten rollback leaves
        // screen and state disagreeing while this test stays green.
        let stale = grid.rect(
            for: .sixthTopLeft, in: CGRect(x: 0, y: 0, width: 800, height: 600))
        let home = grid.rect(
            for: .sixthsRightTwoThirds, in: stale)
        XCTAssertEqual(
            gateway.frame(of: handles[b]!), home,
            "the displaced window is written back to its own tile")
    }

    func testSwapNoticesAndSnapshotsBothForUndo() {
        let a = addWindow()
        let b = addWindow()
        space.state.commit(window: a, into: .sixthTopLeft)
        space.state.commit(window: b, into: .sixthsRightTwoThirds)

        _ = run(.swap(displaced: b), requester: a, slot: .sixthMiddle)

        XCTAssertEqual(
            space.notice,
            "TestApp moved to Top Left Sixth to make room. "
                + "Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo.")
        XCTAssertEqual(space.undoStack.last?.requester, a)
        let snapshot = try! XCTUnwrap(space.undoStack.last?.snapshot)
        XCTAssertEqual(snapshot.count, 2, "both windows are undoable")
        XCTAssertTrue(
            snapshot.contains { $0.slot == .sixthsRightTwoThirds },
            "the displaced window's undo entry names its own former tile")
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
        let blocker = addWindow()
        let requester = addWindow()
        space.state.commit(window: blocker, into: .topLeft)

        // The requester holds no slot, so `.swap` is degenerate; the top
        // left overlaps the left half, so the blocker is evicted; and the
        // cells left free are exactly the right half, which is the slot a
        // re-house would have used. Marking the blocker expanded in the
        // canvas is the rule the fallback must honor.
        space.expanded[blocker] = .zero
        _ = run(
            .swap(displaced: blocker), requester: requester, slot: .leftHalf)

        XCTAssertNil(
            space.state.slot(of: blocker),
            "an expanded evictee is never re-housed, degenerate swap or not")
        XCTAssertEqual(space.state.slot(of: requester), .leftHalf)
    }

    /// The same shape without the expansion: the lone evictee is re-housed
    /// into the one whole slot the request left free, so the assertion
    /// above is the expanded-window exclusion and not a broken re-house.
    func testDegenerateSwapRehousesAnUnexpandedEvictee() {
        let blocker = addWindow()
        let requester = addWindow()
        space.state.commit(window: blocker, into: .topLeft)

        _ = run(.swap(displaced: blocker), requester: requester, slot: .leftHalf)

        XCTAssertEqual(space.state.slot(of: blocker), .rightHalf, "the lone evictee stays tiled")
        XCTAssertEqual(space.state.slot(of: requester), .leftHalf)
    }

    // MARK: Notice copy

    func testSwitchNoticeNamesLayoutCountAndUndoOffer() {
        let a = addWindow()
        let b = addWindow()
        space.state.commit(window: a, into: .topLeft)
        space.state.commit(window: b, into: .topRight)

        _ = run(
            .switchLayout(evicting: [a, b]), requester: b, slot: .sixthLeft)

        XCTAssertEqual(
            space.notice,
            "Switched to Sixths \u{00B7} 1 window untiled. "
                + "Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo.")
    }

    // MARK: Switch

    func testSwitchSnapshotsEvictedAndNotices() {
        let a = addWindow()
        let b = addWindow()
        space.state.commit(window: a, into: .topLeft)
        space.state.commit(window: b, into: .topRight)

        _ = run(
            .switchLayout(evicting: [a, b]), requester: b, slot: .sixthLeft)

        XCTAssertNil(space.error)
        XCTAssertNotNil(space.notice)
        XCTAssertEqual(space.undoStack.last?.snapshot.count, 1, "requester moves, not evicted")
        XCTAssertEqual(space.undoStack.last?.requester, b)
        XCTAssertEqual(space.state.slot(of: b), .sixthLeft)
        XCTAssertNil(space.state.slot(of: a), "evicted window restored (untiled)")
    }

    func testRestoreFailureLosesToNothingButWinsOverSilence() {
        let a = addWindow()
        space.state.commit(window: a, into: .topLeft)
        // Poison a's pre-tile frame restore: the gateway refuses the write.
        space.records[a]?.preTileFrame = CGRect(x: 10, y: 10, width: 100, height: 100)
        gateway.refuseNextWrites(handles[a]!)
        let b = addWindow()

        _ = run(
            .switchLayout(evicting: [a]), requester: b, slot: .sixthLeft)

        XCTAssertNotNil(space.error, "failed restore surfaces instead of silence")
        XCTAssertTrue(space.undoStack.isEmpty, "no undo when the switch didn't cleanly land")
        XCTAssertNil(space.notice)
        XCTAssertEqual(space.state.slot(of: b), .sixthLeft, "requester still lands in its slot")
    }

    // MARK: Undo

    func testUndoRestoresRequesterAndEvicted() {
        let a = addWindow()
        let b = addWindow()
        space.state.commit(window: a, into: .topLeft)
        space.state.commit(window: b, into: .topRight)
        _ = run(
            .switchLayout(evicting: [a, b]), requester: b, slot: .sixthLeft)
        guard let snapshot = space.undoStack.last?.snapshot else {
            return XCTFail("switch should snapshot")
        }

        let result = runUndo(snapshot: snapshot, requester: b)

        XCTAssertEqual(result.notice, "Undid displacement \u{00B7} 1 window restored.")
        XCTAssertNil(result.error)
        XCTAssertEqual(
            space.state.occupant(of: .topLeft).flatMap { space.records[$0]?.handle }, handles[a],
            "evicted window returns to its slot (under a fresh id; its record was pruned at switch)")
    }

    func testUndoAttemptsRestoreForBusyWindows() {
        // A busy app answers the liveness probe with unknown, never dead:
        // undo must still attempt the restore rather than silently skip a
        // maybe-alive window. (With the pre-tri-state `isAlive`, a transient
        // probe failure read as dead and the window was skipped entirely.)
        // Contrast testUndoSkipsDeadHandlesAndReports: same setup, but the
        // handle is busy instead of dead, so the restore lands.
        let a = addWindow()
        let b = addWindow()
        space.state.commit(window: a, into: .topLeft)
        space.state.commit(window: b, into: .topRight)
        _ = run(
            .switchLayout(evicting: [a, b]), requester: b, slot: .sixthLeft)
        guard let snapshot = space.undoStack.last?.snapshot else {
            return XCTFail("switch should snapshot")
        }
        gateway.busy.insert(handles[a]!)

        let result = runUndo(snapshot: snapshot, requester: b)

        XCTAssertNil(result.error)
        XCTAssertEqual(result.notice, "Undid displacement \u{00B7} 1 window restored.")
        XCTAssertEqual(
            space.state.occupant(of: .topLeft).flatMap { space.records[$0]?.handle },
            handles[a],
            "unknown liveness still restores the window to its slot")
    }

    func testUndoSkipsDeadHandlesAndReports() {
        let a = addWindow()
        let b = addWindow()
        space.state.commit(window: a, into: .topLeft)
        space.state.commit(window: b, into: .topRight)
        _ = run(
            .switchLayout(evicting: [a, b]), requester: b, slot: .sixthLeft)
        guard let snapshot = space.undoStack.last?.snapshot else {
            return XCTFail("switch should snapshot")
        }
        XCTAssertEqual(snapshot.count, 1, "requester moves, not evicted")
        gateway.kill(handles[a]!)

        let result = runUndo(snapshot: snapshot, requester: b)

        XCTAssertNil(result.notice)
        XCTAssertEqual(result.error, "Couldn't restore the evicted windows.")
        XCTAssertTrue(space.state.occupants.isEmpty,
            "dead evictee skipped; requester restored (untiled)")
    }

    func testUndoPluralNotice() {
        let a = addWindow()
        let b = addWindow()
        let c = addWindow()
        space.state.commit(window: a, into: .topLeft)
        space.state.commit(window: b, into: .topRight)

        _ = run(
            .switchLayout(evicting: [a, b, c]), requester: c, slot: .sixthLeft)
        guard let snapshot = space.undoStack.last?.snapshot else {
            return XCTFail("switch should snapshot")
        }
        XCTAssertEqual(snapshot.count, 2)

        let result = runUndo(snapshot: snapshot, requester: c)

        XCTAssertEqual(result.notice, "Undid displacement \u{00B7} 2 windows restored.")
    }

    func testUndoRetileRefusalDropsTheWindow() {
        let a = addWindow()
        let b = addWindow()
        space.state.commit(window: a, into: .topLeft)
        space.state.commit(window: b, into: .topRight)
        _ = run(
            .switchLayout(evicting: [a, b]), requester: b, slot: .sixthLeft)
        guard let snapshot = space.undoStack.last?.snapshot else {
            return XCTFail("switch should snapshot")
        }
        gateway.refuseNextWrites(handles[a]!)

        let result = runUndo(snapshot: snapshot, requester: b)

        XCTAssertEqual(result.error, "Couldn't restore the evicted windows.")
        XCTAssertTrue(space.state.occupants.isEmpty,
            "a refused re-tile releases the slot so state and screen agree")
        XCTAssertFalse(
            space.records.values.contains { $0.handle == handles[a] },
            "the refused window's fresh record is dropped, not left dangling")
    }

    func testUndoRetilesEvictedUnderCurrentGrid() {
        let a = addWindow()
        let b = addWindow()
        space.state.commit(window: a, into: .topLeft)
        space.state.commit(window: b, into: .topRight)
        _ = run(
            .switchLayout(evicting: [a, b]), requester: b, slot: .sixthLeft)
        guard let snapshot = space.undoStack.last?.snapshot else {
            return XCTFail("switch should snapshot")
        }
        // At undo time a's live frame is its restored pre-tile frame; the
        // re-tile target derives from the grid evaluated in that frame.
        let aRestoredFrame = gateway.frame(of: handles[a]!)!
        let expected = grid.rect(for: .topLeft, in: aRestoredFrame)

        let result = runUndo(snapshot: snapshot, requester: b)

        XCTAssertNil(result.error)
        XCTAssertEqual(
            gateway.frame(of: handles[a]!), expected,
            "undo writes the slot rect computed from the restored frame")
    }
}
