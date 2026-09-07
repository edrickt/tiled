import AppKit
import XCTest
@testable import tiled

/// Controller-level bulk operations and bookkeeping: untile / untileAll /
/// resetDividers / undoLastDisplacement driven through `TilingController` with
/// the fake gateway. Pins the side effects the pure-state tests can't see:
/// restored frames, the one-step undo lifecycle, feedback callbacks, and
/// notice clearing.
final class ControllerBulkOperationTests: XCTestCase {
    private var gateway: FakeWindowGateway!
    private var controller: TilingController!
    private var feedbacks: [TilingController.Feedback] = []
    private var changeCount = 0
    /// Block-based observers returned by addObserver(forName:) must be
    /// removed explicitly or they leak for the process lifetime.
    private var observers: [NSObjectProtocol] = []

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        controller = TilingController(gateway: gateway, pruneInterval: nil)
        controller.onFeedback = { [weak self] in self?.feedbacks.append($0) }
        controller.onChange = { [weak self] in self?.changeCount += 1 }
    }

    override func tearDown() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers = []
        super.tearDown()
    }

    @discardableResult
    private func addFocusedWindow(
        frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
    ) -> WindowHandle {
        let handle = gateway.addWindow(frame: frame)
        gateway.focused = handle
        return handle
    }

    /// The rect the controller would write for `slot` right now: the live
    /// grid evaluated in the owning screen's visible frame (mirrors the
    /// controller's `visibleBounds` + tracker `rect(for:)`).
    private func expectedRect(_ slot: Slot, for handle: WindowHandle) -> CGRect {
        let frame = gateway.frame(of: handle)!
        let screens = NSScreen.screens
        let index = TilingController.owningScreenIndex(frames: screens.map(\.frame), for: frame) ?? 0
        return controller.grid.rect(for: slot, in: screens[index].visibleFrame)
    }

    // MARK: Untile restores frames

    func testUntileRestoresPreTileFrame() {
        let handle = addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        let original = gateway.frame(of: handle)!
        controller.handle(slot: .topLeft)
        XCTAssertEqual(controller.state.tiledWindows.count, 1)

        controller.untile(window: 1)

        XCTAssertTrue(controller.state.occupants.isEmpty)
        XCTAssertEqual(
            gateway.frame(of: handle), original,
            "untile writes the pre-tile frame back")
    }

    func testUntileUnknownWindowIsSafe() {
        controller.untile(window: 99)
        XCTAssertTrue(controller.state.occupants.isEmpty)
        XCTAssertTrue(feedbacks.isEmpty)
    }

    func testUntileAllRestoresEveryWindow() {
        let a = addFocusedWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let aOriginal = gateway.frame(of: a)!
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 500, y: 100, width: 700, height: 500))
        let bOriginal = gateway.frame(of: b)!
        gateway.focused = b
        controller.handle(slot: .topRight)
        XCTAssertEqual(controller.state.tiledWindows.count, 2)

        controller.untileAll()

        XCTAssertTrue(controller.state.occupants.isEmpty)
        XCTAssertEqual(gateway.frame(of: a), aOriginal)
        XCTAssertEqual(gateway.frame(of: b), bOriginal)
    }

    // MARK: Layout-switch undo lifecycle

    func testUndoLayoutSwitchReturnsEvictedAndUntilesRequester() {
        let a = addFocusedWindow()
        let aOriginal = gateway.frame(of: a)!
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        let bOriginal = gateway.frame(of: b)!
        gateway.focused = b
        controller.handle(slot: .topRight)

        // Cross-layout switch: a is evicted (restored to its pre-tile
        // frame), b lands in the sixths slot.
        gateway.focused = b
        controller.handle(slot: .sixthLeft)
        XCTAssertTrue(controller.canUndoDisplacement)
        XCTAssertEqual(controller.evictedCount, 1)
        XCTAssertNotNil(controller.lastNotice)
        XCTAssertEqual(controller.state.slot(of: 2), .sixthLeft)
        XCTAssertEqual(
            gateway.frame(of: a), aOriginal,
            "eviction restores the pre-tile frame immediately")

        controller.undoLastDisplacement()

        // The evicted window returns to its slot under a fresh id (its
        // record was pruned at switch); the requester is untiled with its
        // original frame back.
        XCTAssertEqual(controller.state.tiledWindows.count, 1)
        XCTAssertNotNil(controller.state.occupant(of: .topLeft))
        XCTAssertEqual(controller.state.slot(of: 2), nil)
        XCTAssertEqual(
            gateway.frame(of: a), expectedRect(.topLeft, for: a),
            "undo re-tiles the evicted window into its old slot")
        XCTAssertEqual(
            gateway.frame(of: b), bOriginal,
            "undo restores the requester's pre-tile frame")
        XCTAssertFalse(controller.canUndoDisplacement)
        XCTAssertEqual(controller.evictedCount, 0)
    }

    func testUndoIsSingleStep() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)

        // Requester b switches; a is evicted and offers undo.
        gateway.focused = b
        controller.handle(slot: .sixthLeft)
        XCTAssertTrue(controller.canUndoDisplacement)

        controller.undoLastDisplacement()
        XCTAssertFalse(controller.canUndoDisplacement)

        controller.undoLastDisplacement()
        XCTAssertEqual(controller.state.tiledWindows.count, 1, "second undo is a no-op")
    }

    func testNewSwitchPushesHistoryInsteadOfReplacingIt() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)

        // Cross-layout switch #1: a is evicted (undo names a).
        gateway.focused = b
        controller.handle(slot: .sixthLeft)
        XCTAssertTrue(controller.canUndoDisplacement)
        XCTAssertEqual(controller.evictedCount, 1)

        // Switch #2 back to quarters: b is evicted. The old undo is NOT
        // gone; history stacks, newest last.
        let c = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        gateway.focused = c
        controller.handle(slot: .bottomRight)
        XCTAssertTrue(controller.canUndoDisplacement, "the new switch offers its own undo")
        XCTAssertEqual(controller.evictedCount, 1)
        XCTAssertEqual(
            controller.lastNotice,
            "Switched to Quarters \u{00B7} 1 window untiled. "
                + "Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo.")

        controller.undoLastDisplacement()
        XCTAssertEqual(controller.state.slot(of: 3), nil, "requester c is untiled by undo")
        XCTAssertNotNil(
            controller.state.occupant(of: .sixthLeft),
            "undo #2 returns b (not a) to its slot")
        XCTAssertNil(controller.state.occupant(of: .topLeft))
        XCTAssertEqual(controller.state.tiledWindows.count, 1)

        // Walking back again returns a to its slot: depth, not amnesia.
        controller.undoLastDisplacement()
        XCTAssertNotNil(
            controller.state.occupant(of: .topLeft),
            "undo #1 returns a to its slot")
        XCTAssertFalse(controller.canUndoDisplacement, "history exhausted")
    }

    func testUndoHistoryIsBoundedByDepthNotAmnesia() {
        // Seven destructive switches; the stack keeps the freshest five
        // and drops the two oldest. Walking back five times consumes
        // everything; the sixth undo answers instead of reaching further.
        var handles: [WindowHandle] = []
        for i in 0..<7 {
            let handle = gateway.addWindow(
                frame: CGRect(x: i * 10, y: i * 10, width: 500, height: 400))
            handles.append(handle)
            gateway.focused = handle
            controller.handle(slot: i.isMultiple(of: 2) ? .topLeft : .sixthLeft)
        }
        XCTAssertTrue(controller.canUndoDisplacement)
        for _ in 0..<5 {
            controller.undoLastDisplacement()
        }
        XCTAssertFalse(
            controller.canUndoDisplacement,
            "five undos exhaust the depth-5 history")
        feedbacks.removeAll()
        controller.undoLastDisplacement()
        XCTAssertEqual(feedbacks.count, 1, "the sixth undo answers, not silence")
        guard case .nothingToUndo = feedbacks[0] else {
            return XCTFail("expected .nothingToUndo, got \(feedbacks[0])")
        }
    }

    func testEmptyUndoStackAnswersInsteadOfSilence() {
        addFocusedWindow()
        XCTAssertFalse(controller.canUndoDisplacement)
        feedbacks.removeAll()
        controller.undoLastDisplacement()
        XCTAssertEqual(feedbacks.count, 1, "an empty undo still answers")
        guard case .nothingToUndo = feedbacks[0] else {
            return XCTFail("expected .nothingToUndo, got \(feedbacks[0])")
        }
    }

    func testSwitchingAloneOffersNoUndo() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)

        // The requester moves; nobody is evicted, so there is nothing to
        // undo and nothing to announce.
        gateway.focused = a
        controller.handle(slot: .sixthLeft)

        XCTAssertEqual(controller.state.slot(of: 1), .sixthLeft)
        XCTAssertNil(controller.lastNotice)
        XCTAssertFalse(controller.canUndoDisplacement)
        XCTAssertEqual(controller.evictedCount, 0)
    }

    func testUndoAfterRequesterDied() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)
        gateway.focused = b
        controller.handle(slot: .sixthLeft)

        // The user closes the switched window before undoing.
        gateway.kill(b)
        controller.undoLastDisplacement()

        XCTAssertEqual(controller.state.tiledWindows.count, 1)
        XCTAssertNotNil(controller.state.occupant(of: .topLeft),
            "the evictee still returns to its slot")
        XCTAssertNil(controller.state.occupant(of: .sixthLeft))
        XCTAssertEqual(controller.lastNotice, "Undid displacement \u{00B7} 1 window restored.")
    }

    func testUndoAfterEvicteeDied() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)
        gateway.focused = b
        controller.handle(slot: .sixthLeft)

        gateway.kill(a)
        controller.undoLastDisplacement()

        XCTAssertEqual(
            controller.lastTileError, "Couldn't restore the evicted windows.")
        XCTAssertTrue(controller.state.occupants.isEmpty,
            "requester untiled by undo; dead evictee skipped")
        XCTAssertFalse(controller.canUndoDisplacement)
    }

    func testPreTileFrameSurvivesLayoutSwitches() {
        let handle = addFocusedWindow(frame: CGRect(x: 21, y: 43, width: 510, height: 320))
        let original = gateway.frame(of: handle)!
        controller.handle(slot: .topLeft)

        // The window itself switches layouts twice (it is always the
        // requester, never evicted): its record (and pre-tile frame)
        // must survive untouched, so untile returns it to where it started.
        gateway.focused = handle
        controller.handle(slot: .sixthLeft)
        gateway.focused = handle
        controller.handle(slot: .rightHalf)
        XCTAssertEqual(controller.state.slot(of: 1), .rightHalf)

        controller.untile(window: 1)
        XCTAssertEqual(
            gateway.frame(of: handle), original,
            "untile restores the original pre-tile frame, not a tile rect")
    }

    func testUntileAllStartsItsOwnUndoChapter() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)

        // Untile-all starts its own undo chapter: the bulk dissolve is
        // itself undoable (the notice + ⌃⌥⇧⌘Z carry it). Both windows are
        // tiled, so the chapter covers both.
        controller.untileAll()
        XCTAssertTrue(controller.canUndoDisplacement, "untile-all is itself undoable")
        XCTAssertEqual(controller.evictedCount, 2)
        XCTAssertEqual(controller.lastNotice, "Untiled 2 windows. Press ⌃⌥⇧⌘Z to undo.")
        controller.undoLastDisplacement()
        // Undo re-tiles each dissolved window into its slot (under fresh
        // ids, since untile-all cleared the records, so the executor reissues
        // them, exactly as it does for pruned undo handles). The
        // arrangement returns, and the chapter is consumed.
        XCTAssertNotNil(
            controller.state.occupant(of: .topLeft),
            "undo re-tiles the dissolved window into its slot")
        XCTAssertNotNil(
            controller.state.occupant(of: .topRight),
            "both dissolved windows return under fresh ids")
        XCTAssertFalse(controller.canUndoDisplacement, "the chapter is consumed")
    }

    // MARK: Feedback

    func testFeedbackNoFocusedWindow() {
        gateway.focused = nil
        controller.handle(slot: .topLeft)
        XCTAssertEqual(feedbacks.count, 1)
        guard case .noFocusedWindow = feedbacks[0] else {
            return XCTFail("expected .noFocusedWindow, got \(feedbacks[0])")
        }
    }

    func testFeedbackAlreadyTiled() {
        addFocusedWindow()
        controller.handle(slot: .topLeft)
        controller.handle(slot: .topLeft)
        XCTAssertEqual(feedbacks.count, 1)
        guard case .alreadyTiled(let slot) = feedbacks[0] else {
            return XCTFail("expected .alreadyTiled, got \(feedbacks[0])")
        }
        XCTAssertEqual(slot, .topLeft)
    }

    func testFeedbackRefused() {
        let handle = addFocusedWindow()
        gateway.refuseNextWrites(handle)
        controller.handle(slot: .topLeft)
        XCTAssertEqual(feedbacks.count, 1)
        guard case .refused(let name) = feedbacks[0] else {
            return XCTFail("expected .refused, got \(feedbacks[0])")
        }
        XCTAssertEqual(name, "TestApp")
    }

    func testUntileWithRefusedRestoreReportsTheWindow() {
        let handle = addFocusedWindow()
        controller.handle(slot: .topLeft)
        gateway.refuseNextWrites(handle)

        controller.untile(window: 1)

        XCTAssertEqual(
            controller.lastTileError,
            "Couldn't restore \u{201C}TestApp\u{201D}: it may still be sitting in its old tile.")
        XCTAssertNil(controller.state.slot(of: 1),
            "slot released even though the frame restore was refused")
    }

    func testUntileAllWithRefusedRestoresReportsPlural() {
        addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)
        gateway.refuseNextWrites(gateway.issued[0])
        gateway.refuseNextWrites(gateway.issued[1])

        controller.untileAll()

        XCTAssertEqual(
            controller.lastTileError,
            "Couldn't restore 2 windows: they may still be sitting in their old tiles.")
        XCTAssertTrue(controller.state.occupants.isEmpty)
    }

    func testNoopHotkeyPreservesNotices() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)
        gateway.focused = b
        controller.handle(slot: .sixthLeft)
        XCTAssertNotNil(controller.lastNotice)

        // Strict no-op: no state, error, or menu side effects; the
        // already-tiled feedback fires, but the notice survives untouched.
        gateway.focused = b
        controller.handle(slot: .sixthLeft)

        XCTAssertNotNil(controller.lastNotice, "no-op must not clear the notice")
        XCTAssertEqual(feedbacks.count, 1)
        guard case .alreadyTiled = feedbacks[0] else {
            return XCTFail("expected .alreadyTiled, got \(feedbacks[0])")
        }
    }

    func testFocusBringsWindowForwardAndIgnoresUnknownIDs() {
        addFocusedWindow()
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
        let handle = addFocusedWindow()
        let original = gateway.frame(of: handle)!
        gateway.silentIgnore.insert(handle)

        controller.handle(slot: .topLeft)

        XCTAssertEqual(controller.state.slot(of: 1), .topLeft,
            "the gateway reported success, so occupancy commits")
        XCTAssertNil(controller.lastTileError, "no refusal: the write 'succeeded'")
        XCTAssertTrue(feedbacks.isEmpty)
        XCTAssertEqual(gateway.frame(of: handle), original,
            "the app ignored the resize; screen and state disagree until the next assertion")
    }

    func testTiledWindowsInfoIsSortedBySlot() {
        // Tile in reverse slot order; presentation must sort by rawValue.
        addFocusedWindow()
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
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        // Drag TL's right edge (echo tick, then escape) to move columnSplit.
        var echo = gateway.frame(of: a)!
        echo.size.width -= 10
        gateway.simulateChange(a, to: echo)
        var dragged = gateway.frame(of: a)!
        dragged.size.width -= 60
        gateway.simulateChange(a, to: dragged)
        XCTAssertNotEqual(controller.grid.columnSplit, 0.5, "drag moved the splitter")

        controller.resetDividers()

        XCTAssertEqual(controller.grid, GridLayout())
        XCTAssertEqual(
            gateway.frame(of: a), expectedRect(.topLeft, for: a),
            "reset re-tiles occupants at the default grid")
        XCTAssertNil(controller.lastTileError)
        // One destructive action, one receipt: the reset parks the
        // displaced fractions for a one-step restore.
        XCTAssertTrue(controller.hasSplitterBackup, "reset keeps receipts")
        XCTAssertTrue(controller.restoreSplitters(), "the backup restores")
        XCTAssertNotEqual(
            controller.grid.columnSplit, 0.5, accuracy: 0.001,
            "restore returns the dragged splitter")
        XCTAssertFalse(
            controller.hasSplitterBackup, "restoring consumes the backup")
        XCTAssertFalse(
            controller.restoreSplitters(), "no backup left: second restore is a no-op")
    }

    func testResetDividersReportsRefusals() {
        let a = addFocusedWindow()
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
        XCTAssertNotEqual(controller.grid.columnSplit, 0.5)

        gateway.refuseNextWrites(a)
        controller.resetDividers()

        XCTAssertEqual(
            controller.lastTileError,
            "Couldn't move that window: the app refused to resize it.",
            "the re-assertion refusal surfaces, never silence")
    }

    // MARK: Ghost cleanup & screen changes

    func testPruneDropsDeadWindows() {
        let handle = addFocusedWindow()
        controller.handle(slot: .topLeft)
        XCTAssertEqual(controller.state.tiledWindows.count, 1)

        gateway.kill(handle)
        controller.pruneDeadWindows()

        XCTAssertTrue(controller.state.occupants.isEmpty)
    }

    func testPruneTimerFiresAndReleasesSlots() {
        // The real 5-second timer, shrunk: the wiring (fire → prune →
        // onChange when the count changed) is what the nil-interval tests
        // bypass by driving pruneDeadWindows directly.
        let gateway = FakeWindowGateway()
        var changes = 0
        let timed = TilingController(gateway: gateway, pruneInterval: 0.05)
        timed.onChange = { changes += 1 }
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        timed.handle(slot: .topLeft)
        XCTAssertEqual(timed.state.tiledWindows.count, 1)

        gateway.kill(handle)
        let waited = XCTestExpectation(description: "prune timer fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { waited.fulfill() }
        wait(for: [waited], timeout: 1.0)

        XCTAssertTrue(timed.state.occupants.isEmpty, "the timer pruned the ghost")
        XCTAssertGreaterThan(changes, 1, "prune announced the change for a menu refresh")
    }

    func testScreenChangeReassertsLayout() {
        let a = addFocusedWindow()
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
