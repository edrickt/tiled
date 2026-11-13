import XCTest
@testable import tiled

/// The ⌥⇧⏎ expand toggle: expands the focused window to fill its screen
/// without disturbing the layout (a tiled window keeps its slot while
/// expanded, exactly like focusing it) and retiles it on the second
/// press. The fake gateway stands in for AX; expected bounds mirror the
/// controller's screen-ownership rule so assertions never hardcode real
/// display pixels.
final class ExpandToggleTests: XCTestCase {
    /// Deterministic display: every produced frame is checked against this
    /// rect, never the host Mac's screen.
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Display 1")

    private var harness: ControllerHarness!
    private var gateway: FakeWindowGateway { harness.gateway }
    private var controller: TilingController { harness.controller }

    /// The canvas the test's single display tiles onto: reads go through
    /// the same accessor actions do.
    private var canvas: TilingSpace { harness.canvas }

    override func setUp() {
        super.setUp()
        // No runloop timer: tests drive pruneDeadWindows directly.
        harness = ControllerHarness(
            screens: [Self.screen], deathConfirmation: 3,
            isMouseDown: { true })
        controller.onChange = {}
    }

    // MARK: Expected geometry (the injected screen)

    private func bounds(for frame: CGRect) -> CGRect {
        Self.screen.visibleFrame
    }

    private func tileRect(_ slot: Slot, in frame: CGRect) -> CGRect {
        GridLayout().rect(for: slot, in: bounds(for: frame))
    }

    /// Independent invariant: a produced frame must sit inside the
    /// injected screen's visible frame. Containment is checked against
    /// the screen value directly, which the tile math cannot fake.
    private func assertWithinOwningVisibleFrame(_ produced: CGRect, preToggle: CGRect) {
        XCTAssertTrue(
            Self.screen.visibleFrame.contains(produced),
            "produced \(produced) escapes the screen's visible frame " +
            "\(Self.screen.visibleFrame)")
    }

    // MARK: Untiled windows

    func testExpandFillsScreenWithoutTiling() {
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let handle = gateway.addWindow(frame: original)
        gateway.focused = handle

        controller.handleExpandToggle()

        let expanded = gateway.frame(of: handle)!
        XCTAssertEqual(expanded, bounds(for: original))
        assertWithinOwningVisibleFrame(expanded, preToggle: original)
        XCTAssertTrue(canvas.state.occupants.isEmpty, "expanding never tiles")
    }

    func testSecondPressRestoresPreviousFrame() {
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let handle = gateway.addWindow(frame: original)
        gateway.focused = handle

        controller.handleExpandToggle()
        controller.handleExpandToggle()

        XCTAssertEqual(gateway.frame(of: handle), original)
    }

    func testExpandOfAnAlreadyExpandedWindowIssuesNoWrite() {
        // The target equals the live frame: the shared write policy
        // skips it, so no expectation is armed that would never
        // converge. Both directions of the toggle share the policy.
        let full = bounds(for: CGRect(x: 100, y: 100, width: 800, height: 600))
        let handle = gateway.addWindow(frame: full)
        gateway.focused = handle

        let receipt = controller.handleExpandToggle()
        XCTAssertTrue(gateway.writes.isEmpty)
        XCTAssertTrue(receipt.performed)
        XCTAssertNil(receipt.announcement, "a landed toggle stays silent")

        controller.handleExpandToggle()
        XCTAssertTrue(gateway.writes.isEmpty)
        XCTAssertEqual(gateway.frame(of: handle), full)
    }

    // MARK: Tiled windows

    func testExpandTiledWindowKeepsItsSlot() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)

        controller.handleExpandToggle()

        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft, "expanding acts like focusing: the slot survives")
        XCTAssertEqual(
            gateway.frame(of: handle),
            bounds(for: tileRect(.topLeft, in: CGRect(x: 0, y: 0, width: 800, height: 600))))
    }

    func testSecondPressRetilesTiledWindow() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        let tiledFrame = gateway.frame(of: handle)!

        controller.handleExpandToggle()
        controller.handleExpandToggle()

        XCTAssertEqual(gateway.frame(of: handle), tiledFrame)
        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)
    }

    // MARK: Menu state

    func testFocusedExpandStateNamesTheSlotOfAnExpandedTiledWindow() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        XCTAssertEqual(controller.focusedExpandState, .expands)

        controller.handleExpandToggle()

        XCTAssertEqual(
            controller.focusedExpandState, .returnsToSlot(.topLeft),
            "the menu names the slot the next press retiles into")
        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft, "expanding keeps the slot")
    }

    func testFocusedExpandStateReturnsToThePreviousFrameOfAnExpandedUntiledWindow() {
        let handle = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        gateway.focused = handle
        XCTAssertEqual(controller.focusedExpandState, .expands)

        controller.handleExpandToggle()

        XCTAssertEqual(
            controller.focusedExpandState, .returnsToPreviousFrame,
            "an expanded untiled window has a frame to return to, not a slot")
        XCTAssertNil(canvas.state.slot(of: 1))
    }

    func testExpandingDoesNotMoveOtherTiledWindows() {
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .bottomRight)
        let bFrame = gateway.frame(of: b)!

        gateway.focused = a
        controller.handleExpandToggle()

        XCTAssertEqual(gateway.frame(of: b), bFrame, "expanding one window leaves its neighbors alone")
        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)
        XCTAssertEqual(canvas.state.slot(of: 2), .bottomRight)
    }

    func testTilingBesideExpandedWindowLeavesItExpanded() {
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))

        gateway.focused = a
        controller.handleExpandToggle()
        let expandedFrame = gateway.frame(of: a)!

        gateway.focused = b
        controller.handle(slot: .topRight)

        XCTAssertEqual(
            gateway.frame(of: a), expandedFrame,
            "tiling a neighbor into a disjoint slot never touches the expanded window")
        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)
        XCTAssertEqual(canvas.state.slot(of: 2), .topRight)

        gateway.focused = a
        controller.handleExpandToggle()
        XCTAssertEqual(
            gateway.frame(of: a),
            tileRect(.topLeft, in: CGRect(x: 0, y: 0, width: 800, height: 600)))
    }

    func testOwnSlotHotkeyWhileExpandedReturnsWindowToItsTile() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)

        controller.handleExpandToggle()
        controller.handle(slot: .topLeft)

        XCTAssertEqual(
            gateway.frame(of: handle),
            tileRect(.topLeft, in: CGRect(x: 0, y: 0, width: 800, height: 600)))
        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)

        // Expansion ended: the toggle expands again instead of collapsing.
        controller.handleExpandToggle()
        XCTAssertEqual(
            gateway.frame(of: handle),
            bounds(for: tileRect(.topLeft, in: CGRect(x: 0, y: 0, width: 800, height: 600))))
    }

    func testDifferentSlotHotkeyWhileExpandedMovesWindowThere() {
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)

        controller.handleExpandToggle()
        controller.handle(slot: .bottomRight)

        XCTAssertEqual(canvas.state.slot(of: 1), .bottomRight)
        XCTAssertEqual(
            gateway.frame(of: handle),
            tileRect(.bottomRight, in: CGRect(x: 0, y: 0, width: 800, height: 600)))
    }

    // MARK: Title-bar double-click

    /// A title-bar double-click runs the toggle for the window under the
    /// click, not the one holding keyboard focus, and attaches an unmanaged
    /// window exactly as a first `⌥⇧⏎` press would.
    func testTitleBarDoubleClickExpandsTheClickedWindowRegardlessOfFocus() {
        let focused = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = focused
        let clicked = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        let clickedFrame = gateway.frame(of: clicked)!

        gateway.simulateTitleBarDoubleClick(on: clicked)

        XCTAssertEqual(
            gateway.frame(of: clicked), bounds(for: clickedFrame),
            "the double-clicked window expands")
        XCTAssertEqual(
            gateway.frame(of: focused), CGRect(x: 0, y: 0, width: 800, height: 600),
            "the focused window is not the gesture's target")
        let id = controller.registeredID(for: clicked)!
        XCTAssertTrue(canvas.isExpanded(id))
        XCTAssertNil(canvas.state.slot(of: id), "expanding never tiles")
    }

    /// A second title-bar double-click is the same toggle: the window
    /// returns to the frame it had before the first one.
    func testTitleBarDoubleClickTogglesBackToThePreviousFrame() {
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let handle = gateway.addWindow(frame: original)
        gateway.focused = handle

        gateway.simulateTitleBarDoubleClick(on: handle)
        XCTAssertEqual(gateway.frame(of: handle), bounds(for: original))

        gateway.simulateTitleBarDoubleClick(on: handle)
        XCTAssertEqual(gateway.frame(of: handle), original)
    }

    /// The gesture has no action caller, so a refusal travels the
    /// late-receipt route: it speaks once instead of being silently lost.
    func testTitleBarDoubleClickRefusalSpeaksThroughTheLateReceipt() {
        let handle = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        gateway.focused = handle
        gateway.refuseNextWrites(handle)
        var receipts: [ActionReceipt] = []
        controller.onLateReceipt = { receipts.append($0) }

        gateway.simulateTitleBarDoubleClick(on: handle)

        XCTAssertEqual(receipts.count, 1)
        XCTAssertFalse(receipts[0].performed)
        XCTAssertEqual(
            receipts[0].announcement,
            "TestApp couldn't be expanded: the app refused to resize it.")
    }

    /// Re-subscribing (the permission-grant retry) replaces the handler: one
    /// gesture still answers once, never twice.
    func testTitleBarDoubleClickResubscriptionReplacesTheHandler() {
        let handle = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        gateway.focused = handle
        controller.observeTitleBarDoubleClicks()
        var receipts = 0
        controller.onLateReceipt = { _ in receipts += 1 }

        gateway.simulateTitleBarDoubleClick(on: handle)

        XCTAssertEqual(receipts, 1)
    }

    // MARK: One full-size window

    /// Expanding a second window returns the first to its tile: a canvas
    /// shows one full-size window at a time.
    func testExpandingSecondWindowReturnsTheFirstToItsTile() {
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .topLeft)
        let aTile = gateway.frame(of: a)!

        controller.handleExpandToggle()
        XCTAssertEqual(gateway.frame(of: a), bounds(for: aTile))

        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .bottomRight)

        let receipt = controller.handleExpandToggle()

        XCTAssertTrue(receipt.performed)
        XCTAssertNil(receipt.announcement, "a landed expansion stays silent")
        XCTAssertEqual(gateway.frame(of: a), aTile, "the first window returns to its tile")
        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)
        XCTAssertFalse(canvas.isExpanded(1), "only the second window stays full-size")
        XCTAssertTrue(canvas.isExpanded(2))
        XCTAssertEqual(gateway.frame(of: b), bounds(for: aTile))
        XCTAssertEqual(canvas.state.slot(of: 2), .bottomRight)
    }

    /// An untiled full-size window has no tile to return to: expanding a
    /// second window restores its pre-expand frame, the documented
    /// collapse return.
    func testExpandingSecondWindowRestoresAnUntiledFirstToItsFrame() {
        let originalA = CGRect(x: 100, y: 100, width: 800, height: 600)
        let a = gateway.addWindow(frame: originalA)
        gateway.focused = a
        controller.handleExpandToggle()
        XCTAssertEqual(gateway.frame(of: a), bounds(for: originalA))

        let b = gateway.addWindow(frame: CGRect(x: 950, y: 120, width: 700, height: 500))
        gateway.focused = b
        controller.handleExpandToggle()

        XCTAssertEqual(gateway.frame(of: a), originalA)
        XCTAssertFalse(canvas.isExpanded(1))
        XCTAssertTrue(canvas.isExpanded(2))
    }

    /// The coverer's app can refuse the return. The canvas will not stage
    /// two full-size windows, so the new expansion is refused and its
    /// sentence names the window that would not move.
    func testRefusedReturnBlocksTheSecondExpansionAndAnswers() {
        let a = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        gateway.focused = a
        controller.handleExpandToggle()
        let b = gateway.addWindow(frame: CGRect(x: 950, y: 120, width: 700, height: 500))
        let bFrame = gateway.frame(of: b)!
        gateway.focused = b
        gateway.refuseNextWrites(a)

        let receipt = controller.handleExpandToggle()

        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(
            receipt.announcement,
            "TestApp couldn't return to its tile, so nothing was expanded.")
        XCTAssertEqual(gateway.frame(of: b), bFrame)
        XCTAssertTrue(canvas.isExpanded(1), "the coverer stays expanded, truthfully")
        XCTAssertFalse(canvas.isExpanded(2))
    }

    // MARK: Untile interaction

    func testUntileWhileExpandedLeavesSizedFrame() {
        let handle = gateway.addWindow(frame: CGRect(x: 120, y: 90, width: 700, height: 500))
        gateway.focused = handle
        controller.handle(slot: .topLeft)

        controller.handleExpandToggle()
        controller.untile(window: 1)

        XCTAssertEqual(
            gateway.frame(of: handle), CGRect(x: 120, y: 90, width: 800, height: 500),
            "untiling an expanded window leaves the quarter footprint")
        // Expansion ended with the untile: the toggle expands from scratch.
        gateway.focused = handle
        controller.handleExpandToggle()
        XCTAssertEqual(gateway.frame(of: handle), Self.screen.visibleFrame)
    }

    func testEvictingAnExpandedWindowRestoresAndClearsExpansion() {
        let a = gateway.addWindow(frame: CGRect(x: 120, y: 90, width: 700, height: 500))
        gateway.focused = a
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))

        gateway.focused = a
        controller.handleExpandToggle()
        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)

        // b requests a's slot while a covers the screen: a is evicted.
        gateway.focused = b
        controller.handle(slot: .topLeft)

        XCTAssertEqual(canvas.state.slot(of: 1), nil)
        XCTAssertEqual(canvas.state.slot(of: 2), .topLeft)
        XCTAssertEqual(
            gateway.frame(of: a), CGRect(x: 120, y: 90, width: 800, height: 500),
            "eviction leaves the quarter footprint and ends the expansion")

        // The expansion is gone: the toggle expands again from scratch.
        gateway.focused = a
        controller.handleExpandToggle()
        XCTAssertEqual(
            gateway.frame(of: a),
            bounds(for: CGRect(x: 120, y: 90, width: 700, height: 500)))
    }

    // MARK: Display changes

    /// A display geometry change (resolution, Dock, menu bar) re-asserts the
    /// canvas. The expanded window's job is to cover that screen, so the
    /// reassert must rewrite it to the new visible frame; otherwise it keeps
    /// the old screen size and no longer fills the display while the canvas
    /// still calls it expanded.
    func testADisplayChangeReExpandsToTheNewVisibleFrame() {
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let handle = gateway.addWindow(frame: original)
        gateway.focused = handle
        controller.handleExpandToggle()
        XCTAssertEqual(gateway.frame(of: handle), Self.screen.visibleFrame)

        let resized = ScreenInfo(
            id: ScreenID(rawValue: 1),
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 780),
            name: "Display 1")
        harness.screens = [resized]
        postDisplayChange()

        XCTAssertEqual(
            gateway.frame(of: handle), resized.visibleFrame,
            "an expanded window still fills its screen after the display changes")
        XCTAssertTrue(canvas.isExpanded(handle.id))
    }

    /// The rule is the same for an untiled expanded window: expansion covers
    /// the canvas's screen, so a display change re-derives its frame too.
    func testADisplayChangeReExpandsAnUntiledWindowToTheNewVisibleFrame() {
        let handle = gateway.addWindow(
            frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        gateway.focused = handle
        controller.handleExpandToggle()

        let resized = ScreenInfo(
            id: ScreenID(rawValue: 1),
            frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 680),
            name: "Display 1")
        harness.screens = [resized]
        postDisplayChange()

        XCTAssertEqual(
            gateway.frame(of: handle), resized.visibleFrame,
            "an untiled expanded window follows the screen it covers")
        XCTAssertTrue(canvas.isExpanded(handle.id))
    }

    /// Fires the controller's display-change observer and waits for it.
    private func postDisplayChange() {
        let reasserted = expectation(description: "display change reassert")
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in reasserted.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        wait(for: [reasserted], timeout: 1.0)
    }

    // MARK: Receipts

    func testExpandWithNoFocusedWindowIsSafeNoop() {
        gateway.focused = nil

        let receipt = controller.handleExpandToggle()

        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(
            receipt.announcement, "No focused window: click a window first.")
    }

    func testExpandWithNoReadableFrameReportsNotPerformed() {
        let handle = gateway.addWindow(frame: .zero)
        gateway.focused = handle

        let receipt = controller.handleExpandToggle()

        XCTAssertFalse(
            receipt.performed,
            "an expansion that wrote nothing must not claim performed")
        XCTAssertEqual(
            receipt.announcement,
            "Couldn't read that window's frame, so it wasn't expanded.")
        XCTAssertEqual(receipt.notice, receipt.announcement, "the menu carries the one sentence")
        XCTAssertNil(canvas.error, "an unreadable frame is not an app refusal")
        XCTAssertFalse(canvas.isExpanded(1))
        XCTAssertTrue(gateway.writes.isEmpty)
    }

    func testRefusedExpandLeavesWindowPutAndReports() {
        let original = CGRect(x: 0, y: 0, width: 800, height: 600)
        let handle = gateway.addWindow(frame: original)
        gateway.focused = handle
        gateway.refuseNextWrites(handle)

        let receipt = controller.handleExpandToggle()

        XCTAssertEqual(gateway.frame(of: handle), original)
        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(
            receipt.announcement,
            "TestApp couldn't be expanded: the app refused to resize it.")
        XCTAssertNotNil(canvas.error)

        // The window never expanded: the next press retries the expand.
        controller.handleExpandToggle()
        XCTAssertEqual(gateway.frame(of: handle), bounds(for: original))
    }

    /// Expanding while an edge drag is still in flight supersedes that
    /// drag: the expand's programmatic write is newer than the gesture,
    /// so the delayed mouse-up must not reassert the window's full-screen
    /// frame onto the shared splitters or move the neighbour.
    func testExpandingDuringAnEdgeDragCancelsThePendingReassert() {
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .sixthTopLeft)
        let b = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .sixthBottomLeft)

        // B's top edge drags the shared row splitter down from half to
        // 0.44: the close tick is the echo, the far tick is the drag.
        let bTiled = gateway.frame(of: b)!
        var echo = bTiled
        echo.size.height -= 10
        gateway.simulateChange(b, to: echo)
        var dragged = bTiled
        dragged.size.height -= 60
        gateway.simulateChange(b, to: dragged)
        let gridAfterDrag = canvas.grid
        XCTAssertEqual(
            gridAfterDrag.sixthsLeftRowSplit, 0.44, accuracy: 0.001,
            "the live drag moved the shared row splitter")
        let neighbourFrame = gateway.frame(of: a)!

        gateway.focused = b
        controller.handleExpandToggle()
        controller.mouseLifted()

        XCTAssertEqual(
            canvas.grid, gridAfterDrag,
            "the expand supersedes the drag: mouse-up must not reconcile the full-screen frame")
        XCTAssertEqual(
            gateway.frame(of: a), neighbourFrame,
            "the neighbour is not re-laid-out by the stale edge drag")
    }

    func testRefusedExpandKeepsThePendingEdgeReassert() {
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .sixthTopLeft)
        let b = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .sixthBottomLeft)

        // B's top edge drags the shared row splitter down to 0.44; A is
        // still at the old 0.5 height until the release reasserts.
        let bTiled = gateway.frame(of: b)!
        var echo = bTiled
        echo.size.height -= 10
        gateway.simulateChange(b, to: echo)
        var dragged = bTiled
        dragged.size.height -= 60
        gateway.simulateChange(b, to: dragged)
        let gridAfterDrag = canvas.grid
        XCTAssertEqual(gridAfterDrag.sixthsLeftRowSplit, 0.44, accuracy: 0.001)

        // The expand is refused: nothing moved, so the pending edge drag
        // still owes the release its reassert.
        gateway.refuseNextWrites(b)
        controller.handleExpandToggle()
        controller.mouseLifted()

        XCTAssertEqual(canvas.grid, gridAfterDrag)
        XCTAssertEqual(
            gateway.frame(of: a)?.height ?? 0, 560, accuracy: 0.5,
            "the release reasserts the neighbour to the dragged edge")
        XCTAssertEqual(
            gateway.frame(of: b)?.height ?? 0, 440, accuracy: 0.5,
            "the refused expand left B at its dragged frame")
    }

    /// A drag-resize coalesces a re-push of the dragged monitor's
    /// neighbors. An expanded window is not one of them: it covers the
    /// layout rather than occupying its slot, so the re-push must never
    /// yank it back down to the tile it keeps in state.
    func testDragResizeDoesNotRePushAnExpandedWindowIntoItsSlot() {
        // Deterministic single display: the re-push must land on known
        // geometry, not the host's real screen.
        let screen = ScreenInfo(
            id: ScreenID(rawValue: 0),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            name: "Display 1")
        let localHarness = ControllerHarness(
            screens: [screen], deathConfirmation: 3)
        let gateway = localHarness.gateway
        let controller = localHarness.controller

        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .sixthTopLeft)
        let b = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .sixthBottomLeft)

        gateway.focused = a
        controller.handleExpandToggle()
        let expandedFrame = gateway.frame(of: a)!
        XCTAssertEqual(expandedFrame, screen.visibleFrame, "A covers the display")

        // Drag B's top edge (the shared row splitter): the tracker
        // coalesces a neighbor re-push onto the next main-queue tick.
        var echo = gateway.frame(of: b)!
        echo.size.height -= 10
        gateway.simulateChange(b, to: echo)
        var dragged = gateway.frame(of: b)!
        dragged.size.height -= 60
        gateway.simulateChange(b, to: dragged)
        controller.mouseLifted()

        let pushed = XCTestExpectation(description: "drag re-push tick")
        DispatchQueue.main.async {
            XCTAssertEqual(
                gateway.frame(of: a), expandedFrame,
                "the expanded window is not a re-push target: it stays covering the layout")
            pushed.fulfill()
        }
        wait(for: [pushed], timeout: 1.0)
    }
}
