import AppKit
import XCTest

@testable import tiled

/// Every Settings tab must lead with the fix when Accessibility is off:
/// an explanation row whose button opens the Accessibility pane -
/// labeled identically to the launch explainer's button.
final class SettingsPermissionButtonTests: XCTestCase {
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // A fresh suite per run: a fixed suite name persists on disk and
        // leaks state (and stale preferences) between runs.
        suiteName = "SettingsPermissionButtonTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let hit = findButton(titled: title, in: subview) { return hit }
        }
        return nil
    }

    private func temporaryDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    /// The selected tab's own view: other tabs hold identically titled
    /// buttons, so searching the whole window could assert on the wrong
    /// tab's row.
    private func selectedTabView(in view: NSView) -> NSTabView? {
        if let tabs = view as? NSTabView, tabs.selectedTabViewItem != nil { return tabs }
        for subview in view.subviews {
            if let hit = selectedTabView(in: subview) { return hit }
        }
        return nil
    }

    private func openWelcome(
        trusted: @escaping () -> Bool
    ) throws -> (controller: SettingsWindowController, view: NSView, button: NSButton) {
        let controller = SettingsWindowController(
            settings: AppSettings(defaults: temporaryDefaults()),
            hotkeyStore: HotkeyStore(defaults: temporaryDefaults()))
        // AppDelegate assigns trust after init; Welcome was already built
        // with no provider, so only show()'s refresh can reveal the row.
        controller.isTrustedProvider = trusted
        controller.show(selecting: .welcome)
        let content = try XCTUnwrap(controller.window?.contentView)
        let tabs = try XCTUnwrap(selectedTabView(in: content))
        XCTAssertEqual(tabs.selectedTabViewItem?.identifier as? String, "welcome")
        let view = try XCTUnwrap(tabs.selectedTabViewItem?.view)
        let button = try XCTUnwrap(
            findButton(titled: "Open Accessibility Settings", in: view))
        return (controller, view, button)
    }

    func testWelcomeTabShowsTheAccessibilityButtonWhenOpenedUntrusted() throws {
        let (controller, _, button) = try openWelcome { false }
        defer { controller.close() }

        XCTAssertFalse(
            button.isHiddenOrHasHiddenAncestor,
            "Opening Welcome while untrusted must show the warning and the grant button.")
    }

    func testWelcomeTabHidesThePermissionRowWhenTrustFlipsWhileOpen() throws {
        var trusted = false
        let (controller, _, button) = try openWelcome { trusted }
        defer { controller.close() }
        XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)

        trusted = true
        controller.permissionStateDidChange()

        XCTAssertTrue(
            button.isHiddenOrHasHiddenAncestor,
            "Granting permission while Welcome is open hides the warning without reopening.")
    }

    func testWelcomeForwardsFailedTopLeftRegistration() throws {
        let (controller, view, _) = try openWelcome { false }
        defer { controller.close() }
        var failed: [HotkeyAction] = []
        controller.failedActionsProvider = { failed }
        controller.showWelcomeAgain()
        var instructions = try XCTUnwrap(textLabels(in: view).first { $0.hasPrefix("1.") })
        XCTAssertTrue(instructions.contains("Press ⌥⇧U"))

        failed = [.slotKey(.topLeft)]
        controller.showWelcomeAgain()
        instructions = try XCTUnwrap(textLabels(in: view).first { $0.hasPrefix("1.") })

        XCTAssertTrue(instructions.contains("Menu bar → Tile Focused Window → Top Left"))
        XCTAssertFalse(
            instructions.contains("Press ⌥⇧U"),
            "The controller must forward failed registrations into the guide.")
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
