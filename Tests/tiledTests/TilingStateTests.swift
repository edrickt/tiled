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

    func testSlotQuads() {
        XCTAssertEqual(Slot.topLeft.quads, [.topLeft])
        XCTAssertEqual(Slot.topRight.quads, [.topRight])
        XCTAssertEqual(Slot.bottomLeft.quads, [.bottomLeft])
        XCTAssertEqual(Slot.bottomRight.quads, [.bottomRight])
        XCTAssertEqual(Slot.leftHalf.quads, [.topLeft, .bottomLeft])
        XCTAssertEqual(Slot.rightHalf.quads, [.topRight, .bottomRight])
    }

    func testSlotOverlapMatrix() {
        XCTAssertTrue(Slot.topLeft.overlaps(.leftHalf))
        XCTAssertTrue(Slot.bottomLeft.overlaps(.leftHalf))
        XCTAssertTrue(Slot.topRight.overlaps(.rightHalf))
        XCTAssertTrue(Slot.bottomRight.overlaps(.rightHalf))
        XCTAssertFalse(Slot.topLeft.overlaps(.rightHalf))
        XCTAssertFalse(Slot.leftHalf.overlaps(.rightHalf))
        XCTAssertFalse(Slot.topLeft.overlaps(.topRight))
        XCTAssertFalse(Slot.topLeft.overlaps(.bottomLeft))
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
        // Every slot overlaps itself; quads never overlap each other.
        for slot in Slot.allCases {
            XCTAssertTrue(slot.overlaps(slot))
        }
        let quads: [Slot] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        for first in quads {
            for second in quads where first != second {
                XCTAssertFalse(first.overlaps(second))
                XCTAssertFalse(second.overlaps(first))
            }
        }
    }

    func testSlotPresentation() {
        XCTAssertEqual(Slot.allCases.count, 6)
        for slot in Slot.allCases {
            XCTAssertFalse(slot.title.isEmpty)
            XCTAssertFalse(slot.hotkeyLabel.isEmpty)
        }
        XCTAssertEqual(Slot.topLeft.title, "Top Left")
        XCTAssertEqual(Slot.leftHalf.title, "Left Half")
        XCTAssertEqual(Set(Slot.allCases.map(\.hotkeyLabel)).count, 6) // labels unique
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
        state.commit(window: b, into: .rightHalf)
        XCTAssertEqual(state.occupant(of: .rightHalf), b)
        XCTAssertEqual(state.slot(of: b), .rightHalf)
        XCTAssertNil(state.slot(of: a))
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
    }

    func testTwoHalvesSwap() {
        var state = TilingState()
        state.commit(window: a, into: .leftHalf)
        state.commit(window: b, into: .rightHalf)
        XCTAssertEqual(
            state.plan(window: a, into: .rightHalf),
            .swap(placements: [a: .rightHalf, b: .leftHalf]))
    }

    func testAdjacentQuadsSwap() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        XCTAssertEqual(
            state.plan(window: a, into: .bottomLeft),
            .swap(placements: [a: .bottomLeft, b: .topLeft]))
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
