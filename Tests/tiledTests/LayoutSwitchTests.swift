import XCTest
@testable import tiled

/// Exhaustive coverage for layout switching: quarters <-> sixths are
/// mutually exclusive on screen, so any request into the non-active layout
/// (with a non-empty space) must reset — evict EVERY tiled window, switch,
/// and place exactly the requester. These tests pin that contract from
/// every angle: full slot matrices, every occupancy shape, commit
/// semantics, ordering, sequences, and a cross-layout BFS invariant sweep.
final class LayoutSwitchTests: XCTestCase {
    private static var quartersSlots: [Slot] {
        Slot.allCases.filter { $0.layout == .quarters }
    }

    private static var sixthsSlots: [Slot] {
        Slot.allCases.filter { $0.layout == .sixths }
    }

    /// Representative occupancy shapes per layout: singles of every size
    /// class, pairs, full grids, and mixed compositions.
    private static var quartersConfigs: [[Slot]] {
        [
            [.topLeft],
            [.bottomRight],
            [.leftHalf],
            [.rightHalf],
            [.topLeft, .bottomRight],
            [.leftHalf, .topRight],
            [.leftHalf, .rightHalf],
            [.topLeft, .bottomLeft],
            [.topLeft, .topRight, .bottomLeft, .bottomRight],
            [.leftHalf, .topRight, .bottomRight],
            [.rightHalf, .topLeft, .bottomLeft],
        ]
    }

    private static var sixthsConfigs: [[Slot]] {
        [
            [.sixthTopLeft], // single corner (1 cell)
            [.sixthTopMiddle], // single middle (2 cells)
            [.sixthMiddle], // single third (4 cells)
            [.sixthsLeftTwoThirds], // single two-thirds (6 cells)
            [.sixthLeft, .sixthRight],
            [.sixthTopLeft, .sixthBottomRight],
            [.sixthLeft, .sixthMiddle, .sixthRight],
            [.sixthsLeftTwoThirds, .sixthRight],
            [.sixthsRightTwoThirds, .sixthLeft],
            [.sixthTopLeft, .sixthTopMiddle, .sixthTopRight],
            [
                .sixthTopLeft, .sixthTopMiddle, .sixthTopRight,
                .sixthBottomLeft, .sixthBottomMiddle, .sixthBottomRight,
            ],
            [.sixthLeft, .sixthTopMiddle, .sixthTopRight,
             .sixthBottomMiddle, .sixthBottomRight],
        ]
    }

    /// Builds a state with `slots` occupied by consecutive window ids.
    private func makeState(slots: [Slot], firstID: WindowID = 1) -> (TilingState, [WindowID]) {
        var state = TilingState()
        var ids: [WindowID] = []
        for (index, slot) in slots.enumerated() {
            let id = firstID + index
            state.commit(window: id, into: slot)
            ids.append(id)
        }
        return (state, ids)
    }

    /// Commits a plan exactly like TilingController.handle does: evicted
    /// windows are removed before the requester is placed.
    private func apply(
        _ plan: TilePlan, to state: inout TilingState, requester: WindowID, target: Slot
    ) {
        switch plan {
        case .noop:
            break // no state change
        case .swap(let placements):
            state.commitSwaps(placements)
        case .tile(let evicting), .switchLayout(let evicting):
            for evicted in evicting { state.remove(window: evicted) }
            state.commit(window: requester, into: target)
        }
    }

    /// Structural health after any transition: no ghosts, at most one
    /// layout on screen, no cell double-booked, activeLayout agrees.
    private func assertHealthy(
        _ state: TilingState, context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            Set(state.tiledWindows), Set(state.occupants.values),
            "\(context): ghost occupant", file: file, line: line)
        let layouts = Set(state.occupants.keys.map(\.layout))
        XCTAssertLessThanOrEqual(
            layouts.count, 1, "\(context): mixed layouts on screen",
            file: file, line: line)
        if let only = state.occupants.keys.first {
            XCTAssertEqual(
                state.activeLayout, only.layout,
                "\(context): activeLayout disagrees", file: file, line: line)
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

    // MARK: Empty space never switches

    func testEmptySpaceNeverSwitches() {
        // The empty space defaults to quarters, but even a sixths request
        // is a plain tile — there is nothing to evict and no layout to leave.
        for slot in Slot.allCases {
            XCTAssertEqual(
                TilingState().plan(window: 1, into: slot), .tile(evicting: []),
                "empty -> \(slot.rawValue)")
        }
    }

    func testFirstTileIntoSixthsSetsLayoutWithoutEviction() {
        var state = TilingState()
        XCTAssertEqual(state.activeLayout, .quarters)
        XCTAssertEqual(state.plan(window: 7, into: .sixthTopLeft), .tile(evicting: []))
        state.commit(window: 7, into: .sixthTopLeft)
        XCTAssertEqual(state.occupants, [.sixthTopLeft: 7])
        XCTAssertEqual(state.activeLayout, .sixths)
        assertHealthy(state, context: "first tile sixths")
    }

    func testEmptiedSpaceReturnsToQuartersDefault() {
        var state = TilingState()
        state.commit(window: 1, into: .sixthMiddle)
        XCTAssertEqual(state.activeLayout, .sixths)
        state.remove(window: 1)
        XCTAssertTrue(state.occupants.isEmpty)
        XCTAssertEqual(state.activeLayout, .quarters)
        // And a quarters tile from there is again a plain tile.
        XCTAssertEqual(state.plan(window: 2, into: .topLeft), .tile(evicting: []))
    }

    // MARK: Single-window switch matrix (every slot both directions)

    func testSingleQuartersWindowSwitchesToEverySixthsSlot() {
        for from in Self.quartersSlots {
            for target in Self.sixthsSlots {
                let (state, ids) = makeState(slots: [from], firstID: 5)
                XCTAssertEqual(
                    state.plan(window: ids[0], into: target),
                    .switchLayout(evicting: ids),
                    "\(from.rawValue) -> \(target.rawValue) (tiled requester)")
                let fresh = 99
                XCTAssertEqual(
                    state.plan(window: fresh, into: target),
                    .switchLayout(evicting: ids),
                    "\(from.rawValue) -> \(target.rawValue) (fresh requester)")
            }
        }
    }

    func testSingleSixthsWindowSwitchesToEveryQuartersSlot() {
        for from in Self.sixthsSlots {
            for target in Self.quartersSlots {
                let (state, ids) = makeState(slots: [from], firstID: 5)
                XCTAssertEqual(
                    state.plan(window: ids[0], into: target),
                    .switchLayout(evicting: ids),
                    "\(from.rawValue) -> \(target.rawValue) (tiled requester)")
                let fresh = 99
                XCTAssertEqual(
                    state.plan(window: fresh, into: target),
                    .switchLayout(evicting: ids),
                    "\(from.rawValue) -> \(target.rawValue) (fresh requester)")
            }
        }
    }

    // MARK: The switch ignores cell overlap entirely

    func testDisjointCrossLayoutPairStillResets() {
        // TL covers col0-1/top; sixthBottomRight is col3/bottom: disjoint.
        XCTAssertTrue(Slot.topLeft.cells.isDisjoint(with: Slot.sixthBottomRight.cells))
        var state = TilingState()
        state.commit(window: 1, into: .topLeft)
        XCTAssertEqual(state.plan(window: 2, into: .sixthBottomRight), .switchLayout(evicting: [1]))
        // Same in reverse: a lone corner never overlaps a far quad.
        XCTAssertTrue(Slot.sixthTopLeft.cells.isDisjoint(with: Slot.bottomRight.cells))
        var other = TilingState()
        other.commit(window: 1, into: .sixthTopLeft)
        XCTAssertEqual(other.plan(window: 2, into: .bottomRight), .switchLayout(evicting: [1]))
    }

    func testOverlappingCrossLayoutPairResetsJustTheSame() {
        // TL fully contains sixthTopLeft's cell — still a full reset, never
        // a swap or a partial eviction of "just the overlap".
        XCTAssertFalse(Slot.topLeft.cells.isDisjoint(with: Slot.sixthTopLeft.cells))
        var state = TilingState()
        state.commit(window: 1, into: .topLeft)
        let plan = state.plan(window: 2, into: .sixthTopLeft)
        XCTAssertEqual(plan, .switchLayout(evicting: [1]))
        // And the tiled window itself fares no better.
        XCTAssertEqual(state.plan(window: 1, into: .sixthTopLeft), .switchLayout(evicting: [1]))
    }

    func testSwitchNeverReturnsTileSwapOrNoop() {
        // Across every occupancy shape, a cross-layout request must be a
        // switchLayout — never a same-layout tile/swap leaking through.
        for config in Self.quartersConfigs {
            let (state, _) = makeState(slots: config, firstID: 10)
            for target in Self.sixthsSlots {
                let plan = state.plan(window: 999, into: target)
                guard case .switchLayout(let evicting) = plan else {
                    XCTFail("\(config) -> \(target.rawValue): got \(plan), want switchLayout")
                    continue
                }
                XCTAssertEqual(evicting, state.tiledWindows.sorted())
            }
        }
        for config in Self.sixthsConfigs {
            let (state, _) = makeState(slots: config, firstID: 10)
            for target in Self.quartersSlots {
                let plan = state.plan(window: 999, into: target)
                guard case .switchLayout(let evicting) = plan else {
                    XCTFail("\(config) -> \(target.rawValue): got \(plan), want switchLayout")
                    continue
                }
                XCTAssertEqual(evicting, state.tiledWindows.sorted())
            }
        }
    }

    // MARK: Eviction set semantics

    func testTiledRequesterIsAlwaysInItsOwnEvictionSet() {
        // Whatever tiled window asks for the other layout joins the evicted
        // set — otherwise it would survive the reset and straddle layouts.
        for config in Self.quartersConfigs {
            let (state, ids) = makeState(slots: config, firstID: 1)
            for requester in ids {
                let plan = state.plan(window: requester, into: .sixthMiddle)
                XCTAssertEqual(
                    plan, .switchLayout(evicting: ids.sorted()),
                    "\(config) requester=\(requester)")
            }
        }
        for config in Self.sixthsConfigs {
            let (state, ids) = makeState(slots: config, firstID: 1)
            for requester in ids {
                let plan = state.plan(window: requester, into: .topLeft)
                XCTAssertEqual(
                    plan, .switchLayout(evicting: ids.sorted()),
                    "\(config) requester=\(requester)")
            }
        }
    }

    func testFreshRequesterEvictsEveryoneButItself() {
        // An untiled window vacates nothing and is in no slot: the eviction
        // set is exactly the tiled set, never containing the fresh id.
        for config in Self.quartersConfigs + Self.sixthsConfigs {
            let (state, ids) = makeState(slots: config, firstID: 1)
            let fresh = 500
            let target: Slot = config[0].layout == .quarters ? .sixthMiddle : .topLeft
            guard case .switchLayout(let evicting) = state.plan(window: fresh, into: target) else {
                XCTFail("\(config) -> \(target.rawValue) did not switch")
                continue
            }
            XCTAssertEqual(evicting, ids.sorted())
            XCTAssertFalse(evicting.contains(fresh))
        }
    }

    func testWindowsToRestoreExcludesRequesterOnSwitchButKeepsEvictions() {
        // The controller restores exactly this list before placing: the
        // requester must survive so its record (and pre-tile frame) is
        // still there when `place` runs.
        let tiled: TilePlan = .switchLayout(evicting: [1, 2, 3])
        XCTAssertEqual(tiled.windowsToRestore(requester: 2), [1, 3])
        // Untiled requester: nothing to spare, full list restored.
        XCTAssertEqual(tiled.windowsToRestore(requester: 99), [1, 2, 3])
        // .tile never names the requester, so the filter is a no-op there.
        XCTAssertEqual(TilePlan.tile(evicting: [1, 3]).windowsToRestore(requester: 2), [1, 3])
        XCTAssertEqual(TilePlan.tile(evicting: []).windowsToRestore(requester: 1), [])
        // .swap/.noop restore nothing.
        XCTAssertEqual(
            TilePlan.swap(placements: [1: .topLeft]).windowsToRestore(requester: 1), [])
        XCTAssertEqual(TilePlan.noop.windowsToRestore(requester: 1), [])
    }

    func testTiledRequesterSurvivesSwitchWithRecordIntact() {
        // Regression test for the reported bug: A=TL-sixth, B=BL-sixth,
        // C=right-two-thirds, then C requests RightHalf. Restoring exactly
        // `windowsToRestore` (not the raw evicting list, which includes C)
        // leaves C's slot claimed until `place` moves it, and the end state
        // is exactly the requester in its new tile.
        var occupancy = TilingState()
        occupancy.commit(window: 1, into: .sixthTopLeft)
        occupancy.commit(window: 2, into: .sixthBottomLeft)
        occupancy.commit(window: 3, into: .sixthsRightTwoThirds)
        let requester = 3
        let target = Slot.rightHalf
        let plan = occupancy.plan(window: requester, into: target)
        XCTAssertEqual(plan, .switchLayout(evicting: [1, 2, 3]))
        // Simulate the controller: restore the filtered list, then place.
        // Evicted windows are released; the requester must still hold its
        // old tile right up to the commit (its record survives with it).
        var next = occupancy
        for evicted in plan.windowsToRestore(requester: requester) {
            next.remove(window: evicted)
        }
        XCTAssertEqual(next.slot(of: requester), .sixthsRightTwoThirds)
        next.commit(window: requester, into: target)
        XCTAssertEqual(next.occupants, [target: requester])
        XCTAssertEqual(next.activeLayout, .quarters)
        assertHealthy(next, context: "reported scenario")
        // Committing must NOT orphan the old sixths tile: the commit
        // itself vacates it.
        XCTAssertNil(next.occupant(of: .sixthsRightTwoThirds))
        XCTAssertNil(next.slot(of: 1))
        XCTAssertNil(next.slot(of: 2))
    }

    func testUnknownWindowIDBehavesLikeFreshRequester() {
        // A window id the state has never seen still triggers the full reset.
        var state = TilingState()
        state.commit(window: 1, into: .leftHalf)
        state.commit(window: 2, into: .rightHalf)
        XCTAssertEqual(
            state.plan(window: 424242, into: .sixthLeft),
            .switchLayout(evicting: [1, 2]))
    }

    func testSwitchEvictionsAreSortedInBothDirections() {
        // Commit order is slot order, not id order — the plan must still
        // come back sorted for deterministic controller restores.
        var quarters = TilingState()
        quarters.commit(window: 30, into: .topLeft)
        quarters.commit(window: 10, into: .bottomRight)
        quarters.commit(window: 20, into: .leftHalf)
        XCTAssertEqual(
            quarters.plan(window: 99, into: .sixthRight),
            .switchLayout(evicting: [10, 20, 30]))
        XCTAssertEqual(
            quarters.plan(window: 20, into: .sixthRight),
            .switchLayout(evicting: [10, 20, 30]))

        var sixths = TilingState()
        let corners: [Slot] = [
            .sixthTopLeft, .sixthTopMiddle, .sixthTopRight,
            .sixthBottomLeft, .sixthBottomMiddle, .sixthBottomRight,
        ]
        let ids = [60, 10, 50, 20, 40, 30]
        for (slot, id) in zip(corners, ids) { sixths.commit(window: id, into: slot) }
        XCTAssertEqual(
            sixths.plan(window: 99, into: .rightHalf),
            .switchLayout(evicting: [10, 20, 30, 40, 50, 60]))
    }

    // MARK: Commit semantics — exactly the requester remains

    func testSwitchCommitLeavesExactlyTheRequester() {
        for config in Self.quartersConfigs {
            let (state, ids) = makeState(slots: config, firstID: 1)
            for target in Self.sixthsSlots {
                for requester in [ids[0], 999] {
                    var next = state
                    let plan = next.plan(window: requester, into: target)
                    guard case .switchLayout(let evicting) = plan else {
                        XCTFail("\(config) -> \(target.rawValue) did not switch")
                        continue
                    }
                    XCTAssertEqual(Set(evicting), Set(ids))
                    apply(plan, to: &next, requester: requester, target: target)
                    XCTAssertEqual(
                        next.occupants, [target: requester],
                        "\(config) -> \(target.rawValue) requester=\(requester)")
                    XCTAssertEqual(next.activeLayout, target.layout)
                    for evicted in ids where evicted != requester {
                        XCTAssertNil(next.slot(of: evicted))
                    }
                    assertHealthy(next, context: "\(config) -> \(target.rawValue)")
                }
            }
        }
        for config in Self.sixthsConfigs {
            let (state, ids) = makeState(slots: config, firstID: 1)
            for target in Self.quartersSlots {
                for requester in [ids[0], 999] {
                    var next = state
                    let plan = next.plan(window: requester, into: target)
                    guard case .switchLayout(let evicting) = plan else {
                        XCTFail("\(config) -> \(target.rawValue) did not switch")
                        continue
                    }
                    XCTAssertEqual(Set(evicting), Set(ids))
                    apply(plan, to: &next, requester: requester, target: target)
                    XCTAssertEqual(
                        next.occupants, [target: requester],
                        "\(config) -> \(target.rawValue) requester=\(requester)")
                    XCTAssertEqual(next.activeLayout, target.layout)
                    assertHealthy(next, context: "\(config) -> \(target.rawValue)")
                }
            }
        }
    }

    // MARK: Full-grid switches

    func testSwitchFromFullQuartersGrid() {
        let (state, ids) = makeState(
            slots: [.topLeft, .topRight, .bottomLeft, .bottomRight], firstID: 1)
        XCTAssertEqual(state.activeLayout, .quarters)
        for target in Self.sixthsSlots {
            XCTAssertEqual(
                state.plan(window: 99, into: target),
                .switchLayout(evicting: ids.sorted()),
                "full quads -> \(target.rawValue)")
        }
        // Full halves: same story.
        let (halves, halfIDs) = makeState(slots: [.leftHalf, .rightHalf], firstID: 1)
        for target in Self.sixthsSlots {
            XCTAssertEqual(
                halves.plan(window: 99, into: target),
                .switchLayout(evicting: halfIDs.sorted()),
                "full halves -> \(target.rawValue)")
        }
    }

    func testSwitchFromFullSixthsCornerGrid() {
        let corners: [Slot] = [
            .sixthTopLeft, .sixthTopMiddle, .sixthTopRight,
            .sixthBottomLeft, .sixthBottomMiddle, .sixthBottomRight,
        ]
        let (state, ids) = makeState(slots: corners, firstID: 1)
        XCTAssertEqual(state.activeLayout, .sixths)
        for target in Self.quartersSlots {
            XCTAssertEqual(
                state.plan(window: 99, into: target),
                .switchLayout(evicting: ids.sorted()),
                "full corners -> \(target.rawValue)")
        }
    }

    func testSwitchFromThirdsAndTwoThirds() {
        for config in [
            [.sixthLeft, .sixthMiddle, .sixthRight],
            [.sixthsLeftTwoThirds, .sixthRight],
            [.sixthsRightTwoThirds, .sixthLeft],
            [.sixthsLeftTwoThirds],
            [.sixthMiddle],
        ] as [[Slot]] {
            let (state, ids) = makeState(slots: config, firstID: 1)
            for target in Self.quartersSlots {
                XCTAssertEqual(
                    state.plan(window: 99, into: target),
                    .switchLayout(evicting: ids.sorted()),
                    "\(config) -> \(target.rawValue)")
            }
        }
    }

    // MARK: Same-slot noop still beats the switch

    func testSameSlotNeverSwitchesAcrossAllSlots() {
        // plan() checks occupancy before layout, so the identical request
        // is a noop for every slot in both layouts — never a reset.
        for slot in Slot.allCases {
            var state = TilingState()
            state.commit(window: 1, into: slot)
            XCTAssertEqual(
                state.plan(window: 1, into: slot), .noop,
                "\(slot.rawValue) self-request")
            XCTAssertEqual(state.occupants, [slot: 1])
        }
    }

    // MARK: Fresh windows into the active layout do not switch

    func testFreshWindowIntoActiveLayoutTilesNormally() {
        // The reset fires only when the target layout differs from the
        // ACTIVE one — a fresh window joining the current layout is a plain
        // tile (or swap), never a switch.
        var quarters = TilingState()
        quarters.commit(window: 1, into: .topLeft)
        XCTAssertEqual(quarters.plan(window: 2, into: .bottomRight), .tile(evicting: []))
        XCTAssertEqual(quarters.plan(window: 2, into: .rightHalf), .tile(evicting: []))

        var sixths = TilingState()
        sixths.commit(window: 1, into: .sixthLeft)
        XCTAssertEqual(sixths.plan(window: 2, into: .sixthRight), .tile(evicting: []))
        XCTAssertEqual(sixths.plan(window: 2, into: .sixthTopMiddle), .tile(evicting: []))
    }

    func testAfterSwitchSameLayoutRequestsDoNotReset() {
        // Once switched, the new layout is home: disjoint tiles and swaps
        // proceed without another reset.
        var state = TilingState()
        state.commit(window: 1, into: .topLeft)
        var next = state
        apply(next.plan(window: 2, into: .sixthLeft), to: &next, requester: 2, target: .sixthLeft)
        XCTAssertEqual(next.occupants, [.sixthLeft: 2])
        // Disjoint sixths tile: plain tile.
        XCTAssertEqual(next.plan(window: 3, into: .sixthRight), .tile(evicting: []))
        // Occupied sixths quad takeover by a fresh window: eviction, not reset.
        next.commit(window: 3, into: .sixthRight)
        XCTAssertEqual(next.plan(window: 4, into: .sixthRight), .tile(evicting: [3]))
        // Tiled window moving between sixths thirds: move, not reset.
        XCTAssertEqual(next.plan(window: 2, into: .sixthMiddle), .tile(evicting: []))
    }

    // MARK: Sequences across layouts

    func testPingPongAlternatesExactlyOneWindow() {
        // Every switch leaves exactly the requester; ping-ponging layouts
        // never accumulates strays.
        var state = TilingState()
        let script: [(WindowID, Slot)] = [
            (1, .topLeft),
            (2, .bottomRight),
            (3, .sixthMiddle), // reset to sixths
            (4, .sixthLeft),
            (1, .rightHalf), // reset to quarters
            (1, .sixthTopLeft), // reset to sixths (tiled requester)
            (1, .topLeft), // reset to quarters (tiled requester)
        ]
        let expected: [[Slot: WindowID]] = [
            [.topLeft: 1],
            [.topLeft: 1, .bottomRight: 2],
            [.sixthMiddle: 3],
            [.sixthMiddle: 3, .sixthLeft: 4],
            [.rightHalf: 1],
            [.sixthTopLeft: 1],
            [.topLeft: 1],
        ]
        for ((window, slot), want) in zip(script, expected) {
            apply(state.plan(window: window, into: slot), to: &state, requester: window, target: slot)
            XCTAssertEqual(state.occupants, want, "after win\(window) -> \(slot.rawValue)")
            XCTAssertEqual(state.activeLayout, slot.layout)
            assertHealthy(state, context: "win\(window) -> \(slot.rawValue)")
        }
    }

    func testQuartersSessionSwitchSixthsSessionSwitchBack() {
        // Fill quarters, reset into sixths, build a sixths session, reset
        // back, and rebuild quarters — asserting the full state at each hop.
        var state = TilingState()
        for (id, slot) in [(1, Slot.topLeft), (2, .topRight), (3, .bottomLeft)] {
            apply(state.plan(window: id, into: slot), to: &state, requester: id, target: slot)
        }
        XCTAssertEqual(state.activeLayout, .quarters)
        XCTAssertEqual(state.tiledWindows.sorted(), [1, 2, 3])

        apply(state.plan(window: 4, into: .sixthLeft), to: &state, requester: 4, target: .sixthLeft)
        XCTAssertEqual(state.occupants, [.sixthLeft: 4])
        XCTAssertEqual(state.activeLayout, .sixths)
        for evicted in [1, 2, 3] { XCTAssertNil(state.slot(of: evicted)) }

        for (id, slot) in [(5, Slot.sixthMiddle), (6, .sixthRight)] {
            let plan = state.plan(window: id, into: slot)
            XCTAssertEqual(plan, .tile(evicting: []), "win\(id) -> \(slot.rawValue)")
            apply(plan, to: &state, requester: id, target: slot)
        }
        XCTAssertEqual(
            state.occupants, [.sixthLeft: 4, .sixthMiddle: 5, .sixthRight: 6])

        apply(state.plan(window: 5, into: .leftHalf), to: &state, requester: 5, target: .leftHalf)
        XCTAssertEqual(state.occupants, [.leftHalf: 5])
        XCTAssertEqual(state.activeLayout, .quarters)
        XCTAssertNil(state.slot(of: 4))
        XCTAssertNil(state.slot(of: 6))

        apply(state.plan(window: 6, into: .rightHalf), to: &state, requester: 6, target: .rightHalf)
        XCTAssertEqual(state.occupants, [.leftHalf: 5, .rightHalf: 6])
        assertHealthy(state, context: "rebuilt quarters")
    }

    func testTiledWindowCarriesAcrossSwitchesButLosesItsOldTile() {
        // A tiled window that requests the other layout is evicted from its
        // old tile like everyone else, then placed alone in the new layout.
        var state = TilingState()
        state.commit(window: 1, into: .topLeft)
        state.commit(window: 2, into: .bottomRight)
        apply(state.plan(window: 1, into: .sixthRight), to: &state, requester: 1, target: .sixthRight)
        XCTAssertEqual(state.occupants, [.sixthRight: 1])
        XCTAssertNil(state.slot(of: 2))
        // And it can carry straight back.
        apply(state.plan(window: 1, into: .bottomLeft), to: &state, requester: 1, target: .bottomLeft)
        XCTAssertEqual(state.occupants, [.bottomLeft: 1])
        XCTAssertEqual(state.activeLayout, .quarters)
    }

    func testSwitchImmediatelyAfterSwitch() {
        // Two resets in a row with no same-layout tiling between: the
        // second reset evicts exactly the first switch's survivor.
        var state = TilingState()
        state.commit(window: 1, into: .leftHalf)
        state.commit(window: 2, into: .rightHalf)
        apply(state.plan(window: 3, into: .sixthMiddle), to: &state, requester: 3, target: .sixthMiddle)
        XCTAssertEqual(state.occupants, [.sixthMiddle: 3])
        XCTAssertEqual(state.plan(window: 4, into: .topLeft), .switchLayout(evicting: [3]))
        apply(state.plan(window: 4, into: .topLeft), to: &state, requester: 4, target: .topLeft)
        XCTAssertEqual(state.occupants, [.topLeft: 4])
        assertHealthy(state, context: "double switch")
    }

    // MARK: Cross-layout BFS invariant sweep

    func testCrossLayoutBFSKeepsSingleLayoutInvariant() {
        // Every interleaving of quarters/sixths requests over 3 windows:
        // after EVERY step there is at most one layout on screen, no ghost
        // windows, and no double-booked cells. Switches must occur in both
        // directions, or the sweep proved nothing.
        let windows = [11, 22, 33]
        let targets = Slot.allCases
        var queue: [(TilingState, Int)] = [(TilingState(), 0)]
        var visited: Set<String> = []
        var steps = 0
        var quartersToSixths = 0
        var sixthsToQuarters = 0
        while !queue.isEmpty {
            let (state, depth) = queue.removeFirst()
            for window in windows {
                for target in targets {
                    var next = state
                    let plan = next.plan(window: window, into: target)
                    if case .switchLayout = plan {
                        if target.layout == .sixths {
                            quartersToSixths += 1
                        } else {
                            sixthsToQuarters += 1
                        }
                    }
                    apply(plan, to: &next, requester: window, target: target)
                    steps += 1
                    assertHealthy(next, context: "win\(window) -> \(target.rawValue)")
                    // A switch must leave exactly the requester behind.
                    if case .switchLayout = plan {
                        XCTAssertEqual(
                            next.occupants, [target: window],
                            "win\(window) -> \(target.rawValue)")
                    }
                    let key = next.occupants
                        .map { "\($0.key.rawValue)=\($0.value)" }
                        .sorted().joined(separator: ",")
                    if depth < 2 && visited.insert(key).inserted {
                        queue.append((next, depth + 1))
                    }
                }
            }
        }
        XCTAssertGreaterThan(steps, 1000, "BFS explored too little")
        XCTAssertGreaterThan(quartersToSixths, 0, "BFS never switched quarters -> sixths")
        XCTAssertGreaterThan(sixthsToQuarters, 0, "BFS never switched sixths -> quarters")
    }

    // MARK: Switch-undo contract (controller-level state machine)

    /// The undo snapshot mirrors the pure plan's eviction set exactly:
    /// every window the plan names must be restorable, the requester
    /// itself must never be in it.
    func testUndoSnapshotMirrorsPlanEvictionSet() {
        for config in Self.quartersConfigs + Self.sixthsConfigs {
            let (state, ids) = makeState(slots: config)
            let requester = 1000 // untiled window pressing into the other layout
            let fromLayout = config.first!.layout
            let target: Slot =
                fromLayout == .quarters ? .sixthTopLeft : .topLeft
            let plan = state.plan(window: requester, into: target)
            guard case .switchLayout(let evicting) = plan else {
                XCTFail("expected switchLayout for \(config)")
                continue
            }
            XCTAssertEqual(Set(evicting), Set(ids), "snapshot must name every tiled window")
            XCTAssertFalse(evicting.contains(requester), "requester moves, never evicts")
            // Undo restores exactly the pre-switch occupancy.
            var undone = state
            for evicted in evicting { undone.remove(window: evicted) }
            // Requester was never tiled: nothing to remove for it.
            XCTAssertNil(undone.slot(of: requester))
            for (slot, id) in zip(config, ids) {
                undone.commit(window: id, into: slot)
            }
            XCTAssertEqual(undone, state, "undo must reproduce pre-switch state")
            assertHealthy(undone, context: "undo of \(config)")
        }
    }

    /// The requester is excluded from the restore set even when already
    /// tiled (it moves, its record must survive until place runs).
    func testRequesterExcludedFromRestoreSet() {
        let (state, ids) = makeState(slots: [.topLeft, .bottomRight])
        let requester = ids[0] // already tiled, pressing into sixths
        let plan = state.plan(window: requester, into: .sixthMiddle)
        guard case .switchLayout(let evicting) = plan else {
            XCTFail("expected switchLayout")
            return
        }
        XCTAssertEqual(
            plan.windowsToRestore(requester: requester), [ids[1]],
            "only the OTHER window restores; the requester moves")
        XCTAssertFalse(evicting.contains(requester) == false, "plan names all, filter excludes")
    }
}
