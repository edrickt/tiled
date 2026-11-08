import AppKit
import XCTest

@testable import tiled

/// The launch permission window: explains why Tiled needs Accessibility
/// and requires an explicit click into System Settings, replacing the
/// automatic system prompt with the product's own explanation.
final class PermissionWindowTests: XCTestCase {
    func testWindowNamesThePermissionAndShowsTheGrantButton() {
        let controller = PermissionWindowController()
        XCTAssertEqual(controller.window?.title, "Accessibility Permission")
        XCTAssertEqual(controller.openSettingsButton.title, "Open Accessibility Settings")
    }

    func testStepsPromiseTheWindowClosesItself() {
        let controller = PermissionWindowController()
        XCTAssertTrue(
            controller.stepsField.stringValue.contains("this window closes itself"),
            "The steps must name the auto-dismiss so nobody wonders whether to come back and confirm.")
    }

    func testHeadlineCarriesTheStrongestTitleVoice() {
        let controller = PermissionWindowController()
        XCTAssertEqual(
            controller.headlineField.font,
            .systemFont(ofSize: NSFont.systemFontSize + 4, weight: .bold),
            "The ask is this window's whole job: it leads at display scale, not settings-row scale.")
    }

    func testGrantButtonIsLargeAndTheDefaultButton() {
        let controller = PermissionWindowController()
        XCTAssertEqual(
            controller.openSettingsButton.controlSize, .large,
            "The grant is the window's one action: it renders at large control size.")
        XCTAssertTrue(
            controller.window?.defaultButtonCell === controller.openSettingsButton.cell,
            "The grant button must be the default: Return works from anywhere in the window.")
    }

    func testGrantButtonOpensAccessibilitySettings() {
        let controller = PermissionWindowController()
        var opened = false
        controller.onOpenSettings = { opened = true }
        controller.openSettingsButton.performClick(nil)
        XCTAssertTrue(opened, "The grant button must be the one action the window offers.")
    }

    func testClosingTheExplainerNotifiesSoThePermissionPollCanStop() {
        // The delegate polls the grant at 1 Hz while this window is up.
        // A user dismissal must end that poll (the same notification key
        // the grant path's own close() posts), or the app keeps waking and
        // refreshing the menu after the explainer is gone.
        let controller = PermissionWindowController()
        var closes = 0
        controller.onClose = { closes += 1 }
        controller.show()

        controller.close()

        XCTAssertEqual(
            closes, 1,
            "closing the explainer must notify the delegate's poll to stop")
    }
}
