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

    func testCustomRowSplitAppliesToBothColumns() {
        var grid = GridLayout()
        grid.rowSplit = 0.25
        // Both columns share the single horizontal divider.
        XCTAssertEqual(
            grid.rect(for: .topLeft, in: bounds),
            CGRect(x: 100, y: 250, width: 500, height: 600))
        XCTAssertEqual(
            grid.rect(for: .bottomLeft, in: bounds),
            CGRect(x: 100, y: 50, width: 500, height: 200))
        XCTAssertEqual(
            grid.rect(for: .topRight, in: bounds),
            CGRect(x: 600, y: 250, width: 500, height: 600))
        XCTAssertEqual(
            grid.rect(for: .bottomRight, in: bounds),
            CGRect(x: 600, y: 50, width: 500, height: 200))
    }

    func testDraggingLeftColumnRowEdgeMovesRightColumnTiles() {
        // Regression: after dragging the left column's horizontal divider,
        // tiles placed in the RIGHT column must respect it (the grid has one
        // shared horizontal divider, not one per column).
        var grid = GridLayout()
        grid.update(boundary: .rowSplit, toPosition: bounds.minY + 0.7 * bounds.height, in: bounds)
        XCTAssertEqual(
            grid.rect(for: .topRight, in: bounds).minY,
            bounds.minY + 0.7 * bounds.height, accuracy: 0.001)
        XCTAssertEqual(
            grid.rect(for: .bottomRight, in: bounds).maxY,
            bounds.minY + 0.7 * bounds.height, accuracy: 0.001)
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
        XCTAssertEqual(GridLayout.boundary(edge: .bottom, slot: .topLeft), .rowSplit)
        XCTAssertEqual(GridLayout.boundary(edge: .top, slot: .bottomLeft), .rowSplit)
        XCTAssertEqual(GridLayout.boundary(edge: .bottom, slot: .topRight), .rowSplit)
        XCTAssertEqual(GridLayout.boundary(edge: .top, slot: .bottomRight), .rowSplit)

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
        // BL's top edge dragged up from y=450 to y=650 -> TL shrinks vertically.
        grid.update(boundary: .rowSplit, toPosition: 650, in: bounds)
        XCTAssertEqual(grid.rowSplit, 0.75, accuracy: 0.001)
        let tl = grid.rect(for: .topLeft, in: bounds)
        XCTAssertEqual(tl.height, 200, accuracy: 0.5)
        XCTAssertEqual(tl.minY, 650, accuracy: 0.5)
    }

    func testUpdateClamps() {
        var grid = GridLayout()
        grid.update(boundary: .columnSplit, toPosition: bounds.minX + 0.01 * bounds.width, in: bounds)
        XCTAssertEqual(grid.columnSplit, GridLayout.columnClamp.lowerBound, accuracy: 0.001)
        grid.update(boundary: .columnSplit, toPosition: bounds.maxX, in: bounds)
        XCTAssertEqual(grid.columnSplit, GridLayout.columnClamp.upperBound, accuracy: 0.001)
        grid.update(boundary: .rowSplit, toPosition: bounds.minY, in: bounds)
        XCTAssertEqual(grid.rowSplit, GridLayout.rowClamp.lowerBound, accuracy: 0.001)
        grid.update(boundary: .rowSplit, toPosition: bounds.maxY, in: bounds)
        XCTAssertEqual(grid.rowSplit, GridLayout.rowClamp.upperBound, accuracy: 0.001)
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
        grid.rowSplit = 0.42
        let tl = grid.rect(for: .topLeft, in: bounds)
        let tr = grid.rect(for: .topRight, in: bounds)
        let bl = grid.rect(for: .bottomLeft, in: bounds)
        let br = grid.rect(for: .bottomRight, in: bounds)
        XCTAssertEqual(tl.maxX, tr.minX, accuracy: 0.001)
        XCTAssertEqual(bl.maxX, br.minX, accuracy: 0.001)
        XCTAssertEqual(tl.minY, bl.maxY, accuracy: 0.001) // shared row divider
        XCTAssertEqual(tr.minY, br.maxY, accuracy: 0.001) // shared row divider
        XCTAssertEqual(tl.minY, tr.minY, accuracy: 0.001) // one divider across both columns
        XCTAssertEqual(tl.maxY, bounds.maxY, accuracy: 0.001) // tops at screen top
        XCTAssertEqual(bl.minY, bounds.minY, accuracy: 0.001) // bottoms at screen bottom
    }
}
