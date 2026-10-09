@testable import tiled

/// An independent model of the plan rules: the expected outcome of one
/// request, stated in the oracle's own terms — Slots and Cells, the
/// vocabulary `CONTEXT.md` defines — never derived from the code under
/// test. The matrix cross-check sweeps the canvas against these
/// expectations, so a wrong re-housing home now disagrees with the
/// oracle instead of being agreed with by a second call into
/// `TilingState.rehousingHome`.
///
/// Every rule here is translated from `CONTEXT.md`'s Swap, Re-house,
/// and Reflow entries, quoted beside its translation. The only
/// production surface the oracle reads is the declarative slot geometry
/// (`Slot.cells`, the shared refinement the rules are written in, pinned
/// for itself by `GridLayoutTests`); no rule function — `plan`,
/// `rehousingHome`, `reflow` — is called.
enum MatrixOracle {
    /// What one request must do to the board: the plan shape, each
    /// re-housed victim's explicit expected home, and the whole expected
    /// final occupancy. A victim absent from `homes` is untiled
    /// (restored to its pre-tile frame).
    struct Expectation: Equatable {
        var plan: Plan
        var homes: [WindowID: Slot]
        var occupants: [Slot: WindowID]
    }

    /// The plan rules' shape, in the oracle's own terms.
    enum Plan: Equatable {
        case noop
        case switchLayout
        case swap(displaced: WindowID)
        case tile(evicting: [WindowID])
    }

    /// The expected outcome of `requester` claiming `target` on `board`.
    /// Stated before the canvas runs, so the canvas is compared against
    /// a prediction, not against its own echo.
    static func expectation(
        occupants board: [Slot: WindowID], requester: WindowID, target: Slot
    ) -> Expectation {
        // "The window already occupies the slot; nothing happens."
        if board[target] == requester {
            return Expectation(plan: .noop, homes: [:], occupants: board)
        }
        // "A request in the other layout switches the space's layout,
        // untileing every tiled window": layouts are mutually exclusive.
        let active = board.keys.first.map(\.layout) ?? .sixths
        if !board.isEmpty, target.layout != active {
            return Expectation(plan: .switchLayout, homes: [:], occupants: [target: requester])
        }
        let blockers = board
            .filter { $0.value != requester && $0.key.overlaps(target) }
            .map(\.value)
            .sorted()
        let vacated = slot(of: requester, in: board)
        // "A blocker whose leftover (its slot minus the target) is
        // exactly one whole slot never swaps — it steps aside instead":
        // the swap stands only when no step-aside home exists.
        if blockers.count == 1, let vacated, !vacated.overlaps(target),
            stepAsideHome(of: blockers[0], target: target, board: board) == nil
        {
            // "the blocker lands in the tile the requester vacated,
            // nobody is untiled".
            var occupants = board
            if let displacedSlot = slot(of: blockers[0], in: board) {
                occupants.removeValue(forKey: displacedSlot)
            }
            occupants.removeValue(forKey: vacated)
            occupants[vacated] = blockers[0]
            occupants[target] = requester
            return Expectation(
                plan: .swap(displaced: blockers[0]), homes: [:], occupants: occupants)
        }
        return tileOutcome(
            evicting: blockers, requester: requester, target: target,
            vacated: vacated, board: board)
    }

    // MARK: Tile: re-house, then reflow

    /// The tile plan's outcome: the requester lands, every evictee
    /// either re-houses or is untiled, and the freed cells reflow into
    /// one survivor.
    ///
    /// The canvas re-houses a lone evictee only ("a lone evictee need
    /// not lose its tiling"; with more than one blocker everyone goes
    /// home), and an expanded window never re-houses — the matrix has
    /// no expanded windows, so expansion stays pinned where it lives
    /// (`ReflowTests.testExpandedSurvivorNeverGrows`).
    private static func tileOutcome(
        evicting: [WindowID], requester: WindowID, target: Slot,
        vacated: Slot?, board: [Slot: WindowID]
    ) -> Expectation {
        var homes: [WindowID: Slot] = [:]
        if evicting.count == 1,
            let home = rehousingHome(
                of: evicting[0], target: target, vacated: vacated, board: board)
        {
            homes[evicting[0]] = home
        }
        var occupants = board
        for evictee in evicting {
            if let former = slot(of: evictee, in: board) {
                occupants.removeValue(forKey: former)
            }
        }
        if let vacated { occupants.removeValue(forKey: vacated) }
        occupants[target] = requester
        for (evictee, home) in homes {
            occupants[home] = evictee
        }
        // "its freed cells merge with exactly one adjacent survivor into
        // a whole slot, and that survivor grows into it": the eviction
        // remainders and the requester's vacated tile.
        var freed: Set<TileCell> = Set(
            evicting.compactMap { slot(of: $0, in: board) }.flatMap(\.cells))
        if let vacated { freed.formUnion(vacated.cells) }
        reflow(&occupants, freed: freed, excluding: Set(evicting + [requester]))
        return Expectation(plan: .tile(evicting: evicting), homes: homes, occupants: occupants)
    }

    /// The Re-house rule: "Two rules, step-aside checked first, both
    /// exact-or-nil". A leftover or free region that is not exactly one
    /// whole slot has no unambiguous home, so the evictee untiles.
    private static func rehousingHome(
        of evictee: WindowID, target: Slot, vacated: Slot?, board: [Slot: WindowID]
    ) -> Slot? {
        if let aside = stepAsideHome(of: evictee, target: target, board: board) {
            return aside
        }
        guard let current = slot(of: evictee, in: board), current.overlaps(target) else {
            return nil
        }
        // Free region: "when the cells left free after the request form
        // exactly one whole slot, the evicted window re-tiles into that
        // slot. The region may include cells that were free before the
        // request" — and the requester's vacated tile is freed too.
        var claimed: Set<TileCell> = target.cells
        for (slot, window) in board where window != evictee && slot != vacated {
            claimed.formUnion(slot.cells)
        }
        let free = Set(TileCell.allCases).subtracting(claimed)
        return Slot.allCases.first { $0.layout == target.layout && $0.cells == free }
    }

    /// Step-aside: "when the evictee's slot overlaps the requested slot
    /// and its leftover — its slot minus the request — is exactly one
    /// whole slot, the blocker steps aside into that leftover". Every
    /// pair whose leftover is a whole slot is written out by hand here,
    /// with the home the rule names — these are the rule's explicit
    /// expected homes, not a recomputation — plus the guard that "no
    /// other occupant holds" the leftover's cells.
    private static let stepAsideHomes: [(blocker: Slot, target: Slot, aside: Slot)] = [
        // Quarters: a half blocking one of its quads steps into the
        // other quad ("the left half into the bottom-left quad").
        (.leftHalf, .topLeft, .bottomLeft),
        (.leftHalf, .bottomLeft, .topLeft),
        (.rightHalf, .topRight, .bottomRight),
        (.rightHalf, .bottomRight, .topRight),
        // Sixths: a third blocking one of its sixth halves steps into
        // the other ("the left third requested at its top sixth steps
        // down into the bottom-left sixth").
        (.sixthLeft, .sixthTopLeft, .sixthBottomLeft),
        (.sixthLeft, .sixthBottomLeft, .sixthTopLeft),
        (.sixthMiddle, .sixthTopMiddle, .sixthBottomMiddle),
        (.sixthMiddle, .sixthBottomMiddle, .sixthTopMiddle),
        (.sixthRight, .sixthTopRight, .sixthBottomRight),
        (.sixthRight, .sixthBottomRight, .sixthTopRight),
        // A two-thirds blocking one of its thirds steps into the other
        // ("a two-thirds into the third its request leaves clean").
        (.sixthsLeftTwoThirds, .sixthLeft, .sixthMiddle),
        (.sixthsLeftTwoThirds, .sixthMiddle, .sixthLeft),
        (.sixthsRightTwoThirds, .sixthRight, .sixthMiddle),
        (.sixthsRightTwoThirds, .sixthMiddle, .sixthRight),
        // The one overlap that is not a containment: two two-thirds
        // crossing step into the third their request leaves clean ("a
        // left two-thirds blocking a right two-thirds request — steps
        // aside into the left third").
        (.sixthsLeftTwoThirds, .sixthsRightTwoThirds, .sixthLeft),
        (.sixthsRightTwoThirds, .sixthsLeftTwoThirds, .sixthRight),
    ]

    private static func stepAsideHome(
        of evictee: WindowID, target: Slot, board: [Slot: WindowID]
    ) -> Slot? {
        guard let current = slot(of: evictee, in: board), current.overlaps(target) else {
            return nil
        }
        guard let row = stepAsideHomes.first(where: {
            $0.blocker == current && $0.target == target
        }) else { return nil }
        // The leftover is the evictee's own cells minus the request's:
        // no other occupant may stand in it (a valid board never holds
        // one, so the guard only rules on paper).
        let leftover = row.aside.cells
        let intruder = board.contains { occupant in
            occupant.value != evictee && !occupant.key.cells.isDisjoint(with: leftover)
        }
        return intruder ? nil : row.aside
    }

    // MARK: Reflow

    /// Reflow: "its freed cells merge with exactly one adjacent survivor
    /// into a whole slot, and that survivor grows into it — rightmost
    /// candidate wins ties. A hole no survivor merges into exactly stays
    /// empty; the requester and expanded windows never grow." The freed
    /// cells still covered by an occupant are not free at all.
    private static func reflow(
        _ occupants: inout [Slot: WindowID], freed: Set<TileCell>,
        excluding: Set<WindowID>
    ) {
        var free = freed
        for slot in occupants.keys { free.subtract(slot.cells) }
        while !free.isEmpty {
            let candidates: [(window: WindowID, from: Slot, grown: Slot)] = occupants
                .filter { !excluding.contains($0.value) }
                .compactMap { slot, window in
                    let union = slot.cells.union(free)
                    guard
                        let grown = Slot.allCases.first(where: {
                            $0.layout == slot.layout && $0.cells == union
                        })
                    else { return nil }
                    return (window, slot, grown)
                }
            guard let best = candidates.max(by: { lhs, rhs in
                // Rightmost candidate wins ties: the grown slot reaching
                // furthest right, then the larger slot, then declaration
                // order for total determinism.
                let left = lhs.grown.geometry, right = rhs.grown.geometry
                if left.columns.upperBound != right.columns.upperBound {
                    return left.columns.upperBound < right.columns.upperBound
                }
                if lhs.grown.cells.count != rhs.grown.cells.count {
                    return lhs.grown.cells.count < rhs.grown.cells.count
                }
                return (Slot.allCases.firstIndex(of: lhs.grown) ?? 0)
                    > (Slot.allCases.firstIndex(of: rhs.grown) ?? 0)
            }) else { break }
            occupants.removeValue(forKey: best.from)
            occupants[best.grown] = best.window
            free.subtract(best.grown.cells)
        }
    }

    // MARK: Vocabulary

    private static func slot(of window: WindowID, in board: [Slot: WindowID]) -> Slot? {
        board.first { $0.value == window }?.key
    }
}
