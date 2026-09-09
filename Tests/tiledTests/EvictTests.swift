import XCTest
@testable import tiled

import AppKit

/// The evict hotkey's (⌥⇧⌫) controller behavior: untiles the focused
/// window and restores its pre-tile frame. Driven through
/// `FakeWindowGateway` so the assertions pin real side effects: written
/// frames, slot releases, and feedback.
final class EvictTests: XCTestCase {
    // MARK: Controller behavior (through the fake gateway)

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!
    private var feedbacks: [TilingController.Feedback] = []

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        controller = TilingController(gateway: gateway, pruneInterval: nil)
        controller.onFeedback = { [weak self] in self?.feedbacks.append($0) }
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
        XCTAssertEqual(controller.state.tiledWindows.count, 6)

        // A seventh window requests the occupied bottom-left sixth:
        // its occupant (handles[3]) is evicted for real.
        let requester = addFocusedWindow()
        gateway.focused = requester
        controller.handle(slot: .sixthBottomLeft)
        let evictee = handles[3]

        XCTAssertEqual(controller.occupant(of: .sixthBottomLeft, on: nil) ?? 0, 7,
                       "the requester holds the slot")
        guard let evicteeIndex = gateway.zOrder.firstIndex(of: evictee) else {
            return XCTFail("the evictee stays in the z-order model")
        }
        for (slot, id) in controller.state.occupants {
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

    func testEvictUntilesFocusedAndRestoresPreTileFrame() {
        let handle = addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        let original = gateway.frame(of: handle)!
        controller.handle(slot: .topLeft)
        XCTAssertEqual(controller.state.tiledWindows.count, 1)

        controller.handleEvict()

        XCTAssertTrue(controller.state.occupants.isEmpty)
        XCTAssertEqual(gateway.frame(of: handle), original)
    }

    func testEvictWithNoFocusedWindowAnswers() {
        gateway.focused = nil
        controller.handleEvict()
        guard case .noFocusedWindow = feedbacks[0] else {
            return XCTFail("expected .noFocusedWindow, got \(feedbacks)")
        }
    }

    func testEvictUntiledWindowAnswers() {
        addFocusedWindow()
        controller.handleEvict()
        XCTAssertEqual(feedbacks.count, 1)
        guard case .nothingToEvict = feedbacks[0] else {
            return XCTFail("expected .nothingToEvict, got \(feedbacks[0])")
        }
        XCTAssertTrue(controller.state.occupants.isEmpty)
    }

    func testEvictExpandedWindowRestoresPreTile() {
        let original = CGRect(x: 120, y: 90, width: 700, height: 500)
        let handle = addFocusedWindow(frame: original)
        controller.handle(slot: .topLeft)
        controller.handleExpandToggle()
        XCTAssertEqual(controller.state.slot(of: 1), .topLeft)

        controller.handleEvict()

        XCTAssertEqual(gateway.frame(of: handle), original)
        XCTAssertTrue(controller.state.occupants.isEmpty)
        // Expansion ended with the evict: the toggle expands from scratch.
        gateway.focused = handle
        controller.handleExpandToggle()
        let screens = NSScreen.screens
        let index = TilingController.owningScreenIndex(
            frames: screens.map(\.frame), for: original) ?? 0
        XCTAssertEqual(gateway.frame(of: handle), screens[index].visibleFrame)
    }

    func testEvictAloneLeavesFocusAlone() {
        addFocusedWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        controller.handle(slot: .topLeft)
        controller.handleEvict()
        XCTAssertTrue(
            gateway.focusCalls.isEmpty,
            "nothing tiled left to focus: the evicted window keeps focus")
    }
}
