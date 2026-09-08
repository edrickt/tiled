import AppKit
import XCTest
@testable import tiled

/// Tile swapping through `TilingController.handle`: a tiled requester
/// swapping tiles with the one window in its way. Pins the report's
/// example end to end: the request is honored, the displaced window
/// lands in the vacated tile, and undo swaps back.
final class SwapTests: XCTestCase {
    private var gateway: FakeWindowGateway!
    private var controller: TilingController!

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        controller = TilingController(gateway: gateway, pruneInterval: nil)
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
        let frame = gateway.frame(of: handle)!
        let screens = NSScreen.screens
        let index = TilingController.owningScreenIndex(frames: screens.map(\.frame), for: frame) ?? 0
        return controller.grid.rect(for: slot, in: screens[index].visibleFrame)
    }

    func testSwapHonorsTileRequestAndMovesDisplacedIntoVacatedTile() {
        let (a, b, c) = tileSixthsSession()

        // Tile the top-left sixth into the middle third: the request is
        // honored, and the right two-thirds window moves into the vacated
        // sixth instead of being untiled.
        gateway.focused = a
        controller.handle(slot: .sixthMiddle)

        XCTAssertEqual(controller.state.slot(of: 1), .sixthMiddle)
        XCTAssertEqual(
            controller.state.slot(of: 3), .sixthTopLeft,
            "the displaced window takes the requester's vacated tile")
        XCTAssertEqual(controller.state.slot(of: 2), .sixthBottomLeft, "bystanders stay put")
        XCTAssertEqual(controller.state.tiledWindows.count, 3, "nobody was untiled")
        XCTAssertEqual(
            gateway.frame(of: a), expectedRect(.sixthMiddle, for: a))
        XCTAssertEqual(
            gateway.frame(of: c), expectedRect(.sixthTopLeft, for: c))
    }

    func testSwapNoticesNamesDisplacedAppAndUndo() {
        let (a, _, _) = tileSixthsSession()

        gateway.focused = a
        controller.handle(slot: .sixthMiddle)

        XCTAssertTrue(controller.canUndoDisplacement)
        XCTAssertTrue(
            controller.lastNotice?.contains("TestApp") ?? false,
            "the notice names the displaced app")
        XCTAssertTrue(
            controller.lastNotice?.contains("Top Left Sixth") ?? false,
            "the notice names the displaced window's landing tile")
        XCTAssertTrue(
            controller.lastNotice?.contains("Z") ?? false,
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

        XCTAssertEqual(controller.state.slot(of: 1), .rightHalf)
        XCTAssertEqual(controller.state.slot(of: 3), .topLeft)
        XCTAssertEqual(
            gateway.focusCalls.last, c,
            "focus follows the displaced window, not the requester")
        XCTAssertEqual(gateway.focused, c)
    }

    func testEvictionKeepsFocusAlone() {
        // Only a swap moves focus: an untiled requester evicting the
        // window in its way leaves the user's attention alone.
        let b = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .rightHalf)
        let a = gateway.addWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        gateway.focused = a

        controller.handle(slot: .rightHalf)

        XCTAssertEqual(controller.state.slot(of: 2), .rightHalf)
        XCTAssertNil(controller.state.slot(of: 1), "b was evicted")
        XCTAssertTrue(
            gateway.focusCalls.isEmpty,
            "no focus call for the eviction itself")
    }

    func testSwapUndoSwapsBack() {
        let (a, _, c) = tileSixthsSession()
        gateway.focused = a
        controller.handle(slot: .sixthMiddle)
        XCTAssertEqual(controller.evictedCount, 2, "both swap partners are recoverable")

        controller.undoLastDisplacement()

        // Both windows re-tile into their former slots. Records were
        // reissued by the shared undo machinery, so ids are fresh (the
        // same shape as an eviction undo's restored windows).
        XCTAssertNil(controller.state.slot(of: 1))
        XCTAssertNil(controller.state.slot(of: 3))
        XCTAssertNotNil(controller.state.occupant(of: .sixthTopLeft))
        XCTAssertNotNil(controller.state.occupant(of: .sixthsRightTwoThirds))
        XCTAssertEqual(
            gateway.frame(of: a), expectedRect(.sixthTopLeft, for: a),
            "undo re-tiles the requester into its old tile")
        XCTAssertEqual(
            gateway.frame(of: c), expectedRect(.sixthsRightTwoThirds, for: c),
            "undo re-tiles the displaced window into its own tile")
        XCTAssertFalse(controller.canUndoDisplacement)
    }

    func testSwapCollapsesExpandedDisplacedWindow() {
        let (a, _, c) = tileSixthsSession()

        // Expand the window that is about to be displaced; the swap must
        // bring it back to earth in its new tile, not leave it expanded
        // across the screen while holding a slot.
        gateway.focused = c
        controller.handleExpandToggle()
        gateway.focused = a
        controller.handle(slot: .sixthMiddle)

        XCTAssertEqual(controller.state.slot(of: 3), .sixthTopLeft)
        gateway.focused = c
        XCTAssertNil(
            controller.expandedFocusedSlot,
            "the displaced window's expansion died with the swap")
        XCTAssertEqual(
            gateway.frame(of: c), expectedRect(.sixthTopLeft, for: c),
            "the displaced window sits collapsed in its new tile")
    }
}
