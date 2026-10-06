import AppKit
import XCTest
@testable import tiled

/// The ⌥⇧⏎ expand toggle: expands the focused window to fill its screen
/// without disturbing the layout (a tiled window keeps its slot while
/// expanded, exactly like focusing it) and retiles it on the second
/// press. The fake gateway stands in for AX; expected bounds mirror the
/// controller's screen-ownership rule so assertions never hardcode real
/// display pixels.
final class ExpandToggleTests: XCTestCase {
    private var gateway: FakeWindowGateway!
    private var controller: TilingController!
    private var feedbacks: [TilingController.Feedback] = []

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        feedbacks = []
        // No runloop timer: tests drive pruneDeadWindows directly.
        controller = TilingController(gateway: gateway, pruneInterval: nil)
        controller.onFeedback = { [weak self] in self?.feedbacks.append($0) }
        controller.onChange = {}
    }

    // MARK: Expected geometry (mirrors the controller's screen rule)

    private func bounds(for frame: CGRect) -> CGRect {
        let screens = NSScreen.screens
        if let index = TilingController.owningScreenIndex(frames: screens.map(\.frame), for: frame) {
            return screens[index].visibleFrame
        }
        if let index = TilingController.midpointScreenIndex(frames: screens.map(\.frame), for: frame) {
            return screens[index].visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? frame
    }

    private func tileRect(_ slot: Slot, in frame: CGRect) -> CGRect {
        GridLayout().rect(for: slot, in: bounds(for: frame))
    }

    /// Independent invariant: a produced frame must sit inside the
    /// visible frame of the screen that owns the pre-toggle frame.
    /// `bounds(for:)` mirrors the controller's ownership chain, so a
    /// broken rule could agree with itself; containment is checked
    /// against the screen API directly, which the mirroring cannot fake.
    private func assertWithinOwningVisibleFrame(_ produced: CGRect, preToggle: CGRect) {
        let screens = NSScreen.screens
        guard let index = TilingController.owningScreenIndex(
            frames: screens.map(\.frame), for: preToggle)
        else { return } // off-screen: the fallback chain owns the frame
        XCTAssertTrue(
            screens[index].visibleFrame.contains(produced),
            "produced \(produced) escapes the owning screen's visible frame " +
            "\(screens[index].visibleFrame)")
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
        XCTAssertTrue(controller.state.occupants.isEmpty, "expanding never tiles")
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

        XCTAssertEqual(controller.state.slot(of: 1), .topLeft, "expanding acts like focusing: the slot survives")
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
        XCTAssertEqual(controller.state.slot(of: 1), .topLeft)
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
        XCTAssertEqual(controller.state.slot(of: 1), .topLeft)
        XCTAssertEqual(controller.state.slot(of: 2), .bottomRight)
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
        XCTAssertEqual(controller.state.slot(of: 1), .topLeft)
        XCTAssertEqual(controller.state.slot(of: 2), .topRight)

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
        XCTAssertEqual(controller.state.slot(of: 1), .topLeft)

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

        XCTAssertEqual(controller.state.slot(of: 1), .bottomRight)
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
        XCTAssertEqual(controller.state.slot(of: 1), .topLeft)

        // b requests a's slot while a covers the screen: a is evicted.
        gateway.focused = b
        controller.handle(slot: .topLeft)

        XCTAssertEqual(controller.state.slot(of: 1), nil)
        XCTAssertEqual(controller.state.slot(of: 2), .topLeft)
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

        XCTAssertTrue(controller.state.occupants.isEmpty)
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
        XCTAssertNotNil(controller.lastTileError)

        // The window never expanded: the next press retries the expand.
        controller.handleExpandToggle()
        XCTAssertEqual(gateway.frame(of: handle), bounds(for: original))
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
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil, screens: { [screen] })

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
