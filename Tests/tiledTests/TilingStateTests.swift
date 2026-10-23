import Carbon.HIToolbox
import XCTest
@testable import tiled

final class TilingStateTests: XCTestCase {
    private let a = 1
    private let b = 2
    private let c = 3

    // MARK: Basics

    func testTileIntoEmptySlot() {
        var state = TilingState(layout: .quarters)
        XCTAssertEqual(state.plan(window: a, into: .topLeft), .tile(evicting: []))
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.occupant(of: .topLeft), a)
        XCTAssertEqual(state.slot(of: a), .topLeft)
    }

    func testSameSlotIsNoop() {
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.plan(window: a, into: .topLeft), .noop)
        // Nothing committed: the window stays exactly where it was.
        XCTAssertEqual(state.occupant(of: .topLeft), a)
        XCTAssertEqual(state.slot(of: a), .topLeft)
    }

    func testSecondWindowIntoOccupiedSlotEvictsFirst() {
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.plan(window: b, into: .topLeft), .tile(evicting: [a]))
    }

    // MARK: Eviction rules (as decided in design)

    func testHalfOverTwoQuadsEvictsBoth() {
        // TL + BL tiled; a fresh window takes the left half. Both quads
        // overlap the target and are evicted.
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        XCTAssertEqual(state.plan(window: c, into: .leftHalf), .tile(evicting: [a, b]))
    }

    func testQuadOverOccupiedHalfEvictsHalf() {
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .leftHalf)
        XCTAssertEqual(state.plan(window: b, into: .bottomLeft), .tile(evicting: [a]))
    }

    func testQuadOverOccupiedHalfEvictsHalfOtherQuad() {
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .rightHalf)
        XCTAssertEqual(state.plan(window: b, into: .topRight), .tile(evicting: [a]))
    }

    func testDisjointSlotsCoexist() {
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.plan(window: b, into: .rightHalf), .tile(evicting: []))
        state.commit(window: b, into: .rightHalf)
        XCTAssertEqual(state.occupant(of: .topLeft), a)
        XCTAssertEqual(state.occupant(of: .rightHalf), b)
    }

    func testQuadsInSameColumnCoexist() {
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.plan(window: b, into: .bottomLeft), .tile(evicting: []))
    }

    // MARK: Tile swapping

    func testBlockerInsideTheTargetStillSwaps() {
        // The report's example, inverted: the middle third sits inside
        // the right two-thirds a tiled requester is asking for. The
        // blocker has no leftover of its own, so the step-aside cannot
        // fire and the vacated tile still offers a landing: swap stands.
        var state = TilingState(layout: .sixths)
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: b, into: .sixthMiddle)
        state.commit(window: c, into: .sixthBottomLeft)
        XCTAssertEqual(
            state.plan(window: a, into: .sixthsRightTwoThirds), .swap(displaced: b))
    }

    func testTiledRequesterStepsTheContainingBlockerAside() {
        // Left, middle, and right thirds; the right third requests the
        // bottom-left sixth. The left third contains the target with a
        // clean leftover — the top-left sixth — so it steps aside into
        // its own strip instead of trading tiles across the screen: the
        // plan is an eviction the commit re-houses, not a swap.
        var state = TilingState(layout: .sixths)
        state.commit(window: a, into: .sixthLeft)
        state.commit(window: b, into: .sixthMiddle)
        state.commit(window: c, into: .sixthRight)
        XCTAssertEqual(state.plan(window: c, into: .sixthBottomLeft), .tile(evicting: [a]))
    }

    func testTiledRequesterIntoExactOccupiedSlotSwaps() {
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)
        XCTAssertEqual(state.plan(window: a, into: .topRight), .swap(displaced: b))
    }

    func testUntiledRequesterOverSingleBlockerStillEvicts() {
        // An untiled requester has no tile to offer, so there is nothing
        // to swap with: eviction stands.
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.plan(window: b, into: .topLeft), .tile(evicting: [a]))
    }

    func testTiledRequesterOverTwoBlockersEvictsBoth() {
        // Only one window can take the requester's old tile; with two in
        // the way the request degrades to an ordinary eviction.
        var state = TilingState(layout: .sixths)
        state.commit(window: a, into: .sixthLeft)
        state.commit(window: b, into: .sixthTopMiddle)
        state.commit(window: c, into: .sixthBottomMiddle)
        XCTAssertEqual(
            state.plan(window: a, into: .sixthsLeftTwoThirds),
            .tile(evicting: [b, c]))
    }

    func testTiledRequesterWhoseTileOverlapsTargetEvicts() {
        // A swap needs a landing tile disjoint from the target: moving
        // from Top Left to Left Half would stuff the displaced window
        // inside the requester's new half, so eviction stands.
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        XCTAssertEqual(state.plan(window: a, into: .leftHalf), .tile(evicting: [b]))
    }

    func testSwapRestoresNothing() {
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)
        XCTAssertEqual(
            state.plan(window: a, into: .topRight).windowsToRestore(), [])
    }

    // MARK: Moving within the layout

    func testWindowMovingToOverlappingSlotDoesNotEvictItself() {
        // Window in Left requests BL: moves, keeps its pre-tile frame.
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .leftHalf)
        XCTAssertEqual(state.plan(window: a, into: .bottomLeft), .tile(evicting: []))
        state.commit(window: a, into: .bottomLeft)
        XCTAssertNil(state.occupant(of: .leftHalf))
        XCTAssertEqual(state.occupant(of: .bottomLeft), a)
    }

    func testWindowTiledIntoSecondSlotLeavesFirst() {
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .topLeft)
        state.commit(window: a, into: .bottomRight)
        XCTAssertNil(state.occupant(of: .topLeft))
        XCTAssertEqual(state.occupant(of: .bottomRight), a)
    }

    func testRemoveCleansUp() {
        var state = TilingState(layout: .quarters)
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
            Set(SlotKey.allCases.map { $0.defaultBinding.label }).count,
            11) // one combo per physical key
    }

    func testHotkeyIDRoundTripsEverySlotKey() {
        // Mirrors the Carbon id scheme: hotkeyID must be a unique dense
        // 1-based index into allCases, and every id must resolve back to
        // its key. A duplicate or gap means a hotkey fires the wrong key
        // or nothing at all.
        let ids = SlotKey.allCases.map(\.hotkeyID)
        XCTAssertEqual(Set(ids).count, SlotKey.allCases.count, "duplicate hotkeyID")
        XCTAssertEqual(Set(ids), Set(1...UInt32(SlotKey.allCases.count)), "hotkeyID gap")
        var keyByID: [UInt32: SlotKey] = [:]
        for key in SlotKey.allCases {
            keyByID[key.hotkeyID] = key
        }
        for key in SlotKey.allCases {
            XCTAssertEqual(
                keyByID[key.hotkeyID], key, "\(key.rawValue) does not round-trip")
        }
    }

    func testHotkeys() {
        // The shared ⌥⇧ set: one keycap per physical position, no ⌘.
        let shiftOption = UInt32(shiftKey | optionKey)
        for key in SlotKey.allCases {
            XCTAssertEqual(key.defaultBinding.modifiers, shiftOption, "\(key.rawValue)")
        }
        let expected: [(SlotKey, UInt32)] = [
            (.topLeft, UInt32(kVK_ANSI_U)),
            (.topMiddle, UInt32(kVK_ANSI_I)),
            (.topRight, UInt32(kVK_ANSI_O)),
            (.bottomLeft, UInt32(kVK_ANSI_M)),
            (.bottomMiddle, UInt32(kVK_ANSI_Comma)),
            (.bottomRight, UInt32(kVK_ANSI_Period)),
            (.leftColumn, UInt32(kVK_ANSI_J)),
            (.middleColumn, UInt32(kVK_ANSI_K)),
            (.rightColumn, UInt32(kVK_ANSI_L)),
            (.leftTwoThirds, UInt32(kVK_ANSI_H)),
            (.rightTwoThirds, UInt32(kVK_ANSI_Semicolon)),
        ]
        XCTAssertEqual(expected.count, SlotKey.allCases.count)
        for (key, keyCode) in expected {
            XCTAssertEqual(key.keyCode, keyCode, "\(key.rawValue)")
        }
        // The pair that actually fires must be unique: two keys sharing
        // (keyCode, modifiers) would both trigger on one keypress.
        let combos = SlotKey.allCases.map { ($0.keyCode, $0.defaultBinding.modifiers) }
        XCTAssertEqual(
            Set(combos.map { "\($0.0)-\($0.1)" }).count, SlotKey.allCases.count,
            "hotkey collision: \(combos)")
    }

    // MARK: Edge cases

    func testPlanIntoEmptySlotEvictsNothing() {
        // Untouched state: nothing to evict from any slot of either layout.
        for slot in Slot.allCases {
            XCTAssertEqual(
                TilingState(layout: slot.layout).plan(window: a, into: slot),
                .tile(evicting: []))
        }
    }

    func testEvictionListIsSortedById() {
        // Evicted ids come back sorted by id, which is observable only
        // when commit order disagrees with it: blockers committed
        // top-right first (id 4), bottom-right second (id 3); the plan
        // must name [3, 4].
        var state = TilingState(layout: .quarters)
        state.commit(window: 4, into: .topRight)
        state.commit(window: 3, into: .bottomRight)
        state.commit(window: 2, into: .bottomLeft)
        state.commit(window: 1, into: .topLeft)
        XCTAssertEqual(state.plan(window: 1, into: .rightHalf), .tile(evicting: [3, 4]))
    }

    func testSameWindowRetilingSameHalfIsNoop() {
        // Already covered for quads; halves noop too.
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .leftHalf)
        XCTAssertEqual(state.plan(window: a, into: .leftHalf), .noop)
    }

    func testFullScreenOfQuadsThenHalfEvictsColumnOnly() {
        // TL+BL+TR tiled; Left evicts the left column, TR survives.
        var state = TilingState(layout: .quarters)
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

    func testRemoveUnknownWindowIsNoop() {
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .topLeft)
        state.remove(window: 999)
        XCTAssertEqual(state.occupant(of: .topLeft), a)
        XCTAssertEqual(state.tiledWindows, [a])
    }

    func testWindowMovesBetweenDisjointSlots() {
        // TL -> RightHalf: leaves the quad, no eviction.
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.plan(window: a, into: .rightHalf), .tile(evicting: []))
        state.commit(window: a, into: .rightHalf)
        XCTAssertNil(state.occupant(of: .topLeft))
        XCTAssertEqual(state.occupant(of: .rightHalf), a)
    }

    // MARK: Layout state

    func testFreshStateStartsInSixths() {
        XCTAssertEqual(TilingState().layout, .sixths)
    }

    func testSetLayoutStoresTheChoiceOnAnEmptyBoard() {
        var state = TilingState()
        state.setLayout(.quarters)
        XCTAssertEqual(state.layout, .quarters)
        XCTAssertTrue(state.occupants.isEmpty)
        state.setLayout(.sixths)
        XCTAssertEqual(state.layout, .sixths)
    }

    func testEmptyBoardKeepsTheChosenLayoutAfterItsWindowsLeave() {
        // The layout is a canvas choice, not an occupancy side effect: the
        // last window leaving must not reset it. Otherwise the next slot
        // key would silently mean a different position.
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .topLeft)
        state.remove(window: a)
        XCTAssertTrue(state.occupants.isEmpty)
        XCTAssertEqual(state.layout, .quarters)
        XCTAssertEqual(state.plan(window: b, into: .bottomRight), .tile(evicting: []))
    }

    func testCommitNeverAdoptsTheSlotsLayout() {
        // The slot must already match: commit is a placement, not a layout
        // writer. A sixths commit on a quarters board is a programming
        // error the precondition fences, so only same-layout commits are
        // reachable from the public pipeline.
        var state = TilingState(layout: .quarters)
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.layout, .quarters)
        state.remove(window: a)
        state.setLayout(.sixths) // after emptying is the only legal path
        state.commit(window: b, into: .sixthMiddle)
        XCTAssertEqual(state.layout, .sixths, "commit left the stored layout alone")
    }

    func testSlotForKeyResolvesAgainstTheStoredLayout() {
        var state = TilingState(layout: .quarters)
        XCTAssertEqual(state.slot(for: .topLeft), .topLeft)
        XCTAssertEqual(state.slot(for: .leftColumn), .leftHalf)
        XCTAssertNil(state.slot(for: .topMiddle), "Quarters has no top middle")
        state.setLayout(.sixths)
        XCTAssertEqual(state.slot(for: .topLeft), .sixthTopLeft)
        XCTAssertEqual(state.slot(for: .topMiddle), .sixthTopMiddle)
        XCTAssertEqual(state.slot(for: .middleColumn), .sixthMiddle)
        XCTAssertEqual(state.slot(for: .rightTwoThirds), .sixthsRightTwoThirds)
    }

    func testCapacityChangesWithTheStoredLayout() {
        // Eight sixths-corner windows cannot coexist in Quarters: the
        // layout gates which slots exist at all.
        var state = TilingState(layout: .sixths)
        let corners: [Slot] = [
            .sixthTopLeft, .sixthTopMiddle, .sixthTopRight,
            .sixthBottomLeft, .sixthBottomMiddle, .sixthBottomRight,
        ]
        for (index, slot) in corners.enumerated() {
            state.commit(window: index + 1, into: slot)
        }
        XCTAssertEqual(state.tiledWindows.count, 6)
        XCTAssertEqual(state.layout, .sixths)
    }

    func testSameSlotSameWindowIsNoop() {
        var state = TilingState(layout: .sixths)
        state.commit(window: a, into: .sixthLeft)
        XCTAssertEqual(state.plan(window: a, into: .sixthLeft), .noop)
    }

    func testUntiledWindowIntoSingleSixthEvicts() {
        var state = TilingState(layout: .sixths)
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
        var state = TilingState(layout: .sixths)
        for (window, slot) in requests {
            switch state.plan(window: window, into: slot) {
            case .noop:
                break // no state change
            case .swap(let displaced):
                if let previous = state.slot(of: window) {
                    state.commit(window: displaced, into: previous)
                }
                state.commit(window: window, into: slot)
            case .tile(let evicting):
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
        XCTAssertEqual(end.layout, .sixths)
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
        XCTAssertEqual(end.layout, .sixths)
    }

    func testLayoutSwitchAfterEmptyingKeepsTheNewLayout() {
        // A switch is an explicit empty-board step now: the canvas untiles
        // its occupancies, adopts the other layout, and the next placement
        // lands there. No request crosses layouts.
        var state = TilingState(layout: .sixths)
        state.commit(window: a, into: .sixthLeft)
        state.commit(window: b, into: .sixthMiddle)
        state.remove(window: a)
        state.remove(window: b)
        state.setLayout(.quarters)
        state.commit(window: c, into: .topLeft)
        XCTAssertEqual(state.occupants, [.topLeft: c])
        XCTAssertEqual(state.layout, .quarters)

        state.remove(window: c)
        state.setLayout(.sixths)
        state.commit(window: a, into: .sixthMiddle)
        XCTAssertEqual(state.occupants, [.sixthMiddle: a])
        XCTAssertEqual(state.layout, .sixths)
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
        var queue: [(TilingState, Int)] = [(TilingState(layout: .sixths), 0)]
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
                    case .swap(let displaced):
                        if let previous = next.slot(of: window) {
                            next.commit(window: displaced, into: previous)
                        }
                        next.commit(window: window, into: target)
                    case .tile(let evicting):
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
                        XCTAssertEqual(slot.layout, next.layout)
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
}
