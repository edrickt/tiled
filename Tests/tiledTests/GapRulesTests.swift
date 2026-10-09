import CoreGraphics
import XCTest

@testable import tiled

/// The gap rules `CONTEXT.md` states, pinned where the audit found them
/// untested: an expanded window ignores the gap (G1), the gap is the
/// same across layouts — sixths' shared-edge and screen-edge halves
/// (G2) — and one non-zero value reaches every display and Space (G5).
/// The geometry pins are hand-computed rectangles, never a call into the
/// rule under test.
final class GapRulesTests: XCTestCase {
    /// Round thirds and halves: every line lands on an integer.
    private let bounds = CGRect(x: 100, y: 50, width: 900, height: 600)

    // MARK: An expanded window ignores the gap (G1)

    func testAnExpandedWindowIgnoresTheGap() {
        let harness = TilingSpaceHarness()
        harness.gap = 10
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let id = harness.addWindow(frame: original)
        harness.apply(slot: .topLeft, requester: id)
        let tiled = harness.rect(.topLeft)
        XCTAssertNotEqual(tiled, harness.bounds, "the tile carries the gap")

        harness.space.expandToggle(window: id, context: harness.context())

        XCTAssertEqual(
            harness.frame(of: id), harness.bounds,
            "the cover fills the screen: an expanded window ignores the gap")

        harness.space.expandToggle(window: id, context: harness.context())

        XCTAssertEqual(
            harness.frame(of: id), tiled,
            "the slot below carries the gap again when the cover collapses")
    }

    // MARK: The same gap in sixths (G2)

    /// Hand-computed sixths geometry at gap 10: the vertical thirds sit
    /// at x = 100/400/700/1000 and the row split at y = 350.
    func testSixthsScreenEdgesShowTheFullGapAndSharedEdgesHalf() {
        let grid = GridLayout()
        // .sixthLeft: screen edges left/top/bottom (full 10), the shared
        // right edge (half, 5).
        XCTAssertEqual(
            grid.rect(for: .sixthLeft, in: bounds, gap: 10),
            CGRect(x: 110, y: 60, width: 285, height: 580))
        // .sixthMiddle: both vertical edges shared (half), screen top
        // and bottom (full).
        XCTAssertEqual(
            grid.rect(for: .sixthMiddle, in: bounds, gap: 10),
            CGRect(x: 405, y: 60, width: 290, height: 580))
        // .sixthTopLeft: screen left/top (full), shared right/bottom
        // (half).
        XCTAssertEqual(
            grid.rect(for: .sixthTopLeft, in: bounds, gap: 10),
            CGRect(x: 110, y: 355, width: 285, height: 285))
        // .sixthBottomMiddle: shared left/right/top (half), screen
        // bottom (full).
        XCTAssertEqual(
            grid.rect(for: .sixthBottomMiddle, in: bounds, gap: 10),
            CGRect(x: 405, y: 60, width: 290, height: 285))
        // .sixthsRightTwoThirds: shared left (half), screen right and
        // both horizontal edges (full).
        XCTAssertEqual(
            grid.rect(for: .sixthsRightTwoThirds, in: bounds, gap: 10),
            CGRect(x: 405, y: 60, width: 585, height: 580))
    }

    func testAdjacentSixthsTilesLeaveExactlyTheGapBetweenThem() {
        let grid = GridLayout()
        let gap: CGFloat = 10
        let left = grid.rect(for: .sixthLeft, in: bounds, gap: gap)
        let middle = grid.rect(for: .sixthMiddle, in: bounds, gap: gap)
        let right = grid.rect(for: .sixthRight, in: bounds, gap: gap)
        let top = grid.rect(for: .sixthTopLeft, in: bounds, gap: gap)
        let bottom = grid.rect(for: .sixthBottomLeft, in: bounds, gap: gap)
        // Half a gap from each neighbour sums to the full gap between.
        XCTAssertEqual(middle.minX - left.maxX, gap)
        XCTAssertEqual(right.minX - middle.maxX, gap)
        XCTAssertEqual(top.minY - bottom.maxY, gap)
    }

    func testSixthsScreenEdgesShowTheFullGap() {
        let grid = GridLayout()
        let gap: CGFloat = 10
        let left = grid.rect(for: .sixthLeft, in: bounds, gap: gap)
        let right = grid.rect(for: .sixthRight, in: bounds, gap: gap)
        let top = grid.rect(for: .sixthTopMiddle, in: bounds, gap: gap)
        let bottom = grid.rect(for: .sixthBottomMiddle, in: bounds, gap: gap)
        XCTAssertEqual(left.minX - bounds.minX, gap)
        XCTAssertEqual(bounds.maxX - right.maxX, gap)
        XCTAssertEqual(bounds.maxY - top.maxY, gap)
        XCTAssertEqual(bottom.minY - bounds.minY, gap)
    }

    func testTheSameGapSeparatesBothLayouts() {
        let grid = GridLayout()
        let gap: CGFloat = 10
        let quartersLeft = grid.rect(for: .leftHalf, in: bounds, gap: gap)
        let quartersRight = grid.rect(for: .rightHalf, in: bounds, gap: gap)
        let sixthsLeft = grid.rect(for: .sixthLeft, in: bounds, gap: gap)
        let sixthsMiddle = grid.rect(for: .sixthMiddle, in: bounds, gap: gap)
        // A neighbour's edge and a screen's edge read identically in
        // both layouts: the gap does not change with the geometry.
        XCTAssertEqual(quartersRight.minX - quartersLeft.maxX, gap)
        XCTAssertEqual(sixthsMiddle.minX - sixthsLeft.maxX, gap)
        XCTAssertEqual(quartersLeft.minX - bounds.minX, gap)
        XCTAssertEqual(sixthsLeft.minX - bounds.minX, gap)
    }

    // MARK: The same gap on every display and Space (G5)

    private static let displayID: CGDirectDisplayID = 42
    private static let otherDisplayID: CGDirectDisplayID = 43
    private static let display = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        name: "Display 1",
        displayID: displayID)
    private static let otherDisplay = ScreenInfo(
        id: ScreenID(rawValue: 2),
        frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        name: "Display 2",
        displayID: otherDisplayID)
    private static let spaceA = SpaceID(rawValue: 101)
    private static let spaceB = SpaceID(rawValue: 102)
    private static let spaceC = SpaceID(rawValue: 103)

    func testTheSameNonZeroGapReachesASecondDisplayAndSpace() {
        let gateway = FakeWindowGateway()
        gateway.activeSpaces = [Self.displayID: Self.spaceA, Self.otherDisplayID: Self.spaceB]
        // One value per app: the same gap closure serves every canvas.
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [Self.display, Self.otherDisplay] },
            gap: { 10 }, deathConfirmation: 0)

        // Display 1, Space A: .topLeft. Screen edges (left/top) take the
        // full 10, the shared edges half.
        let a = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .topLeft)
        XCTAssertEqual(gateway.frame(of: a), CGRect(x: 10, y: 545, width: 945, height: 525))

        // Display 2, Space B: the same request on a second display and a
        // second Space carries the same non-zero gap.
        let b = gateway.addWindow(frame: CGRect(x: 2000, y: 100, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .topLeft)
        XCTAssertEqual(gateway.frame(of: b), CGRect(x: 1930, y: 545, width: 945, height: 525))

        // Display 1, a third Space in the other layout: still the same
        // gap, sixths' screen-edge and shared-edge halves included.
        gateway.activeSpaces[Self.displayID] = Self.spaceC
        gateway.simulateSpaceChange()
        let c = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        gateway.focused = c
        controller.handle(slot: .sixthLeft)
        XCTAssertEqual(gateway.frame(of: c), CGRect(x: 10, y: 10, width: 625, height: 1060))
    }
}
