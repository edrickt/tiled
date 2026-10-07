import Carbon.HIToolbox
import XCTest
@testable import tiled

/// Phase 1: per-slot remappable hotkeys. Bindings persist in UserDefaults;
/// factory defaults are today's fixed set (Quarters = ⌥⇧⌘, Sixths = ⌥⇧).
final class HotkeyBindingTests: XCTestCase {
    private var suiteName: String { "tiledTests-\(UUID().uuidString)" }

    private func makeStore() -> HotkeyStore {
        HotkeyStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    // MARK: Defaults

    func testDefaultsMatchCurrentFixedHotkeys() {
        // The generated label for every default binding must equal the
        // hardcoded labels the menu and cheatsheet showed before custom
        // bindings existed.
        let expected: [Slot: String] = [
            .topLeft: "⌥⇧⌘U", .topRight: "⌥⇧⌘O", .bottomLeft: "⌥⇧⌘M",
            .bottomRight: "⌥⇧⌘.", .leftHalf: "⌥⇧⌘J", .rightHalf: "⌥⇧⌘L",
            .sixthTopLeft: "⌥⇧U", .sixthTopMiddle: "⌥⇧I",
            .sixthTopRight: "⌥⇧O", .sixthBottomLeft: "⌥⇧M",
            .sixthBottomMiddle: "⌥⇧,", .sixthBottomRight: "⌥⇧.",
            .sixthLeft: "⌥⇧J", .sixthMiddle: "⌥⇧K",
            .sixthRight: "⌥⇧L", .sixthsLeftTwoThirds: "⌥⇧H",
            .sixthsRightTwoThirds: "⌥⇧;",
        ]
        for slot in Slot.allCases {
            XCTAssertEqual(
                HotkeyStore.defaultBinding(for: slot).label, expected[slot],
                "\(slot.rawValue) default binding drifted")
        }
    }

    func testFreshStoreReturnsDefaults() {
        let store = makeStore()
        for slot in Slot.allCases {
            XCTAssertEqual(store.binding(for: slot), HotkeyStore.defaultBinding(for: slot))
        }
    }

    func testUnknownKeyCodeFallsBackToHex() {
        // A binding never renders blank, whatever the keycode.
        XCTAssertEqual(
            HotkeyBinding(modifiers: UInt32(optionKey), keyCode: 0xCA).label, "⌥0xCA")
    }

    func testLabelForFunctionKeys() {
        XCTAssertEqual(HotkeyBinding(modifiers: 0, keyCode: UInt32(kVK_F5)).label, "F5")
        XCTAssertEqual(HotkeyBinding(modifiers: UInt32(cmdKey), keyCode: UInt32(kVK_F12)).label, "⌘F12")
    }

    func testLabelForSpecialKeys() {
        XCTAssertEqual(HotkeyBinding(modifiers: 0, keyCode: UInt32(kVK_Space)).label, "Space")
        XCTAssertEqual(HotkeyBinding(modifiers: 0, keyCode: UInt32(kVK_Tab)).label, "Tab")
        XCTAssertEqual(HotkeyBinding(modifiers: 0, keyCode: UInt32(kVK_Return)).label, "⏎")
        XCTAssertEqual(HotkeyBinding(modifiers: 0, keyCode: UInt32(kVK_Escape)).label, "⎋")
        XCTAssertEqual(HotkeyBinding(modifiers: 0, keyCode: UInt32(kVK_Delete)).label, "⌫")
    }

    func testLabelForRemainingPunctuation() {
        let cases: [(UInt32, String)] = [
            (UInt32(kVK_ANSI_Minus), "-"), (UInt32(kVK_ANSI_Equal), "="),
            (UInt32(kVK_ANSI_LeftBracket), "["), (UInt32(kVK_ANSI_RightBracket), "]"),
            (UInt32(kVK_ANSI_Backslash), "\\"), (UInt32(kVK_ANSI_Quote), "'"),
            (UInt32(kVK_ANSI_Period), "."), (UInt32(kVK_ANSI_Slash), "/"),
            (UInt32(kVK_ANSI_Grave), "`"),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(
                HotkeyBinding(modifiers: UInt32(optionKey), keyCode: code).label,
                "⌥\(expected)", "keyCode \(code)")
        }
    }

    // MARK: Labels

    func testLabelOrdersModifiersControlOptionShiftCommand() {
        let binding = HotkeyBinding(
            modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey),
            keyCode: UInt32(kVK_ANSI_U))
        XCTAssertEqual(binding.label, "⌃⌥⇧⌘U")
    }

    func testLabelForPunctuationKeys() {
        XCTAssertEqual(
            HotkeyBinding(modifiers: UInt32(optionKey | shiftKey), keyCode: UInt32(kVK_ANSI_Comma))
                .label, "⌥⇧,")
        XCTAssertEqual(
            HotkeyBinding(
                modifiers: UInt32(optionKey | shiftKey), keyCode: UInt32(kVK_ANSI_Semicolon)
            ).label, "⌥⇧;")
    }

    func testDisabledBindingHasNoLabel() {
        XCTAssertNil(HotkeyBinding(modifiers: 0, keyCode: nil).label)
    }

    // MARK: Persistence

    func testCustomBindingRoundTripsThroughUserDefaults() {
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = HotkeyStore(defaults: defaults)
        let custom = HotkeyBinding(
            modifiers: UInt32(controlKey | optionKey), keyCode: UInt32(kVK_ANSI_F))
        store.set(custom, for: .topLeft)
        XCTAssertEqual(store.binding(for: .topLeft), custom)

        let reloaded = HotkeyStore(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .topLeft), custom)
    }

    func testDisabledSlotPersists() {
        let defaults = UserDefaults(suiteName: suiteName)!
        HotkeyStore(defaults: defaults).set(
            HotkeyBinding(modifiers: 0, keyCode: nil), for: .leftHalf)
        XCTAssertEqual(
            HotkeyStore(defaults: defaults).binding(for: .leftHalf),
            HotkeyBinding(modifiers: 0, keyCode: nil))
    }

    func testResetRestoresDefaults() {
        let store = makeStore()
        store.set(
            HotkeyBinding(modifiers: UInt32(controlKey), keyCode: UInt32(kVK_ANSI_F)),
            for: .topLeft)
        store.resetAll()
        XCTAssertEqual(store.binding(for: .topLeft), HotkeyStore.defaultBinding(for: .topLeft))
    }

    // MARK: Application (duplicate-safe writes for the Shortcuts tab)

    func testApplyStoresNonDuplicate() {
        let store = makeStore()
        let custom = HotkeyBinding(
            modifiers: UInt32(controlKey), keyCode: UInt32(kVK_ANSI_F))
        XCTAssertEqual(store.apply(custom, for: .topLeft), HotkeyStore.ApplyResult.applied)
        XCTAssertEqual(store.binding(for: .topLeft), custom)
    }

    func testApplyRejectsFixedShortcutCombos() {
        let store = makeStore()
        let before = store.binding(for: .topLeft)
        for (name, binding) in HotkeyStore.reservedCombos {
            XCTAssertEqual(
                store.apply(binding, for: .topLeft),
                .reserved(name: name),
                "\(name) must never be stolen by a slot")
            XCTAssertEqual(store.binding(for: .topLeft), before, "rejection leaves the store")
        }
        XCTAssertEqual(store.apply(HotkeyService.expandBinding, for: .sixthLeft),
                       .reserved(name: "Expand"))
    }

    func testResetSplittersComboIsReserved() {
        // ⌥⇧R is the fixed Reset Splitters combo: no slot may claim it.
        // Pinned separately from the loop over reservedCombos, which
        // passes vacuously until the combo is actually added to it.
        XCTAssertEqual(
            HotkeyStore.reservedOwner(of: HotkeyService.resetSplittersBinding),
            "Reset Splitters")
        let store = makeStore()
        XCTAssertEqual(
            store.apply(HotkeyService.resetSplittersBinding, for: .topLeft),
            .reserved(name: "Reset Splitters"))
    }

    func testApplyRejectsDuplicateWithoutStoring() {
        let store = makeStore()
        // topRight's factory default differs from topLeft's, so forcing
        // topLeft's combo onto it must be refused and leave it untouched.
        let dup = HotkeyStore.defaultBinding(for: .topLeft)
        XCTAssertEqual(
            store.apply(dup, for: .topRight),
            HotkeyStore.ApplyResult.duplicate(slots: [.topLeft]))
        XCTAssertEqual(
            store.binding(for: .topRight), HotkeyStore.defaultBinding(for: .topRight))
    }

    func testApplyDisabledBindingAlwaysApplies() {
        let store = makeStore()
        XCTAssertEqual(
            store.apply(HotkeyBinding(modifiers: 0, keyCode: nil), for: .topLeft),
            HotkeyStore.ApplyResult.applied)
        XCTAssertFalse(store.binding(for: .topLeft).isEnabled)
    }

    func testDuplicateDetectionIgnoresDisabledAndSelf() {
        let store = makeStore()
        let dup = HotkeyStore.defaultBinding(for: .topLeft)
        XCTAssertEqual(store.duplicates(of: dup, ignoring: .topRight), [.topLeft])
        XCTAssertTrue(store.duplicates(of: dup, ignoring: .topLeft).isEmpty)
        XCTAssertTrue(
            store.duplicates(of: HotkeyBinding(modifiers: 0, keyCode: nil), ignoring: .topLeft)
                .isEmpty)
    }

    // MARK: Corrupt stored data

    func testCorruptEntryFallsBackToDefaults() {
        let name = suiteName // capture once: the property regenerates per access
        UserDefaults(suiteName: name)!.set(
            ["modifiers": "not-a-number"], forKey: "hotkey.topLeft")

        XCTAssertEqual(
            HotkeyStore(defaults: UserDefaults(suiteName: name)!).binding(for: .topLeft),
            HotkeyStore.defaultBinding(for: .topLeft),
            "a malformed plist entry degrades to the factory default, not a crash")
    }

    func testPartialEntryFallsBackToDefaults() {
        let name = suiteName
        UserDefaults(suiteName: name)!.set(
            ["modifiers": 42], forKey: "hotkey.topLeft") // keyCode missing

        XCTAssertEqual(
            HotkeyStore(defaults: UserDefaults(suiteName: name)!).binding(for: .topLeft),
            HotkeyStore.defaultBinding(for: .topLeft))
    }

    func testStoredNegativeKeyCodeMeansDisabled() {
        let name = suiteName
        UserDefaults(suiteName: name)!.set(
            ["modifiers": Int(optionKey), "keyCode": -1], forKey: "hotkey.topLeft")

        let store = HotkeyStore(defaults: UserDefaults(suiteName: name)!)
        let binding = store.binding(for: .topLeft)
        XCTAssertFalse(binding.isEnabled)
        XCTAssertNil(binding.label)
        // A stored disabled binding never collides with a real combo.
        XCTAssertTrue(store.duplicates(
            of: HotkeyStore.defaultBinding(for: .topLeft), ignoring: .topRight).isEmpty)
    }

    func testStoredNegativeModifiersFallsBackToDefaults() {
        // Never written by set; corrupt data only (hand-edited plist,
        // older build). UInt32(modifiers) would trap, so the store must
        // reject the entry wholesale instead of trusting the key code.
        let name = suiteName
        UserDefaults(suiteName: name)!.set(
            ["modifiers": -5, "keyCode": 6], forKey: "hotkey.topLeft")

        let store = HotkeyStore(defaults: UserDefaults(suiteName: name)!)
        XCTAssertEqual(
            store.binding(for: .topLeft), HotkeyStore.defaultBinding(for: .topLeft),
            "corrupt modifiers fall back to the factory default")
    }
}
