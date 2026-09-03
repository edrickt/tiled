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

    // MARK: Geometry

    func testQuadPlacementRects() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(Slot.topLeft.rect(in: bounds), CGRect(x: 0, y: 0, width: 500, height: 400))
        XCTAssertEqual(Slot.topRight.rect(in: bounds), CGRect(x: 500, y: 0, width: 500, height: 400))
        XCTAssertEqual(Slot.bottomLeft.rect(in: bounds), CGRect(x: 0, y: 400, width: 500, height: 400))
        XCTAssertEqual(Slot.bottomRight.rect(in: bounds), CGRect(x: 500, y: 400, width: 500, height: 400))
    }

    func testHalfPlacementRects() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(Slot.leftHalf.rect(in: bounds), CGRect(x: 0, y: 0, width: 500, height: 800))
        XCTAssertEqual(Slot.rightHalf.rect(in: bounds), CGRect(x: 500, y: 0, width: 500, height: 800))
    }
}
