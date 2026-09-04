import Carbon.HIToolbox
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

    func testSameSlotIsNoop() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.plan(window: a, into: .topLeft), .noop)
        // Nothing committed: the window stays exactly where it was.
        XCTAssertEqual(state.occupant(of: .topLeft), a)
        XCTAssertEqual(state.slot(of: a), .topLeft)
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

    func testSlotCells() {
        XCTAssertEqual(Slot.topLeft.cells, [.col0Top, .col1Top])
        XCTAssertEqual(Slot.topRight.cells, [.col2Top, .col3Top])
        XCTAssertEqual(Slot.bottomLeft.cells, [.col0Bottom, .col1Bottom])
        XCTAssertEqual(Slot.bottomRight.cells, [.col2Bottom, .col3Bottom])
        XCTAssertEqual(
            Slot.leftHalf.cells,
            [.col0Top, .col1Top, .col0Bottom, .col1Bottom])
        XCTAssertEqual(
            Slot.rightHalf.cells,
            [.col2Top, .col3Top, .col2Bottom, .col3Bottom])
        // Every sixths slot pinned exactly (spot checks are not enough:
        // testOverlapMatchesCellIntersection only checks internal consistency).
        XCTAssertEqual(Slot.sixthTopLeft.cells, [.col0Top])
        XCTAssertEqual(Slot.sixthTopMiddle.cells, [.col1Top, .col2Top])
        XCTAssertEqual(Slot.sixthTopRight.cells, [.col3Top])
        XCTAssertEqual(Slot.sixthBottomLeft.cells, [.col0Bottom])
        XCTAssertEqual(Slot.sixthBottomMiddle.cells, [.col1Bottom, .col2Bottom])
        XCTAssertEqual(Slot.sixthBottomRight.cells, [.col3Bottom])
        XCTAssertEqual(Slot.sixthLeft.cells, [.col0Top, .col0Bottom])
        XCTAssertEqual(
            Slot.sixthMiddle.cells,
            [.col1Top, .col2Top, .col1Bottom, .col2Bottom])
        XCTAssertEqual(Slot.sixthRight.cells, [.col3Top, .col3Bottom])
        XCTAssertEqual(
            Slot.sixthsLeftTwoThirds.cells,
            [.col0Top, .col1Top, .col2Top, .col0Bottom, .col1Bottom, .col2Bottom])
        XCTAssertEqual(
            Slot.sixthsRightTwoThirds.cells,
            [.col1Top, .col2Top, .col3Top, .col1Bottom, .col2Bottom, .col3Bottom])
    }

    func testCellCounts() {
        // Guards against a slot silently gaining/losing cells: quarters
        // quads cover 2 cells, halves 4; sixths corners 1, middles 2,
        // thirds 2, middle-third 4, two-thirds 6.
        let expected: [(Slot, Int)] = [
            (.topLeft, 2), (.topRight, 2), (.bottomLeft, 2), (.bottomRight, 2),
            (.leftHalf, 4), (.rightHalf, 4),
            (.sixthTopLeft, 1), (.sixthTopMiddle, 2), (.sixthTopRight, 1),
            (.sixthBottomLeft, 1), (.sixthBottomMiddle, 2), (.sixthBottomRight, 1),
            (.sixthLeft, 2), (.sixthMiddle, 4), (.sixthRight, 2),
            (.sixthsLeftTwoThirds, 6), (.sixthsRightTwoThirds, 6),
        ]
        XCTAssertEqual(expected.count, Slot.allCases.count)
        for (slot, count) in expected {
            XCTAssertEqual(slot.cells.count, count, "\(slot.rawValue)")
        }
    }

    func testOverlapIsCompleteAndSymmetric() {
        // Halves overlap their own quads (all 8 combos), nothing else.
        let halves: [(Slot, Slot, Slot)] = [
            (.leftHalf, .topLeft, .bottomLeft),
            (.rightHalf, .topRight, .bottomRight),
        ]
        for (half, first, second) in halves {
            XCTAssertTrue(half.overlaps(first))
            XCTAssertTrue(half.overlaps(second))
            XCTAssertTrue(first.overlaps(half))
            XCTAssertTrue(second.overlaps(half))
        }
        XCTAssertFalse(Slot.leftHalf.overlaps(.topRight))
        XCTAssertFalse(Slot.leftHalf.overlaps(.bottomRight))
        XCTAssertFalse(Slot.rightHalf.overlaps(.topLeft))
        XCTAssertFalse(Slot.rightHalf.overlaps(.bottomLeft))
        // Every slot overlaps itself; the two halves never overlap each other.
        for slot in Slot.allCases {
            XCTAssertTrue(slot.overlaps(slot))
        }
        XCTAssertFalse(Slot.leftHalf.overlaps(.rightHalf))
        XCTAssertFalse(Slot.rightHalf.overlaps(.leftHalf))
        let quads: [Slot] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        for first in quads {
            for second in quads where first != second {
                XCTAssertFalse(first.overlaps(second))
                XCTAssertFalse(second.overlaps(first))
            }
        }
    }

    func testOverlapMatchesCellIntersection() {
        // overlaps() must agree with raw cell-set intersection for every pair.
        for first in Slot.allCases {
            for second in Slot.allCases {
                XCTAssertEqual(
                    first.overlaps(second),
                    !first.cells.isDisjoint(with: second.cells),
                    "\(first.rawValue) vs \(second.rawValue)")
            }
        }
    }

    func testCrossLayoutOverlaps() {
        // Quarters TL covers strips 0-1 top; sixths left/middle thirds sit
        // inside or across it accordingly.
        XCTAssertTrue(Slot.topLeft.overlaps(.sixthTopLeft))
        XCTAssertTrue(Slot.topLeft.overlaps(.sixthTopMiddle))
        XCTAssertFalse(Slot.topLeft.overlaps(.sixthTopRight))
        XCTAssertFalse(Slot.topLeft.overlaps(.sixthBottomLeft))
        XCTAssertTrue(Slot.leftHalf.overlaps(.sixthLeft))
        XCTAssertTrue(Slot.leftHalf.overlaps(.sixthMiddle))
        XCTAssertFalse(Slot.leftHalf.overlaps(.sixthRight))
        XCTAssertTrue(Slot.leftHalf.overlaps(.sixthsLeftTwoThirds))
        XCTAssertTrue(Slot.leftHalf.overlaps(.sixthsRightTwoThirds))
        // Middle sixth straddles the quarters column split.
        XCTAssertTrue(Slot.sixthMiddle.overlaps(.leftHalf))
        XCTAssertTrue(Slot.sixthMiddle.overlaps(.rightHalf))
        XCTAssertTrue(Slot.sixthMiddle.overlaps(.sixthTopMiddle))
        XCTAssertFalse(Slot.sixthMiddle.overlaps(.sixthTopLeft))
        XCTAssertFalse(Slot.sixthMiddle.overlaps(.sixthTopRight))
    }

    func testSlotPresentation() {
        XCTAssertEqual(Slot.allCases.count, 17)
        for slot in Slot.allCases {
            XCTAssertFalse(SlotPresentation.title(of: slot).isEmpty)
            XCTAssertNotNil(HotkeyStore.defaultBinding(for: slot).label)
        }
        XCTAssertEqual(SlotPresentation.title(of: .topLeft), "Top Left")
        XCTAssertEqual(SlotPresentation.title(of: .leftHalf), "Left Half")
        XCTAssertEqual(SlotPresentation.title(of: .sixthTopLeft), "Top Left Sixth")
        XCTAssertEqual(SlotPresentation.title(of: .sixthLeft), "Left Third")
        XCTAssertEqual(SlotPresentation.title(of: .sixthMiddle), "Middle Third")
        XCTAssertEqual(SlotPresentation.title(of: .sixthRight), "Right Third")
        XCTAssertEqual(SlotPresentation.title(of: .sixthsLeftTwoThirds), "Left Two-Thirds")
        XCTAssertEqual(SlotPresentation.title(of: .sixthsRightTwoThirds), "Right Two-Thirds")
        XCTAssertEqual(
            Set(Slot.allCases.map { HotkeyStore.defaultBinding(for: $0).label }).count,
            17) // default combos unique
    }

    func testHotkeyIDRoundTripsEverySlot() {
        // Mirrors HotkeyService.Context: hotkeyID must be a unique dense
        // 1-based index into allCases, and every id must resolve back to
        // its slot. A duplicate or gap means a hotkey fires the wrong slot
        // or nothing at all.
        let ids = Slot.allCases.map(\.hotkeyID)
        XCTAssertEqual(Set(ids).count, Slot.allCases.count, "duplicate hotkeyID")
        XCTAssertEqual(Set(ids), Set(1...UInt32(Slot.allCases.count)), "hotkeyID gap")
        var slotByID: [UInt32: Slot] = [:]
        for slot in Slot.allCases {
            slotByID[slot.hotkeyID] = slot
        }
        for slot in Slot.allCases {
            XCTAssertEqual(
                slotByID[slot.hotkeyID], slot, "\(slot.rawValue) does not round-trip")
        }
    }

    func testSwitchLayoutEvictionListMatchesControllerBehavior() {
        // The controller untile()s every window in plan's evicting list, so
        // switchLayout's list must contain EVERY tiled window including the
        // requester when tiled — otherwise a tiled window would survive a
        // reset and leave two layouts on screen.
        for layout in [[Slot.topLeft, Slot.bottomRight], [Slot.sixthLeft, Slot.sixthRight]] {
            var state = TilingState()
            var id = 1
            for slot in layout {
                state.commit(window: id, into: slot)
                id += 1
            }
            let other: Slot = layout[0].layout == .quarters ? .sixthMiddle : .topLeft
            for requester in [1, 2, 99] {
                let plan = state.plan(window: requester, into: other)
                guard case .switchLayout(let evicting) = plan else {
                    XCTFail("win\(requester) -> \(other) did not reset")
                    continue
                }
                let tiled = Set(state.tiledWindows)
                XCTAssertEqual(
                    Set(evicting), tiled,
                    "win\(requester) -> \(other): evicting=\(evicting) tiled=\(tiled)")
                var next = state
                for evicted in evicting { next.remove(window: evicted) }
                next.commit(window: requester, into: other)
                XCTAssertEqual(next.occupants, [other: requester])
                XCTAssertEqual(next.activeLayout, other.layout)
            }
        }
    }

    func testHotkeys() {
        // Quarters keep the bare ⌥⇧ keys; sixths add ⌘ on the requested keys.
        let shiftOption = UInt32(shiftKey | optionKey)
        let withCommand = UInt32(shiftKey | optionKey | cmdKey)
        for slot in Slot.allCases {
            switch slot.layout {
            case .quarters: XCTAssertEqual(slot.modifiers, shiftOption, "\(slot.rawValue)")
            case .sixths: XCTAssertEqual(slot.modifiers, withCommand, "\(slot.rawValue)")
            }
        }
        let expected: [(Slot, UInt32)] = [
            (.topLeft, UInt32(kVK_ANSI_U)),
            (.sixthTopLeft, UInt32(kVK_ANSI_U)),
            (.sixthTopMiddle, UInt32(kVK_ANSI_I)),
            (.topRight, UInt32(kVK_ANSI_O)),
            (.sixthTopRight, UInt32(kVK_ANSI_O)),
            (.bottomLeft, UInt32(kVK_ANSI_M)),
            (.sixthBottomLeft, UInt32(kVK_ANSI_M)),
            (.sixthBottomMiddle, UInt32(kVK_ANSI_Comma)),
            (.bottomRight, UInt32(kVK_ANSI_Period)),
            (.sixthBottomRight, UInt32(kVK_ANSI_Period)),
            (.leftHalf, UInt32(kVK_ANSI_J)),
            (.sixthLeft, UInt32(kVK_ANSI_J)),
            (.sixthMiddle, UInt32(kVK_ANSI_K)),
            (.rightHalf, UInt32(kVK_ANSI_L)),
            (.sixthRight, UInt32(kVK_ANSI_L)),
            (.sixthsLeftTwoThirds, UInt32(kVK_ANSI_H)),
            (.sixthsRightTwoThirds, UInt32(kVK_ANSI_Semicolon)),
        ]
        XCTAssertEqual(expected.count, Slot.allCases.count)
        for (slot, keyCode) in expected {
            XCTAssertEqual(slot.keyCode, keyCode, "\(slot.rawValue)")
        }
        // The pair that actually fires must be unique: two slots sharing
        // (keyCode, modifiers) would both trigger on one keypress.
        let combos = Slot.allCases.map { ($0.keyCode, $0.modifiers) }
        XCTAssertEqual(
            Set(combos.map { "\($0.0)-\($0.1)" }).count, Slot.allCases.count,
            "hotkey collision: \(combos)")
    }

    // MARK: Edge cases

    func testPlanIntoEmptySlotEvictsNothing() {
        // Untouched state: nothing to evict from any slot.
        for slot in Slot.allCases {
            XCTAssertEqual(
                TilingState().plan(window: a, into: slot), .tile(evicting: []))
        }
    }

    func testEvictionsAreSorted() {
        // Deterministic order: evicted ids come back sorted, not in slot order.
        var state = TilingState()
        state.commit(window: c, into: .topLeft)
        state.commit(window: a, into: .bottomLeft)
        XCTAssertEqual(state.plan(window: b, into: .leftHalf), .tile(evicting: [a, c]))
    }

    func testRightHalfOverTwoQuadsEvictsBoth() {
        var state = TilingState()
        state.commit(window: a, into: .topRight)
        state.commit(window: b, into: .bottomRight)
        XCTAssertEqual(state.plan(window: c, into: .rightHalf), .tile(evicting: [a, b]))
    }

    func testQuadOverOccupiedHalfKeepsOtherSide() {
        // Tiling TL over a full left+right layout evicts Left only; Right stays.
        var state = TilingState()
        state.commit(window: a, into: .leftHalf)
        state.commit(window: b, into: .rightHalf)
        XCTAssertEqual(state.plan(window: c, into: .topLeft), .tile(evicting: [a]))
        state.remove(window: a) // controller untiles evicted windows before placing
        state.commit(window: c, into: .topLeft)
        XCTAssertEqual(state.occupant(of: .topLeft), c)
        XCTAssertEqual(state.occupant(of: .rightHalf), b)
        XCTAssertNil(state.occupant(of: .leftHalf))
    }

    func testSameWindowRetilingSameHalfIsNoop() {
        // Already covered for quads; halves noop too.
        var state = TilingState()
        state.commit(window: a, into: .leftHalf)
        XCTAssertEqual(state.plan(window: a, into: .leftHalf), .noop)
    }

    func testDifferentWindowIntoOccupiedHalfEvicts() {
        var state = TilingState()
        state.commit(window: a, into: .rightHalf)
        XCTAssertEqual(state.plan(window: b, into: .rightHalf), .tile(evicting: [a]))
        state.remove(window: a) // controller untiles evicted windows before placing
        state.commit(window: b, into: .rightHalf)
        XCTAssertEqual(state.occupant(of: .rightHalf), b)
        XCTAssertEqual(state.slot(of: b), .rightHalf)
        XCTAssertNil(state.slot(of: a))
    }

    func testQuadExpandingToHalfEvictsColumnMate() {
        // TR expands to RightHalf while BR sits there: BR is evicted.
        // (Requester is tiled, but its vacated quad is INSIDE the target,
        // so there is no free space to relocate BR into.)
        var state = TilingState()
        state.commit(window: a, into: .topRight)
        state.commit(window: b, into: .bottomRight)
        XCTAssertEqual(
            state.plan(window: a, into: .rightHalf), .tile(evicting: [b]))
    }

    func testQuadRequestIntoHalfBlockerRelocatesToOtherQuad() {
        // TL -> BL (occupied by LeftHalf): the freed TL quad is exactly
        // enough for the half-window, which demotes to the TL quad.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .leftHalf)
        XCTAssertEqual(
            state.plan(window: a, into: .bottomLeft),
            .swap(placements: [a: .bottomLeft, b: .topLeft]))
        if case .swap(let placements) = state.plan(window: a, into: .bottomLeft) {
            state.commitSwaps(placements)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .bottomLeft), a)
        XCTAssertEqual(state.occupant(of: .topLeft), b)
        XCTAssertNil(state.occupant(of: .leftHalf))
    }

    func testFullScreenOfQuadsThenHalfEvictsColumnOnly() {
        // TL+BL+TR tiled; Left evicts the left column, TR survives.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        state.commit(window: c, into: .topRight)
        let d = 4
        XCTAssertEqual(state.plan(window: d, into: .leftHalf), .tile(evicting: [a, b]))
        state.remove(window: a)
        state.remove(window: b)
        state.commit(window: d, into: .leftHalf)
        XCTAssertEqual(state.occupant(of: .leftHalf), d)
        XCTAssertEqual(state.occupant(of: .topRight), c)
        XCTAssertNil(state.slot(of: a))
        XCTAssertNil(state.slot(of: b))
    }

    func testCommitClearsPendingEvictions() {
        // The caller removes evicted windows, then commits: no ghost occupants.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        let plan = state.plan(window: c, into: .leftHalf)
        XCTAssertEqual(plan, .tile(evicting: [a, b]))
        if case .tile(let evicting) = plan {
            for evicted in evicting { state.remove(window: evicted) }
        }
        state.commit(window: c, into: .leftHalf)
        XCTAssertEqual(state.occupants, [.leftHalf: c])
        XCTAssertEqual(state.tiledWindows, [c])
    }

    func testRemoveUnknownWindowIsNoop() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.remove(window: 999)
        XCTAssertEqual(state.occupant(of: .topLeft), a)
        XCTAssertEqual(state.tiledWindows, [a])
    }

    func testWindowMovesBetweenDisjointSlots() {
        // TL -> RightHalf: leaves the quad, no eviction.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.plan(window: a, into: .rightHalf), .tile(evicting: []))
        state.commit(window: a, into: .rightHalf)
        XCTAssertNil(state.occupant(of: .topLeft))
        XCTAssertEqual(state.occupant(of: .rightHalf), a)
    }

    // MARK: Swapping

    func testQuadToOccupiedQuadSwaps() {
        // TL -> occupied BR: the two windows exchange places, nobody is untiled.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomRight)
        XCTAssertEqual(
            state.plan(window: a, into: .bottomRight),
            .swap(placements: [a: .bottomRight, b: .topLeft]))
        if case .swap(let placements) = state.plan(window: a, into: .bottomRight) {
            state.commitSwaps(placements)
        }
        XCTAssertEqual(state.occupant(of: .bottomRight), a)
        XCTAssertEqual(state.occupant(of: .topLeft), b)
        XCTAssertEqual(state.tiledWindows.sorted(), [a, b])
    }

    func testHalfToOccupiedQuadSwapsAndStaysWhole() {
        // LeftHalf -> occupied TR: the half moves to the quad, the quad
        // window takes over the whole half (not just one of its quads).
        var state = TilingState()
        state.commit(window: a, into: .leftHalf)
        state.commit(window: b, into: .topRight)
        XCTAssertEqual(
            state.plan(window: a, into: .topRight),
            .swap(placements: [a: .topRight, b: .leftHalf]))
        if case .swap(let placements) = state.plan(window: a, into: .topRight) {
            state.commitSwaps(placements)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .topRight), a)
        XCTAssertEqual(state.occupant(of: .leftHalf), b)
        XCTAssertEqual(state.tiledWindows.sorted(), [a, b])
    }

    func testQuadToOccupiedHalfSwapsIntoVacatedQuad() {
        // TR -> TL (occupied by LeftHalf): quad takes TL, the half-window
        // takes over the vacated TR quad.
        var state = TilingState()
        state.commit(window: a, into: .topRight)
        state.commit(window: b, into: .leftHalf)
        XCTAssertEqual(
            state.plan(window: a, into: .topLeft),
            .swap(placements: [a: .topLeft, b: .topRight]))
        if case .swap(let placements) = state.plan(window: a, into: .topLeft) {
            state.commitSwaps(placements)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .topLeft), a)
        XCTAssertEqual(state.occupant(of: .topRight), b)
        XCTAssertNil(state.occupant(of: .leftHalf))
    }

    func testTwoHalvesSwap() {
        var state = TilingState()
        state.commit(window: a, into: .leftHalf)
        state.commit(window: b, into: .rightHalf)
        if case .swap(let placements) = state.plan(window: a, into: .rightHalf) {
            XCTAssertEqual(placements, [a: .rightHalf, b: .leftHalf])
            state.commitSwaps(placements)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .rightHalf), a)
        XCTAssertEqual(state.occupant(of: .leftHalf), b)
        XCTAssertEqual(state.tiledWindows.sorted(), [a, b])
    }

    func testAdjacentQuadsSwap() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        XCTAssertEqual(
            state.plan(window: a, into: .bottomLeft),
            .swap(placements: [a: .bottomLeft, b: .topLeft]))
        if case .swap(let placements) = state.plan(window: a, into: .bottomLeft) {
            state.commitSwaps(placements)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .bottomLeft), a)
        XCTAssertEqual(state.occupant(of: .topLeft), b)
    }

    func testSwapBacktracksWhenLargestFirstFails() {
        // RightHalf -> LeftHalf (occupied by two quads): greedy would give
        // the whole right half to the first blocker and strand the second,
        // so it must split into TR + BR instead.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        state.commit(window: c, into: .rightHalf)
        XCTAssertEqual(
            state.plan(window: c, into: .leftHalf),
            .swap(placements: [c: .leftHalf, a: .topRight, b: .bottomRight]))
        if case .swap(let placements) = state.plan(window: c, into: .leftHalf) {
            state.commitSwaps(placements)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .leftHalf), c)
        XCTAssertEqual(state.occupant(of: .topRight), a)
        XCTAssertEqual(state.occupant(of: .bottomRight), b)
        XCTAssertNil(state.occupant(of: .rightHalf))
    }

    func testSwapRoundTripRestoresLayout() {
        // Swapping twice returns both windows to their original slots.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomRight)
        if case .swap(let first) = state.plan(window: a, into: .bottomRight) {
            state.commitSwaps(first)
        } else {
            XCTFail("expected a swap")
        }
        if case .swap(let second) = state.plan(window: a, into: .topLeft) {
            state.commitSwaps(second)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .topLeft), a)
        XCTAssertEqual(state.occupant(of: .bottomRight), b)
    }

    func testSwapIsExhaustiveAndLeavesNoGhosts() {
        // Every requester/target pair over disjoint starting layouts from
        // BOTH geometries. Same-layout pairs yield noop / plain tile /
        // swap / eviction (cross-checked by the brute-force oracle);
        // cross-layout pairs must reset with the full eviction set.
        // Committing any plan leaves one window per slot, no window in two
        // slots, no cell double-booked, and counts conserved (swap keeps
        // all, eviction/switch drops exactly the evicted).
        let layouts: [[Slot]] = [
            [.topLeft, .topRight, .bottomLeft, .bottomRight],
            [.leftHalf, .topRight, .bottomRight],
            [.rightHalf, .topLeft, .bottomLeft],
            [.leftHalf, .rightHalf],
            [.sixthTopLeft, .sixthTopMiddle, .sixthTopRight,
             .sixthBottomLeft, .sixthBottomMiddle, .sixthBottomRight],
            [.sixthLeft, .sixthMiddle, .sixthRight],
            [.sixthsLeftTwoThirds, .sixthRight],
            [.sixthsRightTwoThirds, .sixthLeft],
            [.sixthLeft, .sixthTopMiddle, .sixthTopRight,
             .sixthBottomMiddle, .sixthBottomRight],
        ]
        var id = 1
        for layout in layouts {
            for requester in layout {
                for target in Slot.allCases {
                    var state = TilingState()
                    var slotByWindow: [WindowID: Slot] = [:]
                    for slot in layout {
                        state.commit(window: id, into: slot)
                        slotByWindow[id] = slot
                        id += 1
                    }
                    let requesterWindow = slotByWindow.first(where: { $0.value == requester })!.key
                    let before = Set(state.tiledWindows)
                    let plan = state.plan(window: requesterWindow, into: target)
                    if target.layout != requester.layout {
                        // Cross-layout: full reset, requester included.
                        XCTAssertEqual(
                            plan, .switchLayout(evicting: before.sorted()),
                            "\(requester) -> \(target)")
                        switch plan {
                        case .switchLayout(let evicting):
                            for evicted in evicting { state.remove(window: evicted) }
                            state.commit(window: requesterWindow, into: target)
                            XCTAssertEqual(state.occupants, [target: requesterWindow])
                            XCTAssertEqual(state.activeLayout, target.layout)
                        default:
                            XCTFail("cross-layout pair \(requester) -> \(target) did not reset")
                            continue
                        }
                        continue
                    }
                    // Independent oracle: brute-force product enumeration over
                    // candidate slots (written plainly, no size heuristic),
                    // cross-checked against plan() so a degraded solver that
                    // evicts where a swap fits cannot slip through.
                    // Mirrors plan(): slots overlapping the target other than
                    // the requester's own (a window never contends with
                    // itself). Note the target slot itself stays: its
                    // occupant is the swap/evict candidate.
                    let blockers = layout.filter {
                        $0 != requester && $0.overlaps(target)
                    }
                    let free = requester.cells.subtracting(target.cells)
                    // No blockers means a plain move, not a swap.
                    let swapPossible = !blockers.isEmpty && Self.bruteForceFits(
                        count: blockers.count, within: free, layout: target.layout)
                    if requester == target {
                        XCTAssertEqual(plan, .noop, "\(requester) -> \(target)")
                    } else if swapPossible {
                        guard case .swap = plan else {
                            XCTFail("\(requester) -> \(target): swap fits but got \(plan)")
                            continue
                        }
                    } else {
                        let expect = blockers.compactMap { blocker in
                            slotByWindow.first(where: { $0.value == blocker })?.key
                        }.sorted()
                        XCTAssertEqual(
                            plan, .tile(evicting: expect),
                            "\(requester) -> \(target)")
                    }
                    switch plan {
                    case .noop:
                        XCTAssertEqual(requester, target)
                        XCTAssertEqual(state.occupant(of: target), requesterWindow)
                    case .switchLayout:
                        XCTFail("same-layout pair \(requester) -> \(target) reset")
                        continue
                    case .tile(let evicting):
                        for evicted in evicting { state.remove(window: evicted) }
                        state.commit(window: requesterWindow, into: target)
                        XCTAssertEqual(state.occupant(of: target), requesterWindow)
                        for evicted in evicting {
                            XCTAssertNil(state.slot(of: evicted), "evicted win\(evicted) lingers")
                        }
                        XCTAssertEqual(
                            Set(state.tiledWindows),
                            before.subtracting(evicting),
                            "\(requester) -> \(target)")
                    case .swap(let placements):
                        XCTAssertEqual(placements[requesterWindow], target)
                        state.commitSwaps(placements)
                        XCTAssertEqual(state.occupant(of: target), requesterWindow)
                        XCTAssertEqual(
                            Set(state.tiledWindows), before,
                            "swap \(requester) -> \(target) lost a window")
                    case .switchLayout:
                        XCTFail("same-layout pair \(requester) -> \(target) reset")
                        continue
                    }
                    // Invariants after every commit path: no ghost windows,
                    // no cell double-booked, committed state matches the plan.
                    XCTAssertEqual(
                        Set(state.tiledWindows),
                        Set(state.occupants.values),
                        "\(requester) -> \(target): ghost occupant")
                    let windows = state.tiledWindows
                    XCTAssertEqual(windows.count, Set(windows).count)
                    var seenCells: Set<TileCell> = []
                    for (slot, occupant) in state.occupants {
                        XCTAssertEqual(state.slot(of: occupant), slot)
                        XCTAssertEqual(
                            slot.layout, state.activeLayout,
                            "\(requester) -> \(target): mixed layouts on screen")
                        for cell in slot.cells {
                            XCTAssertFalse(
                                seenCells.contains(cell),
                                "\(requester) -> \(target): cell \(cell) double-booked")
                            seenCells.insert(cell)
                        }
                    }
                }
            }
        }
    }

    /// Brute-force oracle for the sweep above: tries every assignment of
    /// `count` blockers to cell-disjoint same-layout slots inside `free` via
    /// plain product enumeration (no largest-first heuristic, no pruning),
    /// so it fails independently if the solver under- or over-swaps.
    private static func bruteForceFits(count: Int, within free: Set<TileCell>, layout: LayoutKind) -> Bool {
        if count == 0 { return true }
        let candidates = Slot.allCases.filter {
            $0.layout == layout && $0.cells.isSubset(of: free)
        }
        var assignment = [Slot](repeating: .topLeft, count: count)
        func fits(_ index: Int) -> Bool {
            if index == count {
                var used: Set<TileCell> = []
                for slot in assignment {
                    if !slot.cells.isDisjoint(with: used) { return false }
                    used.formUnion(slot.cells)
                }
                return true
            }
            for candidate in candidates {
                assignment[index] = candidate
                if fits(index + 1) { return true }
            }
            return false
        }
        return fits(0)
    }

    // MARK: Layout switching

    func testActiveLayoutDefaultsToQuarters() {
        XCTAssertEqual(TilingState().activeLayout, .quarters)
    }

    func testCrossLayoutRequestResetsAndSwitches() {
        // Two quarters tiled; an untiled window requests a sixths slot:
        // everything is evicted and the layout switches.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomRight)
        XCTAssertEqual(state.activeLayout, .quarters)
        XCTAssertEqual(
            state.plan(window: c, into: .sixthTopLeft),
            .switchLayout(evicting: [a, b]))
        if case .switchLayout(let evicting) = state.plan(window: c, into: .sixthTopLeft) {
            for evicted in evicting { state.remove(window: evicted) }
        } else {
            XCTFail("expected a layout switch")
        }
        state.commit(window: c, into: .sixthTopLeft)
        XCTAssertEqual(state.occupants, [.sixthTopLeft: c])
        XCTAssertEqual(state.activeLayout, .sixths)
    }

    func testCrossLayoutRequestBackToQuarters() {
        var state = TilingState()
        state.commit(window: a, into: .sixthLeft)
        state.commit(window: b, into: .sixthRight)
        XCTAssertEqual(state.activeLayout, .sixths)
        XCTAssertEqual(
            state.plan(window: c, into: .topLeft),
            .switchLayout(evicting: [a, b]))
    }

    func testSameSlotSameWindowIsNoop() {
        // Same slot, same window: noop wins. Target and occupant share a
        // layout by definition, so switchLayout must never fire for it.
        var state = TilingState()
        state.commit(window: a, into: .sixthLeft)
        XCTAssertEqual(state.plan(window: a, into: .sixthLeft), .noop)
    }

    func testLayoutSwitchEvictionsAreSorted() {
        var state = TilingState()
        state.commit(window: c, into: .topLeft)
        state.commit(window: a, into: .bottomRight)
        XCTAssertEqual(
            state.plan(window: b, into: .sixthMiddle),
            .switchLayout(evicting: [a, c]))
    }

    func testTiledWindowRequestingOtherLayoutResetsToo() {
        // Even a tiled window resets when it targets the other layout — it
        // joins the evicted set rather than swapping across layouts.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomRight)
        XCTAssertEqual(
            state.plan(window: a, into: .sixthTopLeft),
            .switchLayout(evicting: [a, b]))
    }

    func testSixthsSwapWithinLayout() {
        // Sixths slots swap among themselves like quarters do.
        var state = TilingState()
        state.commit(window: a, into: .sixthLeft)
        state.commit(window: b, into: .sixthRight)
        XCTAssertEqual(
            state.plan(window: a, into: .sixthRight),
            .swap(placements: [a: .sixthRight, b: .sixthLeft]))
        if case .swap(let placements) = state.plan(window: a, into: .sixthRight) {
            state.commitSwaps(placements)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .sixthRight), a)
        XCTAssertEqual(state.occupant(of: .sixthLeft), b)
        XCTAssertEqual(state.tiledWindows.sorted(), [a, b])
    }

    func testSixthsTwoThirdsOverThirdsEvicts() {
        // Left 2/3 over tiled Left+Middle thirds overlaps both while
        // vacating one third: no room, both evicted.
        var state = TilingState()
        state.commit(window: a, into: .sixthLeft)
        state.commit(window: b, into: .sixthMiddle)
        XCTAssertEqual(
            state.plan(window: c, into: .sixthsLeftTwoThirds),
            .tile(evicting: [a, b]))
        if case .tile(let evicting) = state.plan(window: c, into: .sixthsLeftTwoThirds) {
            for evicted in evicting { state.remove(window: evicted) }
        } else {
            XCTFail("expected an eviction")
        }
        state.commit(window: c, into: .sixthsLeftTwoThirds)
        XCTAssertEqual(state.occupant(of: .sixthsLeftTwoThirds), c)
        XCTAssertNil(state.slot(of: a))
        XCTAssertNil(state.slot(of: b))
    }

    func testSixthsSwapBacktracksWhenLargestFirstFails() {
        // SixthsLeft -> SixthsRight (occupied by two corner sixths): greedy
        // would park the first blocker in the whole left third and strand
        // the second, so it must split into the two left corners instead.
        var state = TilingState()
        state.commit(window: a, into: .sixthTopRight)
        state.commit(window: b, into: .sixthBottomRight)
        state.commit(window: c, into: .sixthLeft)
        XCTAssertEqual(
            state.plan(window: c, into: .sixthRight),
            .swap(placements: [c: .sixthRight, a: .sixthTopLeft, b: .sixthBottomLeft]))
    }

    func testSingleSixthResetsToQuarters() {
        // One sixths window tiled; a quarters request still resets everything.
        var state = TilingState()
        state.commit(window: a, into: .sixthMiddle)
        XCTAssertEqual(
            state.plan(window: b, into: .topLeft),
            .switchLayout(evicting: [a]))
    }

    func testUntiledWindowIntoSingleSixthEvicts() {
        // Same-layout eviction path with one occupant, for symmetry with the
        // switch test above.
        var state = TilingState()
        state.commit(window: a, into: .sixthMiddle)
        XCTAssertEqual(
            state.plan(window: b, into: .sixthMiddle),
            .tile(evicting: [a]))
    }

    // MARK: Sixths session sequences (tiling, retiling, eviction chains)

    /// Drives a sequence of (window, slot) requests through plan/commit
    /// exactly like TilingController.handle does, then validates the end
    /// state: one window per slot, no cell double-booked, committed state
    /// matches the requester's slot. Returns the final state.
    @discardableResult
    private func drive(
        _ requests: [(WindowID, Slot)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> TilingState {
        var state = TilingState()
        for (window, slot) in requests {
            switch state.plan(window: window, into: slot) {
            case .noop:
                break // no state change

            case .swap(let placements):
                state.commitSwaps(placements)
            case .tile(let evicting), .switchLayout(let evicting):
                for evicted in evicting { state.remove(window: evicted) }
                state.commit(window: window, into: slot)
            }
            for (occupied, occupant) in state.occupants {
                XCTAssertEqual(
                    state.slot(of: occupant), occupied,
                    "after win\(window) -> \(slot)", file: file, line: line)
            }
            var seen: Set<TileCell> = []
            for (occupied, _) in state.occupants {
                for cell in occupied.cells {
                    XCTAssertFalse(
                        seen.contains(cell),
                        "after win\(window) -> \(slot): cell \(cell) double-booked",
                        file: file, line: line)
                    seen.insert(cell)
                }
            }
        }
        return state
    }

    func testSixthsFillRowThenRetile() {
        // Fill the top row corner-by-corner with fresh windows, then move
        // one of them to the other row: the vacated sixth frees up.
        let end = drive([
            (a, .sixthTopLeft), (b, .sixthTopMiddle), (c, .sixthTopRight),
            (b, .sixthBottomMiddle),
        ])
        XCTAssertEqual(end.occupant(of: .sixthTopLeft), a)
        XCTAssertEqual(end.occupant(of: .sixthBottomMiddle), b)
        XCTAssertEqual(end.occupant(of: .sixthTopRight), c)
        XCTAssertNil(end.occupant(of: .sixthTopMiddle))
        XCTAssertEqual(end.activeLayout, .sixths)
    }

    func testSixthsThirdsFillThenTwoThirdsEvicts() {
        // Fill all three thirds, then drop a two-thirds over them: both
        // overlapped thirds are evicted and the third survives.
        let d = 4
        let end = drive([
            (a, .sixthLeft), (b, .sixthMiddle), (c, .sixthRight),
            (d, .sixthsLeftTwoThirds),
        ])
        XCTAssertEqual(end.occupant(of: .sixthsLeftTwoThirds), d)
        XCTAssertEqual(end.occupant(of: .sixthRight), c)
        XCTAssertNil(end.slot(of: a))
        XCTAssertNil(end.slot(of: b))
        XCTAssertEqual(end.tiledWindows.sorted(), [c, d])
    }

    func testSixthsRepeatedRetilingSameWindow() {
        // One window bounced across sixths slots: it always ends up exactly
        // where asked, never duplicated, never evicting needlessly.
        let end = drive([
            (a, .sixthLeft), (a, .sixthTopMiddle), (a, .sixthRight),
            (a, .sixthsRightTwoThirds), (a, .sixthBottomLeft),
        ])
        XCTAssertEqual(end.occupants, [.sixthBottomLeft: a])
        XCTAssertEqual(end.tiledWindows, [a])
    }

    func testSixthsSwapChain() {
        // Left <-> Right is a clean swap; then Middle -> Left swaps the
        // middle window into the left third against the swapped occupant.
        let end = drive([
            (a, .sixthLeft), (b, .sixthMiddle), (c, .sixthRight),
            (a, .sixthRight),
            (b, .sixthLeft),
        ])
        XCTAssertEqual(end.occupant(of: .sixthRight), a)
        XCTAssertEqual(end.occupant(of: .sixthLeft), b)
        XCTAssertEqual(end.occupant(of: .sixthMiddle), c)
    }

    func testSixthsSameSlotIsNoop() {
        // Repeating the same request changes nothing, so the slot stays
        // taken and a different window evicts the occupant.
        let end = drive([
            (a, .sixthTopLeft), (b, .sixthTopMiddle),
            (a, .sixthTopLeft), // noop: a stays
            (c, .sixthTopLeft), // evicts a
        ])
        XCTAssertEqual(end.occupant(of: .sixthTopLeft), c)
        XCTAssertEqual(end.occupant(of: .sixthTopMiddle), b)
        XCTAssertNil(end.slot(of: a))
        XCTAssertEqual(end.activeLayout, .sixths)
    }

    func testSixthsToQuartersAndBack() {
        // Full sixths session, reset to quarters, tile there, reset back:
        // each switch leaves exactly the requester behind.
        let end = drive([
            (a, .sixthLeft), (b, .sixthMiddle), (c, .sixthRight),
            (c, .topLeft), // reset to quarters
            (a, .topRight),
            (a, .sixthMiddle), // reset to sixths
        ])
        XCTAssertEqual(end.occupants, [.sixthMiddle: a])
        XCTAssertEqual(end.activeLayout, .sixths)
        XCTAssertNil(end.slot(of: b))
        XCTAssertNil(end.slot(of: c))
    }

    func testSixthsCornerEvictionCascade() {
        // Stack corners in one third, then cover the third: the stacked
        // corners go, the neighbor third survives; retiling the freed
        // corner works immediately.
        let d = 4
        let end = drive([
            (a, .sixthTopLeft), (b, .sixthBottomLeft), (c, .sixthMiddle),
            (d, .sixthLeft),
            (a, .sixthTopRight),
        ])
        XCTAssertEqual(end.occupant(of: .sixthLeft), d)
        XCTAssertEqual(end.occupant(of: .sixthMiddle), c)
        XCTAssertEqual(end.occupant(of: .sixthTopRight), a)
        XCTAssertNil(end.slot(of: b))
    }

    func testSixthsExhaustiveReachableStates() {
        // BFS over short request sequences (up to 3 windows, sixths slots)
        // asserting the no-ghost / no-overlap / active-layout invariants
        // after EVERY step, not just at the end.
        let windows = [a, b, c]
        let targets: [Slot] = [
            .sixthTopLeft, .sixthTopMiddle, .sixthTopRight,
            .sixthBottomLeft, .sixthBottomMiddle, .sixthBottomRight,
            .sixthLeft, .sixthMiddle, .sixthRight,
            .sixthsLeftTwoThirds, .sixthsRightTwoThirds,
        ]
        var queue: [(TilingState, Int)] = [(TilingState(), 0)]
        var visited: Set<String> = []
        var steps = 0
        while !queue.isEmpty {
            let (state, depth) = queue.removeFirst()
            for window in windows {
                for target in targets {
                    var next = state
                    switch next.plan(window: window, into: target) {
                    case .noop:
                        break // no state change

                    case .swap(let placements):
                        next.commitSwaps(placements)
                    case .tile(let evicting), .switchLayout(let evicting):
                        for evicted in evicting { next.remove(window: evicted) }
                        next.commit(window: window, into: target)
                    }
                    steps += 1
                    // Invariants after every single transition.
                    XCTAssertEqual(
                        Set(next.tiledWindows), Set(next.occupants.values),
                        "win\(window) -> \(target)")
                    var seen: Set<TileCell> = []
                    for (slot, occupant) in next.occupants {
                        XCTAssertEqual(next.slot(of: occupant), slot)
                        XCTAssertEqual(slot.layout, next.activeLayout)
                        for cell in slot.cells {
                            XCTAssertFalse(seen.contains(cell), "win\(window) -> \(target)")
                            seen.insert(cell)
                        }
                    }
                    let key = next.occupants
                        .map { "\($0.key.rawValue)=\($0.value)" }
                        .sorted().joined(separator: ",")
                    if depth < 2 && visited.insert(key).inserted {
                        queue.append((next, depth + 1))
                    }
                }
            }
        }
        XCTAssertGreaterThan(steps, 1000, "BFS explored too little")
    }

    func testSwapWithoutRoomFallsBackToEviction() {
        // All four quads tiled; TL -> RightHalf overlaps two windows but
        // vacates one quad, so both are evicted instead of swapped.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        state.commit(window: c, into: .topRight)
        let d = 4
        state.commit(window: d, into: .bottomRight)
        XCTAssertEqual(
            state.plan(window: a, into: .rightHalf), .tile(evicting: [c, d]))
    }

    func testUntiledRequesterAlwaysEvicts() {
        // An untiled window vacates nothing, so even a clean 1-for-1
        // takeover evicts rather than swaps.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomRight)
        XCTAssertEqual(state.plan(window: c, into: .bottomRight), .tile(evicting: [b]))
        XCTAssertEqual(state.plan(window: c, into: .leftHalf), .tile(evicting: [a]))
    }

    func testSwapKeepsDisjointWindowsInPlace() {
        // TL -> occupied BR swaps the pair; the other two quads are untouched.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomRight)
        state.commit(window: c, into: .topRight)
        let d = 4
        state.commit(window: d, into: .bottomLeft)
        if case .swap(let placements) = state.plan(window: a, into: .bottomRight) {
            state.commitSwaps(placements)
        } else {
            XCTFail("expected a swap")
        }
        XCTAssertEqual(state.occupant(of: .bottomRight), a)
        XCTAssertEqual(state.occupant(of: .topLeft), b)
        XCTAssertEqual(state.occupant(of: .topRight), c)
        XCTAssertEqual(state.occupant(of: .bottomLeft), d)
    }

    func testThirdWindowIntoDisjointSlotCoexists() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        XCTAssertEqual(state.plan(window: c, into: .topRight), .tile(evicting: []))
        state.commit(window: c, into: .topRight)
        XCTAssertEqual(state.tiledWindows.sorted(), [a, b, c])
    }
}
