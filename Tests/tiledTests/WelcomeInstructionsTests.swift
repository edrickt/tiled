import AppKit
import Carbon.HIToolbox
import XCTest

@testable import tiled

final class WelcomeInstructionsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: HotkeyStore!

    override func setUp() {
        super.setUp()
        suiteName = "WelcomeInstructionsTests-\(UUID().uuidString)"
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

    func testDisabledTopLeftTeachesTheMenuInsteadOfAnotherSlotsShortcut() throws {
        let disabled = HotkeyBinding(modifiers: 0, keyCode: nil)
        store.set(disabled, for: .topLeft)
        let tab = WelcomeTab(hotkeyStore: store)
        let view = tab.build(size: NSSize(width: 440, height: 480))
        let instructions = try XCTUnwrap(textLabels(in: view).first { $0.hasPrefix("1.") })

        XCTAssertTrue(instructions.contains("Tile Focused Window → Top Left"))
        XCTAssertTrue(instructions.contains("Settings → Shortcuts"))
        XCTAssertFalse(instructions.contains("Press ⌥⇧U"), "That key is disabled, so no combo may be promised.")
        XCTAssertEqual(store.binding(for: .topLeft), disabled, "Teaching must not enable a shortcut.")
    }

    func testCustomizedShortcutsAreTaughtWithoutPromisingDefaultModifiers() throws {
        store.set(HotkeyBinding(modifiers: UInt32(controlKey | optionKey), keyCode: UInt32(kVK_ANSI_A)),
                  for: .topLeft)
        store.set(HotkeyBinding(modifiers: UInt32(cmdKey), keyCode: UInt32(kVK_ANSI_B)),
                  for: .middleColumn)
        let view = WelcomeTab(hotkeyStore: store).build(size: NSSize(width: 440, height: 480))
        let text = textLabels(in: view)
        let instructions = try XCTUnwrap(text.first { $0.hasPrefix("1.") })

        XCTAssertTrue(instructions.contains("Press ⌃⌥A"))
        XCTAssertFalse(text.contains { $0.contains("Hold ⌥⇧ with the sixths keys") },
                       "Modifier families are defaults, not a promise about customized bindings.")
    }

    func testDisabledTopLeftNamesTheMenuSwitchRowForChangingLayouts() throws {
        store.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: .topLeft)
        let view = WelcomeTab(hotkeyStore: store).build(size: NSSize(width: 440, height: 480))
        let instructions = try XCTUnwrap(textLabels(in: view).first { $0.hasPrefix("1.") })

        XCTAssertTrue(instructions.contains("Sixths"))
        XCTAssertTrue(instructions.contains("Switch to Quarters"),
                      "The menu only lists active-layout slots; Top Left is absent in Sixths.")
    }

    func testFailedTopLeftRegistrationTeachesTheMenuInsteadOfTheDeadCombo() throws {
        let tab = WelcomeTab(hotkeyStore: store)
        tab.failedActionsProvider = { [.slotKey(.topLeft)] }
        let view = tab.build(size: NSSize(width: 440, height: 480))
        let instructions = try XCTUnwrap(textLabels(in: view).first { $0.hasPrefix("1.") })

        XCTAssertTrue(instructions.contains("Menu bar → Tile Focused Window → Top Left"))
        XCTAssertTrue(instructions.contains("couldn't be registered"))
        XCTAssertFalse(
            instructions.contains("Press ⌥⇧U"),
            "A combo that lost global registration still has a label; the guide must not teach it.")
    }

    func testFailedExpandRegistrationTeachesTheMenuInsteadOfTheDeadCombo() throws {
        let tab = WelcomeTab(hotkeyStore: store)
        tab.failedActionsProvider = { [.expand] }
        let view = tab.build(size: NSSize(width: 440, height: 480))
        let behavior = try XCTUnwrap(
            textLabels(in: view).first { $0.hasPrefix("Drag a tiled window far") })

        XCTAssertTrue(behavior.contains("Menu bar → Expand to Fill Screen"))
        XCTAssertFalse(
            behavior.contains("⌥⇧⏎"),
            "A failed Expand combo must never be printed as if it works.")
    }

    func testRegistrationFailureArrivingAfterBuildReplacesTheComboInstructions() throws {
        var failed: [HotkeyAction] = []
        let tab = WelcomeTab(hotkeyStore: store)
        tab.failedActionsProvider = { failed }
        let view = tab.build(size: NSSize(width: 440, height: 480))
        var instructions = try XCTUnwrap(textLabels(in: view).first { $0.hasPrefix("1.") })
        XCTAssertTrue(instructions.contains("Press ⌥⇧U"))

        failed = [.slotKey(.topLeft)]
        tab.refreshShortcutInstructions()
        instructions = try XCTUnwrap(textLabels(in: view).first { $0.hasPrefix("1.") })

        XCTAssertFalse(instructions.contains("Press ⌥⇧U"))
        XCTAssertTrue(instructions.contains("couldn't be registered"))
    }

    func testReopeningTheVisibleGuideRefreshesItsShortcutInstructions() throws {
        let controller = SettingsWindowController(settings: AppSettings(defaults: defaults), hotkeyStore: store)
        defer { controller.close() }
        controller.show(selecting: .welcome)
        let view = try XCTUnwrap(controller.window?.contentView)
        XCTAssertTrue(textLabels(in: view).contains { $0.contains("Press ⌥⇧U") })

        store.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: .topLeft)
        controller.showWelcomeAgain()

        XCTAssertTrue(textLabels(in: view).contains { $0.contains("Top Left's shortcut is disabled") })
        XCTAssertFalse(textLabels(in: view).contains { $0.contains("Press ⌥⇧U") })
    }

    func testLiveSwitchComboAndItsUntilingConsequenceAreTaught() throws {
        store.set(
            HotkeyBinding(
                modifiers: UInt32(controlKey | optionKey),
                keyCode: UInt32(kVK_ANSI_Backslash)),
            for: .switchLayout)
        let view = WelcomeTab(hotkeyStore: store).build(size: NSSize(width: 440, height: 480))
        let behavior = try XCTUnwrap(
            textLabels(in: view).first { $0.hasPrefix("Drag a tiled window far") })

        XCTAssertTrue(
            behavior.contains("⌃⌥\\ switches the canvas to the other layout and untiles every window"),
            "the guide teaches the live switch combo and the consequence")
        XCTAssertTrue(behavior.contains("undo puts them back"))
    }

    func testFailedSwitchRegistrationTeachesTheMenuRowNotTheDeadCombo() throws {
        let tab = WelcomeTab(hotkeyStore: store)
        tab.failedActionsProvider = { [.switchLayout] }
        let view = tab.build(size: NSSize(width: 440, height: 480))
        let behavior = try XCTUnwrap(
            textLabels(in: view).first { $0.hasPrefix("Drag a tiled window far") })

        XCTAssertTrue(behavior.contains("Menu bar → Switch to Sixths"))
        XCTAssertFalse(
            behavior.contains("⌥⇧\\"),
            "a failed switch combo must never be printed as if it works")
    }
}
