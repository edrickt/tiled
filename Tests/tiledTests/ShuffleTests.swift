import XCTest
@testable import tiled

/// Rigorous coverage for shuffling: the swap/exchange path of the tiling
/// engine (`TilePlan.swap` + `TilingState.commitSwaps`).
///
/// There is no dedicated "shuffle" affordance in the app — shuffling IS the
/// swap rule: when a tiled window requests an occupied slot and every
/// overlapping window fits into the footprint it vacates, the windows
/// exchange places and nobody is untiled. These tests pin that contract
/// from every angle:
///
/// - The swap contract: placements name the requester -> target plus every
///   blocker, slots are same-layout / pairwise disjoint / inside the
///   vacated footprint, nothing is restored, window count is conserved.
/// - Pinned shuffles with hand-traced placements (rotations, reversals,
///   demotions, two-thirds slides, corner upgrades) in both layouts.
/// - The swap/evict boundary: one cell too few must evict, never strand.
/// - Solver properties: determinism, largest-first preference with
///   backtracking, fresh requesters never swap, disjoint occupants untouched.
/// - An exhaustive same-layout sweep cross-checked against an independent
///   brute-force oracle (solver swaps iff an assignment exists).
/// - A seeded deterministic fuzz walk asserting health after every step.
final class ShuffleTests: XCTestCase {
    private let a = 1
    private let b = 2
    private let c = 3
    private let d = 4

    // MARK: Helpers

    /// Builds a state with `slots` occupied by consecutive window ids.
    /// Returns the state plus the slot -> window ownership map.
    private func occupy(_ slots: [Slot], firstID: WindowID = 1) -> (TilingState, [Slot: WindowID]) {
        var state = TilingState()
        var owners: [Slot: WindowID] = [:]
        for (index, slot) in slots.enumerated() {
            let id = firstID + index
            state.commit(window: id, into: slot)
            owners[slot] = id
        }
        return (state, owners)
    }

    /// Commits a plan exactly like TilingController.handle does.
    private func commitPlan(
        _ plan: TilePlan, state: inout TilingState, requester: WindowID, target: Slot
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

    /// Windows (other than the requester) occupying slots overlapping `target`.
    /// This is the documented blocker rule, recomputed from raw cell sets so
    /// tests can cross-check the plan's eviction/swap payloads independently.
    private func blockers(in state: TilingState, requester: WindowID, target: Slot) -> [WindowID] {
        state.occupants.compactMap { slot, occupant in
            occupant != requester && slot.overlaps(target) ? occupant : nil
        }.sorted()
    }

    /// Cells the requester vacates and the target does not need: the only
    /// space blockers may relocate into. Mirrors the rule in plan().
    private func freeCells(requesterSlot: Slot?, target: Slot) -> Set<TileCell> {
        guard let requesterSlot else { return [] }
        return requesterSlot.cells.subtracting(target.cells)
    }

    /// Structural health after any transition: no ghosts, at most one
    /// layout on screen, no cell double-booked.
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

    /// Validates a swap placement dict against the full contract:
    /// - keys are exactly {requester} + every blocker (nobody dropped,
    ///   no strangers smuggled in, disjoint occupants untouched by design);
    /// - the requester lands on the target;
    /// - every slot is in the target's layout;
    /// - all slots (including the target) are pairwise cell-disjoint;
    /// - every blocker's slot fits inside the vacated footprint.
    private func assertValidSwap(
        _ placements: [WindowID: Slot],
        state before: TilingState,
        requester: WindowID,
        target: Slot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let context = "win\(requester) -> \(target.rawValue)"
        let expectedKeys = Set(blockers(in: before, requester: requester, target: target) + [requester])
        XCTAssertEqual(
            Set(placements.keys), expectedKeys,
            "\(context): placement keys \(placements.keys.sorted()) != {requester}+blockers \(expectedKeys.sorted())",
            file: file, line: line)
        XCTAssertEqual(
            placements[requester], target, "\(context): requester not on target",
            file: file, line: line)
        for (window, slot) in placements {
            XCTAssertEqual(
                slot.layout, target.layout,
                "\(context): win\(window) placed cross-layout into \(slot.rawValue)",
                file: file, line: line)
        }
        let slots = Array(placements.values)
        for i in slots.indices {
            for j in slots.indices where j > i {
                XCTAssertTrue(
                    slots[i].cells.isDisjoint(with: slots[j].cells),
                    "\(context): \(slots[i].rawValue) overlaps \(slots[j].rawValue)",
                    file: file, line: line)
            }
        }
        let free = freeCells(requesterSlot: before.slot(of: requester), target: target)
        for (window, slot) in placements where window != requester {
            XCTAssertTrue(
                slot.cells.isSubset(of: free),
                "\(context): win\(window) -> \(slot.rawValue) escapes the vacated footprint",
                file: file, line: line)
        }
    }

    /// Independent oracle for the swap/evict decision: plain product
    /// enumeration over candidate slots in raw allCases order — no
    /// largest-first heuristic, no pruning beyond disjointness — returning
    /// an actual assignment when one exists. Agrees with the solver on
    /// success/failure iff the solver neither under- nor over-swaps.
    private static func bruteForceAssign(
        blockers: [WindowID], within free: Set<TileCell>, layout: LayoutKind
    ) -> [WindowID: Slot]? {
        let candidates = Slot.allCases.filter {
            $0.layout == layout && $0.cells.isSubset(of: free)
        }
        if blockers.isEmpty { return [:] }
        guard !candidates.isEmpty else { return nil }
        var assignment: [WindowID: Slot] = [:]
        var used: Set<TileCell> = []
        func search(_ index: Int) -> Bool {
            guard index < blockers.count else { return true }
            for candidate in candidates where candidate.cells.isDisjoint(with: used) {
                assignment[blockers[index]] = candidate
                used.formUnion(candidate.cells)
                if search(index + 1) { return true }
                used.subtract(candidate.cells)
                assignment[blockers[index]] = nil
            }
            return false
        }
        return search(0) ? assignment : nil
    }

    // MARK: Swap contract

    func testSwapNamesRequesterTargetAndEveryBlocker() {
        // Two blockers, one swap: keys are exactly {requester} + blockers.
        let (state, _) = occupy([.topLeft, .bottomLeft, .rightHalf])
        // owners: a=TL, b=BL, c=RH. c -> LeftHalf overlaps a and b.
        let plan = state.plan(window: c, into: .leftHalf)
        guard case .swap(let placements) = plan else {
            XCTFail("expected a swap, got \(plan)")
            return
        }
        XCTAssertEqual(placements[c], .leftHalf)
        XCTAssertEqual(Set(placements.keys), [a, b, c])
        assertValidSwap(placements, state: state, requester: c, target: .leftHalf)
    }

    func testSwapRestoresNothingAndConservesWindows() {
        var (state, _) = occupy([.topLeft, .bottomRight])
        let before = Set(state.tiledWindows)
        guard case .swap(let placements) = state.plan(window: a, into: .bottomRight) else {
            XCTFail("expected a swap")
            return
        }
        XCTAssertEqual(
            TilePlan.swap(placements: placements).windowsToRestore(requester: a), [],
            "a swap must not restore (untile) anyone")
        state.commitSwaps(placements)
        XCTAssertEqual(Set(state.tiledWindows), before, "swap lost or gained a window")
        assertHealthy(state, context: "quad swap")
    }

    func testSwapCommitThenReplanIsNoop() {
        // Once shuffled, asking for the same tile again is a strict no-op.
        var (state, _) = occupy([.leftHalf, .topRight])
        guard case .swap(let placements) = state.plan(window: a, into: .topRight) else {
            XCTFail("expected a swap")
            return
        }
        state.commitSwaps(placements)
        XCTAssertEqual(state.plan(window: a, into: .topRight), .noop)
        XCTAssertEqual(state.plan(window: b, into: .leftHalf), .noop)
    }

    func testSwapNeverMovesDisjointOccupants() {
        // The pair shuffles; the other two quads stay exactly put.
        var (state, _) = occupy([.topLeft, .topRight, .bottomLeft, .bottomRight])
        let untouched: [Slot: WindowID] = [.topRight: b, .bottomLeft: c]
        guard case .swap(let placements) = state.plan(window: a, into: .bottomRight) else {
            XCTFail("expected a swap")
            return
        }
        XCTAssertEqual(Set(placements.keys), [a, d], "disjoint windows must not be in the swap")
        state.commitSwaps(placements)
        for (slot, window) in untouched {
            XCTAssertEqual(state.occupant(of: slot), window, "\(slot.rawValue) moved during a swap")
        }
    }

    // MARK: Pinned quarters shuffles

    func testQuartersThreeWayRotationViaCommitSwaps() {
        // commitSwaps itself is the shuffle primitive: removals happen
        // before placements, so a 3-cycle whose targets overlap old slots
        // never clobbers itself mid-commit. d in BR is untouched.
        var (state, _) = occupy([.topLeft, .topRight, .bottomLeft, .bottomRight])
        state.commitSwaps([a: .topRight, b: .bottomLeft, c: .topLeft])
        XCTAssertEqual(state.occupant(of: .topRight), a)
        XCTAssertEqual(state.occupant(of: .bottomLeft), b)
        XCTAssertEqual(state.occupant(of: .topLeft), c)
        XCTAssertEqual(state.occupant(of: .bottomRight), d, "disjoint window disturbed")
        XCTAssertEqual(Set(state.tiledWindows), [a, b, c, d])
        assertHealthy(state, context: "3-cycle")
    }

    func testCommitSwapsEmptyIsNoop() {
        var (state, _) = occupy([.topLeft, .rightHalf])
        let before = state
        state.commitSwaps([:])
        XCTAssertEqual(state, before)
    }

    func testQuartersFullReverseViaTwoSwaps() {
        // Transpositions generate any permutation: two swaps reverse all
        // four quads. a=TL b=TR c=BL d=BR -> d c b a.
        var (state, owners) = occupy([.topLeft, .topRight, .bottomLeft, .bottomRight])
        XCTAssertEqual(owners, [.topLeft: a, .topRight: b, .bottomLeft: c, .bottomRight: d])

        guard case .swap(let first) = state.plan(window: a, into: .bottomRight) else {
            XCTFail("expected swap 1")
            return
        }
        XCTAssertEqual(first, [a: .bottomRight, d: .topLeft])
        state.commitSwaps(first)

        guard case .swap(let second) = state.plan(window: b, into: .bottomLeft) else {
            XCTFail("expected swap 2, got \(state.plan(window: b, into: .bottomLeft))")
            return
        }
        XCTAssertEqual(second, [b: .bottomLeft, c: .topRight])
        state.commitSwaps(second)

        XCTAssertEqual(
            state.occupants,
            [.topLeft: d, .topRight: c, .bottomLeft: b, .bottomRight: a])
        assertHealthy(state, context: "reversed quads")
    }

    func testBacktrackingSplitsBlockersAcrossQuads() {
        // c=RightHalf -> LeftHalf (a=TL, b=BL): free is the whole right
        // half. Greedy would park a in RightHalf and strand b; the solver
        // must backtrack and split a/b into TR/BR. Lower id takes the
        // earlier slot (deterministic).
        var (state, _) = occupy([.topLeft, .bottomLeft, .rightHalf])
        let plan = state.plan(window: c, into: .leftHalf)
        XCTAssertEqual(plan, .swap(placements: [c: .leftHalf, a: .topRight, b: .bottomRight]))
        if case .swap(let placements) = plan {
            assertValidSwap(placements, state: state, requester: c, target: .leftHalf)
            state.commitSwaps(placements)
        }
        XCTAssertEqual(state.occupant(of: .leftHalf), c)
        XCTAssertEqual(state.occupant(of: .topRight), a)
        XCTAssertEqual(state.occupant(of: .bottomRight), b)
        XCTAssertNil(state.occupant(of: .rightHalf))
        assertHealthy(state, context: "backtrack split")
    }

    func testBacktrackedSwapRoundTrips() {
        // The split above is exactly reversible: c -> RightHalf packs a/b
        // back into TL/BL. Shuffles compose.
        var (state, _) = occupy([.topLeft, .bottomLeft, .rightHalf])
        if case .swap(let first) = state.plan(window: c, into: .leftHalf) {
            state.commitSwaps(first)
        } else {
            XCTFail("expected swap 1")
            return
        }
        let back = state.plan(window: c, into: .rightHalf)
        XCTAssertEqual(back, .swap(placements: [c: .rightHalf, a: .topLeft, b: .bottomLeft]))
        if case .swap(let placements) = back {
            state.commitSwaps(placements)
        }
        XCTAssertEqual(state.occupants, [.topLeft: a, .bottomLeft: b, .rightHalf: c])
        assertHealthy(state, context: "round trip")
    }

    func testHalfShrinkLeavesNeighborAlone() {
        // a=LeftHalf -> TopLeft is a pure shrink (target inside the old
        // slot): no blockers, b=TopRight untouched, nothing swaps.
        var (state, _) = occupy([.leftHalf, .topRight])
        XCTAssertEqual(state.plan(window: a, into: .topLeft), .tile(evicting: []))
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.occupants, [.topLeft: a, .topRight: b])
        assertHealthy(state, context: "shrink")
    }

    func testBlockerInheritsVacatedHalf() {
        // a=LeftHalf -> TR (occupied b): free is the whole left half, so b
        // takes over the entire half — halves stay halves when possible
        // (largest-first preference), not two quads.
        var (state, _) = occupy([.leftHalf, .topRight])
        let plan = state.plan(window: a, into: .topRight)
        XCTAssertEqual(plan, .swap(placements: [a: .topRight, b: .leftHalf]))
        if case .swap(let placements) = plan {
            assertValidSwap(placements, state: state, requester: a, target: .topRight)
            state.commitSwaps(placements)
        }
        XCTAssertEqual(state.occupants, [.topRight: a, .leftHalf: b])
        assertHealthy(state, context: "half inheritance")
    }

    // MARK: The swap/evict boundary

    func testOneCellShortEvictsInsteadOfStranding() {
        // All four quads tiled; a=TL -> RightHalf overlaps c=TR and d=BR
        // but vacates a single quad: only one blocker fits, so BOTH are
        // evicted. A shuffle must never strand a window mid-exchange.
        var (state, _) = occupy([.topLeft, .bottomLeft, .topRight, .bottomRight])
        let plan = state.plan(window: a, into: .rightHalf)
        XCTAssertEqual(plan, .tile(evicting: [c, d]))
        commitPlan(plan, state: &state, requester: a, target: .rightHalf)
        XCTAssertEqual(state.occupants, [.bottomLeft: b, .rightHalf: a])
        XCTAssertNil(state.slot(of: c))
        XCTAssertNil(state.slot(of: d))
        assertHealthy(state, context: "boundary eviction")
    }

    func testEvictionBoundaryIsOneSlotWide() {
        // Same shape but only ONE blocker (c=TR): the vacated TL quad fits
        // it exactly, so this shuffles instead of evicting.
        var (state, _) = occupy([.topLeft, .bottomLeft, .topRight])
        let plan = state.plan(window: a, into: .rightHalf)
        guard case .swap(let placements) = plan else {
            XCTFail("one blocker fits the vacated quad; expected a swap, got \(plan)")
            return
        }
        assertValidSwap(placements, state: state, requester: a, target: .rightHalf)
        commitPlan(plan, state: &state, requester: a, target: .rightHalf)
        XCTAssertEqual(Set(state.tiledWindows), [a, b, c])
        assertHealthy(state, context: "boundary swap")
    }

    // MARK: Pinned sixths shuffles

    func testSixthsThirdsTranspositionChain() {
        // a=Left b=Middle c=Right thirds. a->Right, c->Middle, b->Right:
        // each hop swaps exactly the pair involved; the third stands still.
        var (state, _) = occupy([.sixthLeft, .sixthMiddle, .sixthRight])

        guard case .swap(let s1) = state.plan(window: a, into: .sixthRight) else {
            XCTFail("expected swap 1, got \(state.plan(window: a, into: .sixthRight))")
            return
        }
        XCTAssertEqual(s1, [a: .sixthRight, c: .sixthLeft])
        state.commitSwaps(s1)
        XCTAssertEqual(state.occupant(of: .sixthMiddle), b, "middle moved during an edge swap")

        guard case .swap(let s2) = state.plan(window: c, into: .sixthMiddle) else {
            XCTFail("expected swap 2, got \(state.plan(window: c, into: .sixthMiddle))")
            return
        }
        XCTAssertEqual(s2, [c: .sixthMiddle, b: .sixthLeft])
        state.commitSwaps(s2)

        guard case .swap(let s3) = state.plan(window: b, into: .sixthRight) else {
            XCTFail("expected swap 3, got \(state.plan(window: b, into: .sixthRight))")
            return
        }
        XCTAssertEqual(s3, [b: .sixthRight, a: .sixthLeft])
        state.commitSwaps(s3)

        // Net effect: b and c transposed, a home.
        XCTAssertEqual(state.occupants, [.sixthLeft: a, .sixthMiddle: c, .sixthRight: b])
        XCTAssertEqual(state.activeLayout, .sixths)
        assertHealthy(state, context: "thirds chain")
    }

    func testSixthsTwoThirdsSlide() {
        // a=RightTwoThirds -> LeftTwoThirds (occupied b=Left third): free
        // is the c3 column, so b slides into Right third exactly.
        var (state, _) = occupy([.sixthsRightTwoThirds, .sixthLeft])
        // owners: a=rightTwoThirds, b=left.
        let plan = state.plan(window: a, into: .sixthsLeftTwoThirds)
        XCTAssertEqual(plan, .swap(placements: [a: .sixthsLeftTwoThirds, b: .sixthRight]))
        if case .swap(let placements) = plan {
            assertValidSwap(placements, state: state, requester: a, target: .sixthsLeftTwoThirds)
            state.commitSwaps(placements)
        }
        XCTAssertEqual(state.occupants, [.sixthsLeftTwoThirds: a, .sixthRight: b])
        assertHealthy(state, context: "two-thirds slide")
    }

    func testSixthsBlockerTakesVacatedTwoThirdsWhole() {
        // a=LeftTwoThirds -> TopRight corner (occupied b=Right third…):
        // unreachable (they overlap). Instead: b=Right third tiled alone
        // with a=LeftTwoThirds — also overlapping. Reachable version:
        // b=TopRight corner + c=BottomRight corner, a=LeftTwoThirds ->
        // TopRight: blockers b (corner) — c is disjoint from the target.
        var (state, _) = occupy([.sixthsLeftTwoThirds, .sixthTopRight, .sixthBottomRight])
        // owners: a=leftTwoThirds, b=topRight corner, c=bottomRight corner.
        let plan = state.plan(window: a, into: .sixthTopRight)
        // free = left two-thirds (6 cells, disjoint from the corner):
        // b inherits the whole vacated two-thirds; c never moves.
        XCTAssertEqual(plan, .swap(placements: [a: .sixthTopRight, b: .sixthsLeftTwoThirds]))
        if case .swap(let placements) = plan {
            assertValidSwap(placements, state: state, requester: a, target: .sixthTopRight)
            state.commitSwaps(placements)
        }
        XCTAssertEqual(state.occupant(of: .sixthTopRight), a)
        XCTAssertEqual(state.occupant(of: .sixthsLeftTwoThirds), b)
        XCTAssertEqual(
            state.occupant(of: .sixthBottomRight), c, "disjoint corner moved during a swap")
        assertHealthy(state, context: "two-thirds inheritance")
    }

    func testSixthsCornerUpgradeBacktrack() {
        // b=TopLeft corner, c=BottomLeft corner, a=RightTwoThirds ->
        // Left third: free is the c1-c3 columns (6 cells). Largest-first
        // tries parking b in the whole vacated two-thirds and strands c,
        // so it must backtrack: b takes Middle third, c takes Right third.
        var (state, _) = occupy([.sixthTopLeft, .sixthBottomLeft, .sixthsRightTwoThirds])
        // owners: a=topLeft corner, b=bottomLeft corner, c=rightTwoThirds.
        let requester = c
        let plan = state.plan(window: requester, into: .sixthLeft)
        XCTAssertEqual(
            plan,
            .swap(placements: [requester: .sixthLeft, a: .sixthMiddle, b: .sixthRight]))
        if case .swap(let placements) = plan {
            assertValidSwap(placements, state: state, requester: requester, target: .sixthLeft)
            state.commitSwaps(placements)
        }
        XCTAssertEqual(state.occupant(of: .sixthLeft), requester)
        XCTAssertEqual(state.occupant(of: .sixthMiddle), a)
        XCTAssertEqual(state.occupant(of: .sixthRight), b)
        assertHealthy(state, context: "corner upgrade")
    }

    func testSixthsThreeBlockerEviction() {
        // b=TopMiddle, c=BottomMiddle, d=Right third, a=Left third ->
        // RightTwoThirds overlaps all three but vacates one third: a
        // single third fits one blocker, so all three are evicted.
        var (state, _) = occupy([.sixthLeft, .sixthTopMiddle, .sixthBottomMiddle, .sixthRight])
        // owners: a=left, b=topMiddle, c=bottomMiddle, d=right.
        let plan = state.plan(window: a, into: .sixthsRightTwoThirds)
        XCTAssertEqual(plan, .tile(evicting: [b, c, d]))
        commitPlan(plan, state: &state, requester: a, target: .sixthsRightTwoThirds)
        XCTAssertEqual(state.occupants, [.sixthsRightTwoThirds: a])
        assertHealthy(state, context: "three-blocker eviction")
    }

    func testSixthsSwapRoundTrip() {
        var (state, _) = occupy([.sixthLeft, .sixthRight])
        guard case .swap(let first) = state.plan(window: a, into: .sixthRight) else {
            XCTFail("expected a swap")
            return
        }
        state.commitSwaps(first)
        guard case .swap(let second) = state.plan(window: a, into: .sixthLeft) else {
            XCTFail("expected a swap back, got \(state.plan(window: a, into: .sixthLeft))")
            return
        }
        state.commitSwaps(second)
        XCTAssertEqual(state.occupants, [.sixthLeft: a, .sixthRight: b])
    }

    // MARK: Solver properties

    func testFreshRequesterNeverSwaps() {
        // An untiled window vacates nothing, so even a clean 1-for-1
        // takeover evicts rather than swaps — pinned across shapes where a
        // swap would otherwise fit (the tiled-window variant of each case
        // swaps; see the sweep below).
        var (state, _) = occupy([.topLeft, .bottomRight])
        XCTAssertEqual(state.plan(window: 99, into: .bottomRight), .tile(evicting: [b]))
        var (sixths, _) = occupy([.sixthLeft, .sixthRight])
        XCTAssertEqual(sixths.plan(window: 99, into: .sixthRight), .tile(evicting: [b]))
    }

    func testPlansAreDeterministic() {
        // The solver sorts blockers and breaks size ties by slot order, so
        // the same request against the same state must produce the same
        // plan — a shuffle must never depend on dictionary iteration order.
        let configs: [[Slot]] = [
            [.topLeft, .bottomLeft, .rightHalf],
            [.topLeft, .topRight, .bottomLeft, .bottomRight],
            [.leftHalf, .topRight],
            [.sixthTopLeft, .sixthBottomLeft, .sixthsRightTwoThirds],
            [.sixthLeft, .sixthTopMiddle, .sixthBottomMiddle, .sixthRight],
            [.sixthsLeftTwoThirds, .sixthRight],
        ]
        for config in configs {
            let (state, owners) = occupy(config)
            for requester in owners.values + [999] {
                for target in Slot.allCases where target.layout == config[0].layout {
                    XCTAssertEqual(
                        state.plan(window: requester, into: target),
                        state.plan(window: requester, into: target),
                        "nondeterministic plan: win\(requester) -> \(target.rawValue) over \(config)")
                }
            }
        }
    }

    /// Exhaustive same-layout sweep: every occupancy shape x every
    /// requester (each occupant plus a fresh window) x every same-layout
    /// target. The brute-force oracle independently predicts swap-vs-evict;
    /// every produced swap is validated against the full contract;
    /// every commit conserves windows, keeps disjoint occupants put, stays
    /// healthy, and leaves the requester settled (replan == noop).
    func testSwapSweepMatchesBruteForceOracle() {
        let quartersConfigs: [[Slot]] = [
            [.topLeft],
            [.leftHalf],
            [.topLeft, .bottomRight],
            [.topLeft, .bottomLeft],
            [.topLeft, .topRight],
            [.leftHalf, .rightHalf],
            [.leftHalf, .topRight],
            [.rightHalf, .topLeft, .bottomLeft],
            [.topLeft, .bottomLeft, .rightHalf],
            [.topLeft, .topRight, .bottomLeft, .bottomRight],
        ]
        let sixthsConfigs: [[Slot]] = [
            [.sixthTopLeft],
            [.sixthMiddle],
            [.sixthsLeftTwoThirds],
            [.sixthLeft, .sixthRight],
            [.sixthTopLeft, .sixthBottomRight],
            [.sixthLeft, .sixthMiddle, .sixthRight],
            [.sixthsLeftTwoThirds, .sixthRight],
            [.sixthsRightTwoThirds, .sixthLeft],
            [.sixthTopMiddle, .sixthBottomMiddle, .sixthRight],
            [.sixthTopLeft, .sixthBottomLeft, .sixthsRightTwoThirds],
            [.sixthTopLeft, .sixthTopMiddle, .sixthTopRight],
            [
                .sixthTopLeft, .sixthTopMiddle, .sixthTopRight,
                .sixthBottomLeft, .sixthBottomMiddle, .sixthBottomRight,
            ],
            [.sixthLeft, .sixthTopMiddle, .sixthTopRight,
             .sixthBottomMiddle, .sixthBottomRight],
        ]
        let fresh: WindowID = 999
        var swapsChecked = 0
        var evictionsChecked = 0
        for config in quartersConfigs + sixthsConfigs {
            let layout = config[0].layout
            let (state, owners) = occupy(config)
            for requester in owners.values + [fresh] {
                let requesterSlot = owners.first(where: { $0.value == requester })?.key
                for target in Slot.allCases where target.layout == layout {
                    let context = "\(config.map(\.rawValue)) win\(requester) -> \(target.rawValue)"
                    let plan = state.plan(window: requester, into: target)
                    // Determinism: the same query twice must agree.
                    XCTAssertEqual(
                        plan, state.plan(window: requester, into: target),
                        "\(context): nondeterministic")

                    if owners[target] == requester {
                        XCTAssertEqual(plan, .noop, context)
                        continue
                    }
                    let expectedBlockers = blockers(in: state, requester: requester, target: target)
                    if expectedBlockers.isEmpty {
                        XCTAssertEqual(plan, .tile(evicting: []), context)
                        continue
                    }
                    if requesterSlot == nil {
                        // Untiled requester: always evicts, never swaps.
                        XCTAssertEqual(
                            plan, .tile(evicting: expectedBlockers),
                            "\(context): fresh requester must evict, not swap")
                        evictionsChecked += 1
                        continue
                    }
                    let free = freeCells(requesterSlot: requesterSlot, target: target)
                    let oracle = Self.bruteForceAssign(
                        blockers: expectedBlockers, within: free, layout: layout)
                    switch plan {
                    case .swap(let placements):
                        XCTAssertNotNil(
                            oracle, "\(context): solver swapped but no assignment exists")
                        assertValidSwap(
                            placements, state: state, requester: requester, target: target)
                        swapsChecked += 1
                        var next = state
                        let beforeOccupants = state.occupants
                        next.commitSwaps(placements)
                        XCTAssertEqual(
                            Set(next.tiledWindows), Set(state.tiledWindows),
                            "\(context): swap changed the window set")
                        for (slot, window) in beforeOccupants
                        where !placements.keys.contains(window) {
                            XCTAssertEqual(
                                next.occupant(of: slot), window,
                                "\(context): disjoint win\(window) moved")
                        }
                        assertHealthy(next, context: context)
                        XCTAssertEqual(
                            next.plan(window: requester, into: target), .noop,
                            "\(context): requester not settled after swap")
                    case .tile(let evicting):
                        XCTAssertNil(
                            oracle, "\(context): assignment exists but solver evicted")
                        XCTAssertEqual(evicting, expectedBlockers, "\(context): wrong eviction set")
                        evictionsChecked += 1
                        var next = state
                        commitPlan(plan, state: &next, requester: requester, target: target)
                        XCTAssertEqual(next.occupant(of: target), requester, context)
                        for evicted in expectedBlockers {
                            XCTAssertNil(next.slot(of: evicted), "\(context): evicted win\(evicted) lingers")
                        }
                        assertHealthy(next, context: context)
                    case .noop, .switchLayout:
                        XCTFail("\(context): unexpected \(plan) for a same-layout request")
                    }
                }
            }
        }
        XCTAssertGreaterThan(swapsChecked, 50, "sweep exercised too few swaps: \(swapsChecked)")
        XCTAssertGreaterThan(evictionsChecked, 50, "sweep exercised too few evictions: \(evictionsChecked)")
    }

    // MARK: Deterministic fuzz walk

    /// Seeded PRNG (LCG): the walk is fully deterministic — same seed,
    /// same 3000 requests, same assertions, every run.
    private struct DeterministicRNG {
        var state: UInt64 = 0x123456789ABCDEF
        mutating func next(_ upperBound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(upperBound))
        }
    }

    func testDeterministicShuffleWalk() {
        // 3000 biased-random requests over 5 window ids and all 17 slots:
        // tiled requesters usually stay in-layout (which breeds swaps and
        // evictions), sometimes jump layouts (switches) or re-request
        // their own slot (noops). After EVERY step: exact window-set
        // accounting per plan kind, swap-contract validation, and health.
        var rng = DeterministicRNG()
        var state = TilingState()
        var swaps = 0, evictingTiles = 0, plainTiles = 0, switches = 0, noops = 0
        var switchesToSixths = 0, switchesToQuarters = 0
        let windowIDs = [1, 2, 3, 4, 5]

        for _ in 0..<3000 {
            let requester = windowIDs[rng.next(windowIDs.count)]
            let target: Slot
            if let current = state.slot(of: requester) {
                let roll = rng.next(32)
                if roll == 0 {
                    target = current // forced noop
                } else if roll < 24 {
                    let sameLayout = Slot.allCases.filter { $0.layout == current.layout }
                    target = sameLayout[rng.next(sameLayout.count)]
                } else {
                    target = Slot.allCases[rng.next(Slot.allCases.count)]
                }
            } else {
                target = Slot.allCases[rng.next(Slot.allCases.count)]
            }

            let context = "win\(requester) -> \(target.rawValue) occupants=\(state.occupants)"
            let plan = state.plan(window: requester, into: target)
            let beforeSet = Set(state.tiledWindows)
            let beforeOccupants = state.occupants

            switch plan {
            case .noop:
                noops += 1
                XCTAssertEqual(state.slot(of: requester), target, context)
                XCTAssertEqual(state.occupants, beforeOccupants, "\(context): noop mutated state")
            case .swap(let placements):
                swaps += 1
                XCTAssertEqual(target.layout, state.activeLayout, "\(context): swap leaked cross-layout")
                assertValidSwap(placements, state: state, requester: requester, target: target)
                // Oracle agreement when the search space is small enough to
                // enumerate cheaply; the direct validation above always runs.
                let free = freeCells(requesterSlot: state.slot(of: requester), target: target)
                let blockers = blockers(in: state, requester: requester, target: target)
                if blockers.count <= 3 {
                    XCTAssertNotNil(
                        Self.bruteForceAssign(blockers: blockers, within: free, layout: target.layout),
                        "\(context): solver swapped with no valid assignment")
                }
                state.commitSwaps(placements)
                XCTAssertEqual(
                    Set(state.tiledWindows), beforeSet,
                    "\(context): swap changed the window set")
            case .tile(let evicting):
                XCTAssertEqual(
                    evicting, blockers(in: state, requester: requester, target: target),
                    "\(context): wrong eviction set")
                XCTAssertEqual(target.layout, state.activeLayout, "\(context): tile leaked cross-layout")
                if evicting.isEmpty { plainTiles += 1 } else { evictingTiles += 1 }
                for evicted in evicting { state.remove(window: evicted) }
                state.commit(window: requester, into: target)
                XCTAssertEqual(
                    Set(state.tiledWindows), beforeSet.subtracting(evicting).union([requester]),
                    "\(context): wrong survivors")
            case .switchLayout(let evicting):
                switches += 1
                XCTAssertEqual(evicting, beforeSet.sorted(), "\(context): switch must evict everyone")
                if target.layout == .sixths { switchesToSixths += 1 } else { switchesToQuarters += 1 }
                for evicted in evicting { state.remove(window: evicted) }
                state.commit(window: requester, into: target)
                XCTAssertEqual(state.occupants, [target: requester], "\(context): switch left strays")
            }
            assertHealthy(state, context: context)
            if case .swap = plan {
                XCTAssertEqual(
                    state.plan(window: requester, into: target), .noop,
                    "\(context): requester not settled after swap")
            }
        }

        XCTAssertGreaterThan(swaps, 100, "walk barely shuffled (swaps=\(swaps))")
        XCTAssertGreaterThan(evictingTiles, 30, "walk barely evicted (\(evictingTiles))")
        XCTAssertGreaterThan(plainTiles, 100, "walk barely moved (\(plainTiles))")
        XCTAssertGreaterThan(switchesToSixths, 10, "walk never switched to sixths")
        XCTAssertGreaterThan(switchesToQuarters, 10, "walk never switched to quarters")
        XCTAssertGreaterThan(noops, 3, "walk never noop'd")
        XCTAssertEqual(state.activeLayout, state.occupants.keys.first?.layout ?? .quarters)
        _ = switches // counted via the directional counters above
    }
}
