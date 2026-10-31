import CoreGraphics
import XCTest
@testable import tiled

/// The explicit layout switch: `⌥⇧\` untiles every occupant of the
/// canvas on the cursor's display, adopts the other layout, and pushes
/// one undo chapter; the menu's targeted row follows focus instead. A
/// slot key never switches; the layout sticks on an empty canvas.
final class LayoutSwitchTests: XCTestCase {
    private static let main = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        name: "Display 1")

    private var harness: ControllerHarness!
    private var gateway: FakeWindowGateway { harness.gateway }
    private var controller: TilingController { harness.controller }
    private var canvas: TilingSpace { harness.canvas }

    override func setUp() {
        super.setUp()
        harness = ControllerHarness(screens: [Self.main], deathConfirmation: 0)
    }

    /// The two user steps a quarters setup now takes: switch the empty
    /// canvas, then press the key.
    private func tileQuarter(_ slot: Slot) {
        if canvas.state.layout != .quarters {
            controller.handleSwitchLayout(to: .quarters)
        }
        controller.handle(slotKey: slot.key)
    }

    private func tileSixth(_ slot: Slot) {
        if canvas.state.layout != .sixths {
            controller.handleSwitchLayout(to: .sixths)
        }
        controller.handle(slotKey: slot.key)
    }

    func testZeroWindowSwitchAdoptsTheLayoutNarratesAndPushesNoChapter() {
        let receipt = controller.handleSwitchLayout()

        XCTAssertEqual(canvas.state.layout, .sixths)
        XCTAssertEqual(receipt.announcement, "Switched to Sixths.")
        XCTAssertEqual(canvas.notice, "Switched to Sixths.")
        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertTrue(canvas.undoStack.isEmpty, "nothing destructive happened")

        let back = controller.handleSwitchLayout()
        XCTAssertEqual(canvas.state.layout, .quarters)
        XCTAssertEqual(back.announcement, "Switched to Quarters.")
        XCTAssertTrue(canvas.undoStack.isEmpty)
    }

    func testSwitchUntilesEveryOccupantAndKeepsTheGridFractions() {
        let first = harness.addFocusedWindow()
        tileQuarter(.topLeft)
        harness.addFocusedWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        tileQuarter(.topRight)
        harness.addFocusedWindow(frame: CGRect(x: 0, y: 600, width: 800, height: 400))
        tileQuarter(.bottomLeft)

        // Drag Top Left's right edge so the grid is no longer at defaults.
        var echo = gateway.frame(of: first)!
        echo.size.width -= 10
        gateway.simulateChange(first, to: echo)
        var dragged = gateway.frame(of: first)!
        dragged.size.width += 60
        gateway.simulateChange(first, to: dragged)
        controller.mouseLifted()
        let fractions = canvas.grid
        XCTAssertNotEqual(fractions.columnSplit, 0.5, accuracy: 0.001)

        let receipt = controller.handleSwitchLayout()

        XCTAssertEqual(canvas.state.layout, .sixths)
        XCTAssertTrue(canvas.state.occupants.isEmpty, "every tiled window was untiled")
        XCTAssertEqual(canvas.grid, fractions, "a switch never moves a splitter")
        XCTAssertEqual(receipt.announcement, "Switched to Sixths; 3 windows untiled.")
        XCTAssertEqual(
            canvas.notice,
            "Switched to Sixths · 3 windows untiled. Undo from the Tiled menu.")
    }

    func testExpandedWindowUntanglesToSizedFrameOnSwitch() {
        let preTile = CGRect(x: 100, y: 100, width: 600, height: 400)
        let handle = harness.addFocusedWindow(frame: preTile)
        tileQuarter(.topLeft)
        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)
        controller.handleExpandToggle()
        XCTAssertEqual(gateway.frame(of: handle), Self.main.visibleFrame)

        controller.handleSwitchLayout()

        XCTAssertEqual(
            gateway.frame(of: handle), CGRect(x: 100, y: 0, width: 960, height: 540),
            "an expanded window untangles to the quarter footprint")
        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertEqual(canvas.state.layout, .sixths)

        controller.undoLastDisplacement()

        XCTAssertEqual(canvas.state.layout, .quarters, "undo restores the layout")
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft), "undo re-tiles the window")
        XCTAssertFalse(canvas.isExpanded(1), "undo does not re-expand it")
        XCTAssertEqual(
            gateway.frame(of: handle),
            canvas.grid.rect(for: .topLeft, in: canvas.visibleFrame))
    }

    func testUndoRestoresBothWindowsAndThePreviousLayout() {
        harness.addFocusedWindow()
        tileQuarter(.topLeft)
        harness.addFocusedWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        tileQuarter(.topRight)

        controller.handleSwitchLayout()
        XCTAssertEqual(canvas.state.layout, .sixths)
        XCTAssertTrue(canvas.state.occupants.isEmpty)

        controller.undoLastDisplacement()

        XCTAssertEqual(canvas.state.layout, .quarters)
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft))
        XCTAssertNotNil(canvas.state.occupant(of: .topRight))
        XCTAssertTrue(
            canvas.notice?.contains("back to Quarters") == true,
            "the notice names the layout that came back: \(canvas.notice ?? "nil")")
        XCTAssertTrue(
            canvas.notice?.contains("2 windows restored") == true,
            "the notice names the windows that came back: \(canvas.notice ?? "nil")")
    }

    func testUndoAfterReTilingAChapterMemberReturnsTheOldLayout() {
        let first = harness.addFocusedWindow()
        tileQuarter(.topLeft)
        harness.addFocusedWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        tileQuarter(.topRight)
        controller.handleSwitchLayout()

        // Re-tile a chapter member in the new layout before undoing.
        gateway.focused = first
        tileSixth(.topLeft)
        XCTAssertEqual(canvas.state.layout, .sixths)
        XCTAssertNotNil(canvas.state.occupant(of: .sixthTopLeft))

        controller.undoLastDisplacement()

        XCTAssertEqual(canvas.state.layout, .quarters, "the chapter's layout returns")
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft))
        XCTAssertNotNil(canvas.state.occupant(of: .topRight))
        XCTAssertEqual(canvas.state.tiledWindows.count, 2)
    }

    func testOlderChapterAfterAZeroWindowSwitchRestoresItsLayout() {
        harness.addFocusedWindow()
        tileQuarter(.topLeft)
        // Evict the first window with a second top-left request: one
        // quarters chapter, one survivor.
        harness.addFocusedWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        tileQuarter(.topLeft)
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft))
        XCTAssertEqual(canvas.undoStack.count, 1)

        // Evict the survivor: the board empties, and no chapter is added.
        controller.handleEvict()
        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertEqual(canvas.undoStack.count, 1)

        // A zero-window switch pushes nothing, so undo still reaches the
        // older quarters chapter.
        controller.handleSwitchLayout()
        XCTAssertEqual(canvas.state.layout, .sixths)
        XCTAssertEqual(canvas.undoStack.count, 1)

        controller.undoLastDisplacement()

        XCTAssertEqual(canvas.state.layout, .quarters)
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft))
    }

    /// The hotkey switches the cursor's display's canvas; the display
    /// holding focus keeps its layout and windows. The menu's targeted
    /// row still follows focus even with the cursor elsewhere.
    func testSwitchIsScopedToTheCursorDisplay() {
        let other = ScreenInfo(
            id: ScreenID(rawValue: 2),
            frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            name: "Display 2")
        harness.screens = [Self.main, other]
        let left = ScreenID(rawValue: 1)
        let right = ScreenID(rawValue: 2)

        let leftHandle = gateway.addWindow(
            frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        gateway.focused = leftHandle
        controller.handleSwitchLayout(to: .sixths)
        controller.handle(slotKey: .topLeft)
        let rightHandle = gateway.addWindow(
            frame: CGRect(x: 2020, y: 100, width: 800, height: 600))
        gateway.focused = rightHandle
        controller.handle(slotKey: .topRight)

        XCTAssertEqual(controller.canvas(for: TilingSpaceKey(screen: left, space: nil)).state.layout, .sixths)
        XCTAssertEqual(controller.canvas(for: TilingSpaceKey(screen: right, space: nil)).state.layout, .quarters)

        harness.fireCursorMove(to: CGPoint(x: 2500, y: 500))
        controller.handleSwitchLayout()

        XCTAssertEqual(
            controller.canvas(for: TilingSpaceKey(screen: left, space: nil)).state.layout,
            .sixths, "the focused display's canvas keeps its layout")
        XCTAssertEqual(
            controller.canvas(for: TilingSpaceKey(screen: right, space: nil)).state.layout,
            .sixths, "the cursor's display switched")
        XCTAssertTrue(
            controller.canvas(for: TilingSpaceKey(screen: left, space: nil))
                .state.occupants.isEmpty == false,
            "the focused display's canvas keeps its windows")

        // The targeted row follows focus even with the cursor elsewhere.
        gateway.focused = leftHandle
        controller.handleSwitchLayout(to: .quarters)

        XCTAssertEqual(
            controller.canvas(for: TilingSpaceKey(screen: left, space: nil)).state.layout,
            .quarters, "the targeted row follows focus, not the cursor")
        XCTAssertEqual(
            controller.canvas(for: TilingSpaceKey(screen: right, space: nil)).state.layout,
            .sixths, "the targeted row stays scoped to the focused canvas")
    }

    func testSlotKeyNeverSwitchesLayout() {
        harness.addFocusedWindow()
        tileQuarter(.topLeft)

        // A sixths-only key pressed on a quarters canvas is inert: it
        // changes neither occupancy nor layout.
        let before = canvas.state
        let receipt = controller.handle(slotKey: .topMiddle)

        XCTAssertEqual(canvas.state, before)
        XCTAssertEqual(canvas.state.layout, .quarters)
        XCTAssertFalse(receipt.performed)
        XCTAssertTrue(receipt.announcement?.contains("has no slot in Quarters") == true)
    }

    func testSwitchAdoptsTargetLayoutSize() {
        // Sixths -> quarters: every window lands at the quarter
        // footprint, sized the same under either layout.
        let a = harness.addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        tileSixth(.sixthTopLeft)
        let b = harness.addFocusedWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        tileSixth(.sixthTopRight)

        controller.handleSwitchLayout()

        XCTAssertEqual(canvas.state.layout, .quarters)
        XCTAssertEqual(
            gateway.frame(of: a), CGRect(x: 12, y: 0, width: 960, height: 540),
            "the switch always floats at the quarter footprint hung from the window's top edge")
        XCTAssertEqual(
            gateway.frame(of: b), CGRect(x: 900, y: 0, width: 960, height: 540))
        let snapshot = Dictionary(
            uniqueKeysWithValues: (canvas.undoStack.last?.snapshot ?? []).map {
                ($0.slot, $0.preTileFrame)
            })
        XCTAssertEqual(snapshot[.sixthTopLeft], CGRect(x: 12, y: 0, width: 960, height: 540))
        XCTAssertEqual(snapshot[.sixthTopRight], CGRect(x: 900, y: 0, width: 960, height: 540))
    }

    func testUntileAllWritesQuarterSizedFrames() {
        // Untile-all leaves every window at the quarter footprint hung
        // from its own top edge.
        let a = harness.addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        tileSixth(.sixthTopLeft)
        let b = harness.addFocusedWindow(frame: CGRect(x: 40, y: 500, width: 600, height: 300))
        tileSixth(.sixthBottomLeft)

        controller.untileAll()

        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertEqual(
            gateway.frame(of: a), CGRect(x: 12, y: 0, width: 960, height: 540))
        // b's top edge fits, so its top stays and only the bottom rises.
        XCTAssertEqual(
            gateway.frame(of: b), CGRect(x: 40, y: 260, width: 960, height: 540))
        for handle in [a, b] {
            let frame = gateway.frame(of: handle)
            XCTAssertEqual(frame?.height, 540)
            XCTAssertEqual(frame!.width, 960)
        }
        XCTAssertEqual(canvas.displacedCount, 2, "untile-all still covers both windows")
    }
}
