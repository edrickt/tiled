import AppKit
import XCTest

@testable import tiled

/// The launch permission window: explains why tiled needs Accessibility
/// and requires an explicit click into System Settings — replacing the
/// automatic system prompt with the product's own explanation.
final class PermissionWindowTests: XCTestCase {
    func testWindowNamesThePermissionAndShowsTheGrantButton() {
        let controller = PermissionWindowController()
        XCTAssertEqual(controller.window?.title, "Accessibility Permission")
        XCTAssertEqual(controller.openSettingsButton.title, "Open Accessibility Settings")
    }

    func testGrantButtonOpensAccessibilitySettings() {
        let controller = PermissionWindowController()
        var opened = false
        controller.onOpenSettings = { opened = true }
        controller.openSettingsButton.performClick(nil)
        XCTAssertTrue(opened, "The grant button must be the one action the window offers.")
    }
}
