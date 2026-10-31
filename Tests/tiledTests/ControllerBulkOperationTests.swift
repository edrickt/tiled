import AppKit
import XCTest
@testable import tiled

/// Controller-level bulk operations and bookkeeping: untile / untileAll /
/// resetDividers / undoLastDisplacement driven through `TilingController` with
/// the fake gateway. Pins the side effects the pure-state tests can't see:
/// restored frames, the one-step undo lifecycle, feedback callbacks, and
/// notice clearing.
final class ControllerBulkOperationTests: XCTestCase {
    /// Deterministic display: written rects are checked against this
    /// rect, never the host Mac's screen.
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Display 1")

    private var harness: ControllerHarness!
    private var gateway: FakeWindowGateway { harness.gateway }
    private var controller: TilingController { harness.controller }
    private var changeCount = 0
    /// Block-based observers returned by addObserver(forName:) must be
    /// removed explicitly or they leak for the process lifetime.
    private var observers: [NSObjectProtocol] = []

    /// The canvas the test's single display tiles onto: reads go through
    /// the same accessor actions do.
    private var canvas: TilingSpace { harness.canvas }

    override func setUp() {
        super.setUp()
        harness = ControllerHarness(screens: [Self.screen], deathConfirmation: 0)
        controller.onChange = { [weak self] in self?.changeCount += 1 }
    }

    override func tearDown() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers = []
        super.tearDown()
    }

    /// The rect the controller would write for `slot` right now: the live
    /// grid evaluated in the injected screen's visible frame.
    private func expectedRect(_ slot: Slot, for handle: WindowHandle) -> CGRect {
        controller.canvas(for: Self.screen.id).grid.rect(
            for: slot, in: Self.screen.visibleFrame)
    }

    // MARK: Untile restores frames

    func testUntileRestoresSizedFrame() {
        let handle = harness.addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        controller.handle(slot: .topLeft)
        XCTAssertEqual(canvas.state.tiledWindows.count, 1)

        controller.untile(window: 1)

        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertEqual(
            gateway.frame(of: handle), CGRect(x: 12, y: 0, width: 800, height: 500),
            "untile writes the quarter footprint hung from the pre-tile top edge")
    }

    func testUntileUnknownWindowIsSafe() {
        controller.untile(window: 99)
        XCTAssertTrue(canvas.state.occupants.isEmpty)
    }

    func testUntileAllRestoresEveryWindow() {
        let a = harness.addFocusedWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 500, y: 100, width: 700, height: 500))
        gateway.focused = b
        controller.handle(slot: .topRight)
        XCTAssertEqual(canvas.state.tiledWindows.count, 2)

        controller.untileAll()

        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertEqual(
            gateway.frame(of: a), CGRect(x: 0, y: 0, width: 800, height: 500))
        XCTAssertEqual(
            gateway.frame(of: b), CGRect(x: 500, y: 100, width: 800, height: 500),
            "untile-all leaves every window at the quarter footprint")
    }

    // MARK: Layout-switch undo lifecycle

    func testUndoLayoutSwitchReturnsEvictedWindowsAndTheLayout() {
        let a = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)

        // Explicit switch: both quarters windows are untiled into one
        // chapter, then b is re-tiled into a sixths slot.
        gateway.focused = b
        controller.handleSwitchLayout(to: .sixths)
        XCTAssertEqual(canvas.undoStack.count, 1)
        XCTAssertEqual(canvas.displacedCount, 2)
        XCTAssertNotNil(canvas.notice)
        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertEqual(gateway.frame(of: a)?.origin, CGPoint(x: 0, y: 100))
        XCTAssertEqual(gateway.frame(of: a)?.height, 500)
        XCTAssertEqual(
            gateway.frame(of: a)!.width, 800,
            "the switch always floats at the quarter footprint")
        controller.handle(slotKey: .leftColumn)
        XCTAssertNotNil(canvas.state.occupant(of: .sixthLeft))

        controller.undoLastDisplacement()

        // The chapter's layout returns and both windows re-tile into it;
        // the sixths placement is untiled on the way.
        XCTAssertEqual(canvas.state.layout, .quarters)
        XCTAssertEqual(canvas.state.tiledWindows.count, 2)
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft))
        XCTAssertNotNil(canvas.state.occupant(of: .topRight))
        XCTAssertEqual(
            gateway.frame(of: a), expectedRect(.topLeft, for: a),
            "undo re-tiles the evicted window into its old slot")
        XCTAssertEqual(
            gateway.frame(of: b), expectedRect(.topRight, for: b),
            "undo re-tiles the requester into the slot it left")
        XCTAssertTrue(canvas.undoStack.isEmpty)
        XCTAssertEqual(canvas.displacedCount, 0)
    }

    func testUndoIsSingleStep() {
        harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)

        // Switch (one chapter covering both windows), then re-tile b.
        controller.handleSwitchLayout(to: .sixths)
        controller.handle(slotKey: .leftColumn)
        XCTAssertFalse(canvas.undoStack.isEmpty)

        controller.undoLastDisplacement()
        XCTAssertTrue(canvas.undoStack.isEmpty)
        XCTAssertEqual(canvas.state.tiledWindows.count, 2)

        controller.undoLastDisplacement()
        XCTAssertEqual(canvas.state.tiledWindows.count, 2, "second undo is a no-op")
    }

    func testNewSwitchPushesHistoryInsteadOfReplacingIt() {
        harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)

        // Switch #1: both quarters windows are untiled into one chapter.
        controller.handleSwitchLayout(to: .sixths)
        XCTAssertEqual(canvas.undoStack.count, 1)
        XCTAssertEqual(canvas.displacedCount, 2)

        // b re-tiles in sixths; then switch #2 back to quarters untiles it
        // into its own chapter. The old undo is NOT gone; history stacks,
        // newest last.
        controller.handle(slotKey: .leftColumn)
        // c is tiled into Quarters bottomRight after switch #2; undo #2
        // restores Sixths and untiles it.
        let c = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        gateway.focused = c
        controller.handleSwitchLayout(to: .quarters)
        XCTAssertEqual(canvas.undoStack.count, 2)
        XCTAssertEqual(canvas.displacedCount, 1)
        XCTAssertEqual(
            canvas.notice,
            "Switched to Quarters · 1 window untiled. Undo from the Tiled menu.")
        controller.handle(slotKey: .bottomRight)

        controller.undoLastDisplacement()
        XCTAssertEqual(canvas.state.layout, .sixths)
        XCTAssertNotNil(canvas.state.occupant(of: .sixthLeft),
            "undo #2 returns b to its slot")
        XCTAssertNil(canvas.state.slot(of: 3), "the later window is untiled by undo")
        XCTAssertEqual(canvas.state.tiledWindows.count, 1)

        // Walking back again returns the quarters pair: depth, not amnesia.
        controller.undoLastDisplacement()
        XCTAssertEqual(canvas.state.layout, .quarters)
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft))
        XCTAssertNotNil(canvas.state.occupant(of: .topRight))
        XCTAssertTrue(canvas.undoStack.isEmpty, "history exhausted")
    }

    func testUndoHistoryIsBoundedByDepthNotAmnesia() {
        // Seven explicit switches after the first placement; depth 5 drops
        // the oldest two, so exactly five chapters survive. Walking back
        // five times consumes all of them; the sixth undo answers instead
        // of reaching further, and a stack that kept a sixth chapter would
        // answer it instead of a no-op receipt.
        for i in 0..<7 {
            let handle = gateway.addWindow(
                frame: CGRect(x: i * 10, y: i * 10, width: 500, height: 400))
            gateway.focused = handle
            controller.handleSwitchLayout(to: i.isMultiple(of: 2) ? .quarters : .sixths)
            controller.handle(slotKey: .topLeft)
        }
        XCTAssertFalse(canvas.undoStack.isEmpty)
        // The two oldest chapters are gone, so each of these five undos
        // must consume a real chapter. Asserting only the end state (stack
        // empty) also passed with a depth-2 stack, where three of these
        // five calls were silent no-ops.
        for index in 1...5 {
            let receipt = controller.undoAction()
            XCTAssertTrue(
                receipt.performed,
                "undo #\(index) answered a no-op: the depth-5 history lost a chapter")
        }
        XCTAssertFalse(
            !canvas.undoStack.isEmpty,
            "five undos exhaust the depth-5 history")
        let sixth = controller.undoAction()
        XCTAssertFalse(sixth.performed, "the sixth undo answers, not silence")
        XCTAssertEqual(sixth.announcement, "Nothing to undo: a later change replaced it.")
    }

    func testEmptyUndoStackAnswersInsteadOfSilence() {
        harness.addFocusedWindow()
        XCTAssertTrue(canvas.undoStack.isEmpty)
        let receipt = controller.undoAction()
        XCTAssertFalse(receipt.performed, "an empty undo still answers")
        XCTAssertEqual(receipt.announcement, "Nothing to undo: a later change replaced it.")
    }

    func testSwitchWithNoWindowsOffersNoUndo() {
        let receipt = controller.handleSwitchLayout()

        XCTAssertEqual(canvas.state.layout, .sixths)
        XCTAssertEqual(canvas.notice, "Switched to Sixths.")
        XCTAssertEqual(receipt.announcement, "Switched to Sixths.")
        XCTAssertTrue(canvas.undoStack.isEmpty)
        XCTAssertEqual(canvas.displacedCount, 0)
    }

    func testUndoAfterRequesterDied() {
        harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)
        controller.handleSwitchLayout(to: .sixths)
        controller.handle(slotKey: .leftColumn)

        // The user closes the switched window before undoing.
        gateway.kill(b)
        controller.undoLastDisplacement()

        XCTAssertEqual(canvas.state.layout, .quarters, "the chapter's layout returns")
        XCTAssertEqual(canvas.state.tiledWindows.count, 1)
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft),
            "the live chapter member returns to its slot")
        XCTAssertNil(canvas.state.slot(of: 2))
        XCTAssertNil(canvas.state.occupant(of: .sixthLeft))
        XCTAssertEqual(
            canvas.notice,
            "Undid displacement · back to Quarters · 1 window restored.")
    }

    func testUndoAfterEvicteeDied() {
        let a = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)
        controller.handleSwitchLayout(to: .sixths)
        controller.handle(slotKey: .leftColumn)

        gateway.kill(a)
        controller.undoLastDisplacement()

        XCTAssertNil(canvas.error, "a layout restore with one dead member is still performed")
        XCTAssertEqual(canvas.state.layout, .quarters)
        XCTAssertEqual(canvas.state.tiledWindows.count, 1)
        XCTAssertNotNil(canvas.state.occupant(of: .topRight),
            "the live chapter member returns; the dead one is skipped")
        XCTAssertTrue(canvas.undoStack.isEmpty)
    }

    func testSizedTopEdgeSurvivesLayoutSwitches() {
        let handle = harness.addFocusedWindow(frame: CGRect(x: 21, y: 43, width: 510, height: 320))
        controller.handleSwitchLayout(to: .quarters)
        controller.handle(slotKey: .topLeft)

        // Each explicit switch leaves the sized footprint hung from the
        // pre-tile top edge, and the next placement records that frame as
        // the new pre-tile: untiling still returns the window to its
        // original top edge, never a tile rect from another layout.
        controller.handleSwitchLayout(to: .sixths)
        controller.handle(slotKey: .leftColumn)
        controller.handleSwitchLayout(to: .quarters)
        controller.handle(slotKey: .rightColumn)
        let id = controller.registeredID(for: handle)!
        XCTAssertEqual(canvas.state.slot(of: id), .rightHalf)

        controller.untile(window: id)
        XCTAssertEqual(
            gateway.frame(of: handle), CGRect(x: 21, y: 0, width: 800, height: 500),
            "untile keeps the original top edge at the layout's footprint")
    }

    func testUntileAllStartsItsOwnUndoChapter() {
        let a = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)

        // Untile-all starts its own undo chapter: the bulk dissolve is
        // itself undoable (the notice + ⌃⌥⇧⌘Z carry it). Both windows are
        // tiled, so the chapter covers both.
        controller.untileAll()
        XCTAssertFalse(canvas.undoStack.isEmpty, "untile-all is itself undoable")
        XCTAssertEqual(canvas.displacedCount, 2)
        XCTAssertEqual(canvas.notice, "Untiled 2 windows. Undo from the Tiled menu.")
        controller.undoLastDisplacement()
        // Undo re-tiles each dissolved window into its slot (under fresh
        // ids, since untile-all cleared the records, so the canvas
        // reissues them, exactly as it does for pruned undo handles). The
        // arrangement returns, and the chapter is consumed.
        XCTAssertNotNil(
            canvas.state.occupant(of: .topLeft),
            "undo re-tiles the dissolved window into its slot")
        XCTAssertNotNil(
            canvas.state.occupant(of: .topRight),
            "both dissolved windows return under fresh ids")
        XCTAssertTrue(canvas.undoStack.isEmpty, "the chapter is consumed")
    }

    // MARK: Slot receipts

    func testSlotNoFocusedWindowReturnsAReceipt() {
        gateway.focused = nil

        let receipt = controller.handle(slot: .topLeft)

        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(
            receipt.announcement, "No focused window: click a window first.")
    }

    func testSlotAlreadyTiledReturnsAReceiptThatNamesTheSlot() {
        harness.addFocusedWindow()
        controller.handle(slot: .topLeft)

        let receipt = controller.handle(slot: .topLeft)

        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(receipt.announcement, "Top Left: already there.")
    }

    func testSlotRefusedReturnsAReceiptThatNamesTheWindow() {
        let handle = harness.addFocusedWindow()
        gateway.refuseNextWrites(handle)

        let receipt = controller.handle(slot: .topLeft)

        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(
            receipt.announcement,
            "TestApp couldn't be tiled: the app refused to resize it.")
    }

    func testUntileWithRefusedRestoreReportsTheWindow() {
        let handle = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        gateway.refuseNextWrites(handle)

        controller.untile(window: 1)

        XCTAssertEqual(
            canvas.error,
            "Couldn't restore \u{201C}TestApp\u{201D}: it may still be sitting in its old tile.")
        XCTAssertNil(canvas.state.slot(of: 1),
            "slot released even though the frame restore was refused")
    }

    func testUntileAllWithRefusedRestoresReportsPlural() {
        harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)
        gateway.refuseNextWrites(gateway.issued[0])
        gateway.refuseNextWrites(gateway.issued[1])

        controller.untileAll()

        XCTAssertEqual(
            canvas.error,
            "Couldn't restore 2 windows: they may still be sitting in their old tiles.")
        XCTAssertTrue(canvas.state.occupants.isEmpty)
    }

    func testNoopHotkeyPreservesNotices() {
        harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)
        controller.handleSwitchLayout(to: .sixths)
        controller.handle(slotKey: .leftColumn)
        // A splitter restore is a live receipt: it leaves a notice behind.
        controller.resetOrRestoreSplitters()
        XCTAssertTrue(controller.resetOrRestoreSplitters().performed)
        XCTAssertNotNil(canvas.notice)

        // Strict no-op: no state, error, or menu side effects; the receipt
        // answers once, but the notice survives untouched.
        let receipt = controller.handle(slotKey: .leftColumn)

        XCTAssertNotNil(canvas.notice, "no-op must not clear the notice")
        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(receipt.announcement, "Left Third: already there.")
    }

    func testFocusBringsWindowForwardAndIgnoresUnknownIDs() {
        harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)
        gateway.focused = nil

        controller.focus(window: 2)
        XCTAssertEqual(gateway.focused, b)

        controller.focus(window: 99)
        XCTAssertEqual(gateway.focused, b, "unknown id changes nothing")
    }

    func testSilentlyIgnoringAppTilesStatefully() {
        let handle = harness.addFocusedWindow()
        let original = gateway.frame(of: handle)!
        gateway.silentIgnore.insert(handle)

        controller.handle(slot: .topLeft)

        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft,
            "the gateway reported success, so occupancy commits")
        XCTAssertNil(canvas.error, "no refusal: the write 'succeeded'")
        XCTAssertEqual(gateway.frame(of: handle), original,
            "the app ignored the resize; screen and state disagree until the next assertion")
    }

    func testTiledWindowsInfoIsSortedBySlot() {
        // Tile in reverse slot order; presentation must sort by rawValue.
        harness.addFocusedWindow()
        controller.handle(slot: .topRight)
        let b = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        gateway.focused = b
        controller.handle(slot: .topLeft)

        XCTAssertEqual(
            controller.tiledWindowsInfo.map(\.slot),
            [.topLeft, .topRight])
    }

    // MARK: Reset dividers

    func testResetDividersRestoresDefaultsAndRetiles() {
        let a = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        // Drag TL's right edge (echo tick, then escape) to move columnSplit.
        var echo = gateway.frame(of: a)!
        echo.size.width -= 10
        gateway.simulateChange(a, to: echo)
        var dragged = gateway.frame(of: a)!
        dragged.size.width -= 60
        gateway.simulateChange(a, to: dragged)
        XCTAssertNotEqual(canvas.grid.columnSplit, 0.5, "drag moved the splitter")

        controller.resetOrRestoreSplitters()

        XCTAssertEqual(canvas.grid, GridLayout())
        XCTAssertEqual(
            gateway.frame(of: a), expectedRect(.topLeft, for: a),
            "reset re-tiles occupants at the default grid")
        XCTAssertNil(canvas.error)
        // One destructive action, one receipt: the reset parks the
        // displaced fractions for a one-step restore.
        XCTAssertTrue(canvas.hasSplitterBackup, "reset keeps receipts")
        XCTAssertTrue(
            controller.resetOrRestoreSplitters().performed, "the backup restores")
        XCTAssertNotEqual(
            canvas.grid.columnSplit, 0.5, accuracy: 0.001,
            "restore returns the dragged splitter")
        XCTAssertFalse(
            canvas.hasSplitterBackup, "restoring consumes the backup")
        XCTAssertTrue(
            controller.resetOrRestoreSplitters().performed,
            "with no backup the same press resets again")
        XCTAssertTrue(canvas.hasSplitterBackup, "that reset parked a new backup")
    }

    func testResetOrRestoreSplittersReturnsOneReceiptAndKeepsTheBackup() {
        let a = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        var echo = gateway.frame(of: a)!
        echo.size.width -= 10
        gateway.simulateChange(a, to: echo)
        var dragged = gateway.frame(of: a)!
        dragged.size.width -= 60
        gateway.simulateChange(a, to: dragged)
        let draggedGrid = canvas.grid

        let reset = controller.resetOrRestoreSplitters()

        XCTAssertTrue(reset.performed)
        XCTAssertEqual(reset.announcement, "Splitters reset to even splits.")
        XCTAssertTrue(canvas.hasSplitterBackup)

        let restore = controller.resetOrRestoreSplitters()

        XCTAssertTrue(restore.performed)
        XCTAssertEqual(
            restore.announcement, "Splitters restored to their pre-reset positions.")
        XCTAssertEqual(canvas.grid, draggedGrid)
        XCTAssertFalse(canvas.hasSplitterBackup, "the restore consumes the backup")
    }

    func testResetOrRestoreSplittersReportsARefusalAsNotPerformed() {
        let a = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        var echo = gateway.frame(of: a)!
        echo.size.width -= 10
        gateway.simulateChange(a, to: echo)
        var dragged = gateway.frame(of: a)!
        dragged.size.width -= 60
        gateway.simulateChange(a, to: dragged)
        gateway.refuseNextWrites(a)

        let receipt = controller.resetOrRestoreSplitters()

        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(
            receipt.announcement,
            "Couldn't move that window: the app refused to resize it.")
    }

    func testResetDividersReportsRefusals() {
        let a = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 700, height: 500))
        gateway.focused = b
        controller.handle(slot: .topRight)
        // Move the splitter so reset has real writes to perform.
        var echo = gateway.frame(of: a)!
        echo.size.width -= 10
        gateway.simulateChange(a, to: echo)
        var dragged = gateway.frame(of: a)!
        dragged.size.width -= 60
        gateway.simulateChange(a, to: dragged)
        XCTAssertNotEqual(canvas.grid.columnSplit, 0.5)

        gateway.refuseNextWrites(a)
        controller.resetOrRestoreSplitters()

        XCTAssertEqual(
            canvas.error,
            "Couldn't move that window: the app refused to resize it.",
            "the re-assertion refusal surfaces, never silence")
    }

    func testResetDividersReportsRefusalsInPlural() {
        let a = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 700, height: 500))
        gateway.focused = b
        controller.handle(slot: .topRight)
        // Move the splitter so reset has real writes to perform.
        var echo = gateway.frame(of: a)!
        echo.size.width -= 10
        gateway.simulateChange(a, to: echo)
        var dragged = gateway.frame(of: a)!
        dragged.size.width -= 60
        gateway.simulateChange(a, to: dragged)
        XCTAssertNotEqual(canvas.grid.columnSplit, 0.5)

        // Two apps refuse at once: the refusal names the count instead of
        // reusing the singular sentence. Both windows must actually be
        // written — a window already on its tile rect is skipped as a
        // no-op — so park them far from any tile first.
        let farAway = CGRect(x: -9_999, y: -9_999, width: 1, height: 1)
        gateway.simulateSilentChange(a, to: farAway)
        gateway.simulateSilentChange(b, to: farAway)
        gateway.refuseNextWrites(a)
        gateway.refuseNextWrites(b)
        controller.resetOrRestoreSplitters()

        XCTAssertEqual(
            canvas.error,
            "Couldn't move 2 windows: an app refused to resize.")
    }

    // MARK: Ghost cleanup & screen changes

    func testPruneDropsDeadWindows() {
        let handle = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        XCTAssertEqual(canvas.state.tiledWindows.count, 1)

        gateway.kill(handle)
        controller.pruneDeadWindows()

        XCTAssertTrue(canvas.state.occupants.isEmpty)
    }

    // MARK: Destroyed notifications

    func testDestroyedNotificationReleasesTheSlotAtOnce() {
        // The reported latency bug: a window closed by its app (Firefox
        // merging a dragged tab out of it) left the tile occupied until
        // the 5s prune tick plus the 3s death confirmation completed.
        // The OS's AXUIElementDestroyed notification is the window's own
        // report: run the death check now, and when it agrees, release
        // without waiting for either.
        let a = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 700, height: 500))
        gateway.focused = b
        controller.handle(slot: .topRight)
        XCTAssertEqual(canvas.state.tiledWindows.count, 2)
        changeCount = 0

        gateway.kill(a)
        gateway.simulateDestroyed(a)

        XCTAssertEqual(canvas.state.tiledWindows.count, 1, "the dead window released its slot")
        XCTAssertGreaterThan(changeCount, 0, "the release announced itself for a menu/icon refresh")
    }

    func testDestroyedNotificationForALiveElementKeepsTheSlot() {
        // Element churn: an app can destroy and recreate its window
        // elements while the window lives (display changes are the
        // known live case). The notification only accelerates the check;
        // a live verdict must not untile anything.
        let handle = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)

        gateway.simulateDestroyed(handle)

        XCTAssertEqual(canvas.state.tiledWindows.count, 1)
    }

    func testDestroyedNotificationWithUnknownLivenessKeepsTheSlot() {
        // The lid-cycle transient: probes fail for live windows
        // mid-teardown and the death standard answers unknown. A
        // destroyed report must not force a prune the standard still
        // calls a maybe.
        let handle = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        gateway.busy.insert(handle)

        gateway.simulateDestroyed(handle)

        XCTAssertEqual(canvas.state.tiledWindows.count, 1, "a maybe never untiles")
    }

    func testPruneTimerFiresAndReleasesSlots() {
        // The repeating timer, shrunk: the wiring (schedule → fire → prune
        // → onChange when the count changed) is what the nil-interval tests
        // bypass by driving pruneDeadWindows directly. The harness captures
        // the tick instead of the test waiting out a wall-clock interval.
        harness = ControllerHarness(
            screens: [Self.screen], pruneInterval: 0.05, deathConfirmation: 0)
        var changes = 0
        controller.onChange = { changes += 1 }
        let handle = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        XCTAssertEqual(canvas.state.tiledWindows.count, 1)

        gateway.kill(handle)
        XCTAssertEqual(
            harness.pruneFires.count, 1,
            "the controller scheduled one repeating prune tick")
        harness.pruneFires.last?()

        XCTAssertTrue(
            canvas.state.occupants.isEmpty,
            "the timer pruned the ghost")
        XCTAssertGreaterThan(changes, 1, "prune announced the change for a menu refresh")
    }

    func testScreenChangeReassertsLayout() {
        let a = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 700, height: 500))
        gateway.focused = b
        controller.handle(slot: .topRight)

        let reasserted = XCTestExpectation(description: "screen change reassert")
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            reasserted.fulfill()
        }
        observers.append(token)
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        wait(for: [reasserted], timeout: 1.0)

        XCTAssertEqual(
            gateway.frame(of: a), expectedRect(.topLeft, for: a),
            "windows stay on-grid after a display change")
        XCTAssertEqual(
            gateway.frame(of: b), expectedRect(.topRight, for: b))
    }
}
