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

    // MARK: Edge -> boundary mapping

    func testBoundaryMapping() {
        // Interior edges map to splitters.
        XCTAssertEqual(GridLayout.boundary(edge: .right, slot: .topLeft), .columnSplit)
        XCTAssertEqual(GridLayout.boundary(edge: .right, slot: .bottomLeft), .columnSplit)
        XCTAssertEqual(GridLayout.boundary(edge: .right, slot: .leftHalf), .columnSplit)
        XCTAssertEqual(GridLayout.boundary(edge: .left, slot: .topRight), .columnSplit)
        XCTAssertEqual(GridLayout.boundary(edge: .left, slot: .bottomRight), .columnSplit)
        XCTAssertEqual(GridLayout.boundary(edge: .left, slot: .rightHalf), .columnSplit)
        XCTAssertEqual(GridLayout.boundary(edge: .bottom, slot: .topLeft), .leftRowSplit)
        XCTAssertEqual(GridLayout.boundary(edge: .top, slot: .bottomLeft), .leftRowSplit)
        XCTAssertEqual(GridLayout.boundary(edge: .bottom, slot: .topRight), .rightRowSplit)
        XCTAssertEqual(GridLayout.boundary(edge: .top, slot: .bottomRight), .rightRowSplit)

        // Screen edges are fixed.
        XCTAssertNil(GridLayout.boundary(edge: .left, slot: .topLeft))
        XCTAssertNil(GridLayout.boundary(edge: .top, slot: .topLeft))
        XCTAssertNil(GridLayout.boundary(edge: .bottom, slot: .bottomLeft))
        XCTAssertNil(GridLayout.boundary(edge: .right, slot: .rightHalf))
        XCTAssertNil(GridLayout.boundary(edge: .top, slot: .leftHalf))
        XCTAssertNil(GridLayout.boundary(edge: .bottom, slot: .rightHalf))
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
        // All 24 (slot, edge) pairs: 6 column-split, 2 left-row, 2 right-row,
        // 14 fixed.
        let expectations: [(Slot, TileEdge, GridBoundary?)] = [
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
}
