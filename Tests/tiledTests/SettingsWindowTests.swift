import AppKit
import XCTest

@testable import tiled

/// The Settings shell's tab lifecycle, driven headless: which tabs exist,
/// which one opens selected, where focus lands, that the injected
/// dependency value reaches every tab, and that a Shortcuts rebuild uses
/// the window's live size rather than the size captured at build time.
final class SettingsWindowTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: HotkeyStore!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsWindowTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = HotkeyStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeController(
        dependencies: SettingsDependencies = SettingsDependencies()
    ) -> SettingsWindowController {
        let controller = SettingsWindowController(
            settings: AppSettings(defaults: defaults),
            hotkeyStore: store,
            dependencies: dependencies)
        addTeardownBlock { controller.close() }
        return controller
    }

    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let hit = findButton(titled: title, in: subview) { return hit }
        }
        return nil
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        let own = (view as? NSTextField).map { [$0] } ?? []
        return own + view.subviews.flatMap { textFields(in: $0) }
    }

    private func findStepper(in view: NSView) -> NSStepper? {
        if let stepper = view as? NSStepper { return stepper }
        for subview in view.subviews {
            if let hit = findStepper(in: subview) { return hit }
        }
        return nil
    }

    func testFirstRunLeadsWithWelcomeAndGeneralIsTheDefaultLanding() {
        let controller = makeController()
        XCTAssertEqual(
            controller.tabIdentifiers, ["welcome", "general", "shortcuts"],
            "The first-run Welcome tab leads the tab order.")

        controller.show()
        XCTAssertEqual(
            controller.selectedTabIdentifier, "general",
            "Settings opens on General, not on the first tab in the list.")
    }

    func testDismissedWelcomeLeavesGeneralFirstOnLaterLaunches() {
        let settings = AppSettings(defaults: defaults)
        settings.didDismissWelcome = true
        let controller = SettingsWindowController(
            settings: settings, hotkeyStore: store)
        addTeardownBlock { controller.close() }

        XCTAssertEqual(controller.tabIdentifiers, ["general", "shortcuts"])
    }

    func testDismissingWelcomeRemovesItAndLandsOnGeneral() throws {
        let controller = makeController()
        controller.show(selecting: .welcome)
        let welcome = try XCTUnwrap(controller.tabContent(of: .welcome))
        let dismiss = try XCTUnwrap(
            findButton(titled: "Got it, show General next time", in: welcome))
        dismiss.performClick(nil)

        XCTAssertEqual(controller.tabIdentifiers, ["general", "shortcuts"])
        XCTAssertEqual(controller.selectedTabIdentifier, "general")
        XCTAssertTrue(
            AppSettings(defaults: defaults).didDismissWelcome,
            "Dismissal is persisted so the next launch opens on General.")
    }

    func testReopeningTheGuideRestoresWelcomeAtTheFront() throws {
        let controller = makeController()
        controller.show(selecting: .welcome)
        let welcome = try XCTUnwrap(controller.tabContent(of: .welcome))
        try XCTUnwrap(
            findButton(titled: "Got it, show General next time", in: welcome)
        ).performClick(nil)

        controller.showWelcomeAgain()

        XCTAssertEqual(controller.tabIdentifiers, ["welcome", "general", "shortcuts"])
        XCTAssertEqual(controller.selectedTabIdentifier, "welcome")
    }

    func testShowSelectsTheRequestedTabAndFocusesItsFirstRecorder() throws {
        let controller = makeController()
        controller.show(selecting: .shortcuts)

        XCTAssertEqual(controller.selectedTabIdentifier, "shortcuts")
        XCTAssertTrue(
            controller.window?.firstResponder is RecorderButton,
            "Opening Shortcuts must land focus on its first recorder.")
    }

    func testInjectedDependenciesReachEveryTabThroughOneWiringPoint() throws {
        var opened = 0
        let dependencies = SettingsDependencies(
            isTrusted: { false },
            openAccessibilitySettings: { opened += 1 },
            failedActions: { [.slot(.topLeft)] })
        let controller = makeController(dependencies: dependencies)
        controller.show(selecting: .general)

        // The trust probe reaches General: an untrusted install sees the row.
        let general = try XCTUnwrap(controller.tabContent(of: .general))
        let grant = try XCTUnwrap(
            findButton(titled: "Open Accessibility Settings", in: general))
        XCTAssertFalse(grant.isHiddenOrHasHiddenAncestor)
        grant.performClick(nil)
        XCTAssertEqual(
            opened, 1,
            "The tab must call the action from the injected dependency value.")

        // The same probe reaches Shortcuts, and its registration-failure
        // probe surfaces the injected failures.
        let shortcuts = try XCTUnwrap(controller.tabContent(of: .shortcuts))
        let grantShortcuts = try XCTUnwrap(
            findButton(titled: "Open Accessibility Settings", in: shortcuts))
        XCTAssertFalse(grantShortcuts.isHiddenOrHasHiddenAncestor)
    }

    func testGapStepperShowsTheDefaultAndCommitsTheSetting() throws {
        var reported: Double?
        let dependencies = SettingsDependencies(gapChange: { reported = $0 })
        let controller = makeController(dependencies: dependencies)
        controller.show(selecting: .general)

        let general = try XCTUnwrap(controller.tabContent(of: .general))
        let stepper = try XCTUnwrap(findStepper(in: general))
        XCTAssertEqual(stepper.doubleValue, 5, "the stepper shows the default gap")
        XCTAssertEqual(stepper.minValue, AppSettings.tileGapRange.lowerBound)
        XCTAssertEqual(stepper.maxValue, AppSettings.tileGapRange.upperBound)

        stepper.doubleValue = 12
        stepper.sendAction(stepper.action, to: stepper.target)

        XCTAssertEqual(
            AppSettings(defaults: defaults).tileGap, 12,
            "the stepper persists the gap through AppSettings")
        XCTAssertEqual(
            reported, 12,
            "the change reaches the delegate so it can re-place tiled windows")
        XCTAssertTrue(
            textFields(in: general).contains { $0.stringValue == "12 pt" },
            "the value label mirrors the committed gap")
    }

    func testRegistrationFailuresSurfaceOnTheShortcutsTab() throws {
        let dependencies = SettingsDependencies(failedActions: { [.slot(.topLeft)] })
        let controller = makeController(dependencies: dependencies)
        controller.show(selecting: .shortcuts)

        let shortcuts = try XCTUnwrap(controller.tabContent(of: .shortcuts))
        let warning = textFields(in: shortcuts).first {
            $0.stringValue.contains("could not be registered")
        }
        XCTAssertNotNil(
            warning,
            "A cross-app registration failure must surface beside the recorder rows.")
    }

    func testShortcutsRebuildUsesTheWindowsLiveContentSize() throws {
        let tab = ShortcutsTab(hotkeyStore: store, defaults: defaults)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        _ = tab.build(size: window.contentView!.bounds.size, window: window)

        window.setContentSize(NSSize(width: 700, height: 540))
        let rebuilt = tab.rebuildContent()

        XCTAssertEqual(
            rebuilt.frame.size, NSSize(width: 700, height: 540),
            "A rebuild after a live resize must use the window's current size.")
    }
}
