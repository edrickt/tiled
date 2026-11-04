import XCTest
@testable import tiled

/// macOS native fullscreen (e.g. Firefox presenting a PowerPoint) must
/// never read as a user gesture: the transition's frames arrive while
/// the clicked button's press evidence is fresh, or stream as an
/// animation with the button up. A translation-shaped frame starts a
/// title-bar drag the click's mouse-up decides as a drag-out (untiling
/// the window); a resize-shaped frame commits fullscreen geometry into
/// the splitters and arms a reassert reconciled from the fullscreen
/// achieved frame (corrupting every tile on the canvas).
///
/// Fullscreen-sized frames are never user drags: the tracker swallows
/// them (baseline only, no commit, no track, no decision), drag-end
/// drops a fullscreen landing silently, and resize commits require the
/// hand (button down).
final class FullscreenTests: XCTestCase {
    /// Display where the screen and the visible frame differ by a menu
    /// bar and Dock strip, so a true fullscreen frame is separable from
    /// an expanded (visible-frame-covering) one.
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 950),
        name: "Display 1")

    private var harness: ControllerHarness!
    private var gateway: FakeWindowGateway { harness.gateway }
    private var controller: TilingController { harness.controller }
    private var canvas: TilingSpace { harness.canvas }

    override func setUp() {
        super.setUp()
        harness = ControllerHarness(screens: [Self.screen], deathConfirmation: 0)
        controller.onChange = {}
    }

    /// Tiles two windows side by side and settles their placement echoes,
    /// returning the tiled frames and handles. Win1 is the one that goes
    /// fullscreen.
    @discardableResult
    private func tilePair() -> (
        win1: WindowHandle, win2: WindowHandle, frame1: CGRect, frame2: CGRect
    ) {
        let win1 = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        gateway.focused = win1
        controller.handle(slot: .topLeft)
        let frame1 = gateway.frame(of: win1)!
        gateway.simulateChange(win1, to: frame1) // settle the placement echo

        let win2 = gateway.addWindow(frame: CGRect(x: 900, y: 100, width: 400, height: 300))
        gateway.focused = win2
        controller.handle(slot: .topRight)
        let frame2 = gateway.frame(of: win2)!
        gateway.simulateChange(win2, to: frame2) // settle the placement echo
        return (win1, win2, frame1, frame2)
    }

    func testFullscreenJumpKeepsTheSlotAndTheSplitters() {
        let pair = tilePair()
        let gridBefore = canvas.grid

        // Click the fullscreen button: press inside the tiled window,
        // then the window jumps to the full screen in one AX tick.
        controller.mousePressed(at: CGPoint(x: pair.frame1.midX, y: pair.frame1.midY))
        gateway.simulateChange(pair.win1, to: Self.screen.frame)
        controller.mouseLifted()

        XCTAssertEqual(
            canvas.state.slot(of: 1), .topLeft,
            "a fullscreen jump is never a drag-out")
        XCTAssertEqual(canvas.grid, gridBefore, "fullscreen geometry never reaches the splitters")
        XCTAssertEqual(
            gateway.frame(of: pair.win1), Self.screen.frame,
            "the presentation is never yanked back to its tile")
        XCTAssertEqual(
            gateway.frame(of: pair.win2), pair.frame2,
            "the neighbour keeps its tile while the window is fullscreen")
        XCTAssertEqual(canvas.state.slot(of: 2), .topRight)
    }

    func testFullscreenAnimationWithButtonUpCommitsNoSplitters() {
        harness = ControllerHarness(
            screens: [Self.screen], deathConfirmation: 0, isMouseDown: { false })
        controller.onChange = {}
        let pair = tilePair()
        let gridBefore = canvas.grid

        // The native transition animates with the button already up:
        // growing resize-shaped intermediates, then the fullscreen frame.
        var growing = pair.frame1
        growing.size.width += 200
        growing.size.height += 20
        growing.origin.y -= 20
        gateway.simulateChange(pair.win1, to: growing)
        gateway.simulateChange(pair.win1, to: Self.screen.frame)
        controller.mouseLifted()

        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)
        XCTAssertEqual(
            canvas.grid, gridBefore,
            "animation intermediates with the button up never move splitters")
        XCTAssertEqual(gateway.frame(of: pair.win1), Self.screen.frame)
    }

    func testDragEndWithFullscreenAchievedDropsTheResize() {
        // An edge drag is genuinely in flight (button down, splitters
        // moving) when the window goes fullscreen before release. The
        // last AX tick is still an intermediate, so pending survives the
        // swallow; but the drag-end reads the live frame, which is
        // already the presentation. Reconciling splitters from it would
        // corrupt the canvas and mapping tile rects would yank the
        // presentation back, so the decision drops. The hand's own
        // splitter moves stand; only the fullscreen reconcile is refused.
        harness = ControllerHarness(
            screens: [Self.screen], deathConfirmation: 0, isMouseDown: { true })
        controller.onChange = {}
        let pair = tilePair()

        var echo = pair.frame1
        echo.size.width -= 10
        gateway.simulateChange(pair.win1, to: echo)
        var dragged = pair.frame1
        dragged.size.width -= 60
        gateway.simulateChange(pair.win1, to: dragged)
        let gridAfterDrag = canvas.grid
        XCTAssertNotEqual(gridAfterDrag.columnSplit, 0.5, "the live drag moved the splitter")

        // The animation finished without delivering a final AX tick.
        gateway.simulateSilentChange(pair.win1, to: Self.screen.frame)
        controller.mouseLifted()

        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)
        XCTAssertEqual(
            canvas.grid, gridAfterDrag,
            "the hand's splitter moves stand; the fullscreen reconcile drops")
        XCTAssertEqual(
            gateway.frame(of: pair.win1), Self.screen.frame,
            "the presentation is never yanked back to its tile")
    }

    func testLeavingFullscreenReturnsToTheTile() {
        let pair = tilePair()

        controller.mousePressed(at: CGPoint(x: pair.frame1.midX, y: pair.frame1.midY))
        gateway.simulateChange(pair.win1, to: Self.screen.frame)
        controller.mouseLifted()
        // Exiting restores the tile's own pixels; the state never moved.
        gateway.simulateChange(pair.win1, to: pair.frame1)

        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)
        XCTAssertEqual(canvas.state.slot(of: 2), .topRight)
        XCTAssertEqual(gateway.frame(of: pair.win1), pair.frame1)
        XCTAssertEqual(gateway.frame(of: pair.win2), pair.frame2)
    }
}
