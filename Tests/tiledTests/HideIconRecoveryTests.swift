import Carbon.HIToolbox
import XCTest

@testable import tiled

/// F8: the hide-icon confirm may name only a recovery combo that is
/// actually registered, and it must name the user's live Settings
/// binding. Hiding the icon is irreversible without that recovery, so a
/// disabled or failed binding must fall back to the relaunch path rather
/// than promising a keypress that does nothing.
final class HideIconRecoveryTests: XCTestCase {
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "HideIconRecoveryTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    private func temporaryDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    /// A remapped Settings binding distinct from the default: ⌃⌥F5.
    private let remapped = HotkeyBinding(
        modifiers: UInt32(controlKey | optionKey),
        keyCode: UInt32(kVK_F5))

    private let disabled = HotkeyBinding(
        modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
        keyCode: nil)

    private func makeStore() -> HotkeyStore {
        HotkeyStore(defaults: temporaryDefaults())
    }

    // MARK: Live recovery label

    func testDisabledSettingsBindingHasNoRecoveryLabel() {
        // Registration skips a disabled action, so it never enters
        // failedActions; absence from that list must not read as alive.
        let store = makeStore()
        store.set(disabled, for: .settings)

        XCTAssertNil(store.registeredLabel(for: .settings, failedActions: []))
    }

    func testFailedSettingsRegistrationHasNoRecoveryLabel() {
        XCTAssertNil(
            makeStore().registeredLabel(for: .settings, failedActions: [.settings]))
    }

    func testRemappedSettingsBindingNamesItsLiveLabel() {
        let store = makeStore()
        store.set(remapped, for: .settings)

        XCTAssertEqual(
            store.registeredLabel(for: .settings, failedActions: []),
            "⌃⌥F5")
    }

    func testDefaultSettingsBindingNamesTheDefaultCombo() {
        XCTAssertEqual(
            makeStore().registeredLabel(for: .settings, failedActions: []),
            "⌃⌥⇧⌘,")
    }

    func testOtherActionsFailuresDoNotSuppressTheSettingsLabel() {
        XCTAssertEqual(
            makeStore().registeredLabel(
                for: .settings, failedActions: [.expand, .undo]),
            "⌃⌥⇧⌘,")
    }

    // MARK: Confirm message

    func testDefaultComboAppearsExactlyOnceInTheConfirm() {
        let message = GeneralTab.hideIconRecoverySentence(settingsLabel: "⌃⌥⇧⌘,")

        XCTAssertEqual(
            message,
            "To get back, press ⌃⌥⇧⌘, anywhere or quit and reopen Tiled; "
                + "Settings opens automatically.")
    }

    func testRemappedComboAppearsExactlyOnceAndTheDefaultDoesNot() {
        let message = GeneralTab.hideIconRecoverySentence(settingsLabel: "⌃⌥F5")

        XCTAssertEqual(
            message,
            "To get back, press ⌃⌥F5 anywhere or quit and reopen Tiled; "
                + "Settings opens automatically.")
        XCTAssertFalse(message.contains("⌃⌥⇧⌘,"))
    }

    func testRelaunchOnlyMessageNamesNoComboAndPromisesNoShortcut() {
        let message = GeneralTab.hideIconRecoverySentence(settingsLabel: nil)

        XCTAssertEqual(
            message,
            "To get back, quit and reopen Tiled; Settings opens automatically. "
                + "(The Open Settings shortcut is disabled or unavailable.)")
        XCTAssertFalse(message.contains("⌃"))
        XCTAssertFalse(message.contains("⌥"))
        XCTAssertFalse(message.contains("⇧"))
        XCTAssertFalse(message.contains("⌘"))
        XCTAssertNil(
            message.range(of: "press", options: .caseInsensitive),
            "The relaunch path must not promise a shortcut to press.")
    }

    // MARK: Dialog wiring

    func testGeneralTabReadsTheLiveSettingsLabel() {
        let tab = GeneralTab(settings: AppSettings(defaults: temporaryDefaults()))
        tab.settingsHotkeyLabelProvider = { "⌃⌥F5" }

        XCTAssertEqual(
            tab.hideIconRecoveryText,
            "To get back, press ⌃⌥F5 anywhere or quit and reopen Tiled; "
                + "Settings opens automatically.")
    }

    func testGeneralTabWithoutAProviderTakesTheRelaunchOnlyPath() {
        let tab = GeneralTab(settings: AppSettings(defaults: temporaryDefaults()))

        XCTAssertEqual(
            tab.hideIconRecoveryText,
            "To get back, quit and reopen Tiled; Settings opens automatically. "
                + "(The Open Settings shortcut is disabled or unavailable.)")
    }

    func testStaticHintAndTooltipDoNotHardcodeTheDefaultCombo() {
        let tab = GeneralTab(settings: AppSettings(defaults: temporaryDefaults()))
        let view = tab.build(size: NSSize(width: 440, height: 480))
        let fields = descendants(of: view).compactMap { $0 as? NSTextField }
        let text = fields.map(\.stringValue).joined(separator: "\n")

        XCTAssertTrue(
            text.contains("When the icon is hidden"),
            "the recovery hint stays beside the checkbox")
        XCTAssertTrue(
            text.contains("enabled and registered"),
            "the hint must not promise an enabled-but-unregistered shortcut")
        XCTAssertFalse(
            text.contains("⌃⌥⇧⌘,"),
            "static copy must not promise a combo that may be disabled or remapped")
        let checkbox = descendants(of: view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Hide menu bar icon" }
        XCTAssertTrue(
            checkbox?.toolTip?.contains("enabled and registered") ?? false,
            "the tooltip must not promise an enabled-but-unregistered shortcut")
        XCTAssertFalse(
            checkbox?.toolTip?.contains("⌃⌥⇧⌘,") ?? false,
            "the checkbox tooltip must not promise the default combo either")
    }

    private func descendants(of view: NSView) -> [NSView] {
        var views: [NSView] = [view]
        for subview in view.subviews { views += descendants(of: subview) }
        return views
    }

    func testSettingsWindowForwardsTheLiveSettingsLabel() {
        let defaults = temporaryDefaults()
        let controller = SettingsWindowController(
            settings: AppSettings(defaults: defaults),
            hotkeyStore: HotkeyStore(defaults: defaults))
        defer { controller.close() }
        controller.settingsHotkeyLabelProvider = { "⌃⌥F5" }

        XCTAssertEqual(
            controller.hideIconRecoveryText,
            "To get back, press ⌃⌥F5 anywhere or quit and reopen Tiled; "
                + "Settings opens automatically.")
    }
}
