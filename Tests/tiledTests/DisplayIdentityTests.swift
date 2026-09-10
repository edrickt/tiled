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
        XCTAssertEqual(controller.occupant(of: .topLeft, on: Self.left.id), leftHandle.id)
        XCTAssertEqual(controller.occupant(of: .topLeft, on: Self.right.id), rightHandle.id)
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
        let movedGrid = controller.grid(on: Self.right.id)
        XCTAssertNotEqual(movedGrid.columnSplit, 0.5)
        let draggedFrame = gateway.frame(of: rightHandle)!

        current = [Self.left]
        screenChange()
        XCTAssertEqual(
            gateway.frame(of: rightHandle), draggedFrame,
            "an unplugged display's window is not written in the dark")
        XCTAssertEqual(
            controller.grid(on: Self.right.id), movedGrid,
            "its canvas state survives the unplug")

        // Replug into the first provider slot: identity must come from the
        // display number, not the array index.
        current = [Self.right, Self.left]
        screenChange()
        XCTAssertEqual(
            gateway.frame(of: rightHandle),
            movedGrid.rect(for: .topLeft, in: Self.right.visibleFrame),
            "replug reasserts the kept canvas against the display's bounds")
        XCTAssertEqual(controller.occupant(of: .topLeft, on: Self.left.id), leftHandle.id)
    }
}
