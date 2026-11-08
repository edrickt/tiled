import AppKit
import Carbon.HIToolbox
import XCTest

@testable import tiled

/// The Welcome tab's session lifecycle through the real Settings shell:
/// first build, dismissal persistence, hidden-window reopen, and the
/// instruction refresh on reopen. Temporary defaults keep it hermetic.
final class WelcomeLifecycleTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var store: HotkeyStore!

    override func setUp() {
        super.setUp()
        suiteName = "WelcomeLifecycleTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(defaults: defaults)
        store = HotkeyStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        settings = nil
        store = nil
        suiteName = ""
        super.tearDown()
    }

    func testPermissionFlipIsAnnouncedNotASilentLayoutJump() {
        let tab = WelcomeTab(hotkeyStore: store)
        var trusted = false
        tab.isTrustedProvider = { trusted }
        var announced: [String] = []
        tab.onAnnouncement = { announced.append($0) }
        _ = tab.build(size: NSSize(width: 440, height: 480))
        tab.refreshPermissionState() // baseline: untrusted

        trusted = true
        tab.refreshPermissionState()

        XCTAssertEqual(
            announced,
            ["Accessibility permission granted; tiled can see and move windows now."],
            "the row changes state with a sentence, not a silent jump")
    }

    private func makeController() -> SettingsWindowController {
        SettingsWindowController(settings: settings, hotkeyStore: store)
    }

    private func selectedTab(in view: NSView) -> NSTabView? {
        if let tabs = view as? NSTabView, tabs.selectedTabViewItem != nil {
            return tabs
        }
        for subview in view.subviews {
            if let hit = selectedTab(in: subview) { return hit }
        }
        return nil
    }

    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let hit = findButton(titled: title, in: subview) { return hit }
        }
        return nil
    }

    private func tabIdentifiers(in view: NSView) -> [String] {
        guard let tabs = selectedTab(in: view) else { return [] }
        return tabs.tabViewItems.compactMap { $0.identifier as? String }
    }

    private func selectedIdentifier(in view: NSView) -> String? {
        selectedTab(in: view)?.selectedTabViewItem?.identifier as? String
    }

    func testFirstBuildIncludesAndSelectsWelcome() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.show(selecting: .welcome)
        let content = try XCTUnwrap(controller.window?.contentView)

        XCTAssertEqual(
            tabIdentifiers(in: content), ["welcome", "general", "shortcuts"])
        XCTAssertEqual(selectedIdentifier(in: content), "welcome")
    }

    func testDismissalPersistsRemovesTheTabAndSelectsGeneral() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.show(selecting: .welcome)
        let content = try XCTUnwrap(controller.window?.contentView)
        let dismiss = try XCTUnwrap(
            findButton(titled: "Got it, show General next time", in: content))

        dismiss.performClick(nil)

        XCTAssertTrue(settings.didDismissWelcome, "the dismissal is persisted")
        XCTAssertFalse(tabIdentifiers(in: content).contains("welcome"))
        XCTAssertEqual(selectedIdentifier(in: content), "general")

        // A fresh controller over the same defaults starts on General:
        // the guide is one-time per install, not one-time per window.
        let next = makeController()
        defer { next.close() }
        let nextContent = try XCTUnwrap(next.window?.contentView)
        XCTAssertFalse(tabIdentifiers(in: nextContent).contains("welcome"))
        XCTAssertEqual(selectedIdentifier(in: nextContent), "general")
    }

    func testHiddenWindowReopenRebuildsWelcomeWithoutClearingDismissal() throws {
        settings.didDismissWelcome = true
        let controller = makeController()
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        XCTAssertFalse(tabIdentifiers(in: content).contains("welcome"))
        XCTAssertFalse(controller.window?.isVisible ?? true)

        controller.showWelcomeAgain()

        XCTAssertTrue(tabIdentifiers(in: content).contains("welcome"))
        XCTAssertEqual(selectedIdentifier(in: content), "welcome")
        XCTAssertTrue(
            settings.didDismissWelcome,
            "reopening the guide for this session does not undo the persisted dismissal")
    }

    func testHiddenWindowReopenRefreshesShortcutInstructions() throws {
        settings.didDismissWelcome = true
        let controller = makeController()
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        store.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: .topLeft)

        controller.showWelcomeAgain()

        let instructions = try XCTUnwrap(
            textLabels(in: content).first { $0.hasPrefix("1.") })
        XCTAssertTrue(
            instructions.contains("Top Left's shortcut is disabled."),
            "the rebuilt guide reads the current binding, not the first-launch one")
    }

    /// Puts a second window in front of the visible Settings window, so a
    /// following call must actually raise Settings to pass.
    private func obscure(_ window: NSWindow) -> NSWindow {
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        other.orderFront(nil)
        XCTAssertGreaterThan(
            window.orderedIndex, other.orderedIndex,
            "precondition: the Settings window sits behind another window")
        return other
    }

    func testReopeningTheVisibleGuideRaisesSettings() {
        // Welcome is already in the tab view; selecting it must also raise
        // a visible-but-behind Settings window. The real ordering needs an
        // active app (and makeFirstResponder already raises within this
        // process), so the shell's raise seam pins the call path.
        let controller = makeController()
        defer { controller.close() }
        controller.show(selecting: .welcome)
        var raises = 0
        controller.onRaise = { raises += 1 }

        controller.showWelcomeAgain()

        XCTAssertEqual(
            raises, 1,
            "Tiled Guide must raise and activate Settings, not only select Welcome")
    }

    func testReopeningTheGuideOnAVisibleWindowWithoutTheTabRaisesSettings() throws {
        // The other visible branch: the Welcome item is inserted into an
        // already-visible window, which must be raised as well.
        settings.didDismissWelcome = true
        let controller = makeController()
        defer { controller.close() }
        controller.show(selecting: .general)
        let content = try XCTUnwrap(controller.window?.contentView)
        let window = try XCTUnwrap(controller.window)
        let other = obscure(window)
        defer { other.close() }

        controller.showWelcomeAgain()

        XCTAssertLessThan(
            window.orderedIndex, other.orderedIndex,
            "Tiled Guide must raise Settings when it inserts the Welcome tab")
        XCTAssertEqual(selectedIdentifier(in: content), "welcome")
    }
}
