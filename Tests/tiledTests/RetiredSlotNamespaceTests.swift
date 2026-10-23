import Foundation
import XCTest

@testable import tiled

/// The one-way retirement of the old quarter hotkey namespace. The shared
/// ⌥⇧ keys persist under the sixths slot names, so only the six quarter
/// names are deleted at launch: overrides, section parks, and reset
/// snapshots alike. A second run is a no-op and leaves every surviving
/// entry exactly as it was.
final class RetiredSlotNamespaceTests: XCTestCase {
    private var suiteName: String { "RetiredSlotNamespaceTests-\(UUID().uuidString)" }

    private func makeDefaults() -> (suite: String, defaults: UserDefaults) {
        let suite = suiteName
        return (suite, UserDefaults(suiteName: suite)!)
    }

    private func cleanup(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func storedKeys(in defaults: UserDefaults) -> Set<String> {
        let prefixes = ["hotkey.", "parkedHotkey.", "resetBackupHotkey."]
        return Set(
            defaults.dictionaryRepresentation().keys.filter { key in
                prefixes.contains { key.hasPrefix($0) }
            })
    }

    private func retiredKeys(in defaults: UserDefaults) -> Set<String> {
        storedKeys(in: defaults).filter { key in
            SlotKey.retiredQuarterStorageKeys.contains { key.hasSuffix("." + $0) }
        }
    }

    func testOldSixthsOverrideSurvivesRetirement() {
        let (suite, defaults) = makeDefaults()
        defer { cleanup(suite) }
        let custom = HotkeyBinding(modifiers: 7, keyCode: 41)
        defaults.set(custom.storedEntry, forKey: "hotkey.sixthTopLeft")

        let store = HotkeyStore(defaults: defaults)
        store.removeRetiredSlotBindings()

        XCTAssertEqual(
            store.binding(for: .slotKey(.topLeft)), custom,
            "the shared key keeps resolving the sixths override")
    }

    func testOldQuarterBindingIsRemoved() {
        let (suite, defaults) = makeDefaults()
        defer { cleanup(suite) }
        defaults.set(
            HotkeyBinding(modifiers: 1, keyCode: 2).storedEntry,
            forKey: "hotkey.topLeft")
        let store = HotkeyStore(defaults: defaults)

        store.removeRetiredSlotBindings()

        XCTAssertNil(
            defaults.object(forKey: "hotkey.topLeft"),
            "the inert quarter storage name is gone")
        XCTAssertEqual(
            store.binding(for: .slotKey(.topLeft)),
            HotkeyStore.defaultBinding(for: .slotKey(.topLeft)),
            "the shared key falls back to its default, not the retired override")
    }

    func testOldQuarterSectionParksAndResetEntriesAreRemoved() {
        let (suite, defaults) = makeDefaults()
        defer { cleanup(suite) }
        let binding = HotkeyBinding(modifiers: 3, keyCode: 4)
        defaults.set(binding.storedEntry, forKey: "parkedHotkey.topLeft")
        defaults.set(binding.storedEntry, forKey: "resetBackupHotkey.leftHalf")
        defaults.set(binding.storedEntry, forKey: "parkedHotkey.bottomRight")
        let park = ShortcutPark(store: UserDefaultsParkStore(defaults: defaults))

        park.removeRetiredSlotParks()

        XCTAssertTrue(
            retiredKeys(in: defaults).isEmpty,
            "every retired quarter park and reset entry is deleted")
    }

    func testSecondRetirementRunIsANoOp() {
        let (suite, defaults) = makeDefaults()
        defer { cleanup(suite) }
        let sixths = HotkeyBinding(modifiers: 5, keyCode: 6)
        let unrelated = HotkeyBinding(modifiers: 7, keyCode: 8)
        defaults.set(sixths.storedEntry, forKey: "hotkey.sixthTopLeft")
        defaults.set(unrelated.storedEntry, forKey: "hotkey.action.expand")
        defaults.set(sixths.storedEntry, forKey: "parkedHotkey.sixthTopLeft")
        let store = HotkeyStore(defaults: defaults)
        let park = ShortcutPark(store: UserDefaultsParkStore(defaults: defaults))

        store.removeRetiredSlotBindings()
        park.removeRetiredSlotParks()
        let afterFirst = Set(defaults.dictionaryRepresentation().keys)
        store.removeRetiredSlotBindings()
        park.removeRetiredSlotParks()

        XCTAssertEqual(
            Set(defaults.dictionaryRepresentation().keys), afterFirst,
            "a second launch deletes nothing and writes no marker")
        XCTAssertEqual(store.binding(for: .slotKey(.topLeft)), sixths)
        XCTAssertEqual(store.binding(for: .expand), unrelated)
        XCTAssertEqual(
            park.binding(for: .slotKey(.topLeft), kind: .section), sixths,
            "the sixths section park survives both runs")
    }

    func testUnrelatedKeysSurviveRetirement() {
        let (suite, defaults) = makeDefaults()
        defer { cleanup(suite) }
        let unrelated = HotkeyBinding(modifiers: 9, keyCode: 10)
        defaults.set(unrelated.storedEntry, forKey: "hotkey.action.undo")
        defaults.set(unrelated.storedEntry, forKey: "parkedHotkey.sixthMiddle")
        defaults.set(unrelated.storedEntry, forKey: "resetBackupHotkey.action.expand")
        let store = HotkeyStore(defaults: defaults)
        let park = ShortcutPark(store: UserDefaultsParkStore(defaults: defaults))

        store.removeRetiredSlotBindings()
        park.removeRetiredSlotParks()

        XCTAssertEqual(store.binding(for: .undo), unrelated)
        XCTAssertEqual(
            park.binding(for: .slotKey(.middleColumn), kind: .section), unrelated,
            "a sixths section park is untouched")
        XCTAssertTrue(
            park.anyResetBackup(),
            "an app action's reset backup is untouched")
    }
}
