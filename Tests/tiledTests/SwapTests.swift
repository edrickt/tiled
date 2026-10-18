import XCTest
@testable import tiled

/// Tile displacement through `TilingController.handle`: a tiled
/// requester's way is cleared without untangling anyone. A blocker that
/// *contains* the target with a clean leftover steps aside into it (the
/// report's example); any other single blocker swaps into the vacated
/// tile. Pins both end to end: the request is honored, the displaced
/// window keeps its tiling, and undo puts everything back.
final class SwapTests: XCTestCase {
    /// Deterministic display: written rects are checked against this
    /// rect, never the host Mac's screen.
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Display 1")

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!

    /// The canvas the test's single display tiles onto: reads go through
    /// the same accessor actions do.
    private var canvas: TilingSpace { controller.canvas(for: controller.focusedTilingSpace) }

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [Self.screen] })
    }

    /// The report's setup: top-left and bottom-left sixths plus the right
    /// two-thirds, tiled in focus order (ids 1, 2, 3).
    private func tileSixthsSession() -> (a: WindowHandle, b: WindowHandle, c: WindowHandle) {
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .sixthTopLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .sixthBottomLeft)
        let c = gateway.addWindow(frame: CGRect(x: 1200, y: 100, width: 500, height: 400))
        gateway.focused = c
        controller.handle(slot: .sixthsRightTwoThirds)
        return (a, b, c)
    }

    private func expectedRect(_ slot: Slot, for handle: WindowHandle) -> CGRect {
        controller.canvas(for: Self.screen.id).grid.rect(
            for: slot, in: Self.screen.visibleFrame)
    }

    func testRequestInsideABlockerStepsTheBlockerAside() {
        let (a, b, c) = tileSixthsSession()

        // Tile the top-left sixth into the middle third: the middle
        // third sits inside the right two-thirds, whose leftover — the
        // right third — is a clean slot. The two-thirds window steps
        // aside into it instead of trading tiles across the screen, and
        // the vacated top-left sixth flows down into the bottom-left
        // sixth via reflow.
        gateway.focused = a
        controller.handle(slot: .sixthMiddle)

        XCTAssertEqual(canvas.state.slot(of: 1), .sixthMiddle)
        XCTAssertEqual(
            canvas.state.slot(of: 3), .sixthRight,
            "the containing blocker steps into its own leftover")
        XCTAssertEqual(canvas.state.slot(of: 2), .sixthLeft, "the bystander absorbs the vacated tile")
        XCTAssertEqual(canvas.state.tiledWindows.count, 3, "nobody was untiled")
        XCTAssertEqual(
            gateway.frame(of: a), expectedRect(.sixthMiddle, for: a))
        XCTAssertEqual(
            gateway.frame(of: c), expectedRect(.sixthRight, for: c))
    }

    func testStepAsideNoticeNamesDisplacedAppAndUndo() {
        let (a, _, _) = tileSixthsSession()

        gateway.focused = a
        controller.handle(slot: .sixthMiddle)

        XCTAssertFalse(canvas.undoStack.isEmpty)
        XCTAssertTrue(
            canvas.notice?.contains("TestApp") ?? false,
            "the notice names the displaced app")
        XCTAssertTrue(
            canvas.notice?.contains("Right Third") ?? false,
            "the notice names the displaced window's landing tile")
        XCTAssertTrue(
            canvas.notice?.contains("Z") ?? false,
            "the notice offers the undo")
    }

    func testSwapLeavesFocusOnDisplacedWindow() {
        // The report's follow-up: right half + top-left quad + bottom-left
        // quad; tiling the top-left quad into the right half swaps with
        // the half window, and focus follows the half window into the
        // tile it landed in.
        let a = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = b
        controller.handle(slot: .bottomLeft)
        let c = gateway.addWindow(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        gateway.focused = c
        controller.handle(slot: .rightHalf)

        gateway.focused = a
        controller.handle(slot: .rightHalf)

        XCTAssertEqual(canvas.state.slot(of: 1), .rightHalf)
        XCTAssertEqual(canvas.state.slot(of: 3), .topLeft)
        XCTAssertEqual(
            gateway.focusCalls.last, c,
            "focus follows the displaced window, not the requester")
        XCTAssertEqual(gateway.focused, c)
    }

    func testEvictionKeepsFocusAlone() {
        // Only a swap moves focus: an untiled requester evicting the
        // window in its way leaves the user's attention alone. The
        // victim itself is re-housed: the request leaves exactly the
        // left half free, so it re-tiles there instead of untangling.
        let b = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .rightHalf)
        let a = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = a

        controller.handle(slot: .rightHalf)

        XCTAssertEqual(canvas.state.slot(of: 2), .rightHalf)
        XCTAssertEqual(
            canvas.state.slot(of: 1), .leftHalf,
            "the evicted window re-tiles into the one slot left free")
        XCTAssertTrue(
            gateway.focusCalls.isEmpty,
            "no focus call for the eviction itself")
    }

    func testStepAsideUndoRestoresEveryone() {
        let (a, b, c) = tileSixthsSession()
        gateway.focused = a
        controller.handle(slot: .sixthMiddle)
        XCTAssertEqual(
            canvas.evictedCount, 3,
            "the stepped-aside window, the requester, and the reflow are recoverable")

        controller.undoLastDisplacement()

        // Every window re-tiles into its former slot. The requester's
        // record was reissued by the shared undo machinery, so its id is
        // fresh (the same shape as an eviction undo's restored windows);
        // the stepped-aside and reflowed windows kept theirs.
        XCTAssertNil(canvas.state.slot(of: 1))
        XCTAssertEqual(canvas.state.slot(of: 3), .sixthsRightTwoThirds)
        XCTAssertEqual(canvas.state.slot(of: 2), .sixthBottomLeft)
        XCTAssertNotNil(canvas.state.occupant(of: .sixthTopLeft))
        XCTAssertEqual(
            gateway.frame(of: a), expectedRect(.sixthTopLeft, for: a),
            "undo re-tiles the requester into its old tile")
        XCTAssertEqual(
            gateway.frame(of: c), expectedRect(.sixthsRightTwoThirds, for: c),
            "undo re-tiles the stepped-aside window into its own tile")
        XCTAssertEqual(
            gateway.frame(of: b), expectedRect(.sixthBottomLeft, for: b),
            "undo undoes the reflow that absorbed the vacated tile")
        XCTAssertTrue(canvas.undoStack.isEmpty)
    }

    func testExpandedBlockerUntanglesInsteadOfSteppingAside() {
        let (a, _, c) = tileSixthsSession()

        // Expand the window that is in the way; expanded windows come
        // back to earth by untangling, never by moving — so the
        // step-aside is skipped and the plain eviction stands.
        gateway.focused = c
        controller.handleExpandToggle()
        gateway.focused = a
        controller.handle(slot: .sixthMiddle)

        XCTAssertNil(canvas.state.slot(of: 3))
        gateway.focused = c
        XCTAssertEqual(
            controller.focusedExpandState, .expands,
            "the expanded window's expansion died with the eviction")
        XCTAssertEqual(
            gateway.frame(of: c), CGRect(x: 1200, y: 100, width: 500, height: 400),
            "the expanded window is restored to its pre-tile frame")
        XCTAssertEqual(canvas.state.slot(of: 1), .sixthMiddle, "the requester still lands")
    }
}
