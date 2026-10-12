import XCTest
@testable import tiled

/// The menu-bar glyph is a live occupancy map, not just a layout badge:
/// each icon cell renders solid only while a tiled window actually covers
/// that spot, dimmed solid otherwise. These tests pin the pure mapping from
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

extension StatusIconTests {
    // MARK: Cell rounding geometry

    /// Regression test for the circular bites punched out of every filled
    /// corner cell: the corner arcs must sweep clockwise (the path walks
    /// clockwise), hugging the corner. A counter-clockwise sweep balloons
    /// into the cell: a point just inside the corner's inner diagonal
    /// falls outside the path, reading as a white bite on screen.
    func testRoundedCornerHugsItsCorner() {
        let rect = NSRect(x: 0, y: 0, width: 10, height: 10)
        let all: [AppDelegate.IconCorner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        for corner in all {
            let path = AppDelegate.cellPath(
                rect: rect, roundedCorners: [corner], radius: 3)
            // Just inside the corner along its diagonal: inside a correct
            // rounding, outside a ballooned (bitten) one.
            let probe: NSPoint =
                switch corner {
                case .topLeft: NSPoint(x: 1, y: 9)
                case .topRight: NSPoint(x: 9, y: 9)
                case .bottomLeft: NSPoint(x: 1, y: 1)
                case .bottomRight: NSPoint(x: 9, y: 1)
                }
            XCTAssertTrue(
                path.contains(probe),
                "\(corner): arc balloons into the cell instead of hugging it")
        }
    }

    func testAccessibilityDescriptionCountsWindowsNotCells() {
        // A half lights two cells but is one window: the spoken line must
        // not overstate occupancy (a half used to read "2 of 4").
        let half = StatusIcon.snapshot(layout: .quarters, occupants: [.leftHalf: 1])
        XCTAssertEqual(half.occupiedSlots, 1)
        XCTAssertEqual(half.filled.count, 2, "the glyph still lights its whole column")
        XCTAssertEqual(
            StatusIcon.accessibilityDescription(half),
            "Tiled Quarters layout, 1 of 4 slots occupied")

        let thirds = StatusIcon.snapshot(
            layout: .sixths, occupants: [.sixthLeft: 1, .sixthRight: 2])
        XCTAssertEqual(
            StatusIcon.accessibilityDescription(thirds),
            "Tiled Sixths layout, 2 of 6 slots occupied")
    }

    func testAccessibilityDescriptionNamesTheDisplayOnlyWhenMultiMonitor() {
        // The menu headers name the display; the glyph's spoken line must
        // too, or a VoiceOver user cannot tell which monitor the icon
        // depicts. With one display the name adds nothing and the line is
        // unchanged.
        let single = StatusIcon.snapshot(
            layout: .quarters, occupants: [.topLeft: 1], displayName: nil)
        XCTAssertEqual(
            StatusIcon.accessibilityDescription(single),
            "Tiled Quarters layout, 1 of 4 slots occupied")

        let multi = StatusIcon.snapshot(
            layout: .quarters, occupants: [.topLeft: 1], displayName: "Studio Display")
        XCTAssertEqual(
            StatusIcon.accessibilityDescription(multi),
            "Tiled Quarters layout, 1 of 4 slots occupied, on Studio Display")
    }

    func testUnroundedCellIsTheFullRect() {
        // No corners or zero radius: the path is the rect itself.
        let rect = NSRect(x: 2, y: 3, width: 10, height: 8)
        XCTAssertTrue(
            AppDelegate.cellPath(rect: rect, roundedCorners: [], radius: 3)
                .contains(NSPoint(x: 2.5, y: 3.5)))
        XCTAssertTrue(
            AppDelegate.cellPath(
                rect: rect, roundedCorners: [.topLeft], radius: 0
            ).contains(NSPoint(x: 2.5, y: 10.5)))
    }
}
