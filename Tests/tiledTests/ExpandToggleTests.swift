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

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!
    private var feedbacks: [TilingController.Feedback] = []
    /// Late checks captured from the injectable scheduler.
    private var checkFires: [() -> Void] = []
    /// How many times the controller signalled a state change.
    private var changeCount = 0

    /// The canvas the test's single display tiles onto: reads go through
    /// the same accessor actions do.
    private var canvas: TilingSpace { controller.canvas(for: controller.focusedTilingSpace) }

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        feedbacks = []
        checkFires = []
        changeCount = 0
        // No runloop timer: tests drive pruneDeadWindows directly, and
        // late checks fire via the captured scheduler.
        controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleCheck: { [weak self] fire in
                self?.checkFires.append(fire)
                return {}
            },
            screens: { [Self.screen] })
        controller.onFeedback = { [weak self] in self?.feedbacks.append($0) }
        controller.onChange = { [weak self] in self?.changeCount += 1 }
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

        controller.handleExpandToggle()
        XCTAssertTrue(gateway.writes.isEmpty)
        XCTAssertTrue(feedbacks.isEmpty)

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

    // MARK: Untile interaction

    func testUntileWhileExpandedRestoresPreTileFrame() {
        let original = CGRect(x: 120, y: 90, width: 700, height: 500)
        let handle = gateway.addWindow(frame: original)
        gateway.focused = handle
        controller.handle(slot: .topLeft)

        controller.handleExpandToggle()
        controller.untile(window: 1)

        XCTAssertEqual(gateway.frame(of: handle), original)
        // Expansion ended with the untile: the toggle expands from scratch.
        gateway.focused = handle
        controller.handleExpandToggle()
        XCTAssertEqual(gateway.frame(of: handle), bounds(for: original))
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
            gateway.frame(of: a), CGRect(x: 120, y: 90, width: 700, height: 500),
            "eviction restores the pre-tile frame and ends the expansion")

        // The expansion is gone: the toggle expands again from scratch.
        gateway.focused = a
        controller.handleExpandToggle()
        XCTAssertEqual(
            gateway.frame(of: a),
            bounds(for: CGRect(x: 120, y: 90, width: 700, height: 500)))
    }

    // MARK: Feedback

    func testExpandWithNoFocusedWindowIsSafeNoop() {
        gateway.focused = nil

        controller.handleExpandToggle()

        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertEqual(feedbacks.count, 1)
        guard case .noFocusedWindow = feedbacks[0] else {
            return XCTFail("expected .noFocusedWindow, got \(feedbacks[0])")
        }
    }

    func testRefusedExpandLeavesWindowPutAndReports() {
        let original = CGRect(x: 0, y: 0, width: 800, height: 600)
        let handle = gateway.addWindow(frame: original)
        gateway.focused = handle
        gateway.refuseNextWrites(handle)

        controller.handleExpandToggle()

        XCTAssertEqual(gateway.frame(of: handle), original)
        XCTAssertEqual(feedbacks.count, 1)
        guard case .expandRefused = feedbacks[0] else {
            return XCTFail("expected .expandRefused, got \(feedbacks[0])")
        }
        XCTAssertNotNil(canvas.error)

        // The window never expanded: the next press retries the expand.
        controller.handleExpandToggle()
        XCTAssertEqual(gateway.frame(of: handle), bounds(for: original))
    }

    // MARK: Late cover-toggle consequences (silent ignores)

    func testSilentlyIgnoredExpandRevertsTheExpansion() {
        // The app reported success but never moved: the expansion must
        // not stay in state covering a frame the app never applied. The
        // late check reverts the record and surfaces the immediate
        // path's refusal, writing no frames of its own.
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let handle = gateway.addWindow(frame: original)
        gateway.focused = handle
        gateway.silentIgnore.insert(handle)

        controller.handleExpandToggle()

        XCTAssertTrue(canvas.isExpanded(1), "commits at write time")
        XCTAssertEqual(gateway.frame(of: handle), original, "the app never moved")
        let writesBefore = gateway.writes.count
        let changesBefore = changeCount

        checkFires.last?()

        XCTAssertFalse(canvas.isExpanded(1), "the ignored expand rolled back")
        XCTAssertEqual(
            canvas.error, "Couldn't move that window: the app refused to resize it.")
        XCTAssertEqual(feedbacks.count, 1)
        guard case .expandRefused(let name) = feedbacks[0] else {
            return XCTFail("expected .expandRefused, got \(feedbacks[0])")
        }
        XCTAssertEqual(name, "TestApp")
        XCTAssertEqual(gateway.writes.count, writesBefore, "the revert writes no frames")
        XCTAssertEqual(gateway.frame(of: handle), original)
        XCTAssertEqual(changeCount, changesBefore + 1)

        // The window never expanded: the next press expands for real.
        gateway.silentIgnore.remove(handle)
        controller.handleExpandToggle()
        XCTAssertEqual(gateway.frame(of: handle), bounds(for: original))
    }

    func testSilentlyIgnoredCollapseRestoresTheExpansion() {
        // The reverse direction: a collapse the app ignored leaves the
        // window covering the screen, so the expanded record must come
        // back - again with no frame write by the revert.
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let handle = gateway.addWindow(frame: original)
        gateway.focused = handle
        controller.handleExpandToggle() // expands for real
        let expandedFrame = gateway.frame(of: handle)!
        XCTAssertTrue(canvas.isExpanded(1))

        gateway.silentIgnore.insert(handle)
        controller.handleExpandToggle() // collapses, silently ignored

        XCTAssertFalse(canvas.isExpanded(1), "the collapse cleared the record at write time")
        XCTAssertEqual(gateway.frame(of: handle), expandedFrame, "the app never moved")
        let writesBefore = gateway.writes.count
        let changesBefore = changeCount

        checkFires.last?()

        XCTAssertTrue(canvas.isExpanded(1), "the ignored collapse restored the expansion")
        XCTAssertEqual(canvas.expanded[1], original, "the saved frame is back")
        XCTAssertEqual(
            canvas.error, "Couldn't move that window: the app refused to resize it.")
        XCTAssertEqual(feedbacks.count, 1)
        guard case .expandRefused(let name) = feedbacks[0] else {
            return XCTFail("expected .expandRefused, got \(feedbacks[0])")
        }
        XCTAssertEqual(name, "TestApp")
        XCTAssertEqual(gateway.writes.count, writesBefore, "the revert writes no frames")
        XCTAssertEqual(gateway.frame(of: handle), expandedFrame)
        XCTAssertEqual(changeCount, changesBefore + 1)
    }

    func testSilentlyIgnoredRetileRestoresTheExpansion() {
        // The tiled leg of collapse: an expanded window keeps its slot,
        // so the collapse retiles it. A silent ignore must restore the
        // expansion exactly like the untiled leg.
        let handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        controller.handleExpandToggle() // expands the tiled window
        let expandedFrame = gateway.frame(of: handle)!
        let saved = canvas.expanded[1]!
        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft, "expansion keeps the slot")

        gateway.silentIgnore.insert(handle)
        controller.handleExpandToggle() // retiles, silently ignored

        XCTAssertFalse(canvas.isExpanded(1), "the collapse cleared the record at write time")
        XCTAssertEqual(gateway.frame(of: handle), expandedFrame, "the app never moved")
        let writesBefore = gateway.writes.count

        checkFires.last?()

        XCTAssertTrue(canvas.isExpanded(1), "the ignored retile restored the expansion")
        XCTAssertEqual(canvas.expanded[1], saved, "the saved frame is back")
        XCTAssertEqual(gateway.writes.count, writesBefore, "the revert writes no frames")
        XCTAssertEqual(gateway.frame(of: handle), expandedFrame)
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
        let gateway = FakeWindowGateway()
        var commitFires: [() -> Void] = []
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleCommit: { commitFires.append($0); return {} },
            screens: { [screen] })

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
        commitFires.last?()

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
