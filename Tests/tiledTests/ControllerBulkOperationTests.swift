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

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!
    private var feedbacks: [TilingController.Feedback] = []
    private var changeCount = 0
    /// Block-based observers returned by addObserver(forName:) must be
    /// removed explicitly or they leak for the process lifetime.
    private var observers: [NSObjectProtocol] = []

    /// The canvas the test's single display tiles onto: reads go through
    /// the same accessor actions do.
    private var canvas: TilingSpace { controller.canvas(for: controller.focusedTilingSpace) }

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [Self.screen] }, deathConfirmation: 0)
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
    /// grid evaluated in the injected screen's visible frame (mirrors the
    /// controller's `visibleBounds` + tracker `rect(for:)`).
    private func expectedRect(_ slot: Slot, for handle: WindowHandle) -> CGRect {
        controller.canvas(for: Self.screen.id).grid.rect(
            for: slot, in: Self.screen.visibleFrame)
    }

    // MARK: Untile restores frames

    func testUntileRestoresPreTileFrame() {
        let handle = addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        let original = gateway.frame(of: handle)!
        controller.handle(slot: .topLeft)
        XCTAssertEqual(canvas.state.tiledWindows.count, 1)

        controller.untile(window: 1)

        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertEqual(
            gateway.frame(of: handle), original,
            "untile writes the pre-tile frame back")
    }

    func testUntileUnknownWindowIsSafe() {
        controller.untile(window: 99)
        XCTAssertTrue(canvas.state.occupants.isEmpty)
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
        XCTAssertEqual(canvas.state.tiledWindows.count, 2)

        controller.untileAll()

        XCTAssertTrue(canvas.state.occupants.isEmpty)
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
        XCTAssertFalse(canvas.undoStack.isEmpty)
        XCTAssertEqual(canvas.evictedCount, 1)
        XCTAssertNotNil(canvas.notice)
        XCTAssertEqual(canvas.state.slot(of: 2), .sixthLeft)
        XCTAssertEqual(
            gateway.frame(of: a), aOriginal,
            "eviction restores the pre-tile frame immediately")

        controller.undoLastDisplacement()

        // The evicted window returns to its slot under a fresh id (its
        // record was pruned at switch); the requester is untiled with its
        // original frame back.
        XCTAssertEqual(canvas.state.tiledWindows.count, 1)
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft))
        XCTAssertEqual(canvas.state.slot(of: 2), nil)
        XCTAssertEqual(
            gateway.frame(of: a), expectedRect(.topLeft, for: a),
            "undo re-tiles the evicted window into its old slot")
        XCTAssertEqual(
            gateway.frame(of: b), bOriginal,
            "undo restores the requester's pre-tile frame")
        XCTAssertTrue(canvas.undoStack.isEmpty)
        XCTAssertEqual(canvas.evictedCount, 0)
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
        XCTAssertFalse(canvas.undoStack.isEmpty)

        controller.undoLastDisplacement()
        XCTAssertTrue(canvas.undoStack.isEmpty)

        controller.undoLastDisplacement()
        XCTAssertEqual(canvas.state.tiledWindows.count, 1, "second undo is a no-op")
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
        XCTAssertFalse(canvas.undoStack.isEmpty)
        XCTAssertEqual(canvas.evictedCount, 1)

        // Switch #2 back to quarters: b is evicted. The old undo is NOT
        // gone; history stacks, newest last.
        let c = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        gateway.focused = c
        controller.handle(slot: .bottomRight)
        XCTAssertFalse(canvas.undoStack.isEmpty, "the new switch offers its own undo")
        XCTAssertEqual(canvas.evictedCount, 1)
        XCTAssertEqual(
            canvas.notice,
            "Switched to Quarters \u{00B7} 1 window untiled. "
                + "Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo.")

        controller.undoLastDisplacement()
        XCTAssertEqual(canvas.state.slot(of: 3), nil, "requester c is untiled by undo")
        XCTAssertNotNil(
            canvas.state.occupant(of: .sixthLeft),
            "undo #2 returns b (not a) to its slot")
        XCTAssertNil(canvas.state.occupant(of: .topLeft))
        XCTAssertEqual(canvas.state.tiledWindows.count, 1)

        // Walking back again returns a to its slot: depth, not amnesia.
        controller.undoLastDisplacement()
        XCTAssertNotNil(
            canvas.state.occupant(of: .topLeft),
            "undo #1 returns a to its slot")
        XCTAssertTrue(canvas.undoStack.isEmpty, "history exhausted")
    }

    func testUndoHistoryIsBoundedByDepthNotAmnesia() {
        // Seven destructive switches; the stack keeps the freshest five
        // and drops the two oldest — exactly five chapters survive, not
        // fewer. Walking back five times consumes all of them; the sixth
        // undo answers instead of reaching further, and a stack that kept
        // a sixth chapter would answer it instead of `.nothingToUndo`.
        var handles: [WindowHandle] = []
        for i in 0..<7 {
            let handle = gateway.addWindow(
                frame: CGRect(x: i * 10, y: i * 10, width: 500, height: 400))
            handles.append(handle)
            gateway.focused = handle
            controller.handle(slot: i.isMultiple(of: 2) ? .topLeft : .sixthLeft)
        }
        XCTAssertFalse(canvas.undoStack.isEmpty)
        // Each of the five oldest deletions is gone, so each undo must
        // consume a real chapter. Asserting only the end state (stack
        // empty) also passed with a depth-2 stack, where three of these
        // five calls were silent no-ops.
        for index in 1...5 {
            feedbacks.removeAll()
            controller.undoLastDisplacement()
            XCTAssertTrue(
                feedbacks.isEmpty,
                "undo #\(index) answered .nothingToUndo: the depth-5 history lost a chapter")
        }
        XCTAssertFalse(
            !canvas.undoStack.isEmpty,
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
        XCTAssertTrue(canvas.undoStack.isEmpty)
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

        XCTAssertEqual(canvas.state.slot(of: 1), .sixthLeft)
        XCTAssertNil(canvas.notice)
        XCTAssertTrue(canvas.undoStack.isEmpty)
        XCTAssertEqual(canvas.evictedCount, 0)
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

        XCTAssertEqual(canvas.state.tiledWindows.count, 1)
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft),
            "the evictee still returns to its slot")
        XCTAssertNil(canvas.state.occupant(of: .sixthLeft))
        XCTAssertEqual(canvas.notice, "Undid displacement \u{00B7} 1 window restored.")
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
            canvas.error, "Couldn't restore the evicted windows.")
        XCTAssertTrue(canvas.state.occupants.isEmpty,
            "requester untiled by undo; dead evictee skipped")
        XCTAssertTrue(canvas.undoStack.isEmpty)
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
        XCTAssertEqual(canvas.state.slot(of: 1), .rightHalf)

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
        XCTAssertFalse(canvas.undoStack.isEmpty, "untile-all is itself undoable")
        XCTAssertEqual(canvas.evictedCount, 2)
        XCTAssertEqual(canvas.notice, "Untiled 2 windows. Press ⌃⌥⇧⌘Z to undo.")
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
            canvas.error,
            "Couldn't restore \u{201C}TestApp\u{201D}: it may still be sitting in its old tile.")
        XCTAssertNil(canvas.state.slot(of: 1),
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
            canvas.error,
            "Couldn't restore 2 windows: they may still be sitting in their old tiles.")
        XCTAssertTrue(canvas.state.occupants.isEmpty)
    }

    func testNoopHotkeyPreservesNotices() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)
        gateway.focused = b
        controller.handle(slot: .sixthLeft)
        XCTAssertNotNil(canvas.notice)

        // Strict no-op: no state, error, or menu side effects; the
        // already-tiled feedback fires, but the notice survives untouched.
        gateway.focused = b
        controller.handle(slot: .sixthLeft)

        XCTAssertNotNil(canvas.notice, "no-op must not clear the notice")
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

        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft,
            "the gateway reported success, so occupancy commits")
        XCTAssertNil(canvas.error, "no refusal: the write 'succeeded'")
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
        XCTAssertNotEqual(canvas.grid.columnSplit, 0.5, "drag moved the splitter")

        controller.resetDividers()

        XCTAssertEqual(canvas.grid, GridLayout())
        XCTAssertEqual(
            gateway.frame(of: a), expectedRect(.topLeft, for: a),
            "reset re-tiles occupants at the default grid")
        XCTAssertNil(canvas.error)
        // One destructive action, one receipt: the reset parks the
        // displaced fractions for a one-step restore.
        XCTAssertTrue(canvas.hasSplitterBackup, "reset keeps receipts")
        XCTAssertTrue(controller.restoreSplitters(), "the backup restores")
        XCTAssertNotEqual(
            canvas.grid.columnSplit, 0.5, accuracy: 0.001,
            "restore returns the dragged splitter")
        XCTAssertFalse(
            canvas.hasSplitterBackup, "restoring consumes the backup")
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
        XCTAssertNotEqual(canvas.grid.columnSplit, 0.5)

        gateway.refuseNextWrites(a)
        controller.resetDividers()

        XCTAssertEqual(
            canvas.error,
            "Couldn't move that window: the app refused to resize it.",
            "the re-assertion refusal surfaces, never silence")
    }

    func testResetDividersReportsRefusalsInPlural() {
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
        controller.resetDividers()

        XCTAssertEqual(
            canvas.error,
            "Couldn't move 2 windows: an app refused to resize.")
    }

    // MARK: Ghost cleanup & screen changes

    func testPruneDropsDeadWindows() {
        let handle = addFocusedWindow()
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
        let a = addFocusedWindow()
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
        let handle = addFocusedWindow()
        controller.handle(slot: .topLeft)

        gateway.simulateDestroyed(handle)

        XCTAssertEqual(canvas.state.tiledWindows.count, 1)
    }

    func testDestroyedNotificationWithUnknownLivenessKeepsTheSlot() {
        // The lid-cycle transient: probes fail for live windows
        // mid-teardown and the death standard answers unknown. A
        // destroyed report must not force a prune the standard still
        // calls a maybe.
        let handle = addFocusedWindow()
        controller.handle(slot: .topLeft)
        gateway.busy.insert(handle)

        gateway.simulateDestroyed(handle)

        XCTAssertEqual(canvas.state.tiledWindows.count, 1, "a maybe never untiles")
    }

    func testPruneTimerFiresAndReleasesSlots() {
        // The real 5-second timer, shrunk: the wiring (fire → prune →
        // onChange when the count changed) is what the nil-interval tests
        // bypass by driving pruneDeadWindows directly.
        let gateway = FakeWindowGateway()
        var changes = 0
        let timed = TilingController(
            gateway: gateway, pruneInterval: 0.05,
            screens: { [Self.screen] }, deathConfirmation: 0)
        timed.onChange = { changes += 1 }
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        timed.handle(slot: .topLeft)
        XCTAssertEqual(
            timed.canvas(for: timed.focusedTilingSpace).state.tiledWindows.count, 1)

        gateway.kill(handle)
        let waited = XCTestExpectation(description: "prune timer fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { waited.fulfill() }
        wait(for: [waited], timeout: 1.0)

        XCTAssertTrue(
            timed.canvas(for: timed.focusedTilingSpace).state.occupants.isEmpty,
            "the timer pruned the ghost")
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
