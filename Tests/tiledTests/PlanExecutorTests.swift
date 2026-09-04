import XCTest
@testable import tiled

/// PlanExecutor through its own interface: branch execution (tile, swap,
/// switch), refusal rollback, restore-failure precedence, and undo — with
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

        let outcome = commit(run(.tile(evicting: []), requester: id, slot: .topLeft))

        XCTAssertNil(outcome.error)
        XCTAssertEqual(state.slot(of: id), .topLeft)
        XCTAssertNotEqual(records[id]?.preTileFrame, .zero)
    }

    func testTileRefusalRollsBackAndReports() {
        let id = addWindow()
        gateway.refuseNextWrites(handles[id]!)

        let outcome = commit(run(.tile(evicting: []), requester: id, slot: .topLeft))

        XCTAssertNil(state.slot(of: id), "occupancy rolled back so state and screen agree")
        XCTAssertNotNil(outcome.error)
        XCTAssertNotNil(outcome.feedback)
    }

    // MARK: Swap

    func testSwapMovesBothWithoutEvicting() {
        let a = addWindow()
        let b = addWindow()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)

        let outcome = commit(run(
            .swap(placements: [a: .topRight, b: .topLeft]),
            requester: a, slot: .topRight))

        XCTAssertNil(outcome.error)
        XCTAssertEqual(state.slot(of: a), .topRight)
        XCTAssertEqual(state.slot(of: b), .topLeft)
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

        XCTAssertNil(error)
        XCTAssertNotNil(notice)
        XCTAssertEqual(state.occupant(of: .topLeft).flatMap { records[$0]?.handle }, handles[a],
            "evicted window returns to its slot (under a fresh id — its record was pruned at switch)")
    }
}
