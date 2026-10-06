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

    private func labels(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { labels(in: $0) }
    }

    func testDisabledTopLeftTeachesTheMenuInsteadOfAnotherSlotsShortcut() throws {
        let disabled = HotkeyBinding(modifiers: 0, keyCode: nil)
        store.set(disabled, for: .topLeft)
        let tab = WelcomeTab(hotkeyStore: store)
        let view = tab.build(size: NSSize(width: 440, height: 480))
        let instructions = try XCTUnwrap(labels(in: view).first { $0.hasPrefix("1.") })

        XCTAssertTrue(instructions.contains("Tile Focused Window → Top Left"))
        XCTAssertTrue(instructions.contains("Settings → Shortcuts"))
        XCTAssertFalse(instructions.contains("Press ⌥⇧U"), "That default belongs to Top Left Sixth.")
        XCTAssertEqual(store.binding(for: .topLeft), disabled, "Teaching must not enable a shortcut.")
    }

    func testCustomizedShortcutsAreTaughtWithoutPromisingDefaultModifiers() throws {
        store.set(HotkeyBinding(modifiers: UInt32(controlKey | optionKey), keyCode: UInt32(kVK_ANSI_A)),
                  for: .topLeft)
        store.set(HotkeyBinding(modifiers: UInt32(cmdKey), keyCode: UInt32(kVK_ANSI_B)),
                  for: .sixthMiddle)
        let view = WelcomeTab(hotkeyStore: store).build(size: NSSize(width: 440, height: 480))
        let text = labels(in: view)
        let instructions = try XCTUnwrap(text.first { $0.hasPrefix("1.") })

        XCTAssertTrue(instructions.contains("Press ⌃⌥A"))
        XCTAssertFalse(text.contains { $0.contains("Hold ⌥⇧ with the sixths keys") },
                       "Modifier families are defaults, not a promise about customized bindings.")
    }

    func testDisabledTopLeftNamesTheMenuSwitchNeededWhenSixthsIsActive() throws {
        store.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: .topLeft)
        let view = WelcomeTab(hotkeyStore: store).build(size: NSSize(width: 440, height: 480))
        let instructions = try XCTUnwrap(labels(in: view).first { $0.hasPrefix("1.") })

        XCTAssertTrue(instructions.contains("Sixths"))
        XCTAssertTrue(instructions.contains("Switch to Quarters"),
                      "The menu only lists active-layout slots; Top Left is absent in Sixths.")
    }

    func testReopeningTheVisibleGuideRefreshesItsShortcutInstructions() throws {
        let controller = SettingsWindowController(settings: AppSettings(defaults: defaults), hotkeyStore: store)
        defer { controller.close() }
        controller.show(selecting: .welcome)
        let view = try XCTUnwrap(controller.window?.contentView)
        XCTAssertTrue(labels(in: view).contains { $0.contains("Press ⌥⇧⌘U") })

        store.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: .topLeft)
        controller.showWelcomeAgain()

        XCTAssertTrue(labels(in: view).contains { $0.contains("Top Left's shortcut is disabled") })
        XCTAssertFalse(labels(in: view).contains { $0.contains("Press ⌥⇧⌘U") })
    }
}
