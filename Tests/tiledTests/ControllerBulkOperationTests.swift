import AppKit
import XCTest
@testable import tiled

/// Controller-level bulk operations and bookkeeping: untile / untileAll /
/// resetDividers / undoLayoutSwitch driven through `TilingController` with
/// the fake gateway. Pins the side effects the pure-state tests can't see —
/// restored frames, the one-step undo lifecycle, feedback callbacks, and
/// notice clearing.
final class ControllerBulkOperationTests: XCTestCase {
    private var gateway: FakeWindowGateway!
    private var controller: TilingController!
    private var feedbacks: [TilingController.Feedback] = []
    private var changeCount = 0

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        controller = TilingController(gateway: gateway, pruneInterval: nil)
        controller.onFeedback = { [weak self] in self?.feedbacks.append($0) }
        controller.onChange = { [weak self] in self?.changeCount += 1 }
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
        XCTAssertTrue(controller.canUndoSwitch)
        XCTAssertEqual(controller.evictedCount, 1)
        XCTAssertNotNil(controller.lastNotice)
        XCTAssertEqual(controller.state.slot(of: 2), .sixthLeft)
        XCTAssertEqual(
            gateway.frame(of: a), aOriginal,
            "eviction restores the pre-tile frame immediately")

        controller.undoLayoutSwitch()

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
        XCTAssertFalse(controller.canUndoSwitch)
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
        XCTAssertTrue(controller.canUndoSwitch)

        controller.undoLayoutSwitch()
        XCTAssertFalse(controller.canUndoSwitch)

        controller.undoLayoutSwitch()
        XCTAssertEqual(controller.state.tiledWindows.count, 1, "second undo is a no-op")
    }

    func testNewSwitchReplacesTheUndoSnapshot() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)

        // Cross-layout switch #1: a is evicted (undo names a).
        gateway.focused = b
        controller.handle(slot: .sixthLeft)
        XCTAssertTrue(controller.canUndoSwitch)
        XCTAssertEqual(controller.evictedCount, 1)

        // Switch #2 back to quarters: b is evicted (undo now names b). The
        // old undo is gone — exactly one step exists at any time.
        let c = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        gateway.focused = c
        controller.handle(slot: .bottomRight)
        XCTAssertTrue(controller.canUndoSwitch, "the new switch offers its own undo")
        XCTAssertEqual(controller.evictedCount, 1)
        XCTAssertEqual(
            controller.lastNotice,
            "Switched to Quarters \u{00B7} 1 window untiled. "
                + "Undo: Restore 1 Evicted Window.")

        controller.undoLayoutSwitch()
        XCTAssertEqual(controller.state.slot(of: 3), nil, "requester c is untiled by undo")
        XCTAssertNotNil(
            controller.state.occupant(of: .sixthLeft),
            "undo #2 returns b — not a — to its slot")
        XCTAssertNil(controller.state.occupant(of: .topLeft))
        XCTAssertEqual(controller.state.tiledWindows.count, 1)
    }

    func testNonSwitchActionClearsTheUndoOffer() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .topRight)
        gateway.focused = b
        controller.handle(slot: .sixthLeft)
        XCTAssertTrue(controller.canUndoSwitch)
        XCTAssertNotNil(controller.lastNotice)

        // A bulk op (or any non-switch action) consumes the undo offer.
        controller.untileAll()
        XCTAssertFalse(controller.canUndoSwitch)
        XCTAssertEqual(controller.evictedCount, 0)
        XCTAssertNil(controller.lastNotice)
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

    func testScreenChangeReassertsLayout() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 700, height: 500))
        gateway.focused = b
        controller.handle(slot: .topRight)

        let reasserted = XCTestExpectation(description: "screen change reassert")
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            reasserted.fulfill()
        }
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
