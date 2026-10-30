import CoreGraphics
import XCTest
@testable import tiled

/// The mirror re-house: the reflection that keeps a whole group of
/// windows in the way tiled, and the canvas that commits it.
final class MirrorRehouseTests: XCTestCase {
    // MARK: The reflection

    func testMirrorReflectsColumnsAndKeepsRows() {
        // Worked values from the spec: column c mirrors to 3 − c, row
        // unchanged, so left and right swap and the middle column is
        // its own reflection.
        XCTAssertEqual(Slot.topLeft.mirror, .topRight)
        XCTAssertEqual(Slot.bottomLeft.mirror, .bottomRight)
        XCTAssertEqual(Slot.leftHalf.mirror, .rightHalf)
        XCTAssertEqual(Slot.sixthTopLeft.mirror, .sixthTopRight)
        XCTAssertEqual(Slot.sixthBottomLeft.mirror, .sixthBottomRight)
        XCTAssertEqual(Slot.sixthLeft.mirror, .sixthRight)
        XCTAssertEqual(Slot.sixthsLeftTwoThirds.mirror, .sixthsRightTwoThirds)
    }

    func testMiddleSlotsMirrorToThemselves() {
        // The one-thirds split is symmetric about the centre line, so
        // the middle third and both middle sixths cannot move.
        XCTAssertEqual(Slot.sixthMiddle.mirror, .sixthMiddle)
        XCTAssertEqual(Slot.sixthTopMiddle.mirror, .sixthTopMiddle)
        XCTAssertEqual(Slot.sixthBottomMiddle.mirror, .sixthBottomMiddle)
    }

    func testEverySlotMirrorsInsideItsLayoutAndBack() {
        for slot in Slot.allCases {
            XCTAssertEqual(slot.mirror.layout, slot.layout, "\(slot)")
            XCTAssertEqual(slot.mirror.mirror, slot, "the reflection is its own inverse: \(slot)")
        }
    }

    func testMirrorReflectsEachCellIntoTheMirroredSlot() {
        // Independent of the implementation's arithmetic: every cell of
        // a slot, reflected in the centre line, is a cell of its mirror.
        for slot in Slot.allCases {
            let reflected = Set(
                slot.cells.map { cell -> TileCell in
                    let index = TileCell.allCases.firstIndex(of: cell)!
                    return TileCell(column: 3 - index % 4, row: index / 4)
                })
            XCTAssertEqual(slot.mirror.cells, reflected, "\(slot)")
        }
    }

    // MARK: The group decision

    /// A board built by committing occupancy directly: the decision reads
    /// slots and occupancy only, so no canvas or gateway is involved.
    private func board(_ occupants: [(Slot, WindowID)], layout: LayoutKind = .quarters)
        -> TilingState
    {
        var state = TilingState(layout: layout)
        for (slot, window) in occupants { state.commit(window: window, into: slot) }
        return state
    }

    func testBothRightQuadsMirrorIntoTheLeftHalf() {
        // The user's case: window 1 holds the left half and asks for the
        // right half, which windows 2 and 3 tile between them.
        let state = board([(.leftHalf, 1), (.topRight, 2), (.bottomRight, 3)])

        XCTAssertEqual(
            state.mirroredHomes(evicting: [2, 3], for: .rightHalf, requester: 1),
            [2: .topLeft, 3: .bottomLeft])
    }

    func testPlanStillEvictsTheGroup() {
        // The plan shape does not change: the group stays `.tile`, and the
        // re-house decision happens at commit time where re-house lives.
        let state = board([(.leftHalf, 1), (.topRight, 2), (.bottomRight, 3)])

        XCTAssertEqual(state.plan(window: 1, into: .rightHalf), .tile(evicting: [2, 3]))
    }

    func testRefusesWhenAMembersMirrorIsItsOwnSlot() {
        // The middle third reflects to itself, and its own slot overlaps
        // the target, so this group has no home and evicts.
        let state = board([(.sixthMiddle, 2), (.sixthRight, 3)], layout: .sixths)

        XCTAssertNil(
            state.mirroredHomes(evicting: [2, 3], for: .sixthsRightTwoThirds, requester: 1))
    }

    func testRefusesWhenAHomeIsHeldByAWindowThatStays() {
        // Window 1 holds the middle third and window 4 the top-left
        // sixth, so window 2's mirror is taken: the whole group takes the
        // eviction path. (Four windows cannot coexist in quarters at all:
        // the two halves cover the screen.)
        let state = board(
            [(.sixthMiddle, 1), (.sixthTopRight, 2), (.sixthBottomRight, 3), (.sixthTopLeft, 4)],
            layout: .sixths)

        XCTAssertNil(
            state.mirroredHomes(evicting: [2, 3], for: .sixthRight, requester: 1))
    }

    func testIgnoresTheRequestersVacatedSlot() {
        // Window 1 only held the top-left quad and is moving to the right
        // half, so its old slot is free: window 2 may mirror onto it and
        // window 3 onto the empty bottom-left quad.
        let state = board([(.topLeft, 1), (.topRight, 2), (.bottomRight, 3)])

        XCTAssertEqual(
            state.mirroredHomes(evicting: [2, 3], for: .rightHalf, requester: 1),
            [2: .topLeft, 3: .bottomLeft])
    }

    func testNeedsTwoBlockers() {
        let state = board([(.leftHalf, 1), (.topRight, 2)])

        XCTAssertNil(
            state.mirroredHomes(evicting: [2], for: .rightHalf, requester: 1))
    }
}
