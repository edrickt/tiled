import XCTest
@testable import tiled


/// The evict hotkey's (⌥⇧⌫) controller behavior: untiles the focused
/// window and restores its pre-tile frame. Driven through
/// `FakeWindowGateway` so the assertions pin real side effects: written
/// frames, slot releases, and feedback.
final class EvictTests: XCTestCase {
    // MARK: Controller behavior (through the fake gateway)

    /// Deterministic display: tile geometry comes from this rect, never
    /// the host Mac's screen.
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
        controller.onChange = {}
    }

    @discardableResult
    private func addFocusedWindow(
        frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
    ) -> WindowHandle {
        let handle = gateway.addWindow(frame: frame)
        gateway.focused = handle
        return handle
    }

    func testEvictedWindowSitsBelowTheGrownSurvivor() {
        // Two stacked left sixths; evicting the bottom lets the top one
        // grow into the freed cells. The restored window must land
        // BELOW the survivor, not on top of it.
        let a = addFocusedWindow()
        controller.handle(slot: .sixthTopLeft)
        let b = addFocusedWindow()
        controller.handle(slot: .sixthBottomLeft)
        XCTAssertEqual(gateway.zOrder, [a, b])

        controller.handleEvict()   // evicts b (focused); a grows

        XCTAssertEqual(gateway.raiseCalls, [a], "the survivor is raised over the evictee")
        XCTAssertEqual(gateway.zOrder, [b, a], "the survivor ends above the evictee")
    }

    func testEvicteeFromTileRequestSitsBelowOccupants() {
        // A tiling request that truly evicts (every slot filled, so no
        // re-house is possible) must leave the evictee below every
        // remaining tiled window.
        let slots: [Slot] = [
            .sixthTopLeft, .sixthTopMiddle, .sixthTopRight,
            .sixthBottomLeft, .sixthBottomMiddle, .sixthBottomRight,
        ]
        var handles: [WindowHandle] = []
        for slot in slots {
            let handle = addFocusedWindow()
            controller.handle(slot: slot)
            handles.append(handle)
        }
        XCTAssertEqual(canvas.state.tiledWindows.count, 6)

        // A seventh window requests the occupied bottom-left sixth:
        // its occupant (handles[3]) is evicted for real.
        let requester = addFocusedWindow()
        gateway.focused = requester
        controller.handle(slot: .sixthBottomLeft)
        let evictee = handles[3]

        XCTAssertEqual(canvas.state.occupant(of: .sixthBottomLeft) ?? 0, 7,
                       "the requester holds the slot")
        guard let evicteeIndex = gateway.zOrder.firstIndex(of: evictee) else {
            return XCTFail("the evictee stays in the z-order model")
        }
        for (slot, id) in canvas.state.occupants {
            let handle = gateway.issued[id - 1]
            guard let index = gateway.zOrder.firstIndex(of: handle) else { continue }
            XCTAssertLessThan(
                evicteeIndex, index,
                "\(slot.rawValue): every tiled window sits above the evictee")
        }
    }

    func testEvictedWindowSitsBelowAnExpandedSurvivor() {
        // An expanded window still holds its slot and is non-evicted:
        // the evictee sits below it too, even though reflow never moves
        // the expanded window.
        let a = addFocusedWindow()
        controller.handle(slot: .sixthTopLeft)
        let b = addFocusedWindow()
        controller.handle(slot: .sixthBottomLeft)
        gateway.focused = a
        controller.handleExpandToggle()   // a covers the layout, keeps its slot
        XCTAssertTrue(gateway.raiseCalls.isEmpty, "expanding raises nothing")

        gateway.focused = b
        controller.handleEvict()

        XCTAssertEqual(gateway.raiseCalls, [a], "the expanded survivor is raised")
        XCTAssertEqual(gateway.zOrder.last, a, "the expanded survivor ends above the evictee")
    }

    func testEvictUntilesFocusedAndLeavesSizedFrame() {
        let handle = addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        controller.handle(slot: .topLeft)
        XCTAssertEqual(canvas.state.tiledWindows.count, 1)

        controller.handleEvict()

        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertEqual(
            gateway.frame(of: handle), CGRect(x: 12, y: 34, width: 800, height: 500),
            "evict leaves the quarter footprint at the pre-tile origin")
    }

    func testEvictWithNoFocusedWindowAnswers() {
        gateway.focused = nil
        let receipt = controller.handleEvict()
        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(receipt.announcement, "No focused window: click a window first.")
    }

    func testEvictUntiledWindowAnswers() {
        addFocusedWindow()
        let receipt = controller.handleEvict()
        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(receipt.announcement, "That window isn't tiled: nothing to evict.")
        XCTAssertTrue(canvas.state.occupants.isEmpty)
    }

    func testEvictUntiledWindowLeavesNoRecord() {
        // A no-op evict must not hand the window a record: a record is
        // ownership, and a stale one would pin the window's canvas
        // against a later tile (including one after a drag to the other
        // display).
        addFocusedWindow()
        controller.handleEvict()
        XCTAssertTrue(
            canvas.records.isEmpty,
            "pressing Evict on an untiled window leaves no record behind")
    }

    func testEvictExpandedWindowLeavesSizedFrame() {
        let handle = addFocusedWindow(frame: CGRect(x: 120, y: 90, width: 700, height: 500))
        controller.handle(slot: .topLeft)
        controller.handleExpandToggle()
        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)

        controller.handleEvict()

        XCTAssertEqual(
            gateway.frame(of: handle), CGRect(x: 120, y: 90, width: 800, height: 500),
            "evicting an expanded window leaves the quarter footprint")
        XCTAssertTrue(canvas.state.occupants.isEmpty)
        // Expansion ended with the evict: the toggle expands from scratch.
        gateway.focused = handle
        controller.handleExpandToggle()
        XCTAssertEqual(gateway.frame(of: handle), Self.screen.visibleFrame)
    }

    func testEvictAloneLeavesFocusAlone() {
        addFocusedWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        controller.handle(slot: .topLeft)
        controller.handleEvict()
        XCTAssertTrue(
            gateway.focusCalls.isEmpty,
            "nothing tiled left to focus: the evicted window keeps focus")
    }

    func testEvictWritesQuarterSizedFrame() {
        // Quarters canvas: evicting leaves the window floating at the
        // quarter footprint with its origin kept, not the raw pre-tile frame.
        controller.handleSwitchLayout(to: .quarters)
        let handle = addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        controller.handle(slot: .topLeft)

        controller.handleEvict()

        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertEqual(
            gateway.frame(of: handle),
            CGRect(x: 12, y: 34, width: 800, height: 500),
            "evict resizes in place to the layout's slot footprint")
    }
}
