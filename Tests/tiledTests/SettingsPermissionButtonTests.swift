import AppKit
import XCTest

@testable import tiled

/// Every Settings tab must lead with the fix when Accessibility is off:
/// an explanation row whose button opens the Accessibility pane —
/// labeled identically to the launch explainer's button.
final class SettingsPermissionButtonTests: XCTestCase {
    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let hit = findButton(titled: title, in: subview) { return hit }
        }
        return nil
    }

    private func temporaryDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SettingsPermissionButtonTests")!
    }

    func testGeneralTabLeadsWithTheAccessibilityButtonWhenUntrusted() {
        let tab = GeneralTab(settings: AppSettings(defaults: temporaryDefaults()))
        var opened = false
        tab.isTrustedProvider = { false }
        tab.onOpenAccessibilitySettings = { opened = true }
        let view = tab.build(size: NSSize(width: 440, height: 480))
        tab.loadValues()

        let button = findButton(titled: "Open Accessibility Settings", in: view)
        XCTAssertNotNil(button, "Untrusted installs must see the grant button on General.")
        button?.performClick(nil)
        XCTAssertTrue(opened, "The button must open the Accessibility pane.")
    }

    func testGeneralTabHidesThePermissionRowWhenTrusted() {
        let tab = GeneralTab(settings: AppSettings(defaults: temporaryDefaults()))
        tab.isTrustedProvider = { true }
        let view = tab.build(size: NSSize(width: 440, height: 480))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        tab.loadValues()

        let button = findButton(titled: "Open Accessibility Settings", in: view)
        XCTAssertNotNil(button)
        XCTAssertTrue(
            button!.isHiddenOrHasHiddenAncestor,
            "Trusted installs never need the grant button.")
    }

    func testShortcutsTabLeadsWithTheAccessibilityButtonWhenUntrusted() {
        let tab = ShortcutsTab(hotkeyStore: HotkeyStore(defaults: temporaryDefaults()))
        var opened = false
        tab.isTrustedProvider = { false }
        tab.onOpenAccessibilitySettings = { opened = true }
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        tab.reload()

        let button = findButton(titled: "Open Accessibility Settings", in: view)
        XCTAssertNotNil(button, "Untrusted installs must see the grant button on Shortcuts.")
        XCTAssertFalse(button!.isHiddenOrHasHiddenAncestor)
        button?.performClick(nil)
        XCTAssertTrue(opened, "The button must open the Accessibility pane.")
    }
}
