import XCTest
@testable import tiled

/// PlanExecutor through its own interface: branch execution (tile, swap,
/// switch), refusal rollback, restore-failure precedence, and undo - with
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

    private func run(_ decision: TilePlan, requester: WindowID, slot: Slot)
        -> (PlanExecutor.Outcome, TilingState, [WindowID: WindowRecord], WindowID)
    {
        executor.execute(
            decision: decision, requester: requester, slot: slot,
            state: state, records: records, nextID: nextID,
            tracker: tracker,
            boundsOf: { $0 },
            observe: { [weak self] id in
                guard let handle = self?.records[id]?.handle else { return }
                self?.gateway.observe(handle, onChange: {})
            })
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

    // MARK: Swap

    func testSwapMovesBothWithoutEvicting() {
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)
        // Both windows still sit at their initial frames, so each write's
        // bounds resolve to the same rect and the quads are exact.
        let initial = gateway.frame(of: handles[a]!)!
        let aTarget = tracker.grid.rect(for: .topRight, in: initial)
        let bTarget = tracker.grid.rect(for: .topLeft, in: initial)

        let outcome = commit(run(
            .swap(placements: [a: .topRight, b: .topLeft]),
            requester: a, slot: .topRight))

        XCTAssertNil(outcome.error)
        XCTAssertEqual(state.slot(of: a), .topRight)
        XCTAssertEqual(state.slot(of: b), .topLeft)
        XCTAssertEqual(
            gateway.frame(of: handles[a]!), aTarget,
            "the requester lands in the top-right quad")
        XCTAssertEqual(
            gateway.frame(of: handles[b]!), bTarget,
            "the partner lands in the top-left quad")
    }

    // MARK: Swap refusals

    func testSwapRefusalRollsBackTheWholeExchange() {
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)
        let aOriginal = gateway.frame(of: handles[a]!)
        let bOriginal = gateway.frame(of: handles[b]!)
        gateway.refuseNextWrites(handles[a]!)

        let outcome = commit(run(
            .swap(placements: [a: .topRight, b: .topLeft]),
            requester: a, slot: .topRight))

        XCTAssertEqual(
            outcome.error, "TestApp couldn't be swapped - the app refused to resize it.")
        XCTAssertNotNil(outcome.feedback)
        if case .refused(let name) = outcome.feedback {
            // Same failure class as a tile refusal, same attribution: the
            // announcement must name the app, never "That window" for a swap.
            XCTAssertEqual(name, "TestApp")
        } else {
            XCTFail("swap refusal must carry named feedback")
        }
        // A swap is atomic: a refused exchange moves nobody. b's write to
        // top left succeeded, but the rollback returns it - otherwise a
        // (still at top left's pixels) and b would stack in one tile.
        XCTAssertEqual(state.slot(of: a), .topLeft)
        XCTAssertEqual(state.slot(of: b), .topRight)
        XCTAssertEqual(gateway.frame(of: handles[a]!), aOriginal)
        XCTAssertEqual(gateway.frame(of: handles[b]!), bOriginal)
    }

    func testFailedRollbackSurfacesItsOwnError() {
        // A refusal stacked on a refusal: a refuses its swap write (calling
        // the exchange off) AND its own rollback write. The transient class
        // is already retried at the gateway, so this is a hard refusal -
        // the plain refusal message would understate it: a's restore never
        // landed, so state and screen may disagree. The error must say so.
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)
        let bOriginal = gateway.frame(of: handles[b]!)
        gateway.refuseNextWrites(handles[a]!, count: 5)

        let outcome = commit(run(
            .swap(placements: [a: .topRight, b: .topLeft]),
            requester: a, slot: .topRight))

        // State keeps the pre-swap slots either way (the exchange was
        // called off); b's rollback succeeded so b matches its slot.
        XCTAssertEqual(state.slot(of: a), .topLeft)
        XCTAssertEqual(state.slot(of: b), .topRight)
        XCTAssertEqual(gateway.frame(of: handles[b]!), bOriginal, "b's rollback succeeded")
        XCTAssertEqual(
            outcome.error,
            "The swap was refused, and TestApp couldn't be moved back - it may be in the wrong tile.")
    }

    func testSwapPartnerSilentlyIgnoringCommitsWithoutError() {
        // The dominant real-world refusal shape: the gateway reports
        // success but the app never moves. The executor trusts the
        // write result, so the exchange commits with no error at write
        // time - the controller's late verification (fired here manually
        // via the injectable scheduler in controller tests) rolls the
        // ignored window back. Pinned at this level so the write-time
        // trust is visible; see ControllerGatewayTests for the rollback.
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)
        let bOriginal = gateway.frame(of: handles[b]!)
        gateway.silentIgnore.insert(handles[b]!)

        let outcome = commit(run(
            .swap(placements: [a: .topRight, b: .topLeft]),
            requester: a, slot: .topRight))

        XCTAssertNil(outcome.error, "the write 'succeeded'")
        XCTAssertEqual(state.slot(of: a), .topRight)
        XCTAssertEqual(state.slot(of: b), .topLeft)
        XCTAssertEqual(
            gateway.frame(of: handles[b]!), bOriginal,
            "the partner never moved; screen and state disagree")
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
            "evicted window returns to its slot (under a fresh id - its record was pruned at switch)")
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

    func testSwapRefusalPluralMessage() {
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)
        gateway.refuseNextWrites(handles[a]!)
        gateway.refuseNextWrites(handles[b]!)

        let outcome = commit(run(
            .swap(placements: [a: .topRight, b: .topLeft]),
            requester: a, slot: .topRight))

        XCTAssertEqual(
            outcome.error, "TestApp and 1 more couldn't be swapped - an app refused to resize.")
        // Atomic: both writes refused, nothing moved at all.
        XCTAssertEqual(state.slot(of: a), .topLeft)
        XCTAssertEqual(state.slot(of: b), .topRight)
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
