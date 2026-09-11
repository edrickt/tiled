import XCTest
@testable import tiled

/// PlanExecutor through its own interface: branch execution (tile,
/// switch), refusal rollback, restore-failure precedence, and undo, with
/// a fake gateway and a real DragTracker. No controller, no AX.
final class PlanExecutorTests: XCTestCase {
    private var gateway: FakeWindowGateway!
    private var tracker: DragTracker!
    private var executor: PlanExecutor!
    private var state: TilingState!
    private var records: [WindowID: WindowRecord]!
    private var handles: [WindowID: WindowHandle]!
    private var nextID: WindowID!

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        state = TilingState()
        records = [:]
        handles = [:]
        nextID = 1
        tracker = DragTracker(
            context: DragTracker.Context(
                slotOf: { [weak self] in self?.state.slot(of: $0) ?? nil },
                frameOf: { [weak self] in
                    guard let self, let handle = self.handles[$0] else { return nil }
                    return self.gateway.frame(of: handle)
                        ?? self.records[$0]?.preTileFrame
                },
                boundsOf: { $0 },
                occupants: { [weak self] in self?.state.occupants ?? [:] }),
            apply: { _, _ in 0 })
        executor = PlanExecutor(gateway: gateway)
    }

    @discardableResult
    private func addWindow(frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)) -> WindowID {
        let id: WindowID = nextID
        nextID += 1
        let handle = gateway.addWindow(frame: frame)
        handles[id] = handle
        records[id] = WindowRecord(handle: handle, preTileFrame: .zero)
        return id
    }

    private func run(
        _ decision: TilePlan, requester: WindowID, slot: Slot,
        isExpanded: @escaping (WindowID) -> Bool = { _ in false }
    ) -> (PlanExecutor.Outcome, TilingState, [WindowID: WindowRecord], WindowID) {
        executor.execute(
            decision: decision, requester: requester, slot: slot,
            state: state, records: records, nextID: nextID,
            tracker: tracker,
            boundsOf: { $0 },
            observe: { [weak self] id in
                guard let handle = self?.records[id]?.handle else { return }
                self?.gateway.observe(handle, onChange: {})
            },
            isExpanded: isExpanded)
    }

    private func commit(_ result: (PlanExecutor.Outcome, TilingState, [WindowID: WindowRecord], WindowID))
        -> PlanExecutor.Outcome
    {
        state = result.1
        records = result.2
        nextID = result.3
        // Sync the handle map for ids the executor created (undo restores
        // pruned handles under fresh ids).
        for (id, record) in records where handles[id] == nil {
            handles[id] = record.handle
        }
        return result.0
    }

    // MARK: Tile

    func testTilePlacesAndWritesFrame() {
        let id = addWindow()
        let initialFrame = gateway.frame(of: handles[id]!)!
        let expected = tracker.grid.rect(for: .topLeft, in: initialFrame)

        let outcome = commit(run(.tile(evicting: []), requester: id, slot: .topLeft))

        XCTAssertNil(outcome.error)
        XCTAssertEqual(state.slot(of: id), .topLeft)
        XCTAssertNotEqual(records[id]?.preTileFrame, .zero)
        XCTAssertEqual(
            gateway.frame(of: handles[id]!), expected,
            "the tile writes the top-left quad of the window's own bounds")
    }

    func testTileRefusalRollsBackAndReports() {
        let id = addWindow()
        gateway.refuseNextWrites(handles[id]!)

        let outcome = commit(run(.tile(evicting: []), requester: id, slot: .topLeft))

        XCTAssertNil(state.slot(of: id), "occupancy rolled back so state and screen agree")
        XCTAssertNotNil(outcome.error)
        XCTAssertNotNil(outcome.feedback)
    }

    func testEvictionRestoresPreTileFrame() {
        let a = addWindow()
        let original = CGRect(x: 10, y: 20, width: 300, height: 200)
        gateway.setFrame(handles[a]!, to: original)
        records[a]?.preTileFrame = original
        state.commit(window: a, into: .topLeft)
        let b = addWindow()

        let outcome = commit(run(.tile(evicting: [a]), requester: b, slot: .topLeft))

        XCTAssertNil(outcome.error)
        XCTAssertNil(state.slot(of: a))
        XCTAssertEqual(
            gateway.frame(of: handles[a]!), original,
            "eviction writes the pre-tile frame back to the window")
    }

    func testPlainTileEvictionNoticesAndSnapshotsForUndo() {
        let a = addWindow()
        state.commit(window: a, into: .topLeft)
        let b = addWindow()

        let outcome = commit(run(.tile(evicting: [a]), requester: b, slot: .topLeft))

        // Ordinary eviction gets the same narrative as a layout switch:
        // a notice naming the displaced app (not a count), plus the
        // shared one-step undo.
        XCTAssertEqual(
            outcome.notice,
            "TestApp went back to where it was. "
                + "Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo.")
        XCTAssertNotNil(outcome.snapshot, "the eviction is undoable like a switch")
        XCTAssertEqual(outcome.snapshot?.first?.slot, .topLeft)
        XCTAssertEqual(outcome.requester, b)
    }

    func testPlainTileWithoutEvictionHasNoNoticeOrSnapshot() {
        let b = addWindow()

        let outcome = commit(run(.tile(evicting: []), requester: b, slot: .topLeft))

        XCTAssertNil(outcome.notice, "nothing was displaced, nothing to narrate")
        XCTAssertNil(outcome.snapshot)
    }

    // MARK: Swap

    func testSwapMovesBothWindowsAndKeepsThemTiled() {
        // The report's example: the top-left sixth swaps into the middle
        // third with the right two-thirds window; nobody is untiled.
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: b, into: .sixthsRightTwoThirds)
        let aBounds = gateway.frame(of: handles[a]!)!
        let bBounds = gateway.frame(of: handles[b]!)!

        let outcome = commit(run(.swap(displaced: b), requester: a, slot: .sixthMiddle))

        XCTAssertNil(outcome.error)
        XCTAssertNil(outcome.feedback)
        XCTAssertEqual(state.slot(of: a), .sixthMiddle)
        XCTAssertEqual(
            state.slot(of: b), .sixthTopLeft,
            "the displaced window takes the tile the requester vacated")
        XCTAssertEqual(
            gateway.frame(of: handles[a]!),
            tracker.grid.rect(for: .sixthMiddle, in: aBounds))
        XCTAssertEqual(
            gateway.frame(of: handles[b]!),
            tracker.grid.rect(for: .sixthTopLeft, in: bBounds))
    }

    func testSwapKeepsBothPreTileFrames() {
        let a = addWindow()
        let b = addWindow()
        let aFrame = CGRect(x: 5, y: 6, width: 300, height: 200)
        let bFrame = CGRect(x: 7, y: 8, width: 280, height: 190)
        gateway.setFrame(handles[a]!, to: aFrame)
        gateway.setFrame(handles[b]!, to: bFrame)
        records[a]?.preTileFrame = aFrame
        records[b]?.preTileFrame = bFrame
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: b, into: .sixthsRightTwoThirds)

        _ = commit(run(.swap(displaced: b), requester: a, slot: .sixthMiddle))

        XCTAssertEqual(records[a]?.preTileFrame, aFrame)
        XCTAssertEqual(records[b]?.preTileFrame, bFrame)
    }

    func testSwapRefusalByDisplacedMovesNothing() {
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: b, into: .sixthsRightTwoThirds)
        gateway.refuseNextWrites(handles[b]!)

        let outcome = commit(run(.swap(displaced: b), requester: a, slot: .sixthMiddle))

        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(state.slot(of: a), .sixthTopLeft, "the requester stays put")
        XCTAssertEqual(state.slot(of: b), .sixthsRightTwoThirds, "the displaced window stays put")
        XCTAssertNil(outcome.snapshot)
    }

    func testSwapRefusalByRequesterRollsDisplacedBack() {
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: b, into: .sixthsRightTwoThirds)
        gateway.refuseNextWrites(handles[a]!)

        let outcome = commit(run(.swap(displaced: b), requester: a, slot: .sixthMiddle))

        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(state.slot(of: a), .sixthTopLeft)
        XCTAssertEqual(state.slot(of: b), .sixthsRightTwoThirds, "rolled back to its own tile")
        // The displaced window's first write succeeded, so it visibly sits
        // in the requester's vacated tile unless the rollback writes it
        // home. State alone cannot see that: an unwritten rollback leaves
        // screen and state disagreeing while this test stays green.
        let stale = tracker.grid(for: nil).rect(
            for: .sixthTopLeft, in: CGRect(x: 0, y: 0, width: 800, height: 600))
        let home = tracker.grid(for: nil).rect(
            for: .sixthsRightTwoThirds, in: stale)
        XCTAssertEqual(
            gateway.frame(of: handles[b]!), home,
            "the displaced window is written back to its own tile")
    }

    func testSwapNoticesAndSnapshotsBothForUndo() {
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: b, into: .sixthsRightTwoThirds)

        let outcome = commit(run(.swap(displaced: b), requester: a, slot: .sixthMiddle))

        XCTAssertEqual(
            outcome.notice,
            "TestApp moved to Top Left Sixth to make room. "
                + "Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo.")
        XCTAssertEqual(outcome.requester, a)
        let snapshot = try! XCTUnwrap(outcome.snapshot)
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
        state.commit(window: blocker, into: .topLeft)

        // The requester holds no slot, so `.swap` is degenerate; the top
        // left overlaps the left half, so the blocker is evicted; and the
        // cells left free are exactly the right half, which is the slot a
        // re-house would have used.
        let outcome = commit(
            run(
                .swap(displaced: blocker), requester: requester, slot: .leftHalf,
                isExpanded: { $0 == blocker }))

        XCTAssertNil(
            outcome.rehoused,
            "an expanded evictee is never re-housed, degenerate swap or not")
        XCTAssertNil(state.slot(of: blocker), "the expanded blocker untangles")
        XCTAssertEqual(state.slot(of: requester), .leftHalf)
    }

    /// The same shape without the expansion: the lone evictee is re-housed
    /// into the one whole slot the request left free, so the assertion
    /// above is the expanded-window exclusion and not a broken re-house.
    func testDegenerateSwapRehousesAnUnexpandedEvictee() {
        let blocker = addWindow()
        let requester = addWindow()
        state.commit(window: blocker, into: .topLeft)

        let outcome = commit(
            run(.swap(displaced: blocker), requester: requester, slot: .leftHalf))

        XCTAssertEqual(outcome.rehoused, blocker, "the lone evictee stays tiled")
        XCTAssertEqual(state.slot(of: blocker), .rightHalf)
        XCTAssertEqual(state.slot(of: requester), .leftHalf)
    }

    // MARK: Notice copy

    func testSwitchNoticeNamesLayoutCountAndUndoOffer() {
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)

        let outcome = commit(run(
            .switchLayout(evicting: [a, b]), requester: b, slot: .sixthLeft))

        XCTAssertEqual(
            outcome.notice,
            "Switched to Sixths \u{00B7} 1 window untiled. "
                + "Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo.")
    }

    // MARK: Switch

    func testSwitchSnapshotsEvictedAndNotices() {
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)

        let outcome = commit(run(
            .switchLayout(evicting: [a, b]), requester: b, slot: .sixthLeft))

        XCTAssertNil(outcome.error)
        XCTAssertNotNil(outcome.notice)
        XCTAssertEqual(outcome.snapshot?.count, 1, "requester moves, not evicted")
        XCTAssertEqual(outcome.requester, b)
        XCTAssertEqual(state.slot(of: b), .sixthLeft)
        XCTAssertNil(state.slot(of: a), "evicted window restored (untiled)")
    }

    func testRestoreFailureLosesToNothingButWinsOverSilence() {
        let a = addWindow()
        state.commit(window: a, into: .topLeft)
        // Poison a's pre-tile frame restore: the gateway refuses the write.
        records[a]?.preTileFrame = CGRect(x: 10, y: 10, width: 100, height: 100)
        gateway.refuseNextWrites(handles[a]!)
        let b = addWindow()

        let outcome = commit(run(
            .switchLayout(evicting: [a]), requester: b, slot: .sixthLeft))

        XCTAssertNotNil(outcome.error, "failed restore surfaces instead of silence")
        XCTAssertNil(outcome.snapshot, "no undo when the switch didn't cleanly land")
        XCTAssertNil(outcome.notice)
        XCTAssertEqual(state.slot(of: b), .sixthLeft, "requester still lands in its slot")
    }

    // MARK: Undo

    func testUndoRestoresRequesterAndEvicted() {
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)
        let outcome = commit(run(
            .switchLayout(evicting: [a, b]), requester: b, slot: .sixthLeft))
        guard let snapshot = outcome.snapshot else {
            return XCTFail("switch should snapshot")
        }

        let (notice, error, newState, newRecords, newNextID) = executor.undo(
            snapshot: snapshot, requester: outcome.requester,
            state: state, records: records, nextID: nextID, tracker: tracker,
            boundsOf: { $0 },
            observe: { [weak self] id in
                guard let handle = self?.records[id]?.handle else { return }
                self?.gateway.observe(handle, onChange: {})
            })
        state = newState
        records = newRecords
        nextID = newNextID

        XCTAssertEqual(notice, "Undid displacement \u{00B7} 1 window restored.")
        XCTAssertNil(error)
        XCTAssertEqual(state.occupant(of: .topLeft).flatMap { records[$0]?.handle }, handles[a],
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
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)
        let outcome = commit(run(
            .switchLayout(evicting: [a, b]), requester: b, slot: .sixthLeft))
        guard let snapshot = outcome.snapshot else {
            return XCTFail("switch should snapshot")
        }
        gateway.busy.insert(handles[a]!)

        let result = executor.undo(
            snapshot: snapshot, requester: outcome.requester,
            state: state, records: records, nextID: nextID, tracker: tracker,
            boundsOf: { $0 }, observe: { _ in })

        XCTAssertNil(result.error)
        XCTAssertEqual(result.notice, "Undid displacement \u{00B7} 1 window restored.")
        XCTAssertEqual(
            result.state.occupant(of: .topLeft).flatMap { result.3[$0]?.handle },
            handles[a],
            "unknown liveness still restores the window to its slot")
    }

    func testUndoSkipsDeadHandlesAndReports() {
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)
        let outcome = commit(run(
            .switchLayout(evicting: [a, b]), requester: b, slot: .sixthLeft))
        guard let snapshot = outcome.snapshot else {
            return XCTFail("switch should snapshot")
        }
        XCTAssertEqual(snapshot.count, 1, "requester moves, not evicted")
        gateway.kill(handles[a]!)

        let result = executor.undo(
            snapshot: snapshot, requester: outcome.requester,
            state: state, records: records, nextID: nextID, tracker: tracker,
            boundsOf: { $0 }, observe: { _ in })

        XCTAssertNil(result.notice)
        XCTAssertEqual(result.error, "Couldn't restore the evicted windows.")
        XCTAssertTrue(result.state.occupants.isEmpty,
            "dead evictee skipped; requester restored (untiled)")
    }

    func testUndoPluralNotice() {
        let a = addWindow()
        let b = addWindow()
        let c = addWindow()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)

        let outcome = commit(run(
            .switchLayout(evicting: [a, b, c]), requester: c, slot: .sixthLeft))
        guard let snapshot = outcome.snapshot else {
            return XCTFail("switch should snapshot")
        }
        XCTAssertEqual(snapshot.count, 2)

        let result = executor.undo(
            snapshot: snapshot, requester: outcome.requester,
            state: state, records: records, nextID: nextID, tracker: tracker,
            boundsOf: { $0 }, observe: { _ in })

        XCTAssertEqual(result.notice, "Undid displacement \u{00B7} 2 windows restored.")
    }

    func testUndoRetileRefusalDropsTheWindow() {
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)
        let outcome = commit(run(
            .switchLayout(evicting: [a, b]), requester: b, slot: .sixthLeft))
        guard let snapshot = outcome.snapshot else {
            return XCTFail("switch should snapshot")
        }
        gateway.refuseNextWrites(handles[a]!)

        let result = executor.undo(
            snapshot: snapshot, requester: outcome.requester,
            state: state, records: records, nextID: nextID, tracker: tracker,
            boundsOf: { $0 }, observe: { _ in })

        XCTAssertEqual(result.error, "Couldn't restore the evicted windows.")
        XCTAssertTrue(result.state.occupants.isEmpty,
            "a refused re-tile releases the slot so state and screen agree")
        XCTAssertFalse(
            result.records.values.contains { $0.handle == handles[a] },
            "the refused window's fresh record is dropped, not left dangling")
    }

    func testUndoRetilesEvictedUnderCurrentGrid() {
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)
        let outcome = commit(run(
            .switchLayout(evicting: [a, b]), requester: b, slot: .sixthLeft))
        guard let snapshot = outcome.snapshot else {
            return XCTFail("switch should snapshot")
        }
        // At undo time a's live frame is its restored pre-tile frame; the
        // re-tile target derives from the grid evaluated in that frame.
        let aRestoredFrame = gateway.frame(of: handles[a]!)!
        let expected = tracker.grid.rect(for: .topLeft, in: aRestoredFrame)

        let result = executor.undo(
            snapshot: snapshot, requester: outcome.requester,
            state: state, records: records, nextID: nextID, tracker: tracker,
            boundsOf: { $0 },
            observe: { [weak self] id in
                guard let handle = self?.records[id]?.handle else { return }
                self?.gateway.observe(handle, onChange: {})
            })

        XCTAssertNil(result.error)
        XCTAssertEqual(
            gateway.frame(of: handles[a]!), expected,
            "undo writes the slot rect computed from the restored frame")
    }
}
