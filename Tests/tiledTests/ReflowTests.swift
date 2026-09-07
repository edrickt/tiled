import XCTest
@testable import tiled

/// No-eviction reflow: the tile action is always honored, and windows
/// covered by it (plus, when needed, untouched neighbors that must shrink
/// to leave no empty space) are re-tiled into the leftover cells instead
/// of being evicted: whenever the leftovers can house every other window
/// with no gaps. Otherwise the legacy swap/evict rules apply.
final class ReflowTests: XCTestCase {
    private let a = 1
    private let b = 2
    private let c = 3
    private let d = 4

    func testSixthsMiddleThirdToRightTwoThirdsReflowsNeighbors() {
        // left/middle/right thirds tiled; the middle window takes the
        // right two-thirds. Leftover col0 houses both neighbors as corners:
        // left -> top-left sixth, right -> bottom-left sixth. Nobody evicted.
        var state = TilingState()
        state.commit(window: a, into: .sixthLeft)
        state.commit(window: b, into: .sixthMiddle)
        state.commit(window: c, into: .sixthRight)
        let plan = state.plan(window: b, into: .sixthsRightTwoThirds)
        XCTAssertEqual(
            plan,
            .swap(placements: [
                b: .sixthsRightTwoThirds,
                a: .sixthTopLeft,
                c: .sixthBottomLeft,
            ]))
        if case .swap(let placements) = plan {
            state.commitSwaps(placements)
        } else {
            return XCTFail("expected a reflow swap, got \(plan)")
        }
        XCTAssertEqual(state.occupant(of: .sixthsRightTwoThirds), b)
        XCTAssertEqual(state.occupant(of: .sixthTopLeft), a)
        XCTAssertEqual(state.occupant(of: .sixthBottomLeft), c)
        XCTAssertEqual(Set(state.tiledWindows), [a, b, c])
    }

    func testFreshWindowIntoRightTwoThirdsAdoptsMiddleThird() {
        // Only the middle third tiled; a fresh window takes the right
        // two-thirds. The middle window slides to the left third instead
        // of being evicted; leftovers covered exactly, no gaps.
        var state = TilingState()
        state.commit(window: a, into: .sixthMiddle)
        let plan = state.plan(window: b, into: .sixthsRightTwoThirds)
        XCTAssertEqual(plan, .swap(placements: [b: .sixthsRightTwoThirds, a: .sixthLeft]))
        if case .swap(let placements) = plan {
            state.commitSwaps(placements)
        } else {
            return XCTFail("expected a reflow swap, got \(plan)")
        }
        XCTAssertEqual(state.occupant(of: .sixthsRightTwoThirds), b)
        XCTAssertEqual(state.occupant(of: .sixthLeft), a)
    }

    func testQuartersFreshHalfAdoptsBothQuads() {
        // TL + BL tiled; a fresh window takes the left half. Both quads
        // slide right (TR + BR) instead of being evicted.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        let plan = state.plan(window: c, into: .leftHalf)
        XCTAssertEqual(
            plan,
            .swap(placements: [c: .leftHalf, a: .topRight, b: .bottomRight]))
        if case .swap(let placements) = plan {
            state.commitSwaps(placements)
        } else {
            return XCTFail("expected a reflow swap, got \(plan)")
        }
        XCTAssertEqual(state.occupant(of: .leftHalf), c)
        XCTAssertEqual(state.occupant(of: .topRight), a)
        XCTAssertEqual(state.occupant(of: .bottomRight), b)
    }

    func testReflowFallsBackToEvictionWhenLeftoversCannotHouseEveryone() {
        // All four quads tiled; TL -> RightHalf vacates one quad for two
        // blockers and the leftovers cannot house all three survivors
        // exactly: both blockers evicted, like before.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        state.commit(window: c, into: .topRight)
        state.commit(window: d, into: .bottomRight)
        XCTAssertEqual(state.plan(window: a, into: .rightHalf), .tile(evicting: [c, d]))
    }

    func testUndisputedWindowsStayPutDuringReflow() {
        // Left third + right two-thirds tiled; a fresh window takes the
        // bottom-left sixth. The untouched right two-thirds stays, the
        // blocking left third shrinks to the top-left sixth in place -
        // never thrown across the screen while its occupant squeezes
        // into a corner.
        var state = TilingState()
        state.commit(window: a, into: .sixthLeft)
        state.commit(window: b, into: .sixthsRightTwoThirds)
        let plan = state.plan(window: c, into: .sixthBottomLeft)
        XCTAssertEqual(
            plan,
            .swap(placements: [
                c: .sixthBottomLeft,
                a: .sixthTopLeft,
                b: .sixthsRightTwoThirds,
            ]))
        if case .swap(let placements) = plan {
            state.commitSwaps(placements)
        } else {
            return XCTFail("expected a reflow swap, got \(plan)")
        }
        XCTAssertEqual(state.occupant(of: .sixthBottomLeft), c)
        XCTAssertEqual(state.occupant(of: .sixthTopLeft), a)
        XCTAssertEqual(state.occupant(of: .sixthsRightTwoThirds), b)
        XCTAssertEqual(Set(state.tiledWindows), [a, b, c])
    }

    func testShrinkWithoutContentionLeavesNeighborsAlone() {
        // LeftHalf -> TopLeft is a pure shrink with no blockers: the
        // neighbor stays put even though gaps remain. Reflow only runs
        // under overlap contention.
        var state = TilingState()
        state.commit(window: a, into: .leftHalf)
        state.commit(window: b, into: .topRight)
        XCTAssertEqual(state.plan(window: a, into: .topLeft), .tile(evicting: []))
    }
}
