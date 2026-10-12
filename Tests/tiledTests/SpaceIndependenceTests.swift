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

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!
    private var currentScreens: [ScreenInfo] = []

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        currentScreens = [Self.display]
        gateway.activeSpaces = [Self.displayID: Self.spaceA]
        controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [self] in currentScreens },
            deathConfirmation: 0)
    }

    @discardableResult
    private func addFocusedWindow(
        frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600)
    ) -> WindowHandle {
        let handle = gateway.addWindow(frame: frame)
        gateway.focused = handle
        return handle
    }

    /// Swipes to `space` on `display`, as the workspace notification
    /// would report it.
    private func switchTo(_ space: SpaceID, on display: CGDirectDisplayID = displayID) {
        gateway.activeSpaces[display] = space
        gateway.simulateSpaceChange()
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

        XCTAssertEqual(controller.canvas(for: Self.display.id).state.activeLayout, .sixths)
        switchTo(Self.spaceA)

        XCTAssertEqual(
            controller.canvas(for: Self.display.id).state.activeLayout, .quarters,
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
        // The cross-layout request resets only this canvas: d is untiled,
        // c retiles into the new layout, and the other Space is untouched.
        gateway.focused = c
        controller.handle(slot: .sixthTopLeft)

        XCTAssertEqual(controller.canvas(for: Self.display.id).state.activeLayout, .sixths)
        XCTAssertEqual(controller.canvas(for: Self.display.id).state.slot(of: c.id), .sixthTopLeft)
        XCTAssertNil(
            controller.canvas(for: Self.display.id).state.slot(of: d.id),
            "the layout switch untiled only this Space's other window")
        XCTAssertNotNil(controller.canvas(for: Self.display.id).notice)

        switchTo(Self.spaceA)
        XCTAssertEqual(controller.canvas(for: Self.display.id).state.activeLayout, .quarters)
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
        XCTAssertEqual(controller.canvas(for: Self.otherDisplay.id).state.activeLayout, .sixths)
        XCTAssertEqual(controller.canvas(for: Self.display.id).state.activeLayout, .quarters)
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
            controller.canvas(for: controller.focusedTilingSpace).state.activeLayout, .sixths,
            "the focused canvas follows the newly visible Space")
        XCTAssertTrue(
            controller.canvas(for: controller.focusedTilingSpace).state.occupants.isEmpty)

        switchTo(Self.spaceB)
        XCTAssertEqual(reports, 1, "re-reporting the same Space is not a canvas change")

        switchTo(Self.spaceA)
        XCTAssertEqual(reports, 2, "swiping back redraws the glyph for the other layout")
        XCTAssertEqual(
            controller.canvas(for: controller.focusedTilingSpace).state.activeLayout, .quarters)
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

        var feedbacks: [TilingController.Feedback] = []
        controller.onFeedback = { feedbacks.append($0) }
        switchTo(Self.spaceB)

        XCTAssertTrue(
            controller.canvas(for: keyB).undoStack.isEmpty,
            "a fresh Space has no history")
        controller.undoLastDisplacement()
        guard case .nothingToUndo = feedbacks.first else {
            return XCTFail("expected .nothingToUndo in the fresh Space, got \(feedbacks)")
        }

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
        addFocusedWindow(frame: CGRect(x: 200, y: 200, width: 500, height: 400))
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
        gateway.clearWrites()
        controller.undoLastDisplacement(on: Self.display.id)

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
        var feedbacks: [TilingController.Feedback] = []
        controller.onFeedback = { feedbacks.append($0) }

        controller.handle(slot: .topRight)

        XCTAssertEqual(
            gateway.frame(of: a), hiddenFrame,
            "a hidden canvas is never written in the dark")
        XCTAssertEqual(
            controller.canvas(for: keyA).state.slot(of: a.id), .topRight,
            "the deferred placement stands rather than rolling back")
        guard case .deferred = feedbacks.first else {
            return XCTFail("expected .deferred, got \(feedbacks)")
        }

        // Swiping back reconciles the retained placement, exactly like a
        // deferred reflow.
        switchTo(Self.spaceA)
        XCTAssertEqual(
            gateway.frame(of: a),
            GridLayout().rect(for: .topRight, in: Self.display.visibleFrame),
            "the deferred placement lands when the Space becomes visible")
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
        var feedbacks: [TilingController.Feedback] = []
        controller.onFeedback = { feedbacks.append($0) }
        gateway.focused = a
        controller.handleExpandToggle()

        XCTAssertEqual(gateway.frame(of: a), aTiled, "hidden A is never written")
        guard case .deferred = feedbacks.first else {
            return XCTFail("expected .deferred, got \(feedbacks)")
        }
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
        XCTAssertEqual(gateway.frame(of: a), aFrame, "the parked restore lands on return")
        XCTAssertEqual(gateway.frame(of: d), dFrame)
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
