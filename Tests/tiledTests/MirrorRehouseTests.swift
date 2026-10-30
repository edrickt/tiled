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
}
