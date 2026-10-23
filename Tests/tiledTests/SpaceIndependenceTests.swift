import AppKit
import CoreGraphics
import XCTest

@testable import tiled

/// Mission Control Space independence: every display's every Space is
/// its own tiling canvas. Swiping to another Space (the three-finger
/// swipe up) never disturbs another Space's layout, occupancy, splitters,
/// undo history, or notices, and screen changes while a Space is hidden
/// are re-asserted when it comes back. Driven through `TilingController`
/// with the fake gateway plus scripted active-Space state.
final class SpaceIndependenceTests: XCTestCase {
    private static let displayID: CGDirectDisplayID = 42
    private static let otherDisplayID: CGDirectDisplayID = 43

    private static let display = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        name: "Display 1",
        displayID: displayID)
    private static let otherDisplay = ScreenInfo(
        id: ScreenID(rawValue: 2),
        frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        name: "Display 2",
        displayID: otherDisplayID)

    private static let spaceA = SpaceID(rawValue: 101)
    private static let spaceB = SpaceID(rawValue: 102)
    private static let spaceC = SpaceID(rawValue: 103)

    private var harness: ControllerHarness!
    private var gateway: FakeWindowGateway { harness.gateway }
    private var controller: TilingController { harness.controller }
    private var currentScreens: [ScreenInfo] {
        get { harness.screens }
        set { harness.screens = newValue }
    }

    override func setUp() {
        super.setUp()
        harness = ControllerHarness(
            screens: [Self.display],
            activeSpaces: [Self.displayID: Self.spaceA],
            deathConfirmation: 0)
    }

    /// This suite's windows start on the display's first slot; the harness
    /// owns the gateway/focus mechanics.
    @discardableResult
    private func addFocusedWindow(
        frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600)
    ) -> WindowHandle {
        harness.addFocusedWindow(frame: frame)
    }

    /// Swipes to `space` on `display`, as the workspace notification
    /// would report it.
    private func switchTo(_ space: SpaceID, on display: CGDirectDisplayID = displayID) {
        gateway.activeSpaces[display] = space
        gateway.simulateSpaceChange()
    }

    /// Asserts a swipe back to `space` writes nothing for `handle` and
    /// leaves it on `frame`: a stale deferred restore would write the old
    /// frame and yank the window off its new slot.
    private func assertSwipeBackLeavesTheNewSlot(
        _ handle: WindowHandle, to space: SpaceID, keeping frame: CGRect
    ) {
        gateway.clearWrites()
        switchTo(space)
        XCTAssertFalse(
            gateway.writes.contains { $0.handle == handle },
            "the swipe back never writes the discarded pre-tile restore")
        XCTAssertEqual(
            gateway.frame(of: handle), frame,
            "the window stays on its new slot instead of being yanked back to the old frame")
    }

    // MARK: Independent canvases

    func testSameSlotCoexistsInTwoSpacesOnOneDisplay() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)

        switchTo(Self.spaceB)
        XCTAssertNil(
            controller.canvas(for: Self.display.id).state.occupant(of: .topLeft),
            "the fresh Space has its own empty occupancy")
        let b = addFocusedWindow()
        controller.handle(slot: .topLeft)

        XCTAssertEqual(controller.canvas(for: Self.display.id).state.occupant(of: .topLeft), b.id)
        let target = GridLayout().rect(for: .topLeft, in: Self.display.visibleFrame)
        XCTAssertEqual(gateway.frame(of: a), target, "the hidden Space keeps its tile")
        XCTAssertEqual(gateway.frame(of: b), target)

        switchTo(Self.spaceA)
        XCTAssertEqual(
            controller.canvas(for: Self.display.id).state.occupant(of: .topLeft), a.id,
            "swiping back restores the first Space's arrangement")
    }

    func testEachSpaceRunsItsOwnLayout() {
        addFocusedWindow()
        controller.handle(slot: .topLeft)

        switchTo(Self.spaceB)
        addFocusedWindow()
        controller.handle(slot: .sixthTopLeft)

        XCTAssertEqual(controller.canvas(for: Self.display.id).state.layout, .sixths)
        switchTo(Self.spaceA)

        XCTAssertEqual(
            controller.canvas(for: Self.display.id).state.layout, .quarters,
            "the first Space kept quarters while the second used sixths")
        XCTAssertNotNil(controller.canvas(for: Self.display.id).state.occupant(of: .topLeft))
        XCTAssertNil(controller.canvas(for: Self.display.id).state.occupant(of: .sixthTopLeft))
    }

    func testLayoutSwitchOnlyDissolvesItsOwnSpace() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = addFocusedWindow()
        controller.handle(slot: .topRight)
        XCTAssertEqual(controller.canvas(for: Self.display.id).state.tiledWindows.count, 2)

        switchTo(Self.spaceB)
        let c = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let d = addFocusedWindow()
        controller.handle(slot: .topRight)
        // An explicit switch resets only this canvas: d is untiled, then c
        // re-tiles into the new layout, and the other Space is untouched.
        gateway.focused = c
        controller.handleSwitchLayout(to: .sixths)
        XCTAssertNotNil(controller.canvas(for: Self.display.id).notice)
        controller.handle(slotKey: .topLeft)

        XCTAssertEqual(controller.canvas(for: Self.display.id).state.layout, .sixths)
        let cID = controller.registeredID(for: c)!
        XCTAssertEqual(
            controller.canvas(for: Self.display.id).state.slot(of: cID), .sixthTopLeft)
        XCTAssertNil(
            controller.registeredID(for: d),
            "the layout switch untiled only this Space's other window")

        switchTo(Self.spaceA)
        XCTAssertEqual(controller.canvas(for: Self.display.id).state.layout, .quarters)
        XCTAssertEqual(controller.canvas(for: Self.display.id).state.occupant(of: .topLeft), a.id)
        XCTAssertEqual(controller.canvas(for: Self.display.id).state.occupant(of: .topRight), b.id)
    }

    func testSameSlotCoexistsAcrossSpacesAndDisplays() {
        currentScreens = [Self.display, Self.otherDisplay]
        gateway.activeSpaces = [
            Self.displayID: Self.spaceA,
            Self.otherDisplayID: Self.spaceA,
        ]
        let left = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let right = addFocusedWindow(
            frame: CGRect(x: 2000, y: 100, width: 800, height: 600))
        controller.handle(slot: .topLeft)

        XCTAssertEqual(controller.canvas(for: Self.display.id).state.occupant(of: .topLeft), left.id)
        XCTAssertEqual(
            controller.canvas(for: Self.otherDisplay.id).state.occupant(of: .topLeft), right.id,
            "the same window-server Space id on two displays still keys two canvases")

        // A layout switch on the right display's Space leaves the left
        // display's same-id canvas alone.
        gateway.focused = right
        controller.handle(slot: .sixthTopLeft)
        XCTAssertEqual(controller.canvas(for: Self.otherDisplay.id).state.layout, .sixths)
        XCTAssertEqual(controller.canvas(for: Self.display.id).state.layout, .quarters)
        XCTAssertEqual(controller.canvas(for: Self.display.id).state.occupant(of: .topLeft), left.id)
    }

    // MARK: Focus and menu scoping

    func testSpaceSwitchReportsTheFocusedCanvasChange() {
        addFocusedWindow()
        controller.handle(slot: .topLeft)

        var reports = 0
        controller.onFocusedSpaceChange = { reports += 1 }

        switchTo(Self.spaceB)
        XCTAssertEqual(reports, 1, "the first callback resolves the starting canvas")
        XCTAssertEqual(
            controller.canvas(for: controller.focusedTilingSpace).state.layout, .sixths,
            "the focused canvas follows the newly visible Space")
        XCTAssertTrue(
            controller.canvas(for: controller.focusedTilingSpace).state.occupants.isEmpty)

        switchTo(Self.spaceB)
        XCTAssertEqual(reports, 1, "re-reporting the same Space is not a canvas change")

        switchTo(Self.spaceA)
        XCTAssertEqual(reports, 2, "swiping back redraws the glyph for the other layout")
        XCTAssertEqual(
            controller.canvas(for: controller.focusedTilingSpace).state.layout, .quarters)
        XCTAssertNotNil(
            controller.canvas(for: controller.focusedTilingSpace).state.occupant(of: .topLeft))
    }

    func testSpaceSwitchOnAnotherDisplayRefreshesTheMenuButNotTheGlyph() {
        currentScreens = [Self.display, Self.otherDisplay]
        gateway.activeSpaces = [
            Self.displayID: Self.spaceA,
            Self.otherDisplayID: Self.spaceB,
        ]
        let left = addFocusedWindow()
        controller.handle(slot: .topLeft)

        var iconReports = 0
        var menuReports = 0
        controller.onFocusedSpaceChange = { iconReports += 1 }
        // Resolve the starting canvas first: an unobserved controller
        // reports the first focus event because it has never compared.
        gateway.simulateFocusChange()
        XCTAssertEqual(iconReports, 1)

        controller.onChange = { menuReports += 1 }

        // The right display swipes to another Space; keyboard focus and
        // the glyph stay on the left display.
        gateway.activeSpaces[Self.otherDisplayID] = Self.spaceC
        gateway.simulateSpaceChange()

        XCTAssertEqual(iconReports, 1, "the focused canvas did not change")
        XCTAssertGreaterThan(menuReports, 0, "the menu aggregates visible canvases")
        XCTAssertEqual(controller.focusedScreen, Self.display.id)
        XCTAssertEqual(controller.focusedTilingSpace.space, Self.spaceA)
        XCTAssertEqual(gateway.focused, left)
    }

    // MARK: Cursor and glyph scoping

    /// Two displays and a window tiled on each, focus on the first.
    private func setUpTwoDisplaysWithFocusOnTheFirst() -> (first: WindowHandle, second: WindowHandle) {
        currentScreens = [Self.display, Self.otherDisplay]
        gateway.activeSpaces = [
            Self.displayID: Self.spaceA,
            Self.otherDisplayID: Self.spaceB,
        ]
        let first = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let second = addFocusedWindow(
            frame: CGRect(x: 2000, y: 100, width: 800, height: 600))
        controller.handle(slot: .topLeft)
        gateway.focused = first
        return (first, second)
    }

    func testCursorMoveToAnotherDisplayFiresTheGlyphRouteOnly() {
        setUpTwoDisplaysWithFocusOnTheFirst()
        var glyphReports = 0
        var menuReports = 0
        controller.onCursorDisplayChange = { glyphReports += 1 }
        controller.onChange = { menuReports += 1 }

        harness.fireCursorMove(to: CGPoint(x: 2500, y: 500))
        XCTAssertEqual(glyphReports, 1, "the first resolution reports")
        XCTAssertEqual(menuReports, 0, "a cursor move is never a full-refresh trigger")

        harness.fireCursorMove(to: CGPoint(x: 3000, y: 500))
        XCTAssertEqual(glyphReports, 1, "a move within one display is silent")
    }

    func testFocusMoveChangesTheMenuKeyButNeverTheGlyphKey() {
        // The feature's premise: the glyph follows the cursor, the menu
        // follows focus. A focus move across displays reports the focus
        // route and leaves the cursor display — the canvas the glyph
        // derives from — exactly where the cursor left it.
        setUpTwoDisplaysWithFocusOnTheFirst()
        harness.fireCursorMove(to: CGPoint(x: 2500, y: 500))
        XCTAssertEqual(controller.cursorTilingSpace.screen, Self.otherDisplay.id)

        var focusReports = 0
        var glyphReports = 0
        controller.onFocusedSpaceChange = { focusReports += 1 }
        controller.onCursorDisplayChange = { glyphReports += 1 }

        gateway.simulateFocusChange()
        XCTAssertEqual(focusReports, 1, "the focused canvas moved")
        XCTAssertEqual(glyphReports, 0, "focus does not drive the glyph route")
        XCTAssertEqual(controller.focusedTilingSpace.screen, Self.display.id)
        XCTAssertEqual(
            controller.cursorTilingSpace.screen, Self.otherDisplay.id,
            "the glyph key stays on the cursor's display")
    }

    func testHiddenSpaceWindowsStayManagedButLeaveTheMenu() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)

        switchTo(Self.spaceB)
        let b = addFocusedWindow()
        controller.handle(slot: .sixthTopLeft)

        XCTAssertEqual(controller.tiledWindowsInfo.map(\.id), [b.id])
        XCTAssertEqual(
            controller.allTiledWindowsInfo().map(\.id), [b.id],
            "hidden-Space windows are not rows in the visible menu")

        // A hidden window still prunes when it closes: management follows
        // the window, not the currently shown Space.
        gateway.kill(a)
        controller.pruneDeadWindows()
        switchTo(Self.spaceA)
        XCTAssertNil(controller.canvas(for: Self.display.id).state.slot(of: a.id))
        XCTAssertEqual(controller.canvas(for: Self.display.id).state.occupants, [:])

        switchTo(Self.spaceB)
        XCTAssertEqual(controller.canvas(for: Self.display.id).state.occupant(of: .sixthTopLeft), b.id)
    }

    // MARK: Per-canvas undo and splitters

    func testUndoHistoryIsPerSpace() {
        let keyA = TilingSpaceKey(screen: Self.display.id, space: Self.spaceA)
        let keyB = TilingSpaceKey(screen: Self.display.id, space: Self.spaceB)
        addFocusedWindow()
        controller.handle(slot: .topLeft)
        let challenger = addFocusedWindow()
        controller.handle(slot: .topLeft)
        XCTAssertFalse(controller.canvas(for: keyA).undoStack.isEmpty)

        switchTo(Self.spaceB)

        XCTAssertTrue(
            controller.canvas(for: keyB).undoStack.isEmpty,
            "a fresh Space has no history")
        let receipt = controller.undoAction()
        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(receipt.announcement, "Nothing to undo: a later change replaced it.")

        switchTo(Self.spaceA)
        XCTAssertFalse(
            controller.canvas(for: keyA).undoStack.isEmpty,
            "the first Space's chapter survived the round trip")
        controller.undoLastDisplacement()
        XCTAssertNotNil(controller.canvas(for: Self.display.id).state.occupant(of: .topLeft))
        XCTAssertNil(controller.canvas(for: Self.display.id).state.slot(of: challenger.id))
    }

    /// M1: a handle resolves to at most one canvas record. A window evicted
    /// on one canvas, re-tiled on another, then restored by the first
    /// canvas's undo must leave exactly one live record, and the menu must
    /// count it once. Both canvases are visible at once (two displays), so
    /// a duplicate is directly observable.
    func testUndoReclaimsAWindowRetiledOnAnotherCanvas() {
        currentScreens = [Self.display, Self.otherDisplay]
        gateway.activeSpaces = [
            Self.displayID: Self.spaceA,
            Self.otherDisplayID: Self.spaceA,
        ]
        let origin = TilingSpaceKey(screen: Self.display.id, space: Self.spaceA)
        let other = TilingSpaceKey(screen: Self.otherDisplay.id, space: Self.spaceA)

        let w = addFocusedWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        controller.handle(slot: .topLeft)
        let challenger = addFocusedWindow(
            frame: CGRect(x: 200, y: 200, width: 500, height: 400))
        controller.handle(slot: .topLeft) // evicts w on the first display

        // The evicted window is moved to the second display and tiled
        // there: a fresh record for the same handle on the other canvas.
        gateway.simulateSilentChange(w, to: CGRect(x: 2000, y: 100, width: 800, height: 600))
        gateway.focused = w
        controller.handle(slot: .topLeft)
        XCTAssertTrue(
            controller.canvas(for: other).records.values.contains { $0.handle == w },
            "the window is tiled on the second canvas")

        // Undoing the eviction returns the window to the canvas it left.
        // Focus the challenger so the focused-key path names the first
        // display's canvas; w itself now lives on the second display.
        gateway.clearWrites()
        gateway.focused = challenger
        controller.undoLastDisplacement()

        let owners = [origin, other].filter { key in
            controller.canvas(for: key).records.values.contains { $0.handle == w }
        }
        XCTAssertEqual(owners, [origin], "a handle resolves to exactly one canvas")
        XCTAssertEqual(
            gateway.writes.filter { $0.handle == w }.count, 1,
            "only the reclaiming canvas writes the moved window")
        XCTAssertEqual(
            controller.allTiledWindowsInfo().count, 1,
            "the window is counted once across the visible canvases")
    }

    /// F5 through the undo claim: undo retiles a window onto the canvas
    /// it left, so the re-place must discard any deferred restore the
    /// window left behind on the canvas it was just untiled from.
    func testUndoRetileDiscardsTheOtherCanvasDeferredRestore() {
        let keyA = TilingSpaceKey(screen: Self.display.id, space: Self.spaceA)
        let keyB = TilingSpaceKey(screen: Self.display.id, space: Self.spaceB)
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let w = addFocusedWindow(frame: original)
        controller.handle(slot: .topLeft)
        addFocusedWindow(frame: CGRect(x: 200, y: 200, width: 500, height: 400))
        controller.handle(slot: .topLeft) // evicts w; A holds the undo chapter
        XCTAssertFalse(controller.canvas(for: keyA).undoStack.isEmpty)

        // Retile w on B, then evict it there while B is hidden: B holds
        // the deferred pre-tile restore.
        switchTo(Self.spaceB)
        gateway.focused = w
        controller.handle(slot: .bottomRight)
        switchTo(Self.spaceA)
        gateway.focused = w
        controller.handleEvict()
        XCTAssertNotNil(
            controller.canvas(for: keyB).deferredRestores[w],
            "the eviction on hidden B deferred w's pre-tile restore")

        // A's undo re-observes and retiles w; the re-place claims the
        // handle and must discard B's deferred restore.
        controller.undoLastDisplacement()
        let aSlot = GridLayout().rect(for: .topLeft, in: Self.display.visibleFrame)
        XCTAssertEqual(
            controller.canvas(for: keyA).state.occupant(of: .topLeft),
            controller.registeredID(for: w),
            "undo retiles the window on A")
        XCTAssertNil(
            controller.canvas(for: keyB).deferredRestores[w],
            "the re-place claim cleared the other canvas's deferred restore")
        XCTAssertEqual(gateway.frame(of: w), aSlot)

        assertSwipeBackLeavesTheNewSlot(w, to: Self.spaceB, keeping: aSlot)
    }

    func testRefusedExpandKeepsTheOldCanvasDeferredRestore() {
        let keyA = TilingSpaceKey(screen: Self.display.id, space: Self.spaceA)
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let w = addFocusedWindow(frame: original)
        controller.handle(slot: .topLeft)

        switchTo(Self.spaceB)
        gateway.focused = w
        controller.handleEvict()
        XCTAssertNotNil(
            controller.canvas(for: keyA).deferredRestores[w],
            "the eviction on hidden A deferred w's pre-tile restore")

        gateway.focused = w
        gateway.refuseNextWrites(w)
        controller.handleExpandToggle()

        XCTAssertNotNil(
            controller.canvas(for: keyA).deferredRestores[w],
            "a refused expand did not claim the window, so A's restore is still live")
    }

    func testRefusedUndoRetileKeepsTheOtherCanvasDeferredRestore() {
        let keyA = TilingSpaceKey(screen: Self.display.id, space: Self.spaceA)
        let keyB = TilingSpaceKey(screen: Self.display.id, space: Self.spaceB)
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let w = addFocusedWindow(frame: original)
        controller.handle(slot: .topLeft)
        addFocusedWindow(frame: CGRect(x: 200, y: 200, width: 500, height: 400))
        controller.handle(slot: .topLeft) // evicts w; A holds the undo chapter
        XCTAssertFalse(controller.canvas(for: keyA).undoStack.isEmpty)

        // Retile w on B, then evict it there while B is hidden: B holds
        // the deferred pre-tile restore.
        switchTo(Self.spaceB)
        gateway.focused = w
        controller.handle(slot: .bottomRight)
        switchTo(Self.spaceA)
        gateway.focused = w
        controller.handleEvict()
        XCTAssertNotNil(
            controller.canvas(for: keyB).deferredRestores[w],
            "the eviction on hidden B deferred w's pre-tile restore")

        // A's undo re-places w, but its app refuses: w never returned to
        // A, so B's restore is still live and must not be discarded.
        gateway.refuseNextWrites(w)
        controller.undoLastDisplacement()
        XCTAssertTrue(
            controller.canvas(for: keyA).state.occupants.isEmpty,
            "the refused re-place did not tile w on A")
        XCTAssertNotNil(
            controller.canvas(for: keyB).deferredRestores[w],
            "a refused re-place did not claim or discard B's deferred restore")

        switchTo(Self.spaceB)
        XCTAssertEqual(
            gateway.frame(of: w), original,
            "B's pre-tile restore still lands after the refused undo")
    }

    func testSplittersAreIndependentPerSpace() {
        let handle = addFocusedWindow()
        controller.handle(slot: .topLeft)
        // Drag TL's right edge: echo tick, then escape.
        var echo = gateway.frame(of: handle)!
        echo.size.width -= 10
        gateway.simulateChange(handle, to: echo)
        var dragged = gateway.frame(of: handle)!
        dragged.size.width -= 60
        gateway.simulateChange(handle, to: dragged)
        let moved = controller.canvas(for: Self.display.id).grid.columnSplit
        XCTAssertNotEqual(moved, 0.5)

        switchTo(Self.spaceB)
        XCTAssertEqual(
            controller.canvas(for: Self.display.id).grid, GridLayout(),
            "the second Space starts from the default splitters")

        switchTo(Self.spaceA)
        XCTAssertEqual(
            controller.canvas(for: Self.display.id).grid.columnSplit, moved, accuracy: 0.001,
            "the first Space kept the dragged splitter")
    }

    func testMouseUpReassertStaysOnTheDraggedWindowsCanvas() {
        // A resize's settle reasserts the dragged window's canvas alone:
        // another display's window and splitters are never touched, even
        // though its canvas is visible at the same time.
        currentScreens = [Self.display, Self.otherDisplay]
        gateway.activeSpaces = [
            Self.displayID: Self.spaceA,
            Self.otherDisplayID: Self.spaceA,
        ]
        let left = addFocusedWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        controller.handle(slot: .topLeft)
        let right = addFocusedWindow(
            frame: CGRect(x: 2000, y: 100, width: 800, height: 600))
        controller.handle(slot: .topLeft)

        let rightFrame = gateway.frame(of: right)!
        let rightGrid = controller.canvas(for: Self.otherDisplay.id).grid

        // Drag the left display's window's edge, then release.
        var echo = gateway.frame(of: left)!
        echo.size.width -= 10
        gateway.simulateChange(left, to: echo)
        var dragged = gateway.frame(of: left)!
        dragged.size.width -= 60
        gateway.simulateChange(left, to: dragged)
        controller.mouseLifted()

        XCTAssertEqual(
            gateway.frame(of: right), rightFrame,
            "a resize on one display never moves another display's window")
        XCTAssertEqual(
            controller.canvas(for: Self.otherDisplay.id).grid, rightGrid,
            "the splitter change stays on the dragged window's canvas")
    }

    func testCloseInHiddenSpaceReflowsOnReturnWithoutWritingFirst() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let b = addFocusedWindow()
        controller.handle(slot: .bottomLeft)

        switchTo(Self.spaceB)
        let keyA = TilingSpaceKey(screen: Self.display.id, space: Self.spaceA)
        let frameBefore = gateway.frame(of: b)!
        gateway.kill(a)
        controller.pruneDeadWindows()

        XCTAssertEqual(
            controller.canvas(for: keyA).state.slot(of: b.id), .leftHalf,
            "the freed cells reflow in hidden-state logically")
        XCTAssertNil(
            controller.canvas(for: keyA).error,
            "a deferred reflow is not narrated as an app refusal")
        XCTAssertEqual(
            gateway.frame(of: b), frameBefore,
            "the hidden canvas is not written: an off-Space resize can pull the window forward")

        switchTo(Self.spaceA)
        XCTAssertEqual(
            gateway.frame(of: b),
            GridLayout().rect(for: .leftHalf, in: Self.display.visibleFrame),
            "the deferred reflow is written when the Space becomes visible")
    }

    // MARK: Display-change reassertion

    func testTileOnAHiddenSpaceDefersAndStandsForReconciliation() {
        // A tiled window's own canvas wins even while hidden: asking it
        // to move to another slot must not write the off-Space window
        // (the write could pull it onto the visible Space). The deferred
        // placement stands and reconciles when the Space returns, and it
        // is narrated as a deferral — never as an app refusal.
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let hiddenFrame = gateway.frame(of: a)!

        switchTo(Self.spaceB)
        gateway.focused = a
        let keyA = TilingSpaceKey(screen: Self.display.id, space: Self.spaceA)

        let receipt = controller.handle(slot: .topRight)

        XCTAssertEqual(
            gateway.frame(of: a), hiddenFrame,
            "a hidden canvas is never written in the dark")
        XCTAssertEqual(
            controller.canvas(for: keyA).state.slot(of: a.id), .topRight,
            "the deferred placement stands rather than rolling back")
        XCTAssertTrue(receipt.performed, "a deferral is never a failure")
        XCTAssertEqual(
            receipt.announcement,
            "That Space isn't visible yet: the change will apply when you return to it.")
        XCTAssertTrue(
            controller.isMarkedStale(keyA),
            "the deferred write marks the hidden canvas stale for the swipe back")

        // Swiping back reconciles the retained placement, exactly like a
        // deferred reflow.
        switchTo(Self.spaceA)
        XCTAssertEqual(
            gateway.frame(of: a),
            GridLayout().rect(for: .topRight, in: Self.display.visibleFrame),
            "the deferred placement lands when the Space becomes visible")
    }

    /// M3: "the window server cannot name the visible Space" is not the
    /// same as "a different, known Space is visible". A Space-table
    /// hiccup on the canvas's own display leaves the user looking at that
    /// canvas, so the placement applies instead of being deferred
    /// off-Space — no write skipped, no deferral narrated, nothing
    /// retained for a swipe back that may never come. A known different
    /// Space still defers (the hidden test above).
    func testAnUnnameableActiveSpaceReadDoesNotDeferTheVisibleCanvas() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)

        // The Space table hiccups: the display's active Space can no
        // longer be named, though the canvas shown is still Space A.
        gateway.activeSpaces = [:]

        let receipt = controller.handle(slot: .topRight)

        let keyA = TilingSpaceKey(screen: Self.display.id, space: Self.spaceA)
        XCTAssertEqual(
            gateway.frame(of: a),
            GridLayout().rect(for: .topRight, in: Self.display.visibleFrame),
            "an unknown Space read is not a hidden canvas: the placement is written")
        XCTAssertTrue(
            receipt.announcement == nil,
            "an unknown Space read is not a deferral: nothing is narrated")
        XCTAssertEqual(
            controller.canvas(for: keyA).state.slot(of: a.id), .topRight,
            "the placement stands on its canvas")
        XCTAssertTrue(
            controller.canvas(for: keyA).deferredRequests.isEmpty,
            "no deferral is retained for a canvas the user can see")
    }

    /// A retained request belongs to the canvas it was made on: while
    /// another canvas is visible it is never written there, and it does
    /// not leak across canvases.
    func testDeferredRequestDoesNotLeakToAnotherCanvas() {
        let keyB = TilingSpaceKey(screen: Self.display.id, space: Self.spaceB)
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        let aTiled = gateway.frame(of: a)!

        // Space B is visible and holds its own window.
        switchTo(Self.spaceB)
        let b = addFocusedWindow(frame: CGRect(x: 300, y: 300, width: 400, height: 300))
        controller.handle(slot: .topRight)
        let bTiled = gateway.frame(of: b)!

        // Expanding A while its canvas is hidden defers and retains.
        gateway.focused = a
        let receipt = controller.handleExpandToggle()

        XCTAssertEqual(gateway.frame(of: a), aTiled, "hidden A is never written")
        XCTAssertTrue(receipt.performed, "a deferral is never a failure")
        XCTAssertEqual(
            receipt.announcement,
            "That Space isn't visible yet: the change will apply when you return to it.")
        XCTAssertEqual(
            gateway.frame(of: b), bTiled,
            "the deferred request for A is never applied to the visible B")
        XCTAssertNil(
            controller.canvas(for: keyB).state.slot(of: a.id),
            "A's window never leaks onto B's canvas")

        // The request lands on its own canvas when A returns.
        switchTo(Self.spaceA)
        XCTAssertEqual(
            gateway.frame(of: a), Self.display.visibleFrame,
            "the retained expansion lands on A when it becomes visible")
    }

    /// A stale canvas whose visible frame is degenerate writes nothing on
    /// the swipe back (the reassert early-returns), so its stale mark must
    /// survive: clearing it here would drop the deferred reassert and the
    /// placement would never land.
    func testDegenerateVisibleFrameKeepsAStaleCanvasMarkedForRetry() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)

        // Move the window while its Space is hidden: the deferred write
        // marks the canvas stale for the swipe back.
        switchTo(Self.spaceB)
        gateway.focused = a
        controller.handle(slot: .topRight)

        // The display reports a degenerate visible frame. Swiping back
        // reasserts nothing and must leave the mark in place.
        let degenerate = ScreenInfo(
            id: Self.display.id,
            frame: .zero,
            visibleFrame: .zero,
            name: Self.display.name,
            displayID: Self.displayID)
        currentScreens = [degenerate]
        switchTo(Self.spaceA)

        // Geometry returns with no screen-change notification, so nothing
        // re-marks the canvas: only the retained mark can drive the retry.
        currentScreens = [Self.display]
        switchTo(Self.spaceB)
        switchTo(Self.spaceA)

        XCTAssertEqual(
            gateway.frame(of: a),
            GridLayout().rect(for: .topRight, in: Self.display.visibleFrame),
            "the retained stale mark lands the deferred placement on the next swipe back")
    }

    /// A reassert with real geometry writes, and clearing the mark then is
    /// correct: the canvas does not latch stale and reassert forever. The
    /// app moving the window afterwards is left alone on the next swipe
    /// back because no stale mark remains.
    func testNormalSwipeBackReassertClearsTheStaleMark() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)

        switchTo(Self.spaceB)
        gateway.focused = a
        controller.handle(slot: .topRight)

        // Swipe back with real geometry: the reassert writes and clears.
        switchTo(Self.spaceA)
        let target = GridLayout().rect(for: .topRight, in: Self.display.visibleFrame)
        XCTAssertEqual(gateway.frame(of: a), target)

        // The app moves the window off its tile. No stale mark remains, so
        // a swipe away and back must not drag it back to the tile.
        let movedByApp = target.offsetBy(dx: 40, dy: 30)
        gateway.simulateSilentChange(a, to: movedByApp)
        switchTo(Self.spaceB)
        switchTo(Self.spaceA)
        XCTAssertEqual(
            gateway.frame(of: a), movedByApp,
            "a cleared stale mark does not reassert an app-moved window")
    }

    func testHiddenSpaceEvictionDefersTheRestoreAndReconcilesOnReturn() {
        // Three windows tiled on Space A, then the user swipes to B and
        // issues a request that evicts two of them. The restores must not
        // drag those windows through Mission Control while A is hidden;
        // they land on A when the user swipes back.
        let aFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let dFrame = CGRect(x: 200, y: 200, width: 500, height: 400)
        let a = addFocusedWindow(frame: aFrame)
        controller.handle(slot: .topLeft)
        let d = addFocusedWindow(frame: dFrame)
        controller.handle(slot: .bottomLeft)
        let e = addFocusedWindow(frame: CGRect(x: 300, y: 300, width: 400, height: 300))
        controller.handle(slot: .bottomRight)

        // The user swipes away; a request on the (hidden) Space A evicts
        // two windows to make room for e.
        switchTo(Self.spaceB)
        gateway.focused = e
        let aTiled = gateway.frame(of: a)!
        let dTiled = gateway.frame(of: d)!
        gateway.clearWrites()
        controller.handle(slot: .leftHalf)

        XCTAssertFalse(
            gateway.writes.contains { $0.handle == a || $0.handle == d },
            "a hidden Space never drags its evicted windows through Mission Control")
        XCTAssertEqual(
            gateway.frame(of: a), aTiled,
            "a deferred restore leaves the window where it was, not blind-written")
        XCTAssertEqual(gateway.frame(of: d), dTiled)

        switchTo(Self.spaceA)
        XCTAssertEqual(gateway.frame(of: a), aFrame, "the deferred restore lands on return")
        XCTAssertEqual(gateway.frame(of: d), dFrame)
    }

    /// F5: untiling on a hidden canvas defers the window's pre-tile
    /// restore there. If the same window is retiled on another canvas
    /// before the first returns, claiming the handle must discard the
    /// stale restore everywhere; otherwise the swipe back writes the old
    /// frame and pulls the window off its new slot.
    func testRetileOnAnotherCanvasDiscardsTheOldCanvasDeferredRestore() {
        let keyA = TilingSpaceKey(screen: Self.display.id, space: Self.spaceA)
        let keyB = TilingSpaceKey(screen: Self.display.id, space: Self.spaceB)
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let a = addFocusedWindow(frame: original)
        controller.handle(slot: .topLeft)
        let b = addFocusedWindow(frame: CGRect(x: 200, y: 200, width: 500, height: 400))
        controller.handle(slot: .bottomLeft)
        let requester = addFocusedWindow(frame: CGRect(x: 300, y: 300, width: 400, height: 300))
        controller.handle(slot: .bottomRight)

        // On the hidden canvas, the requester's left-half request evicts
        // both left-side windows. Their pre-tile restores defer because A
        // is not visible.
        switchTo(Self.spaceB)
        gateway.focused = requester
        controller.handle(slot: .leftHalf)
        XCTAssertNotNil(
            controller.canvas(for: keyA).deferredRestores[a],
            "the eviction on hidden A deferred a's pre-tile restore")
        XCTAssertNotNil(
            controller.canvas(for: keyA).deferredRestores[b],
            "the unrelated eviction's restore stays deferred")

        // Retile the same handle on the visible B before A returns.
        gateway.focused = a
        controller.handle(slot: .bottomRight)
        guard let retiledID = controller.registeredID(for: a) else {
            return XCTFail("the retile on B registered the handle")
        }
        let bSlot = GridLayout().rect(for: .bottomRight, in: Self.display.visibleFrame)
        XCTAssertEqual(controller.canvas(for: keyB).state.slot(of: retiledID), .bottomRight)
        XCTAssertEqual(gateway.frame(of: a), bSlot)
        XCTAssertNil(
            controller.canvas(for: keyA).deferredRestores[a],
            "claiming the handle cleared the old canvas's deferred restore")
        XCTAssertNotNil(
            controller.canvas(for: keyA).deferredRestores[b],
            "only the claimed handle's restore is discarded")

        // Returning to A must not write the stale pre-tile frame: the
        // window belongs to B's slot now.
        assertSwipeBackLeavesTheNewSlot(a, to: Self.spaceA, keeping: bSlot)
        XCTAssertEqual(controller.canvas(for: keyB).state.slot(of: retiledID), .bottomRight)
    }

    /// F5 through Expand: the toggle claims the handle for the focused
    /// canvas even though it does not assign a slot. A deferred restore
    /// left on another canvas must not fire on the swipe back and write
    /// the old frame over the expanded one.
    func testExpandClaimsAHandleAndDiscardsTheOldCanvasDeferredRestore() {
        let keyA = TilingSpaceKey(screen: Self.display.id, space: Self.spaceA)
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let w = addFocusedWindow(frame: original)
        controller.handle(slot: .topLeft)

        switchTo(Self.spaceB)
        gateway.focused = w
        controller.handleEvict()
        XCTAssertNotNil(
            controller.canvas(for: keyA).deferredRestores[w],
            "the eviction on hidden A deferred w's pre-tile restore")

        gateway.focused = w
        controller.handleExpandToggle()
        let expanded = controller.canvas(for: keyA).visibleFrame
        XCTAssertEqual(gateway.frame(of: w), expanded, "the window is expanded on B")

        XCTAssertNil(
            controller.canvas(for: keyA).deferredRestores[w],
            "expanding the handle on B must discard A's stale pre-tile restore")
        assertSwipeBackLeavesTheNewSlot(w, to: Self.spaceA, keeping: expanded)
    }

    func testRefusedFirstTilingKeepsTheOldCanvasDeferredRestore() {
        let keyA = TilingSpaceKey(screen: Self.display.id, space: Self.spaceA)
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let w = addFocusedWindow(frame: original)
        controller.handle(slot: .topLeft)
        let tiled = gateway.frame(of: w)!

        switchTo(Self.spaceB)
        gateway.focused = w
        controller.handleEvict()
        XCTAssertNotNil(
            controller.canvas(for: keyA).deferredRestores[w],
            "the eviction on hidden A deferred w's pre-tile restore")

        gateway.refuseNextWrites(w)
        controller.handle(slot: .topRight)
        XCTAssertNotNil(
            controller.canvas(for: keyA).deferredRestores[w],
            "a refused first tiling did not claim the handle, so A's restore is still live")
        XCTAssertEqual(gateway.frame(of: w), tiled, "the refusal changed nothing")

        switchTo(Self.spaceA)
        XCTAssertEqual(
            gateway.frame(of: w), original,
            "the deferred pre-tile restore still lands on the swipe back")
    }

    func testScreenChangeWhileHiddenReassertsWhenTheSpaceReturns() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)

        // Resolution changes while the user is on another Space: the
        // hidden canvas must not be written in the dark.
        switchTo(Self.spaceB)
        let resized = ScreenInfo(
            id: Self.display.id,
            frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
            visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 720),
            name: Self.display.name,
            displayID: Self.displayID)
        currentScreens = [resized]
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        switchTo(Self.spaceA)
        XCTAssertEqual(
            gateway.frame(of: a),
            GridLayout().rect(for: .topLeft, in: resized.visibleFrame),
            "swiping back re-asserts the hidden canvas against the new bounds")
    }
}
