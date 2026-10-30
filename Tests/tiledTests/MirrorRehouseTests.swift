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

    // MARK: The re-house notice

    func testNoticeNamesTwoHomesWithTheirSlots() {
        // Two windows that stayed tiled each get a verb and a slot, so the
        // sentence cannot be read as one window moving twice.
        XCTAssertEqual(
            TilingSpace.rehouseNotice(homes: [
                (name: "Preview", slot: .topLeft), (name: "Notes", slot: .bottomLeft),
            ]),
            "Preview moved to Top Left and Notes moved to Bottom Left to make room."
                + MenuText.undoRecoveryHint)
    }

    func testNoticeFallsBackToACountWhenANameIsMissing() {
        // An unnamed app (an AX tree that answers nothing) must not read
        // as "That window moved to Top Left and That window moved to
        // Bottom Left".
        XCTAssertEqual(
            TilingSpace.rehouseNotice(homes: [
                (name: "Preview", slot: .topLeft), (name: nil, slot: .bottomLeft),
            ]),
            "2 windows moved to the other side to make room." + MenuText.undoRecoveryHint)
    }

    func testSingleHomeKeepsItsOwnWording() {
        // The lone re-house sentence is unchanged, fallback name included.
        XCTAssertEqual(
            TilingSpace.rehouseNotice(homes: [(name: "Preview", slot: .sixthRight)]),
            "Preview moved to Right Third to make room." + MenuText.undoRecoveryHint)
        XCTAssertEqual(
            TilingSpace.rehouseNotice(homes: [(name: nil, slot: .sixthRight)]),
            "That window moved to Right Third to make room." + MenuText.undoRecoveryHint)
    }

    func testNoticeNamesThreeOrMoreByFirstAndCount() {
        let homes: [(name: String?, slot: Slot)] = [
            (name: "Preview", slot: .topLeft), (name: "Notes", slot: .bottomLeft),
            (name: "Mail", slot: .topRight),
        ]
        XCTAssertEqual(
            TilingSpace.rehouseNotice(homes: homes),
            "Preview and 2 other windows moved to the other side to make room."
                + MenuText.undoRecoveryHint)
    }

    // MARK: The canvas

    private var harness: TilingSpaceHarness!
    private var space: TilingSpace { harness.space }

    override func setUp() {
        super.setUp()
        harness = TilingSpaceHarness()
    }

    func testLeftHalfRequestMirrorsBothRightQuadsToTheLeft() {
        // The user's case, on the canvas: window 1 held the left half, so
        // windows 2 and 3 moved to the two left quads and window 1 took
        // the right half. Everyone stays tiled.
        let a = harness.addWindow()
        harness.apply(slot: .leftHalf, requester: a)
        let b = harness.addWindow()
        harness.apply(slot: .topRight, requester: b)
        let c = harness.addWindow(frame: CGRect(x: 40, y: 50, width: 500, height: 400))
        harness.apply(slot: .bottomRight, requester: c)
        let bPreTile = space.records[b]!.preTileFrame
        let cPreTile = space.records[c]!.preTileFrame

        harness.apply(slot: .rightHalf, requester: a)

        XCTAssertNil(space.error)
        XCTAssertEqual(space.state.slot(of: a), .rightHalf)
        XCTAssertEqual(space.state.slot(of: b), .topLeft)
        XCTAssertEqual(space.state.slot(of: c), .bottomLeft)
        XCTAssertEqual(
            harness.frame(of: b), CGRect(x: 0, y: 600, width: 800, height: 600),
            "the top-right quad's window now holds the top-left quad")
        XCTAssertEqual(
            harness.frame(of: c), CGRect(x: 0, y: 0, width: 800, height: 600),
            "the bottom-right quad's window now holds the bottom-left quad")
        XCTAssertEqual(
            space.records[b]!.preTileFrame, bPreTile,
            "a re-housed window keeps the frame it will untile to")
        XCTAssertEqual(space.records[c]!.preTileFrame, cPreTile)
        XCTAssertEqual(
            space.notice,
            "TestApp moved to Top Left and TestApp moved to Bottom Left to make room."
                + MenuText.undoRecoveryHint)
    }

    func testFreshRequesterMirrorsBothQuadsIntoEmptySlots() {
        // A window that was not tiled gets the same mirror: the quads land
        // on the left even though the requester never held that side.
        let b = harness.addWindow()
        harness.apply(slot: .topRight, requester: b)
        let c = harness.addWindow()
        harness.apply(slot: .bottomRight, requester: c)
        let fresh = harness.addWindow()

        harness.apply(slot: .rightHalf, requester: fresh)

        XCTAssertEqual(space.state.slot(of: fresh), .rightHalf)
        XCTAssertEqual(space.state.slot(of: b), .topLeft)
        XCTAssertEqual(space.state.slot(of: c), .bottomLeft)
    }

    func testSixthCornerPairMirrorsOntoTheLeftThird() {
        // One layout over: the left two-thirds moves right, so the two
        // right corner sixths take the top-left and bottom-left sixths.
        let a = harness.addWindow()
        harness.apply(slot: .sixthsLeftTwoThirds, requester: a)
        let b = harness.addWindow()
        harness.apply(slot: .sixthTopRight, requester: b)
        let c = harness.addWindow()
        harness.apply(slot: .sixthBottomRight, requester: c)

        harness.apply(slot: .sixthsRightTwoThirds, requester: a)

        XCTAssertNil(space.error)
        XCTAssertEqual(space.state.slot(of: a), .sixthsRightTwoThirds)
        XCTAssertEqual(space.state.slot(of: b), .sixthTopLeft)
        XCTAssertEqual(space.state.slot(of: c), .sixthBottomLeft)
        // Worked values from the injected 1600×1200 bounds: each sixth is
        // a third of the screen wide (533⅓pt) and half of it tall.
        let topLeft = harness.frame(of: b)!
        XCTAssertEqual(topLeft.origin, CGPoint(x: 0, y: 600))
        XCTAssertEqual(topLeft.width, 1600.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(topLeft.height, 600)
        let bottomLeft = harness.frame(of: c)!
        XCTAssertEqual(bottomLeft.origin, CGPoint(x: 0, y: 0))
        XCTAssertEqual(bottomLeft.width, 1600.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(bottomLeft.height, 600)
    }

    func testOneUndoPutsTheWholeMirroredGroupBack() {
        // The event is one displacement chapter: both blockers return to
        // the slots they were evicted from, and the requester to the slot
        // it vacated.
        let a = harness.addWindow()
        harness.apply(slot: .leftHalf, requester: a)
        let b = harness.addWindow()
        harness.apply(slot: .topRight, requester: b)
        let c = harness.addWindow()
        harness.apply(slot: .bottomRight, requester: c)

        harness.apply(slot: .rightHalf, requester: a)

        XCTAssertEqual(space.undoStack.count, 1)
        XCTAssertEqual(
            space.undoStack.last?.snapshot.map(\.slot), [.topRight, .bottomRight, .leftHalf])
        XCTAssertEqual(space.undoStack.last?.requester, a)
    }

    func testAHomeHeldByAWindowThatStaysEvictsTheGroup() {
        // All or nothing: window 4 holds the top-left sixth, so the
        // top-right sixth has no home and both corner sixths untangle
        // instead of one moving and one going home.
        let a = harness.addWindow()
        harness.apply(slot: .sixthMiddle, requester: a)
        let b = harness.addWindow()
        harness.apply(slot: .sixthTopRight, requester: b)
        let c = harness.addWindow()
        harness.apply(slot: .sixthBottomRight, requester: c)
        let d = harness.addWindow()
        harness.apply(slot: .sixthTopLeft, requester: d)
        let bPreTile = space.records[b]!.preTileFrame
        let cPreTile = space.records[c]!.preTileFrame

        harness.apply(slot: .sixthRight, requester: a)

        XCTAssertEqual(space.state.slot(of: a), .sixthRight)
        XCTAssertNil(space.state.slot(of: b))
        XCTAssertNil(space.state.slot(of: c))
        XCTAssertEqual(
            space.state.slot(of: d), .sixthTopLeft, "the window that stayed did not move")
        XCTAssertEqual(harness.frame(of: b), bPreTile, "an evicted window goes back to its frame")
        XCTAssertEqual(harness.frame(of: c), cPreTile)
    }

    func testExpandedBlockerForcesTheGroupToUntangle() {
        // An expanded window never re-houses, so its group takes the
        // eviction path and nobody stays tiled.
        let a = harness.addWindow()
        harness.apply(slot: .leftHalf, requester: a)
        let b = harness.addWindow()
        harness.apply(slot: .topRight, requester: b)
        let c = harness.addWindow()
        harness.apply(slot: .bottomRight, requester: c)
        harness.space.expandToggle(window: b, context: harness.context())

        harness.apply(slot: .rightHalf, requester: a)

        XCTAssertEqual(space.state.slot(of: a), .rightHalf)
        XCTAssertNil(space.state.slot(of: b))
        XCTAssertNil(space.state.slot(of: c))
    }

    func testARefusedHomeRestoresThatWindowAndKeepsTheOtherTiled() {
        // The group writes each home in turn: a refusal untangles that one
        // window (its own restore lands, so the action is not an error) and
        // its neighbour keeps the home it reached, then reflow grows it
        // into the quad the refusal freed.
        let a = harness.addWindow()
        harness.apply(slot: .leftHalf, requester: a)
        let b = harness.addWindow()
        harness.apply(slot: .topRight, requester: b)
        let c = harness.addWindow()
        harness.apply(slot: .bottomRight, requester: c)
        let cPreTile = space.records[c]!.preTileFrame
        harness.gateway.refuseNextWrites(harness.handle(of: c)!, count: 1)

        harness.apply(slot: .rightHalf, requester: a)

        XCTAssertEqual(
            space.state.slot(of: b), .leftHalf,
            "the home landed, then reflow grew it into the freed bottom-left quad")
        XCTAssertNil(space.state.slot(of: c), "the refused window untangled")
        XCTAssertEqual(harness.frame(of: c), cPreTile)
        XCTAssertNil(
            space.error, "the restore itself succeeded, exactly as a lone re-house's does")
    }

    func testADeferredHomeStandsWithoutAWrite() {
        // A canvas on a Space the user cannot see is never written blind:
        // the group's homes stand in state and reconcile on the swipe
        // back, exactly as a lone re-house does.
        let a = harness.addWindow()
        harness.apply(slot: .leftHalf, requester: a)
        let b = harness.addWindow()
        harness.apply(slot: .topRight, requester: b)
        let c = harness.addWindow()
        harness.apply(slot: .bottomRight, requester: c)
        let bFrame = harness.frame(of: b)
        harness.clearExpectedWrites()
        harness.canvasVisible = false

        let outcome = harness.apply(slot: .rightHalf, requester: a)

        XCTAssertEqual(outcome.result, .deferred)
        XCTAssertNil(space.error, "a deferral is not an app refusal")
        XCTAssertEqual(space.state.slot(of: b), .topLeft)
        XCTAssertEqual(space.state.slot(of: c), .bottomLeft)
        XCTAssertEqual(harness.frame(of: b), bFrame, "a hidden canvas is never written blind")
        XCTAssertTrue(harness.expectedWrites.isEmpty, "a deferred home arms no phantom expectation")
    }

    func testAHomeLandsOnTheDraggedSplitter() {
        // The mirror writes slot rects from the canvas's current grid, so
        // a dragged vertical splitter moves the homes with it: at 0.6 the
        // left side is 960pt wide.
        let a = harness.addWindow()
        harness.apply(slot: .leftHalf, requester: a)
        let b = harness.addWindow()
        harness.apply(slot: .topRight, requester: b)
        let c = harness.addWindow()
        harness.apply(slot: .bottomRight, requester: c)
        harness.space.grid.columnSplit = 0.6

        harness.apply(slot: .rightHalf, requester: a)

        XCTAssertEqual(harness.frame(of: b), CGRect(x: 0, y: 600, width: 960, height: 600))
        XCTAssertEqual(harness.frame(of: c), CGRect(x: 0, y: 0, width: 960, height: 600))
        XCTAssertEqual(harness.frame(of: a), CGRect(x: 960, y: 0, width: 640, height: 1200))
    }

    func testARefusedRequesterRestoresTheWholeGroup() {
        // The requester's own write is refused: every window in the way
        // goes back to its pre-tile frame, nothing claims to have moved,
        // and the error names the refusal rather than swallowing it.
        let a = harness.addWindow()
        harness.apply(slot: .leftHalf, requester: a)
        let b = harness.addWindow()
        harness.apply(slot: .topRight, requester: b)
        let c = harness.addWindow()
        harness.apply(slot: .bottomRight, requester: c)
        let bPreTile = space.records[b]!.preTileFrame
        let cPreTile = space.records[c]!.preTileFrame
        harness.gateway.refuseNextWrites(harness.handle(of: a)!, count: 1)

        harness.apply(slot: .rightHalf, requester: a)

        XCTAssertNil(space.state.slot(of: b), "the requester's refusal restores the group")
        XCTAssertNil(space.state.slot(of: c))
        XCTAssertEqual(harness.frame(of: b), bPreTile)
        XCTAssertEqual(harness.frame(of: c), cPreTile)
        XCTAssertNotNil(space.error, "the requester's refusal is reported")
        XCTAssertFalse(
            space.notice?.contains("to make room") ?? true,
            "no window moved, so the notice must not claim one did")
        XCTAssertNotNil(space.undoStack.last, "the eviction is still undoable")
    }

    func testARefusedRestoreKeepsTheWentBackNoticeOffTheBoard() {
        // Both homes are refused and only the second window's restore
        // lands: the board is half torn down, so the notice must not claim
        // every window went back to where it was.
        let a = harness.addWindow()
        harness.apply(slot: .leftHalf, requester: a)
        let b = harness.addWindow()
        harness.apply(slot: .topRight, requester: b)
        let c = harness.addWindow()
        harness.apply(slot: .bottomRight, requester: c)
        harness.gateway.refuseNextWrites(harness.handle(of: b)!, count: 2)
        harness.gateway.refuseNextWrites(harness.handle(of: c)!, count: 1)

        harness.apply(slot: .rightHalf, requester: a)

        XCTAssertFalse(
            space.notice?.contains("went back") ?? false,
            "one refused restore keeps the notice from claiming both went back")
        XCTAssertNotNil(space.error, "the refused restore is reported")
    }
}
