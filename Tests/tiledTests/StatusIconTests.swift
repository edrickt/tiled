import XCTest
@testable import tiled

/// The menu-bar glyph is a live occupancy map, not just a layout badge:
/// each icon cell renders solid only while a tiled window actually covers
/// that spot, hollow otherwise. These tests pin the pure mapping from
/// tiling state to filled icon cells; `AppDelegate` draws the result.
final class StatusIconTests: XCTestCase {
    // MARK: Icon geometry

    func testQuartersIconCellsAreTheFourQuads() {
        XCTAssertEqual(
            StatusIcon.cells(for: .quarters),
            [.topLeft, .topRight, .bottomLeft, .bottomRight])
    }

    func testSixthsIconCellsAreTheSixCorners() {
        XCTAssertEqual(
            StatusIcon.cells(for: .sixths),
            [
                .sixthTopLeft, .sixthTopMiddle, .sixthTopRight,
                .sixthBottomLeft, .sixthBottomMiddle, .sixthBottomRight,
            ])
    }

    // MARK: Empty space

    func testEmptyQuartersFillsNothing() {
        XCTAssertEqual(
            StatusIcon.filledCells(layout: .quarters, occupants: [:]), [])
    }

    func testEmptySixthsFillsNothing() {
        XCTAssertEqual(
            StatusIcon.filledCells(layout: .sixths, occupants: [:]), [])
    }

    // MARK: Quarters occupancy

    func testQuartersQuadFillsItsOwnCellOnly() {
        XCTAssertEqual(
            StatusIcon.filledCells(layout: .quarters, occupants: [.topLeft: 1]),
            [.topLeft])
    }

    func testQuartersHalfFillsItsWholeColumn() {
        XCTAssertEqual(
            StatusIcon.filledCells(layout: .quarters, occupants: [.leftHalf: 1]),
            [.topLeft, .bottomLeft])
        XCTAssertEqual(
            StatusIcon.filledCells(layout: .quarters, occupants: [.rightHalf: 2]),
            [.topRight, .bottomRight])
    }

    func testQuartersDiagonalQuadsFillDiagonalCells() {
        XCTAssertEqual(
            StatusIcon.filledCells(
                layout: .quarters,
                occupants: [.topLeft: 1, .bottomRight: 2]),
            [.topLeft, .bottomRight])
    }

    func testFullQuartersFillsEveryCell() {
        XCTAssertEqual(
            StatusIcon.filledCells(
                layout: .quarters,
                occupants: [.topLeft: 1, .topRight: 2, .bottomLeft: 3, .bottomRight: 4]),
            [.topLeft, .topRight, .bottomLeft, .bottomRight])
    }

    // MARK: Sixths occupancy

    func testSixthsCornerFillsOneCell() {
        XCTAssertEqual(
            StatusIcon.filledCells(
                layout: .sixths, occupants: [.sixthTopMiddle: 1]),
            [.sixthTopMiddle])
    }

    func testSixthsThirdFillsItsWholeColumn() {
        XCTAssertEqual(
            StatusIcon.filledCells(layout: .sixths, occupants: [.sixthLeft: 1]),
            [.sixthTopLeft, .sixthBottomLeft])
        XCTAssertEqual(
            StatusIcon.filledCells(layout: .sixths, occupants: [.sixthMiddle: 2]),
            [.sixthTopMiddle, .sixthBottomMiddle])
        XCTAssertEqual(
            StatusIcon.filledCells(layout: .sixths, occupants: [.sixthRight: 3]),
            [.sixthTopRight, .sixthBottomRight])
    }

    func testSixthsLeftTwoThirdsFillsAllButTheRightColumn() {
        XCTAssertEqual(
            StatusIcon.filledCells(
                layout: .sixths, occupants: [.sixthsLeftTwoThirds: 1]),
            [
                .sixthTopLeft, .sixthTopMiddle,
                .sixthBottomLeft, .sixthBottomMiddle,
            ])
    }

    func testSixthsRightTwoThirdsFillsAllButTheLeftColumn() {
        XCTAssertEqual(
            StatusIcon.filledCells(
                layout: .sixths, occupants: [.sixthsRightTwoThirds: 1]),
            [
                .sixthTopMiddle, .sixthTopRight,
                .sixthBottomMiddle, .sixthBottomRight,
            ])
    }

    // MARK: Overlap rule

    func testIconCellLightsWhenAnyOccupantOverlapsIt() {
        // A sixths squatter under a quarters icon still lights the quads
        // it touches: occupancy is cell overlap, not slot identity, so a
        // transient mixed state never reads as empty.
        XCTAssertEqual(
            StatusIcon.filledCells(
                layout: .quarters, occupants: [.sixthTopLeft: 1]),
            [.topLeft])
        XCTAssertEqual(
            StatusIcon.filledCells(
                layout: .sixths, occupants: [.topLeft: 1]),
            [.sixthTopLeft, .sixthTopMiddle])
    }

    // MARK: Snapshot

    func testSnapshotCapturesLayoutAndFillTogether() {
        let empty = StatusIcon.snapshot(layout: .quarters, occupants: [:])
        XCTAssertEqual(empty.layout, .quarters)
        XCTAssertEqual(empty.filled, [])
        let tiled = StatusIcon.snapshot(
            layout: .quarters, occupants: [.leftHalf: 1, .topRight: 2])
        XCTAssertEqual(tiled.filled, [.topLeft, .topRight, .bottomLeft])
        XCTAssertNotEqual(empty, tiled)
    }

    func testSnapshotDistinguishesOccupancyChangesWithinOneLayout() {
        // The icon must redraw when windows come and go without a layout
        // switch: same layout, different fill, unequal snapshots.
        let before = StatusIcon.snapshot(
            layout: .sixths, occupants: [.sixthLeft: 1])
        let after = StatusIcon.snapshot(
            layout: .sixths, occupants: [.sixthLeft: 1, .sixthRight: 2])
        XCTAssertNotEqual(before, after)
    }
}
