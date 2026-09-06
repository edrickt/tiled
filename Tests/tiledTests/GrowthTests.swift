import XCTest
@testable import tiled

/// No-gap growth after an uncontended move: a window moving to a disjoint
/// slot vacates cells, and when those cells merge with exactly one adjacent
/// occupant into one whole slot, that neighbor grows into them — the move
/// never leaves slack a neighbor could take (the max-space ethic, the same
/// exact-or-empty rule the evict reflow uses). Two left sixths with the top
/// one moving to the middle third is the canonical case: the bottom sixth
/// expands into the left third. A hole no neighbor merges into exactly
/// stays a hole; fresh windows vacate nothing and never grow anyone.
final class GrowthTests: XCTestCase {
    private let a = 1
    private let b = 2

    // MARK: The canonical grow

    func testTopLeftSixthToMiddleThirdGrowsBottomIntoLeftThird() {
        // a=sixthTopLeft, b=sixthBottomLeft; a -> sixthMiddle vacates
        // col0Top, which merges with b's col0Bottom into the left third.
        var state = TilingState()
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: b, into: .sixthBottomLeft)

        let plan = state.plan(window: a, into: .sixthMiddle)

        XCTAssertEqual(plan, .swap(placements: [a: .sixthMiddle, b: .sixthLeft]))
        if case .swap(let placements) = plan {
            state.commitSwaps(placements)
        } else {
            return XCTFail("expected a growth swap, got \(plan)")
        }
        XCTAssertEqual(state.occupant(of: .sixthMiddle), a)
        XCTAssertEqual(state.occupant(of: .sixthLeft), b, "the bottom sixth grew upwards")
        XCTAssertEqual(Set(state.tiledWindows), [a, b])
        XCTAssertEqual(state.plan(window: a, into: .sixthMiddle), .noop)
    }

    func testTopLeftQuadToTopRightGrowsBottomIntoLeftHalf() {
        // Quarters mirror: TL + BL tiled; TL -> TR vacates the top-left
        // quad, which merges with BL into the left half.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)

        let plan = state.plan(window: a, into: .topRight)

        XCTAssertEqual(plan, .swap(placements: [a: .topRight, b: .leftHalf]))
        if case .swap(let placements) = plan {
            state.commitSwaps(placements)
        } else {
            return XCTFail("expected a growth swap, got \(plan)")
        }
        XCTAssertEqual(state.occupant(of: .topRight), a)
        XCTAssertEqual(state.occupant(of: .leftHalf), b)
        XCTAssertEqual(Set(state.tiledWindows), [a, b])
    }

    // MARK: Exact-or-empty

    func testMoveWithoutHoleLeavesNeighborsAlone() {
        // a=sixthLeft -> sixthTopLeft is a pure shrink: b already covers
        // the bottom half of the old slot, so nothing is vacated.
        var state = TilingState()
        state.commit(window: a, into: .sixthLeft)
        state.commit(window: b, into: .sixthRight)

        XCTAssertEqual(state.plan(window: a, into: .sixthTopLeft), .tile(evicting: []))
    }

    func testHoleNoMateMergesStaysHole() {
        // a=LeftHalf -> TopLeft vacates the bottom-left cells; the only
        // other window (topRight) cannot merge them into a whole slot.
        // Exact-or-empty: the hole stays, nobody moves.
        var state = TilingState()
        state.commit(window: a, into: .leftHalf)
        state.commit(window: b, into: .topRight)

        XCTAssertEqual(state.plan(window: a, into: .topLeft), .tile(evicting: []))
    }

    func testFreshRequesterNeverGrowsAnyone() {
        // A fresh window vacates nothing, so tiling into a free slot
        // never grows a neighbor — even one that could absorb the slot's
        // surroundings.
        var state = TilingState()
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: b, into: .sixthBottomLeft)

        XCTAssertEqual(state.plan(window: 99, into: .sixthMiddle), .tile(evicting: []))
    }

    func testGrowthIsDeterministicAcrossTilingOrder() {
        // Same visual arrangement, opposite tiling order: the growth is
        // identical — spatial order, never window ids.
        var early = TilingState()
        early.commit(window: 1, into: .sixthTopLeft)
        early.commit(window: 2, into: .sixthBottomLeft)
        var late = TilingState()
        late.commit(window: 2, into: .sixthBottomLeft)
        late.commit(window: 1, into: .sixthTopLeft)

        XCTAssertEqual(
            early.plan(window: 1, into: .sixthMiddle),
            .swap(placements: [1: .sixthMiddle, 2: .sixthLeft]))
        XCTAssertEqual(
            late.plan(window: 1, into: .sixthMiddle),
            .swap(placements: [1: .sixthMiddle, 2: .sixthLeft]))
    }
}
