import XCTest
@testable import tiled

final class GridLayoutTests: XCTestCase {
    let bounds = CGRect(x: 100, y: 50, width: 1000, height: 800)

    // MARK: Default rects (all splitters at 0.5)

    func testDefaultQuads() {
        let grid = GridLayout()
        // AppKit coords: y grows upward, so top quads sit at midY.
        XCTAssertEqual(
            grid.rect(for: .topLeft, in: bounds),
            CGRect(x: 100, y: 450, width: 500, height: 400))
        XCTAssertEqual(
            grid.rect(for: .topRight, in: bounds),
            CGRect(x: 600, y: 450, width: 500, height: 400))
        XCTAssertEqual(
            grid.rect(for: .bottomLeft, in: bounds),
            CGRect(x: 100, y: 50, width: 500, height: 400))
        XCTAssertEqual(
            grid.rect(for: .bottomRight, in: bounds),
            CGRect(x: 600, y: 50, width: 500, height: 400))
    }

    func testDefaultHalves() {
        let grid = GridLayout()
        XCTAssertEqual(
            grid.rect(for: .leftHalf, in: bounds),
            CGRect(x: 100, y: 50, width: 500, height: 800))
        XCTAssertEqual(
            grid.rect(for: .rightHalf, in: bounds),
            CGRect(x: 600, y: 50, width: 500, height: 800))
    }

    // MARK: Custom splitters

    func testCustomColumnSplit() {
        var grid = GridLayout()
        grid.columnSplit = 0.4
        XCTAssertEqual(
            grid.rect(for: .leftHalf, in: bounds),
            CGRect(x: 100, y: 50, width: 400, height: 800))
        XCTAssertEqual(
            grid.rect(for: .rightHalf, in: bounds),
            CGRect(x: 500, y: 50, width: 600, height: 800))
    }

    func testCustomRowSplitsAreIndependentPerColumn() {
        var grid = GridLayout()
        grid.leftRowSplit = 0.25 // left divider at y=250; right stays at y=450.
        XCTAssertEqual(
            grid.rect(for: .topLeft, in: bounds),
            CGRect(x: 100, y: 250, width: 500, height: 600))
        XCTAssertEqual(
            grid.rect(for: .bottomLeft, in: bounds),
            CGRect(x: 100, y: 50, width: 500, height: 200))
        // Right column untouched.
        XCTAssertEqual(
            grid.rect(for: .topRight, in: bounds),
            CGRect(x: 600, y: 450, width: 500, height: 400))
        XCTAssertEqual(
            grid.rect(for: .bottomRight, in: bounds),
            CGRect(x: 600, y: 50, width: 500, height: 400))
    }

    func testDraggingLeftColumnRowEdgeLeavesRightColumnUntouched() {
        // With all four quarters tiled, dragging BL's top edge moves the LEFT
        // divider only: BL+TL resize, TR+BR keep their rects.
        var grid = GridLayout()
        let oldTR = grid.rect(for: .topRight, in: bounds)
        let oldBR = grid.rect(for: .bottomRight, in: bounds)
        grid.update(
            boundary: .leftRowSplit, toPosition: bounds.minY + 0.7 * bounds.height,
            in: bounds)
        XCTAssertEqual(grid.leftRowSplit, 0.7, accuracy: 0.001)
        XCTAssertEqual(
            grid.rect(for: .topLeft, in: bounds).minY,
            bounds.minY + 0.7 * bounds.height, accuracy: 0.001)
        XCTAssertEqual(
            grid.rect(for: .bottomLeft, in: bounds).maxY,
            bounds.minY + 0.7 * bounds.height, accuracy: 0.001)
        XCTAssertEqual(grid.rect(for: .topRight, in: bounds), oldTR)
        XCTAssertEqual(grid.rect(for: .bottomRight, in: bounds), oldBR)
    }

    func testDraggingRightColumnRowEdgeLeavesLeftColumnUntouched() {
        // Symmetric: dragging BR's top edge moves the RIGHT divider only.
        var grid = GridLayout()
        let oldTL = grid.rect(for: .topLeft, in: bounds)
        let oldBL = grid.rect(for: .bottomLeft, in: bounds)
        grid.update(
            boundary: .rightRowSplit, toPosition: bounds.minY + 0.3 * bounds.height,
            in: bounds)
        XCTAssertEqual(grid.rightRowSplit, 0.3, accuracy: 0.001)
        XCTAssertEqual(
            grid.rect(for: .topRight, in: bounds).minY,
            bounds.minY + 0.3 * bounds.height, accuracy: 0.001)
        XCTAssertEqual(
            grid.rect(for: .bottomRight, in: bounds).maxY,
            bounds.minY + 0.3 * bounds.height, accuracy: 0.001)
        XCTAssertEqual(grid.rect(for: .topLeft, in: bounds), oldTL)
        XCTAssertEqual(grid.rect(for: .bottomLeft, in: bounds), oldBL)
    }

    // MARK: Splitter updates (the live-resize math)

    func testDragBottomRightLeftEdgeUpdatesColumnSplit() {
        // The reported scenario: BL + BR tiled, drag BR's left edge leftwards.
        var grid = GridLayout()
        let oldBR = grid.rect(for: .bottomRight, in: bounds)
        // User drags BR's left edge from x=600 to x=400.
        grid.update(boundary: .columnSplit, toPosition: 400, in: bounds)
        XCTAssertEqual(grid.columnSplit, 0.3, accuracy: 0.001)

        let newBL = grid.rect(for: .bottomLeft, in: bounds)
        XCTAssertEqual(newBL.width, 300, accuracy: 0.5) // was 500 -> shrunk
        XCTAssertEqual(newBL.maxX, 400, accuracy: 0.5) // flush against BR's new left edge

        let newBR = grid.rect(for: .bottomRight, in: bounds)
        XCTAssertEqual(newBR.minX, 400, accuracy: 0.5)
        XCTAssertEqual(newBR.width, oldBR.width + 200, accuracy: 1) // grew leftwards
    }

    func testDragBottomLeftRightEdgeGrowsItAndShrinksRightColumn() {
        var grid = GridLayout()
        // BL's right edge is the column split; drag it right to x=800.
        grid.update(boundary: .columnSplit, toPosition: 800, in: bounds)
        XCTAssertEqual(grid.columnSplit, 0.7, accuracy: 0.001)
        XCTAssertEqual(
            grid.rect(for: .bottomLeft, in: bounds).width, 700, accuracy: 0.5)
        XCTAssertEqual(
            grid.rect(for: .bottomRight, in: bounds).minX, 800, accuracy: 0.5)
    }

    func testDragBottomLeftTopEdgeMovesLeftRowSplit() {
        var grid = GridLayout()
        let oldTR = grid.rect(for: .topRight, in: bounds)
        let oldBR = grid.rect(for: .bottomRight, in: bounds)
        // BL's top edge dragged up from y=450 to y=650 -> TL shrinks vertically.
        grid.update(boundary: .leftRowSplit, toPosition: 650, in: bounds)
        XCTAssertEqual(grid.leftRowSplit, 0.75, accuracy: 0.001)
        let tl = grid.rect(for: .topLeft, in: bounds)
        XCTAssertEqual(tl.height, 200, accuracy: 0.5)
        XCTAssertEqual(tl.minY, 650, accuracy: 0.5)
        // Right column keeps its rects.
        XCTAssertEqual(grid.rect(for: .topRight, in: bounds), oldTR)
        XCTAssertEqual(grid.rect(for: .bottomRight, in: bounds), oldBR)
    }

    func testUpdateClamps() {
        var grid = GridLayout()
        grid.update(boundary: .columnSplit, toPosition: bounds.minX + 0.01 * bounds.width, in: bounds)
        XCTAssertEqual(grid.columnSplit, GridLayout.columnClamp.lowerBound, accuracy: 0.001)
        grid.update(boundary: .columnSplit, toPosition: bounds.maxX, in: bounds)
        XCTAssertEqual(grid.columnSplit, GridLayout.columnClamp.upperBound, accuracy: 0.001)
        grid.update(boundary: .leftRowSplit, toPosition: bounds.minY, in: bounds)
        XCTAssertEqual(grid.leftRowSplit, GridLayout.rowClamp.lowerBound, accuracy: 0.001)
        grid.update(boundary: .leftRowSplit, toPosition: bounds.maxY, in: bounds)
        XCTAssertEqual(grid.leftRowSplit, GridLayout.rowClamp.upperBound, accuracy: 0.001)
        grid.update(boundary: .rightRowSplit, toPosition: bounds.minY, in: bounds)
        XCTAssertEqual(grid.rightRowSplit, GridLayout.rowClamp.lowerBound, accuracy: 0.001)
        grid.update(boundary: .rightRowSplit, toPosition: bounds.maxY, in: bounds)
        XCTAssertEqual(grid.rightRowSplit, GridLayout.rowClamp.upperBound, accuracy: 0.001)
    }

    func testUpdateReturnsFalseWhenUnchanged() {
        var grid = GridLayout()
        let position = grid.position(of: .columnSplit, in: bounds)
        XCTAssertFalse(grid.update(boundary: .columnSplit, toPosition: position, in: bounds))
        XCTAssertTrue(
            grid.update(boundary: .columnSplit, toPosition: position + 50, in: bounds))
    }

    func testTilesStayFlushAcrossSplitter() {
        // Neighboring tiles must share the exact divider line.
        var grid = GridLayout()
        grid.columnSplit = 0.37
        grid.leftRowSplit = 0.42
        grid.rightRowSplit = 0.42
        let tl = grid.rect(for: .topLeft, in: bounds)
        let tr = grid.rect(for: .topRight, in: bounds)
        let bl = grid.rect(for: .bottomLeft, in: bounds)
        let br = grid.rect(for: .bottomRight, in: bounds)
        XCTAssertEqual(tl.maxX, tr.minX, accuracy: 0.001)
        XCTAssertEqual(bl.maxX, br.minX, accuracy: 0.001)
        XCTAssertEqual(tl.minY, bl.maxY, accuracy: 0.001) // left row divider
        XCTAssertEqual(tr.minY, br.maxY, accuracy: 0.001) // right row divider
        XCTAssertEqual(tl.minY, tr.minY, accuracy: 0.001) // dividers agree here
        XCTAssertEqual(tl.maxY, bounds.maxY, accuracy: 0.001) // tops at screen top
        XCTAssertEqual(bl.minY, bounds.minY, accuracy: 0.001) // bottoms at screen bottom
    }

    func testTilesStayFlushWithDivergentRowSplits() {
        // With independent dividers, tiles within each column still meet
        // exactly, at different heights per column.
        var grid = GridLayout()
        grid.columnSplit = 0.37
        grid.leftRowSplit = 0.42 // left divider at y=386
        grid.rightRowSplit = 0.58 // right divider at y=514
        let tl = grid.rect(for: .topLeft, in: bounds)
        let tr = grid.rect(for: .topRight, in: bounds)
        let bl = grid.rect(for: .bottomLeft, in: bounds)
        let br = grid.rect(for: .bottomRight, in: bounds)
        XCTAssertEqual(tl.maxX, tr.minX, accuracy: 0.001) // shared column divider
        XCTAssertEqual(bl.maxX, br.minX, accuracy: 0.001)
        XCTAssertEqual(tl.minY, bl.maxY, accuracy: 0.001) // left divider exact
        XCTAssertEqual(tr.minY, br.maxY, accuracy: 0.001) // right divider exact
        XCTAssertEqual(tl.minY, bounds.minY + 0.42 * bounds.height, accuracy: 0.001)
        XCTAssertEqual(tr.minY, bounds.minY + 0.58 * bounds.height, accuracy: 0.001)
        XCTAssertNotEqual(tl.minY, tr.minY, accuracy: 0.001) // independent
    }

    // MARK: Edge cases

    func testHalvesIgnoreRowSplits() {
        // Halves span the full height no matter where either row divider sits.
        var grid = GridLayout()
        grid.leftRowSplit = 0.2
        grid.rightRowSplit = 0.8
        XCTAssertEqual(
            grid.rect(for: .leftHalf, in: bounds),
            CGRect(x: 100, y: 50, width: 500, height: 800))
        XCTAssertEqual(
            grid.rect(for: .rightHalf, in: bounds),
            CGRect(x: 600, y: 50, width: 500, height: 800))
        grid.leftRowSplit = 0.8
        grid.rightRowSplit = 0.2
        XCTAssertEqual(
            grid.rect(for: .leftHalf, in: bounds),
            CGRect(x: 100, y: 50, width: 500, height: 800))
        XCTAssertEqual(
            grid.rect(for: .rightHalf, in: bounds),
            CGRect(x: 600, y: 50, width: 500, height: 800))
    }

    func testQuadsShareColumnSplit() {
        var grid = GridLayout()
        grid.columnSplit = 0.25 // divider at x=350
        XCTAssertEqual(
            grid.rect(for: .topLeft, in: bounds),
            CGRect(x: 100, y: 450, width: 250, height: 400))
        XCTAssertEqual(
            grid.rect(for: .bottomLeft, in: bounds),
            CGRect(x: 100, y: 50, width: 250, height: 400))
        XCTAssertEqual(
            grid.rect(for: .topRight, in: bounds),
            CGRect(x: 350, y: 450, width: 750, height: 400))
        XCTAssertEqual(
            grid.rect(for: .bottomRight, in: bounds),
            CGRect(x: 350, y: 50, width: 750, height: 400))
    }

    func testAllSlotsWithBothSplitsCustom() {
        var grid = GridLayout()
        grid.columnSplit = 0.25 // divider at x=350
        grid.leftRowSplit = 0.75 // left divider at y=650
        grid.rightRowSplit = 0.75 // right divider at y=650
        XCTAssertEqual(
            grid.rect(for: .leftHalf, in: bounds),
            CGRect(x: 100, y: 50, width: 250, height: 800))
        XCTAssertEqual(
            grid.rect(for: .rightHalf, in: bounds),
            CGRect(x: 350, y: 50, width: 750, height: 800))
        XCTAssertEqual(
            grid.rect(for: .topLeft, in: bounds),
            CGRect(x: 100, y: 650, width: 250, height: 200))
        XCTAssertEqual(
            grid.rect(for: .bottomLeft, in: bounds),
            CGRect(x: 100, y: 50, width: 250, height: 600))
        XCTAssertEqual(
            grid.rect(for: .topRight, in: bounds),
            CGRect(x: 350, y: 650, width: 750, height: 200))
        XCTAssertEqual(
            grid.rect(for: .bottomRight, in: bounds),
            CGRect(x: 350, y: 50, width: 750, height: 600))
    }

    func testColumnDragMovesBothRows() {
        // Mirror of the row-divider regression test: a column drag must move
        // the shared vertical edge of all four quads, not just one row.
        var grid = GridLayout()
        grid.update(boundary: .columnSplit, toPosition: 400, in: bounds)
        XCTAssertEqual(grid.rect(for: .topLeft, in: bounds).maxX, 400, accuracy: 0.5)
        XCTAssertEqual(grid.rect(for: .topRight, in: bounds).minX, 400, accuracy: 0.5)
        XCTAssertEqual(grid.rect(for: .bottomLeft, in: bounds).maxX, 400, accuracy: 0.5)
        XCTAssertEqual(grid.rect(for: .bottomRight, in: bounds).minX, 400, accuracy: 0.5)
    }

    func testBoundaryMappingExhaustive() {
        // All 68 (slot, edge) pairs: 6 column-split, 2 left-row, 2 right-row,
        // 58 fixed. Sixths rects are fixed fractions with no draggable
        // splitters, so every sixths edge maps to nil.
        var expectations: [(Slot, TileEdge, GridBoundary?)] = [
            (.topLeft, .right, .columnSplit),
            (.bottomLeft, .right, .columnSplit),
            (.leftHalf, .right, .columnSplit),
            (.topRight, .left, .columnSplit),
            (.bottomRight, .left, .columnSplit),
            (.rightHalf, .left, .columnSplit),
            (.topLeft, .bottom, .leftRowSplit),
            (.bottomLeft, .top, .leftRowSplit),
            (.topRight, .bottom, .rightRowSplit),
            (.bottomRight, .top, .rightRowSplit),
            (.topLeft, .left, nil), (.topLeft, .top, nil),
            (.topRight, .right, nil), (.topRight, .top, nil),
            (.bottomLeft, .left, nil), (.bottomLeft, .bottom, nil),
            (.bottomRight, .right, nil), (.bottomRight, .bottom, nil),
            (.leftHalf, .left, nil), (.leftHalf, .top, nil), (.leftHalf, .bottom, nil),
            (.rightHalf, .right, nil), (.rightHalf, .top, nil), (.rightHalf, .bottom, nil),
        ]
        for slot in Slot.allCases where slot.layout == .sixths {
            for edge in TileEdge.allCases {
                expectations.append((slot, edge, nil))
            }
        }
        XCTAssertEqual(expectations.count, Slot.allCases.count * TileEdge.allCases.count)
        for (slot, edge, expected) in expectations {
            XCTAssertEqual(
                GridLayout.boundary(edge: edge, slot: slot), expected,
                "\(slot.rawValue) \(edge)")
        }
    }

    func testPositionOfBoundaries() {
        let grid = GridLayout()
        XCTAssertEqual(grid.position(of: .columnSplit, in: bounds), 600)
        XCTAssertEqual(grid.position(of: .leftRowSplit, in: bounds), 450)
        XCTAssertEqual(grid.position(of: .rightRowSplit, in: bounds), 450)
        var moved = GridLayout()
        moved.columnSplit = 0.25
        moved.leftRowSplit = 0.75
        moved.rightRowSplit = 0.3
        XCTAssertEqual(moved.position(of: .columnSplit, in: bounds), 350)
        XCTAssertEqual(moved.position(of: .leftRowSplit, in: bounds), 650)
        XCTAssertEqual(moved.position(of: .rightRowSplit, in: bounds), 290)
    }

    func testUpdateDeadZone() {
        // Sub-pixel jitter (under the 0.001 fraction threshold) is ignored.
        var grid = GridLayout()
        let columnPosition = grid.position(of: .columnSplit, in: bounds)
        XCTAssertFalse(
            grid.update(boundary: .columnSplit, toPosition: columnPosition + 0.5, in: bounds))
        XCTAssertEqual(grid.columnSplit, 0.5)
        let rowPosition = grid.position(of: .leftRowSplit, in: bounds)
        XCTAssertFalse(
            grid.update(boundary: .leftRowSplit, toPosition: rowPosition - 0.5, in: bounds))
        XCTAssertEqual(grid.leftRowSplit, 0.5)
        let rightRowPosition = grid.position(of: .rightRowSplit, in: bounds)
        XCTAssertFalse(
            grid.update(boundary: .rightRowSplit, toPosition: rightRowPosition + 0.5, in: bounds))
        XCTAssertEqual(grid.rightRowSplit, 0.5)
    }

    func testUpdateAtAndBeyondClampBounds() {
        var grid = GridLayout()
        // Exactly on the lower column bound: applies once, then no-ops.
        let lowerX = bounds.minX + GridLayout.columnClamp.lowerBound * bounds.width
        XCTAssertTrue(grid.update(boundary: .columnSplit, toPosition: lowerX, in: bounds))
        XCTAssertEqual(grid.columnSplit, 0.15, accuracy: 0.0001)
        XCTAssertFalse(grid.update(boundary: .columnSplit, toPosition: lowerX, in: bounds))
        // Far outside the screen clamps instead of escaping.
        XCTAssertTrue(
            grid.update(boundary: .leftRowSplit, toPosition: bounds.maxY + 5000, in: bounds))
        XCTAssertEqual(grid.leftRowSplit, GridLayout.rowClamp.upperBound)
        XCTAssertFalse(
            grid.update(boundary: .leftRowSplit, toPosition: bounds.maxY + 5000, in: bounds))
        XCTAssertTrue(
            grid.update(boundary: .rightRowSplit, toPosition: bounds.minY - 5000, in: bounds))
        XCTAssertEqual(grid.rightRowSplit, GridLayout.rowClamp.lowerBound)
    }

    func testEnumCompleteness() {
        // Adding a slot/edge/boundary without updating the mapping must fail
        // loudly instead of silently leaving an edge unmapped.
        XCTAssertEqual(Slot.allCases.count, 17)
        XCTAssertEqual(TileEdge.allCases.count, 4)
        XCTAssertEqual(GridBoundary.allCases.count, 3)
        XCTAssertEqual(
            GridLayout.boundary(edge: .right, slot: .topLeft), .columnSplit)
    }

    func testSixthsRects() {
        // Sixths are fixed fractions: thirds at 1/3 and 2/3, rows split at 1/2.
        let grid = GridLayout()
        let x13 = bounds.minX + bounds.width / 3
        let x23 = bounds.minX + 2 * bounds.width / 3
        let midY = bounds.minY + bounds.height / 2
        XCTAssertEqual(
            grid.rect(for: .sixthTopLeft, in: bounds),
            CGRect(x: bounds.minX, y: midY, width: x13 - bounds.minX, height: bounds.maxY - midY))
        XCTAssertEqual(
            grid.rect(for: .sixthTopMiddle, in: bounds),
            CGRect(x: x13, y: midY, width: x23 - x13, height: bounds.maxY - midY))
        XCTAssertEqual(
            grid.rect(for: .sixthTopRight, in: bounds),
            CGRect(x: x23, y: midY, width: bounds.maxX - x23, height: bounds.maxY - midY))
        XCTAssertEqual(
            grid.rect(for: .sixthBottomLeft, in: bounds),
            CGRect(x: bounds.minX, y: bounds.minY, width: x13 - bounds.minX, height: midY - bounds.minY))
        XCTAssertEqual(
            grid.rect(for: .sixthBottomMiddle, in: bounds),
            CGRect(x: x13, y: bounds.minY, width: x23 - x13, height: midY - bounds.minY))
        XCTAssertEqual(
            grid.rect(for: .sixthBottomRight, in: bounds),
            CGRect(x: x23, y: bounds.minY, width: bounds.maxX - x23, height: midY - bounds.minY))
        XCTAssertEqual(
            grid.rect(for: .sixthLeft, in: bounds),
            CGRect(x: bounds.minX, y: bounds.minY, width: x13 - bounds.minX, height: bounds.height))
        XCTAssertEqual(
            grid.rect(for: .sixthMiddle, in: bounds),
            CGRect(x: x13, y: bounds.minY, width: x23 - x13, height: bounds.height))
        XCTAssertEqual(
            grid.rect(for: .sixthRight, in: bounds),
            CGRect(x: x23, y: bounds.minY, width: bounds.maxX - x23, height: bounds.height))
        XCTAssertEqual(
            grid.rect(for: .sixthsLeftTwoThirds, in: bounds),
            CGRect(x: bounds.minX, y: bounds.minY, width: x23 - bounds.minX, height: bounds.height))
        XCTAssertEqual(
            grid.rect(for: .sixthsRightTwoThirds, in: bounds),
            CGRect(x: x13, y: bounds.minY, width: bounds.maxX - x13, height: bounds.height))
    }

    func testSixthsThirdsPartitionTheScreen() {
        // Left + Middle + Right thirds exactly cover the screen; the two
        // two-thirds overlap in the middle third.
        let grid = GridLayout()
        let left = grid.rect(for: .sixthLeft, in: bounds)
        let middle = grid.rect(for: .sixthMiddle, in: bounds)
        let right = grid.rect(for: .sixthRight, in: bounds)
        XCTAssertEqual(left.minX, bounds.minX, accuracy: 0.001)
        XCTAssertEqual(left.maxX, middle.minX, accuracy: 0.001)
        XCTAssertEqual(middle.maxX, right.minX, accuracy: 0.001)
        XCTAssertEqual(right.maxX, bounds.maxX, accuracy: 0.001)
        XCTAssertEqual(left.width, bounds.width / 3, accuracy: 0.001)
        XCTAssertEqual(middle.width, bounds.width / 3, accuracy: 0.001)
        XCTAssertEqual(right.width, bounds.width / 3, accuracy: 0.001)
        for third in [left, middle, right] {
            XCTAssertEqual(third.minY, bounds.minY, accuracy: 0.001)
            XCTAssertEqual(third.maxY, bounds.maxY, accuracy: 0.001)
        }
        let leftTwo = grid.rect(for: .sixthsLeftTwoThirds, in: bounds)
        XCTAssertEqual(leftTwo.minX, bounds.minX, accuracy: 0.001)
        XCTAssertEqual(leftTwo.maxX, right.minX, accuracy: 0.001)
        let rightTwo = grid.rect(for: .sixthsRightTwoThirds, in: bounds)
        XCTAssertEqual(rightTwo.minX, middle.minX, accuracy: 0.001)
        XCTAssertEqual(rightTwo.maxX, bounds.maxX, accuracy: 0.001)
    }

    func testSixthsCornersCoverScreen() {
        // All six corner sixths together must tile the screen exactly:
        // contained in bounds, touching every edge, area preserved
        // (no gaps, no overlaps).
        let grid = GridLayout()
        let corners: [Slot] = [
            .sixthTopLeft, .sixthTopMiddle, .sixthTopRight,
            .sixthBottomLeft, .sixthBottomMiddle, .sixthBottomRight,
        ]
        let rects = corners.map { grid.rect(for: $0, in: bounds) }
        for rect in rects {
            XCTAssertGreaterThanOrEqual(rect.minX, bounds.minX - 0.001)
            XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + 0.001)
            XCTAssertGreaterThanOrEqual(rect.minY, bounds.minY - 0.001)
            XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + 0.001)
        }
        XCTAssertEqual(rects.map(\.minX).min()!, bounds.minX, accuracy: 0.001)
        XCTAssertEqual(rects.map(\.maxX).max()!, bounds.maxX, accuracy: 0.001)
        XCTAssertEqual(rects.map(\.minY).min()!, bounds.minY, accuracy: 0.001)
        XCTAssertEqual(rects.map(\.maxY).max()!, bounds.maxY, accuracy: 0.001)
        let area = rects.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        XCTAssertEqual(area, bounds.width * bounds.height, accuracy: 1)
    }

    func testSixthsCornersPartitionTheirThird() {
        // The two corner sixths of each column stack exactly into its third.
        let grid = GridLayout()
        for (top, bottom, third) in [
            (Slot.sixthTopLeft, Slot.sixthBottomLeft, Slot.sixthLeft),
            (Slot.sixthTopMiddle, Slot.sixthBottomMiddle, Slot.sixthMiddle),
            (Slot.sixthTopRight, Slot.sixthBottomRight, Slot.sixthRight),
        ] as [(Slot, Slot, Slot)] {
            let topRect = grid.rect(for: top, in: bounds)
            let bottomRect = grid.rect(for: bottom, in: bounds)
            let whole = grid.rect(for: third, in: bounds)
            XCTAssertEqual(topRect.minX, whole.minX, accuracy: 0.001)
            XCTAssertEqual(bottomRect.minX, whole.minX, accuracy: 0.001)
            XCTAssertEqual(topRect.width, whole.width, accuracy: 0.001)
            XCTAssertEqual(bottomRect.width, whole.width, accuracy: 0.001)
            XCTAssertEqual(topRect.minY, bottomRect.maxY, accuracy: 0.001)
            XCTAssertEqual(topRect.maxY, whole.maxY, accuracy: 0.001)
            XCTAssertEqual(bottomRect.minY, whole.minY, accuracy: 0.001)
        }
    }

    func testSixthsIgnoreSplitters() {
        // Sixths are fixed fractions: dragging quarters splitters must not
        // move any sixths rect.
        var grid = GridLayout()
        grid.columnSplit = 0.25
        grid.leftRowSplit = 0.75
        grid.rightRowSplit = 0.3
        let fixed = GridLayout()
        for slot in Slot.allCases where slot.layout == .sixths {
            XCTAssertEqual(
                grid.rect(for: slot, in: bounds), fixed.rect(for: slot, in: bounds),
                "\(slot.rawValue) moved with quarters splitters")
        }
    }

    func testDefaultSplitsAreCentered() {
        XCTAssertEqual(GridLayout().columnSplit, 0.5)
        XCTAssertEqual(GridLayout().leftRowSplit, 0.5)
        XCTAssertEqual(GridLayout().rightRowSplit, 0.5)
        XCTAssertEqual(GridLayout(), GridLayout(columnSplit: 0.5, leftRowSplit: 0.5, rightRowSplit: 0.5))
    }

    func testQuadsPartitionTheirHalf() {
        // TL + BL exactly cover Left; TR + BR exactly cover Right, at any
        // splitter position (union height = full height, widths agree).
        var grid = GridLayout()
        grid.columnSplit = 0.37
        grid.leftRowSplit = 0.42
        grid.rightRowSplit = 0.63
        for (quad1, quad2, half) in [
            (Slot.topLeft, Slot.bottomLeft, Slot.leftHalf),
            (Slot.topRight, Slot.bottomRight, Slot.rightHalf),
        ] as [(Slot, Slot, Slot)] {
            let first = grid.rect(for: quad1, in: bounds)
            let second = grid.rect(for: quad2, in: bounds)
            let whole = grid.rect(for: half, in: bounds)
            XCTAssertEqual(first.width, whole.width, accuracy: 0.001)
            XCTAssertEqual(second.width, whole.width, accuracy: 0.001)
            XCTAssertEqual(first.minX, whole.minX, accuracy: 0.001)
            XCTAssertEqual(
                first.height + second.height, whole.height, accuracy: 0.001)
            XCTAssertEqual(first.maxY, whole.maxY, accuracy: 0.001)
            XCTAssertEqual(second.minY, whole.minY, accuracy: 0.001)
            XCTAssertEqual(first.minY, second.maxY, accuracy: 0.001)
        }
    }

    func testRectsWithZeroOriginBounds() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let grid = GridLayout()
        XCTAssertEqual(
            grid.rect(for: .leftHalf, in: screen),
            CGRect(x: 0, y: 0, width: 960, height: 1080))
        XCTAssertEqual(
            grid.rect(for: .rightHalf, in: screen),
            CGRect(x: 960, y: 0, width: 960, height: 1080))
        XCTAssertEqual(
            grid.rect(for: .topLeft, in: screen),
            CGRect(x: 0, y: 540, width: 960, height: 540))
        XCTAssertEqual(
            grid.rect(for: .bottomRight, in: screen),
            CGRect(x: 960, y: 0, width: 960, height: 540))
    }

    func testRectsWithNegativeOriginBounds() {
        // Secondary monitors left of the main screen have negative origins;
        // rects must track the origin, not assume (0, 0).
        let second = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let grid = GridLayout()
        XCTAssertEqual(
            grid.rect(for: .leftHalf, in: second),
            CGRect(x: -1920, y: 0, width: 960, height: 1080))
        XCTAssertEqual(
            grid.rect(for: .rightHalf, in: second),
            CGRect(x: -960, y: 0, width: 960, height: 1080))
        XCTAssertEqual(
            grid.rect(for: .topLeft, in: second),
            CGRect(x: -1920, y: 540, width: 960, height: 540))
        XCTAssertEqual(
            grid.rect(for: .bottomRight, in: second),
            CGRect(x: -960, y: 0, width: 960, height: 540))
    }
}
