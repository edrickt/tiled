import AppKit
import CoreGraphics
import XCTest

@testable import tiled

/// Display identity across screen-provider changes: a physical monitor's
/// canvas must survive list reordering, primary-display changes, and
/// unplug/replug. Other per-monitor tests keep `ScreenID` fixed, so they
/// cannot catch an identity derived from `NSScreen.screens` order.
final class DisplayIdentityTests: XCTestCase {
    private static let leftFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private static let rightFrame = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    private static let leftDisplayID: CGDirectDisplayID = 101
    private static let rightDisplayID: CGDirectDisplayID = 202
    private static let left = screen(
        displayID: leftDisplayID, frame: leftFrame, name: "Display 1")
    private static let right = screen(
        displayID: rightDisplayID, frame: rightFrame, name: "Display 2")

    private static func screen(
        displayID: CGDirectDisplayID,
        fallbackIndex: Int = 0,
        frame: CGRect,
        name: String
    ) -> ScreenInfo {
        ScreenInfo(
            id: ScreenID(displayID: displayID, fallbackIndex: fallbackIndex),
            frame: frame,
            visibleFrame: frame,
            name: name,
            displayID: displayID)
    }

    private func makeController(
        gateway: FakeWindowGateway,
        screens: @escaping () -> [ScreenInfo]
    ) -> TilingController {
        TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: screens, deathConfirmation: 0)
    }

    @discardableResult
    private func addWindow(
        _ frame: CGRect, to gateway: FakeWindowGateway
    ) -> WindowHandle {
        let handle = gateway.addWindow(frame: frame)
        gateway.focused = handle
        return handle
    }

    private func screenChange() {
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func dragRightEdge(
        _ handle: WindowHandle, by delta: CGFloat, on gateway: FakeWindowGateway
    ) {
        var echo = gateway.frame(of: handle)!
        echo.size.width -= 10
        gateway.simulateChange(handle, to: echo)
        var dragged = gateway.frame(of: handle)!
        dragged.size.width += delta
        gateway.simulateChange(handle, to: dragged)
    }

    // MARK: Stable identity

    func testScreenIDPrefersTheStableDisplayNumberOverListOrder() {
        let first = ScreenID(displayID: 42, fallbackIndex: 0)
        let rebuiltInAnotherOrder = ScreenID(displayID: 42, fallbackIndex: 99)

        XCTAssertEqual(
            first, rebuiltInAnotherOrder,
            "the same physical display keeps one identity when the provider reorders")
        XCTAssertEqual(first.rawValue, 42)
    }

    func testScreenIDFallsBackToProviderIndexWithoutADisplayNumber() {
        XCTAssertEqual(ScreenID(displayID: 0, fallbackIndex: 3).rawValue, 3)
    }

    func testLiveScreenInfoUsesItsDisplayNumberAsIdentity() throws {
        guard let live = NSScreen.screens.first else {
            throw XCTSkip("no display attached")
        }
        guard
            let number = live.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            number.uint32Value != 0
        else { throw XCTSkip("screen has no NSScreenNumber") }

        let info = ScreenInfo(appKit: live, index: 4242)

        XCTAssertEqual(
            info.id, ScreenID(displayID: number.uint32Value, fallbackIndex: 4242),
            "the live provider must not key canvas state by screen order")
    }

    // MARK: Reorder, unplug, replug

    func testProviderReorderKeepsEachCanvasWithItsPhysicalDisplay() {
        var current = [Self.left, Self.right]
        let gateway = FakeWindowGateway()
        let controller = makeController(gateway: gateway, screens: { current })

        let leftHandle = addWindow(
            CGRect(x: 100, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)
        let rightHandle = addWindow(
            CGRect(x: 2000, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)
        let leftTiled = gateway.frame(of: leftHandle)!
        let rightTiled = gateway.frame(of: rightHandle)!

        // Rebuilding the provider after a primary-display change reverses
        // the array; each entry still describes the same physical display.
        current = [Self.right, Self.left]
        screenChange()

        XCTAssertEqual(gateway.frame(of: leftHandle), leftTiled)
        XCTAssertEqual(gateway.frame(of: rightHandle), rightTiled)
        XCTAssertEqual(controller.canvas(for: Self.left.id).state.occupant(of: .topLeft), leftHandle.id)
        XCTAssertEqual(controller.canvas(for: Self.right.id).state.occupant(of: .topLeft), rightHandle.id)
    }

    func testUnpluggedDisplayKeepsItsCanvasForReplug() {
        var current = [Self.left, Self.right]
        let gateway = FakeWindowGateway()
        let controller = makeController(gateway: gateway, screens: { current })

        let leftHandle = addWindow(
            CGRect(x: 100, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)
        let rightHandle = addWindow(
            CGRect(x: 2000, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)

        // Give the right canvas a distinctive splitter state, so replug
        // has to restore more than the default screen geometry.
        dragRightEdge(rightHandle, by: -60, on: gateway)
        let movedGrid = controller.canvas(for: Self.right.id).grid
        XCTAssertNotEqual(movedGrid.columnSplit, 0.5)
        let draggedFrame = gateway.frame(of: rightHandle)!

        current = [Self.left]
        screenChange()
        XCTAssertEqual(
            gateway.frame(of: rightHandle), draggedFrame,
            "an unplugged display's window is not written in the dark")
        XCTAssertEqual(
            controller.canvas(for: Self.right.id).grid, movedGrid,
            "its canvas state survives the unplug")

        // Replug into the first provider slot: identity must come from the
        // display number, not the array index.
        current = [Self.right, Self.left]
        screenChange()
        XCTAssertEqual(
            gateway.frame(of: rightHandle),
            movedGrid.rect(for: .topLeft, in: Self.right.visibleFrame),
            "replug reasserts the kept canvas against the display's bounds")
        XCTAssertEqual(controller.canvas(for: Self.left.id).state.occupant(of: .topLeft), leftHandle.id)
    }

    /// An unplugged display's kept canvas must keep the geometry it had.
    /// Re-resolving it from the provider while its display is absent would
    /// write the main display's frame into the kept canvas, so the last-known
    /// frame survives until replug recomputes it.
    func testUnpluggedDisplayKeepsItsStoredVisibleFrameForReplug() {
        var current = [Self.left, Self.right]
        let gateway = FakeWindowGateway()
        let controller = makeController(gateway: gateway, screens: { current })

        let rightHandle = addWindow(
            CGRect(x: 2000, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)
        let kept = controller.canvas(for: Self.right.id).visibleFrame
        XCTAssertEqual(kept, Self.right.visibleFrame)

        // The right display goes away. Its kept canvas must not adopt the
        // main display's geometry: the last-known frame survives the unplug.
        current = [Self.left]
        screenChange()
        XCTAssertEqual(
            controller.canvas(for: Self.right.id).visibleFrame, kept,
            "an unplugged canvas keeps its last-known visible frame, not the main display's")

        // Replug re-resolves both canvases from their own restored displays.
        current = [Self.right, Self.left]
        screenChange()
        XCTAssertEqual(
            controller.canvas(for: Self.right.id).visibleFrame, Self.right.visibleFrame)
        XCTAssertEqual(
            controller.canvas(for: Self.left.id).visibleFrame, Self.left.visibleFrame)
        XCTAssertEqual(controller.canvas(for: Self.right.id).state.occupant(of: .topLeft), rightHandle.id)
    }

    /// A canvas established with the OS withholding the Space id keys
    /// `(screen, nil)`. Once its display is unplugged that canvas is
    /// invisible: a hotkey must defer rather than lay the window out
    /// against the main display's frame, and replug must reassert it.
    func testHotkeyOnAWithheldCanvasOfAnUnpluggedDisplayDefersThenReassertsOnReplug() {
        var current = [Self.left, Self.right]
        let gateway = FakeWindowGateway()
        // No Space ids are named, so each display's canvas is its
        // per-display fallback: (screen, nil).
        let controller = makeController(gateway: gateway, screens: { current })
        let withheld = TilingSpaceKey(screen: Self.right.id, space: nil)

        let rightHandle = addWindow(
            CGRect(x: 2000, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)
        let tiledFrame = gateway.frame(of: rightHandle)!
        XCTAssertEqual(
            controller.canvas(for: withheld).state.occupant(of: .topLeft), rightHandle.id,
            "the window tiled onto the display's withheld canvas")

        // The right display goes away; its kept canvas must never be
        // written in the dark.
        current = [Self.left]
        screenChange()

        // A hotkey still resolves the window's own (now unplugged)
        // canvas, and that canvas is not visible.
        gateway.focused = rightHandle
        let receipt = controller.handle(slot: .topRight)

        XCTAssertEqual(
            gateway.frame(of: rightHandle), tiledFrame,
            "an unplugged display's withheld canvas is not written")
        XCTAssertTrue(receipt.performed, "a deferral is never a failure")
        XCTAssertEqual(
            receipt.announcement,
            "That Space isn't visible yet: the change will apply when you return to it.")
        XCTAssertEqual(
            controller.canvas(for: withheld).state.slot(of: rightHandle.id), .topRight,
            "the deferred placement stands on the kept canvas")
        XCTAssertTrue(
            controller.isMarkedStale(withheld),
            "the deferred write leaves the kept canvas marked stale for the reassert")

        // Replug: the kept canvas reasserts against the restored display.
        current = [Self.left, Self.right]
        screenChange()
        XCTAssertEqual(
            gateway.frame(of: rightHandle),
            GridLayout().rect(for: .topRight, in: Self.right.visibleFrame),
            "replug reasserts the kept canvas against the restored display")
        XCTAssertFalse(
            controller.isMarkedStale(withheld),
            "the replug reassert clears the stale mark")
    }

    /// With no displays at all the canvas is genuinely display-less
    /// (`TilingSpaceKey.displayless`): there is no hidden canvas to
    /// protect, so it stays visible and still writes.
    func testDisplaylessCanvasStaysVisible() {
        let gateway = FakeWindowGateway()
        let controller = makeController(gateway: gateway, screens: { [] })

        let handle = addWindow(
            CGRect(x: 100, y: 100, width: 800, height: 600), to: gateway)
        let original = gateway.frame(of: handle)!
        controller.handle(slot: .topLeft)

        XCTAssertEqual(
            controller.canvas(for: .displayless).state.occupant(of: .topLeft), handle.id,
            "the window tiles onto the display-less canvas")
        XCTAssertNotEqual(
            gateway.frame(of: handle), original,
            "the display-less canvas is visible and still writes")
    }
}
