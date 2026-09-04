import Carbon.HIToolbox
import XCTest
@testable import tiled

final class TilingStateTests: XCTestCase {
    private let a = 1
    private let b = 2
    private let c = 3

    // MARK: Basics

    func testTileIntoEmptySlot() {
        var state = TilingState()
        XCTAssertEqual(state.plan(window: a, into: .topLeft), .tile(evicting: []))
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.occupant(of: .topLeft), a)
        XCTAssertEqual(state.slot(of: a), .topLeft)
    }

    func testToggleUntiles() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.plan(window: a, into: .topLeft), .untile)
        state.remove(window: a)
        XCTAssertNil(state.occupant(of: .topLeft))
        XCTAssertNil(state.slot(of: a))
    }

    func testSecondWindowIntoOccupiedSlotEvictsFirst() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.plan(window: b, into: .topLeft), .tile(evicting: [a]))
    }

    // MARK: Eviction rules (as decided in design)

    func testHalfOverTwoQuadsEvictsBoth() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        XCTAssertEqual(state.plan(window: c, into: .leftHalf), .tile(evicting: [a, b]))
    }

    func testQuadOverOccupiedHalfEvictsHalf() {
        var state = TilingState()
        state.commit(window: a, into: .leftHalf)
        XCTAssertEqual(state.plan(window: b, into: .bottomLeft), .tile(evicting: [a]))
    }

    func testQuadOverOccupiedHalfEvictsHalfOtherQuad() {
        var state = TilingState()
        state.commit(window: a, into: .rightHalf)
        XCTAssertEqual(state.plan(window: b, into: .topRight), .tile(evicting: [a]))
    }

    func testHalfOverOccupiedQuadEvictsQuad() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.plan(window: b, into: .leftHalf), .tile(evicting: [a]))
    }

    func testDisjointSlotsCoexist() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.plan(window: b, into: .rightHalf), .tile(evicting: []))
        state.commit(window: b, into: .rightHalf)
        XCTAssertEqual(state.occupant(of: .topLeft), a)
        XCTAssertEqual(state.occupant(of: .rightHalf), b)
    }

    func testQuadsInSameColumnCoexist() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.plan(window: b, into: .bottomLeft), .tile(evicting: []))
    }

    // MARK: Moving within the layout

    func testWindowMovingToOverlappingSlotDoesNotEvictItself() {
        // Window in Left requests BL: moves, keeps its pre-tile frame.
        var state = TilingState()
        state.commit(window: a, into: .leftHalf)
        XCTAssertEqual(state.plan(window: a, into: .bottomLeft), .tile(evicting: []))
        state.commit(window: a, into: .bottomLeft)
        XCTAssertNil(state.occupant(of: .leftHalf))
        XCTAssertEqual(state.occupant(of: .bottomLeft), a)
    }

    func testWindowTiledIntoSecondSlotLeavesFirst() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: a, into: .bottomRight)
        XCTAssertNil(state.occupant(of: .topLeft))
        XCTAssertEqual(state.occupant(of: .bottomRight), a)
    }

    func testRemoveCleansUp() {
        var state = TilingState()
        state.commit(window: a, into: .leftHalf)
        state.remove(window: a)
        XCTAssertTrue(state.occupants.isEmpty)
    }

    // MARK: Overlap matrix

    func testSlotCells() {
        XCTAssertEqual(Slot.topLeft.cells, [.col0Top, .col1Top])
        XCTAssertEqual(Slot.topRight.cells, [.col2Top, .col3Top])
        XCTAssertEqual(Slot.bottomLeft.cells, [.col0Bottom, .col1Bottom])
        XCTAssertEqual(Slot.bottomRight.cells, [.col2Bottom, .col3Bottom])
        XCTAssertEqual(
            Slot.leftHalf.cells,
            [.col0Top, .col1Top, .col0Bottom, .col1Bottom])
        XCTAssertEqual(
            Slot.rightHalf.cells,
            [.col2Top, .col3Top, .col2Bottom, .col3Bottom])
        // Sixths spot checks; the full matrix below pins the rest.
        XCTAssertEqual(Slot.sixthTopLeft.cells, [.col0Top])
        XCTAssertEqual(Slot.sixthTopMiddle.cells, [.col1Top, .col2Top])
        XCTAssertEqual(Slot.sixthLeft.cells, [.col0Top, .col0Bottom])
        XCTAssertEqual(
            Slot.sixthMiddle.cells,
            [.col1Top, .col2Top, .col1Bottom, .col2Bottom])
        XCTAssertEqual(
            Slot.sixthsLeftTwoThirds.cells,
            [.col0Top, .col1Top, .col2Top, .col0Bottom, .col1Bottom, .col2Bottom])
        XCTAssertEqual(
            Slot.sixthsRightTwoThirds.cells,
            [.col1Top, .col2Top, .col3Top, .col1Bottom, .col2Bottom, .col3Bottom])
    }

    func testOverlapIsCompleteAndSymmetric() {
        // Halves overlap their own quads (all 8 combos), nothing else.
        let halves: [(Slot, Slot, Slot)] = [
            (.leftHalf, .topLeft, .bottomLeft),
            (.rightHalf, .topRight, .bottomRight),
        ]
        for (half, first, second) in halves {
            XCTAssertTrue(half.overlaps(first))
            XCTAssertTrue(half.overlaps(second))
            XCTAssertTrue(first.overlaps(half))
            XCTAssertTrue(second.overlaps(half))
        }
        XCTAssertFalse(Slot.leftHalf.overlaps(.topRight))
        XCTAssertFalse(Slot.leftHalf.overlaps(.bottomRight))
        XCTAssertFalse(Slot.rightHalf.overlaps(.topLeft))
        XCTAssertFalse(Slot.rightHalf.overlaps(.bottomLeft))
        // Every slot overlaps itself; the two halves never overlap each other.
        for slot in Slot.allCases {
            XCTAssertTrue(slot.overlaps(slot))
        }
        XCTAssertFalse(Slot.leftHalf.overlaps(.rightHalf))
        XCTAssertFalse(Slot.rightHalf.overlaps(.leftHalf))
        let quads: [Slot] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        for first in quads {
            for second in quads where first != second {
                XCTAssertFalse(first.overlaps(second))
                XCTAssertFalse(second.overlaps(first))
            }
        }
    }

    func testOverlapMatchesCellIntersection() {
        // overlaps() must agree with raw cell-set intersection for every pair.
        for first in Slot.allCases {
            for second in Slot.allCases {
                XCTAssertEqual(
                    first.overlaps(second),
                    !first.cells.isDisjoint(with: second.cells),
                    "\(first.rawValue) vs \(second.rawValue)")
            }
        }
    }

    func testCrossLayoutOverlaps() {
        // Quarters TL covers strips 0-1 top; sixths left/middle thirds sit
        // inside or across it accordingly.
        XCTAssertTrue(Slot.topLeft.overlaps(.sixthTopLeft))
        XCTAssertTrue(Slot.topLeft.overlaps(.sixthTopMiddle))
        XCTAssertFalse(Slot.topLeft.overlaps(.sixthTopRight))
        XCTAssertFalse(Slot.topLeft.overlaps(.sixthBottomLeft))
        XCTAssertTrue(Slot.leftHalf.overlaps(.sixthLeft))
        XCTAssertTrue(Slot.leftHalf.overlaps(.sixthMiddle))
        XCTAssertFalse(Slot.leftHalf.overlaps(.sixthRight))
        XCTAssertTrue(Slot.leftHalf.overlaps(.sixthsLeftTwoThirds))
        XCTAssertTrue(Slot.leftHalf.overlaps(.sixthsRightTwoThirds))
        // Middle sixth straddles the quarters column split.
        XCTAssertTrue(Slot.sixthMiddle.overlaps(.leftHalf))
        XCTAssertTrue(Slot.sixthMiddle.overlaps(.rightHalf))
        XCTAssertTrue(Slot.sixthMiddle.overlaps(.sixthTopMiddle))
        XCTAssertFalse(Slot.sixthMiddle.overlaps(.sixthTopLeft))
        XCTAssertFalse(Slot.sixthMiddle.overlaps(.sixthTopRight))
    }

    func testSlotPresentation() {
        XCTAssertEqual(Slot.allCases.count, 17)
        for slot in Slot.allCases {
            XCTAssertFalse(slot.title.isEmpty)
            XCTAssertFalse(slot.hotkeyLabel.isEmpty)
        }
        XCTAssertEqual(Slot.topLeft.title, "Top Left")
        XCTAssertEqual(Slot.leftHalf.title, "Left Half")
        XCTAssertEqual(Slot.sixthTopLeft.title, "Top Left Sixth")
        XCTAssertEqual(Set(Slot.allCases.map(\.hotkeyLabel)).count, 17) // labels unique
    }

    func testHotkeys() {
        // Quarters keep the bare ⌥⇧ keys; sixths add ⌘ on the requested keys.
        let shiftOption = UInt32(shiftKey | optionKey)
        let withCommand = UInt32(shiftKey | optionKey | cmdKey)
        for slot in Slot.allCases {
            switch slot.layout {
            case .quarters: XCTAssertEqual(slot.modifiers, shiftOption, "\(slot.rawValue)")
            case .sixths: XCTAssertEqual(slot.modifiers, withCommand, "\(slot.rawValue)")
            }
        }
        let expected: [(Slot, UInt32)] = [
            (.topLeft, UInt32(kVK_ANSI_U)),
            (.sixthTopLeft, UInt32(kVK_ANSI_U)),
            (.sixthTopMiddle, UInt32(kVK_ANSI_I)),
            (.topRight, UInt32(kVK_ANSI_O)),
            (.sixthTopRight, UInt32(kVK_ANSI_O)),
            (.bottomLeft, UInt32(kVK_ANSI_M)),
            (.sixthBottomLeft, UInt32(kVK_ANSI_M)),
            (.sixthBottomMiddle, UInt32(kVK_ANSI_Comma)),
            (.bottomRight, UInt32(kVK_ANSI_Period)),
            (.sixthBottomRight, UInt32(kVK_ANSI_Period)),
            (.leftHalf, UInt32(kVK_ANSI_J)),
            (.sixthLeft, UInt32(kVK_ANSI_J)),
            (.sixthMiddle, UInt32(kVK_ANSI_K)),
            (.rightHalf, UInt32(kVK_ANSI_L)),
            (.sixthRight, UInt32(kVK_ANSI_L)),
            (.sixthsLeftTwoThirds, UInt32(kVK_ANSI_H)),
            (.sixthsRightTwoThirds, UInt32(kVK_ANSI_Semicolon)),
        ]
        XCTAssertEqual(expected.count, Slot.allCases.count)
        for (slot, keyCode) in expected {
            XCTAssertEqual(slot.keyCode, keyCode, "\(slot.rawValue)")
        }
    }

    // MARK: Edge cases

    func testPlanIntoEmptySlotEvictsNothing() {
        // Untouched state: nothing to evict from any slot.
        for slot in Slot.allCases {
            XCTAssertEqual(
                TilingState().plan(window: a, into: slot), .tile(evicting: []))
        }
    }

    func testEvictionsAreSorted() {
        // Deterministic order: evicted ids come back sorted, not in slot order.
        var state = TilingState()
        state.commit(window: c, into: .topLeft)
        state.commit(window: a, into: .bottomLeft)
        XCTAssertEqual(state.plan(window: b, into: .leftHalf), .tile(evicting: [a, c]))
    }

    func testRightHalfOverTwoQuadsEvictsBoth() {
        var state = TilingState()
        state.commit(window: a, into: .topRight)
        state.commit(window: b, into: .bottomRight)
        XCTAssertEqual(state.plan(window: c, into: .rightHalf), .tile(evicting: [a, b]))
    }

    func testQuadOverOccupiedHalfKeepsOtherSide() {
        // Tiling TL over a full left+right layout evicts Left only; Right stays.
        var state = TilingState()
        state.commit(window: a, into: .leftHalf)
        state.commit(window: b, into: .rightHalf)
        XCTAssertEqual(state.plan(window: c, into: .topLeft), .tile(evicting: [a]))
        state.remove(window: a) // controller untiles evicted windows before placing
        state.commit(window: c, into: .topLeft)
        XCTAssertEqual(state.occupant(of: .topLeft), c)
        XCTAssertEqual(state.occupant(of: .rightHalf), b)
        XCTAssertNil(state.occupant(of: .leftHalf))
    }

    func testSameWindowRetilingSameSlotToggles() {
        // Already covered for quads; halves toggle too.
        var state = TilingState()
        state.commit(window: a, into: .leftHalf)
        XCTAssertEqual(state.plan(window: a, into: .leftHalf), .untile)
    }

    func testDifferentWindowIntoOccupiedHalfEvicts() {
        var state = TilingState()
        state.commit(window: a, into: .rightHalf)
        XCTAssertEqual(state.plan(window: b, into: .rightHalf), .tile(evicting: [a]))
        state.remove(window: a) // controller untiles evicted windows before placing
        state.commit(window: b, into: .rightHalf)
        XCTAssertEqual(state.occupant(of: .rightHalf), b)
        XCTAssertEqual(state.slot(of: b), .rightHalf)
        XCTAssertNil(state.slot(of: a))
    }

    func testQuadExpandingToHalfEvictsColumnMate() {
        // TR expands to RightHalf while BR sits there: BR is evicted.
        // (Requester is tiled, but its vacated quad is INSIDE the target,
        // so there is no free space to relocate BR into.)
        var state = TilingState()
        state.commit(window: a, into: .topRight)
        state.commit(window: b, into: .bottomRight)
        XCTAssertEqual(
            state.plan(window: a, into: .rightHalf), .tile(evicting: [b]))
    }

    func testQuadRequestIntoHalfBlockerRelocatesToOtherQuad() {
        // TL -> BL (occupied by LeftHalf): the freed TL quad is exactly
        // enough for the half-window, which demotes to the TL quad.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .leftHalf)
        XCTAssertEqual(
            state.plan(window: a, into: .bottomLeft),
            .swap(placements: [a: .bottomLeft, b: .topLeft]))
        if case .swap(let placements) = state.plan(window: a, into: .bottomLeft) {
            state.commitSwaps(placements)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .bottomLeft), a)
        XCTAssertEqual(state.occupant(of: .topLeft), b)
        XCTAssertNil(state.occupant(of: .leftHalf))
    }

    func testFullScreenOfQuadsThenHalfEvictsColumnOnly() {
        // TL+BL+TR tiled; Left evicts the left column, TR survives.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        state.commit(window: c, into: .topRight)
        let d = 4
        XCTAssertEqual(state.plan(window: d, into: .leftHalf), .tile(evicting: [a, b]))
        state.remove(window: a)
        state.remove(window: b)
        state.commit(window: d, into: .leftHalf)
        XCTAssertEqual(state.occupant(of: .leftHalf), d)
        XCTAssertEqual(state.occupant(of: .topRight), c)
        XCTAssertNil(state.slot(of: a))
        XCTAssertNil(state.slot(of: b))
    }

    func testCommitClearsPendingEvictions() {
        // The caller removes evicted windows, then commits: no ghost occupants.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        let plan = state.plan(window: c, into: .leftHalf)
        XCTAssertEqual(plan, .tile(evicting: [a, b]))
        if case .tile(let evicting) = plan {
            for evicted in evicting { state.remove(window: evicted) }
        }
        state.commit(window: c, into: .leftHalf)
        XCTAssertEqual(state.occupants, [.leftHalf: c])
        XCTAssertEqual(state.tiledWindows, [c])
    }

    func testRemoveUnknownWindowIsNoop() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.remove(window: 999)
        XCTAssertEqual(state.occupant(of: .topLeft), a)
        XCTAssertEqual(state.tiledWindows, [a])
    }

    func testWindowMovesBetweenDisjointSlots() {
        // TL -> RightHalf: leaves the quad, no eviction.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.plan(window: a, into: .rightHalf), .tile(evicting: []))
        state.commit(window: a, into: .rightHalf)
        XCTAssertNil(state.occupant(of: .topLeft))
        XCTAssertEqual(state.occupant(of: .rightHalf), a)
    }

    // MARK: Swapping

    func testQuadToOccupiedQuadSwaps() {
        // TL -> occupied BR: the two windows exchange places, nobody is untiled.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomRight)
        XCTAssertEqual(
            state.plan(window: a, into: .bottomRight),
            .swap(placements: [a: .bottomRight, b: .topLeft]))
        if case .swap(let placements) = state.plan(window: a, into: .bottomRight) {
            state.commitSwaps(placements)
        }
        XCTAssertEqual(state.occupant(of: .bottomRight), a)
        XCTAssertEqual(state.occupant(of: .topLeft), b)
        XCTAssertEqual(state.tiledWindows.sorted(), [a, b])
    }

    func testHalfToOccupiedQuadSwapsAndStaysWhole() {
        // LeftHalf -> occupied TR: the half moves to the quad, the quad
        // window takes over the whole half (not just one of its quads).
        var state = TilingState()
        state.commit(window: a, into: .leftHalf)
        state.commit(window: b, into: .topRight)
        XCTAssertEqual(
            state.plan(window: a, into: .topRight),
            .swap(placements: [a: .topRight, b: .leftHalf]))
        if case .swap(let placements) = state.plan(window: a, into: .topRight) {
            state.commitSwaps(placements)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .topRight), a)
        XCTAssertEqual(state.occupant(of: .leftHalf), b)
        XCTAssertEqual(state.tiledWindows.sorted(), [a, b])
    }

    func testQuadToOccupiedHalfSwapsIntoVacatedQuad() {
        // TR -> TL (occupied by LeftHalf): quad takes TL, the half-window
        // takes over the vacated TR quad.
        var state = TilingState()
        state.commit(window: a, into: .topRight)
        state.commit(window: b, into: .leftHalf)
        XCTAssertEqual(
            state.plan(window: a, into: .topLeft),
            .swap(placements: [a: .topLeft, b: .topRight]))
        if case .swap(let placements) = state.plan(window: a, into: .topLeft) {
            state.commitSwaps(placements)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .topLeft), a)
        XCTAssertEqual(state.occupant(of: .topRight), b)
        XCTAssertNil(state.occupant(of: .leftHalf))
    }

    func testTwoHalvesSwap() {
        var state = TilingState()
        state.commit(window: a, into: .leftHalf)
        state.commit(window: b, into: .rightHalf)
        if case .swap(let placements) = state.plan(window: a, into: .rightHalf) {
            XCTAssertEqual(placements, [a: .rightHalf, b: .leftHalf])
            state.commitSwaps(placements)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .rightHalf), a)
        XCTAssertEqual(state.occupant(of: .leftHalf), b)
        XCTAssertEqual(state.tiledWindows.sorted(), [a, b])
    }

    func testAdjacentQuadsSwap() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        XCTAssertEqual(
            state.plan(window: a, into: .bottomLeft),
            .swap(placements: [a: .bottomLeft, b: .topLeft]))
        if case .swap(let placements) = state.plan(window: a, into: .bottomLeft) {
            state.commitSwaps(placements)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .bottomLeft), a)
        XCTAssertEqual(state.occupant(of: .topLeft), b)
    }

    func testSwapBacktracksWhenLargestFirstFails() {
        // RightHalf -> LeftHalf (occupied by two quads): greedy would give
        // the whole right half to the first blocker and strand the second,
        // so it must split into TR + BR instead.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        state.commit(window: c, into: .rightHalf)
        XCTAssertEqual(
            state.plan(window: c, into: .leftHalf),
            .swap(placements: [c: .leftHalf, a: .topRight, b: .bottomRight]))
        if case .swap(let placements) = state.plan(window: c, into: .leftHalf) {
            state.commitSwaps(placements)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .leftHalf), c)
        XCTAssertEqual(state.occupant(of: .topRight), a)
        XCTAssertEqual(state.occupant(of: .bottomRight), b)
        XCTAssertNil(state.occupant(of: .rightHalf))
    }

    func testSwapRoundTripRestoresLayout() {
        // Swapping twice returns both windows to their original slots.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomRight)
        if case .swap(let first) = state.plan(window: a, into: .bottomRight) {
            state.commitSwaps(first)
        } else {
            XCTFail("expected a swap")
        }
        if case .swap(let second) = state.plan(window: a, into: .topLeft) {
            state.commitSwaps(second)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .topLeft), a)
        XCTAssertEqual(state.occupant(of: .bottomRight), b)
    }

    func testSwapIsExhaustiveAndLeavesNoGhosts() {
        // Same-layout pairs only (cross-layout pairs reset; covered by the
        // layout-switch tests below). Every tiled-requester/occupied-target
        // pair yields exactly one of untile / plain tile / swap / eviction,
        // and committing the plan always leaves one window per slot, no
        // window in two slots, no overlap between different windows, and
        // counts conserved (swap keeps all, eviction drops exactly the
        // evicted). Swept over disjoint quarters layouts so every quarters
        // slot type acts as the requester.
        let layouts: [[Slot]] = [
            [.topLeft, .topRight, .bottomLeft, .bottomRight],
            [.leftHalf, .topRight, .bottomRight],
            [.rightHalf, .topLeft, .bottomLeft],
            [.leftHalf, .rightHalf],
        ]
        var id = 1
        for layout in layouts {
            for requester in layout {
                for target in Slot.allCases where target.layout == requester.layout {
                    var state = TilingState()
                    var slotByWindow: [WindowID: Slot] = [:]
                    for slot in layout {
                        state.commit(window: id, into: slot)
                        slotByWindow[id] = slot
                        id += 1
                    }
                    let requesterWindow = slotByWindow.first(where: { $0.value == requester })!.key
                    let before = Set(state.tiledWindows)
                    // Independent oracle: brute-force product enumeration over
                    // candidate slots (written plainly, no size heuristic),
                    // cross-checked against plan() so a degraded solver that
                    // evicts where a swap fits cannot slip through.
                    // Mirrors plan(): slots overlapping the target other than
                    // the requester's own (a window never contends with
                    // itself). Note the target slot itself stays: its
                    // occupant is the swap/evict candidate.
                    let blockers = layout.filter {
                        $0 != requester && $0.overlaps(target)
                    }
                    let free = requester.cells.subtracting(target.cells)
                    // No blockers means a plain move, not a swap.
                    let swapPossible = !blockers.isEmpty && Self.bruteForceFits(
                        count: blockers.count, within: free, layout: target.layout)
                    let plan = state.plan(window: requesterWindow, into: target)
                    if requester == target {
                        XCTAssertEqual(plan, .untile, "\(requester) -> \(target)")
                    } else if swapPossible {
                        guard case .swap = plan else {
                            XCTFail("\(requester) -> \(target): swap fits but got \(plan)")
                            continue
                        }
                    } else {
                        let expect = blockers.compactMap { blocker in
                            slotByWindow.first(where: { $0.value == blocker })?.key
                        }.sorted()
                        XCTAssertEqual(
                            plan, .tile(evicting: expect),
                            "\(requester) -> \(target)")
                    }
                    switch plan {
                    case .untile:
                        XCTAssertEqual(requester, target)
                        state.remove(window: requesterWindow)
                        XCTAssertNil(state.slot(of: requesterWindow))
                    case .tile(let evicting):
                        for evicted in evicting { state.remove(window: evicted) }
                        state.commit(window: requesterWindow, into: target)
                        XCTAssertEqual(state.occupant(of: target), requesterWindow)
                        for evicted in evicting {
                            XCTAssertNil(state.slot(of: evicted), "evicted win\(evicted) lingers")
                        }
                        XCTAssertEqual(
                            Set(state.tiledWindows),
                            before.subtracting(evicting),
                            "\(requester) -> \(target)")
                    case .swap(let placements):
                        XCTAssertEqual(placements[requesterWindow], target)
                        state.commitSwaps(placements)
                        XCTAssertEqual(state.occupant(of: target), requesterWindow)
                        XCTAssertEqual(
                            Set(state.tiledWindows), before,
                            "swap \(requester) -> \(target) lost a window")
                    case .switchLayout:
                        XCTFail("same-layout pair \(requester) -> \(target) reset")
                        continue
                    }
                    // Invariants after every commit path.
                    let windows = state.tiledWindows
                    XCTAssertEqual(windows.count, Set(windows).count)
                    var seenCells: Set<TileCell> = []
                    for (slot, occupant) in state.occupants {
                        XCTAssertEqual(state.slot(of: occupant), slot)
                        for cell in slot.cells {
                            XCTAssertFalse(
                                seenCells.contains(cell),
                                "\(requester) -> \(target): cell \(cell) double-booked")
                            seenCells.insert(cell)
                        }
                    }
                }
            }
        }
    }

    /// Brute-force oracle for the sweep above: tries every assignment of
    /// `count` blockers to cell-disjoint same-layout slots inside `free` via
    /// plain product enumeration (no largest-first heuristic, no pruning),
    /// so it fails independently if the solver under- or over-swaps.
    private static func bruteForceFits(count: Int, within free: Set<TileCell>, layout: LayoutKind) -> Bool {
        if count == 0 { return true }
        let candidates = Slot.allCases.filter {
            $0.layout == layout && $0.cells.isSubset(of: free)
        }
        var assignment = [Slot](repeating: .topLeft, count: count)
        func fits(_ index: Int) -> Bool {
            if index == count {
                var used: Set<TileCell> = []
                for slot in assignment {
                    if !slot.cells.isDisjoint(with: used) { return false }
                    used.formUnion(slot.cells)
                }
                return true
            }
            for candidate in candidates {
                assignment[index] = candidate
                if fits(index + 1) { return true }
            }
            return false
        }
        return fits(0)
    }

    // MARK: Layout switching

    func testActiveLayoutDefaultsToQuarters() {
        XCTAssertEqual(TilingState().activeLayout, .quarters)
    }

    func testCrossLayoutRequestResetsAndSwitches() {
        // Two quarters tiled; an untiled window requests a sixths slot:
        // everything is evicted and the layout switches.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomRight)
        XCTAssertEqual(state.activeLayout, .quarters)
        XCTAssertEqual(
            state.plan(window: c, into: .sixthTopLeft),
            .switchLayout(evicting: [a, b]))
        if case .switchLayout(let evicting) = state.plan(window: c, into: .sixthTopLeft) {
            for evicted in evicting { state.remove(window: evicted) }
        } else {
            XCTFail("expected a layout switch")
        }
        state.commit(window: c, into: .sixthTopLeft)
        XCTAssertEqual(state.occupants, [.sixthTopLeft: c])
        XCTAssertEqual(state.activeLayout, .sixths)
    }

    func testCrossLayoutRequestBackToQuarters() {
        var state = TilingState()
        state.commit(window: a, into: .sixthLeft)
        state.commit(window: b, into: .sixthRight)
        XCTAssertEqual(state.activeLayout, .sixths)
        XCTAssertEqual(
            state.plan(window: c, into: .topLeft),
            .switchLayout(evicting: [a, b]))
    }

    func testCrossLayoutToggleStillUntiles() {
        // Same slot, same window: toggle wins even across... (same layout by
        // definition, so this just pins that switchLayout never fires for it).
        var state = TilingState()
        state.commit(window: a, into: .sixthLeft)
        XCTAssertEqual(state.plan(window: a, into: .sixthLeft), .untile)
    }

    func testLayoutSwitchEvictionsAreSorted() {
        var state = TilingState()
        state.commit(window: c, into: .topLeft)
        state.commit(window: a, into: .bottomRight)
        XCTAssertEqual(
            state.plan(window: b, into: .sixthMiddle),
            .switchLayout(evicting: [a, c]))
    }

    func testTiledWindowRequestingOtherLayoutResetsToo() {
        // Even a tiled window resets when it targets the other layout — it
        // joins the evicted set rather than swapping across layouts.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomRight)
        XCTAssertEqual(
            state.plan(window: a, into: .sixthTopLeft),
            .switchLayout(evicting: [a, b]))
    }

    func testSixthsSwapWithinLayout() {
        // Sixths slots swap among themselves like quarters do.
        var state = TilingState()
        state.commit(window: a, into: .sixthLeft)
        state.commit(window: b, into: .sixthRight)
        XCTAssertEqual(
            state.plan(window: a, into: .sixthRight),
            .swap(placements: [a: .sixthRight, b: .sixthLeft]))
    }

    func testSixthsTwoThirdsOverThirdsEvicts() {
        // Left 2/3 over tiled Left+Middle thirds overlaps both while
        // vacating one third: no room, both evicted.
        var state = TilingState()
        state.commit(window: a, into: .sixthLeft)
        state.commit(window: b, into: .sixthMiddle)
        XCTAssertEqual(
            state.plan(window: c, into: .sixthsLeftTwoThirds),
            .tile(evicting: [a, b]))
    }

    func testSwapWithoutRoomFallsBackToEviction() {
        // All four quads tiled; TL -> RightHalf overlaps two windows but
        // vacates one quad, so both are evicted instead of swapped.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        state.commit(window: c, into: .topRight)
        let d = 4
        state.commit(window: d, into: .bottomRight)
        XCTAssertEqual(
            state.plan(window: a, into: .rightHalf), .tile(evicting: [c, d]))
    }

    func testUntiledRequesterAlwaysEvicts() {
        // An untiled window vacates nothing, so even a clean 1-for-1
        // takeover evicts rather than swaps.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomRight)
        XCTAssertEqual(state.plan(window: c, into: .bottomRight), .tile(evicting: [b]))
        XCTAssertEqual(state.plan(window: c, into: .leftHalf), .tile(evicting: [a]))
    }

    func testSwapKeepsDisjointWindowsInPlace() {
        // TL -> occupied BR swaps the pair; the other two quads are untouched.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomRight)
        state.commit(window: c, into: .topRight)
        let d = 4
        state.commit(window: d, into: .bottomLeft)
        if case .swap(let placements) = state.plan(window: a, into: .bottomRight) {
            state.commitSwaps(placements)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .bottomRight), a)
        XCTAssertEqual(state.occupant(of: .topLeft), b)
        XCTAssertEqual(state.occupant(of: .topRight), c)
        XCTAssertEqual(state.occupant(of: .bottomLeft), d)
    }

    func testThirdWindowIntoDisjointSlotCoexists() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        XCTAssertEqual(state.plan(window: c, into: .topRight), .tile(evicting: []))
        state.commit(window: c, into: .topRight)
        XCTAssertEqual(state.tiledWindows.sorted(), [a, b, c])
    }
}
