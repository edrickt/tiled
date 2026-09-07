import XCTest
@testable import tiled

import AppKit

/// The evict hotkey's (⌥⇧⌫) controller behavior: untiles the focused
/// window (restoring its pre-tile frame) and grows the surviving
/// column-mate into the freed cells when they cover them exactly. Driven
/// through `FakeWindowGateway` so the assertions pin real side effects:
/// written frames, slot releases, reflow placements, and feedback.
/// its slot, survivors sharing a vertical strip with the vacated slot
/// expand to cover the freed cells exactly (e.g. evicting Top Left grows
/// Bottom Left into Left Half). Column-local like the tile reflow is
/// exact-or-empty: a hole nobody can fill stays a hole, and other columns
/// never move.
final class EvictReflowTests: XCTestCase {
    private let a = 1
    private let b = 2
    private let c = 3
    private let d = 4

    func testEvictSingleWindowGrowsNothing() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.reflowAfterEvict(window: a, from: .topLeft), [:])
    }

    func testEvictColumnMateExpandsToHalf() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        XCTAssertEqual(
            state.reflowAfterEvict(window: a, from: .topLeft),
            [b: .leftHalf])
    }

    func testEvictUnknownWindowIsEmpty() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        XCTAssertEqual(state.reflowAfterEvict(window: 99, from: .topLeft), [:])
    }

    func testEvictFullScreenGrowsOnlyItsColumn() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .bottomLeft)
        state.commit(window: c, into: .topRight)
        state.commit(window: d, into: .bottomRight)
        XCTAssertEqual(
            state.reflowAfterEvict(window: a, from: .topLeft),
            [b: .leftHalf])
    }

    func testEvictLeavesHoleWhenNothingSharesTheColumn() {
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)
        XCTAssertEqual(state.reflowAfterEvict(window: a, from: .topLeft), [:])
    }

    func testEvictHalfLeavesHole() {
        var state = TilingState()
        state.commit(window: a, into: .leftHalf)
        state.commit(window: b, into: .topRight)
        state.commit(window: c, into: .bottomRight)
        XCTAssertEqual(state.reflowAfterEvict(window: a, from: .leftHalf), [:])
    }

    func testEvictSixthsCornersGrowToThird() {
        var state = TilingState()
        state.commit(window: a, into: .sixthTopLeft)
        state.commit(window: b, into: .sixthBottomLeft)
        XCTAssertEqual(
            state.reflowAfterEvict(window: a, from: .sixthTopLeft),
            [b: .sixthLeft])
    }

    func testEvictSixthsMiddleGrowsLeftThirdSideways() {
        // The mirror of the left-third evict: the middle hole merges
        // leftwards, so the left third becomes the left two-thirds and
        // the right third never moves.
        var state = TilingState()
        state.commit(window: a, into: .sixthLeft)
        state.commit(window: b, into: .sixthMiddle)
        state.commit(window: c, into: .sixthRight)
        XCTAssertEqual(
            state.reflowAfterEvict(window: b, from: .sixthMiddle),
            [a: .sixthsLeftTwoThirds])
    }

    func testEvictLeftThirdGrowsMiddleThirdSideways() {
        var state = TilingState()
        state.commit(window: a, into: .sixthLeft)
        state.commit(window: b, into: .sixthMiddle)
        state.commit(window: c, into: .sixthRight)
        XCTAssertEqual(
            state.reflowAfterEvict(window: a, from: .sixthLeft),
            [b: .sixthsLeftTwoThirds])
    }

    func testEvictTopLeftGrowsOnlyTheMergeableMate() {
        // Bottom-left merges up into the left half; top-right can't
        // (the full top row is no slot), so it stays put and its hole stays.
        var state = TilingState()
        state.commit(window: a, into: .topLeft)
        state.commit(window: b, into: .topRight)
        state.commit(window: c, into: .bottomLeft)
        state.commit(window: d, into: .bottomRight)
        XCTAssertEqual(
            state.reflowAfterEvict(window: a, from: .topLeft),
            [c: .leftHalf])
    }

    func testEvictLeavesHoleWhenNoAdjacentMergeExists() {
        // Left two-thirds + right third tiled; evicting the two-thirds
        // frees 6 cells no single adjacent survivor merges into exactly.
        var state = TilingState()
        state.commit(window: a, into: .sixthsLeftTwoThirds)
        state.commit(window: b, into: .sixthRight)
        XCTAssertEqual(state.reflowAfterEvict(window: a, from: .sixthsLeftTwoThirds), [:])
    }

    // MARK: Controller behavior (through the fake gateway)

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!
    private var feedbacks: [TilingController.Feedback] = []

    private func setUpController() {
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

    private func expectedRect(_ slot: Slot, for handle: WindowHandle) -> CGRect {
        let frame = gateway.frame(of: handle)!
        let screens = NSScreen.screens
        let index = TilingController.owningScreenIndex(frames: screens.map(\.frame), for: frame) ?? 0
        return controller.grid.rect(for: slot, in: screens[index].visibleFrame)
    }

    /// Independent invariant: a produced frame must sit inside the
    /// visible frame of the screen that owns the window's pre-tile
    /// frame. `expectedRect` mirrors the controller's ownership rule, so
    /// a broken rule could agree with itself; containment is checked
    /// against the screen API directly, which the mirroring cannot fake.
    private func assertWithinOwningVisibleFrame(_ produced: CGRect, preTile: CGRect) {
        let screens = NSScreen.screens
        guard let index = TilingController.owningScreenIndex(
            frames: screens.map(\.frame), for: preTile)
        else { return } // off-screen: the fallback chain owns the frame
        XCTAssertTrue(
            screens[index].visibleFrame.contains(produced),
            "produced \(produced) escapes the owning screen's visible frame " +
            "\(screens[index].visibleFrame)")
    }

    func testEvictUntilesFocusedAndRestoresPreTileFrame() {
        setUpController()
        let handle = addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        let original = gateway.frame(of: handle)!
        controller.handle(slot: .topLeft)
        XCTAssertEqual(controller.state.tiledWindows.count, 1)

        controller.handleEvict()

        XCTAssertTrue(controller.state.occupants.isEmpty)
        XCTAssertEqual(gateway.frame(of: handle), original)
    }

    func testEvictGrowsColumnMateIntoLeftHalf() {
        setUpController()
        let a = addFocusedWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .bottomLeft)
        let aOriginal = gateway.frame(of: a)!
        // Sanity: a is not at its pre-tile frame anymore (it tiled).
        XCTAssertNotEqual(aOriginal, CGRect(x: 0, y: 0, width: 800, height: 600))

        gateway.focused = a
        controller.handleEvict()

        XCTAssertNil(controller.state.slot(of: 1), "evicted window holds no slot")
        XCTAssertEqual(controller.state.slot(of: 2), .leftHalf, "column-mate expands")
        let grown = gateway.frame(of: b)!
        XCTAssertEqual(grown, expectedRect(.leftHalf, for: b),
                       "column-mate frame covers the freed cells")
        assertWithinOwningVisibleFrame(grown, preTile: CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    func testEvictWithNoFocusedWindowAnswers() {
        setUpController()
        gateway.focused = nil
        controller.handleEvict()
        guard case .noFocusedWindow = feedbacks[0] else {
            return XCTFail("expected .noFocusedWindow, got \(feedbacks)")
        }
    }

    func testEvictUntiledWindowAnswers() {
        setUpController()
        addFocusedWindow()
        controller.handleEvict()
        XCTAssertEqual(feedbacks.count, 1)
        guard case .nothingToEvict = feedbacks[0] else {
            return XCTFail("expected .nothingToEvict, got \(feedbacks[0])")
        }
        XCTAssertTrue(controller.state.occupants.isEmpty)
    }

    func testEvictSixthsCornerGrowsItsColumnMate() {
        var state = TilingState()
        state.commit(window: a, into: .sixthsLeftTwoThirds)
        state.commit(window: b, into: .sixthTopRight)
        state.commit(window: c, into: .sixthBottomRight)
        XCTAssertEqual(
            state.reflowAfterEvict(window: b, from: .sixthTopRight),
            [c: .sixthRight])
    }

    func testEvictExpandedWindowCollapsesExpansionAndRestoresPreTile() {
        setUpController()
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

    func testEvictFocusesGrownSurvivor() {
        setUpController()
        let a = addFocusedWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .bottomLeft)

        gateway.focused = a
        controller.handleEvict()

        XCTAssertEqual(
            gateway.focusCalls.last, b,
            "evict hands focus to the survivor covering the freed cells, " +
            "so the reflow lands frontmost instead of hiding behind the evicted window")
    }

    func testEvictAloneLeavesFocusAlone() {
        setUpController()
        addFocusedWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        controller.handle(slot: .topLeft)
        controller.handleEvict()
        XCTAssertTrue(
            gateway.focusCalls.isEmpty,
            "nothing tiled left to focus: the evicted window keeps focus")
    }

    func testEvictHoleLeavesFocusAlone() {
        setUpController()
        let a = addFocusedWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .topRight)

        gateway.focused = a
        controller.handleEvict()

        XCTAssertNil(controller.state.slot(of: 1))
        XCTAssertEqual(controller.state.slot(of: 2), .topRight)
        XCTAssertTrue(
            gateway.focusCalls.isEmpty,
            "no survivor covers the vacated tile: focus stays put instead of " +
            "jumping to an unrelated window")
    }

    func testEvictWithRefusedReflowReleasesSlotsAndReports() {
        setUpController()
        let a = addFocusedWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = b
        controller.handle(slot: .bottomLeft)

        gateway.refuseNextWrites(b)
        gateway.focused = a
        controller.handleEvict()

        XCTAssertNil(controller.state.slot(of: 1), "evicted window holds no slot")
        XCTAssertNil(
            controller.state.slot(of: 2),
            "refused reflow rolls back like a refused swap")
        XCTAssertNotNil(controller.lastTileError)
        guard case .evictRefused = feedbacks.last else {
            return XCTFail("expected .evictRefused, got \(feedbacks)")
        }
    }
}
