import Carbon.HIToolbox
import XCTest
@testable import tiled

/// Phase 1: per-slot remappable hotkeys. Bindings persist in UserDefaults;
/// factory defaults are today's fixed set (Quarters = ⌥⇧, Sixths = ⌥⇧⌘).
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
            .topLeft: "⌥⇧U", .topRight: "⌥⇧O", .bottomLeft: "⌥⇧M",
            .bottomRight: "⌥⇧.", .leftHalf: "⌥⇧J", .rightHalf: "⌥⇧L",
            .sixthTopLeft: "⌥⇧⌘U", .sixthTopMiddle: "⌥⇧⌘I",
            .sixthTopRight: "⌥⇧⌘O", .sixthBottomLeft: "⌥⇧⌘M",
            .sixthBottomMiddle: "⌥⇧⌘,", .sixthBottomRight: "⌥⇧⌘.",
            .sixthLeft: "⌥⇧⌘J", .sixthMiddle: "⌥⇧⌘K",
            .sixthRight: "⌥⇧⌘L", .sixthsLeftTwoThirds: "⌥⇧⌘H",
            .sixthsRightTwoThirds: "⌥⇧⌘;",
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
}
