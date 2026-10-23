import Carbon.HIToolbox
import XCTest

@testable import tiled

/// The park model's pure decisions: a stale edit beats its older section
/// park, a reset snapshot restores a swapped pair as one state, and a
/// skipped or fixpoint-demoted snapshot entry stays in the backup for the
/// next press instead of vanishing.
final class ShortcutParkTests: XCTestCase {
    private func binding(keyCode: Int, modifiers: UInt32 = 0) -> HotkeyBinding {
        HotkeyBinding(modifiers: modifiers, keyCode: UInt32(keyCode))
    }

    /// A complete table, defaults with the requested overrides: the plans
    /// resolve duplicate owners against every action, not just the section.
    private func current(
        _ overrides: [HotkeyAction: HotkeyBinding] = [:]
    ) -> [HotkeyAction: HotkeyBinding] {
        var table = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map {
            ($0, $0.defaultBinding)
        })
        for (action, binding) in overrides {
            table[action] = binding
        }
        return table
    }

    private func disabled() -> HotkeyBinding {
        HotkeyBinding(modifiers: 0, keyCode: nil)
    }

    func testBulkPlanKeepsAnEditMadeWhileDisabledAndDropsOnlyItsPark() {
        let park = ShortcutPark(store: InMemoryParkStore())
        let oldTopLeft = binding(keyCode: kVK_ANSI_U)
        let edit = binding(keyCode: kVK_ANSI_K, modifiers: UInt32(optionKey))
        let parkedTopRight = binding(keyCode: kVK_ANSI_I)
        park.park(oldTopLeft, for: .slot(.topLeft), kind: .section)
        park.park(parkedTopRight, for: .slot(.topRight), kind: .section)

        var table = current()
        table[.slot(.topLeft)] = edit
        table[.slot(.topRight)] = disabled()
        let plan = park.bulkRestorePlan(for: .quarters, current: table)

        XCTAssertEqual(
            plan.keptEdits, [BulkRestorePlan.KeptEdit(action: .slot(.topLeft), binding: edit)],
            "a slot edited while disabled keeps the edit, never the stale park")
        XCTAssertFalse(
            plan.restored.contains { $0.action == .slot(.topLeft) },
            "the stale park is not restored over the fresh edit")
        XCTAssertEqual(
            plan.restored, [BulkRestorePlan.Restored(action: .slot(.topRight), binding: parkedTopRight)],
            "the unedited disabled slot restores its parked combo")
        XCTAssertEqual(
            Set(plan.clearedParks), [.slot(.topLeft), .slot(.topRight)],
            "the applied park and the stale park are both consumed")
        XCTAssertTrue(plan.clashes.isEmpty)
    }

    func testBulkPlanRetainsAParkWhoseComboAnotherSectionClaimed() {
        let park = ShortcutPark(store: InMemoryParkStore())
        let combo = binding(keyCode: kVK_ANSI_J, modifiers: UInt32(controlKey | optionKey))
        park.park(combo, for: .slot(.topLeft), kind: .section)

        var table = current()
        table[.slot(.topLeft)] = disabled()
        table[.slot(.sixthTopLeft)] = combo
        let plan = park.bulkRestorePlan(for: .quarters, current: table)

        XCTAssertTrue(plan.restored.isEmpty)
        XCTAssertEqual(
            plan.clashes,
            [BulkRestorePlan.Clash(
                action: .slot(.topLeft), binding: combo, owners: [.slot(.sixthTopLeft)])],
            "an outside owner refuses the restore and is named")
        XCTAssertEqual(
            park.binding(for: .slot(.topLeft), kind: .section), combo,
            "a clash-reported park survives for a later Enable all")
    }

    func testSnapshotPlanRestoresASwappedPairAsOneState() {
        let park = ShortcutPark(store: InMemoryParkStore())
        let topLeft = binding(
            keyCode: kVK_ANSI_O,
            modifiers: UInt32(cmdKey | optionKey | shiftKey))
        let topRight = binding(
            keyCode: kVK_ANSI_U,
            modifiers: UInt32(cmdKey | optionKey | shiftKey))
        park.park(topLeft, for: .slot(.topLeft), kind: .resetBackup)
        park.park(topRight, for: .slot(.topRight), kind: .resetBackup)

        let plan = park.snapshotRestorePlan(current: current())

        XCTAssertEqual(
            plan.accepted,
            [.slot(.topLeft): topLeft, .slot(.topRight): topRight],
            "each combo currently belongs to the other snapshot action, which is not a clash")
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertTrue(plan.remaining.isEmpty, "a fully applied snapshot leaves no retry state")
    }

    func testSnapshotPlanRetainsAClashSkippedEntryForARetry() {
        let park = ShortcutPark(store: InMemoryParkStore())
        let combo = binding(keyCode: kVK_ANSI_J, modifiers: UInt32(controlKey | optionKey))
        park.park(combo, for: .slot(.topLeft), kind: .resetBackup)

        var table = current()
        table[.slot(.sixthTopLeft)] = combo
        let plan = park.snapshotRestorePlan(current: table)

        XCTAssertTrue(plan.accepted.isEmpty)
        XCTAssertEqual(
            plan.skipped,
            [SnapshotRestorePlan.Skipped(
                action: .slot(.topLeft), owners: [.slot(.sixthTopLeft)])])
        XCTAssertEqual(
            plan.remaining, [.slot(.topLeft): combo],
            "the skipped entry stays parked for the next Restore Previous Shortcuts")
        XCTAssertEqual(
            park.binding(for: .slot(.topLeft), kind: .resetBackup), combo,
            "the plan does not clear the retry state it reports")
    }

    func testSnapshotFixpointDemotesAnEntryWhoseComboARefusedEntryStillHolds() {
        let park = ShortcutPark(store: InMemoryParkStore())
        let topLeftBackup = binding(keyCode: kVK_ANSI_Y, modifiers: UInt32(optionKey))
        let topRightBackup = binding(keyCode: kVK_ANSI_Z, modifiers: UInt32(optionKey))
        park.park(topLeftBackup, for: .slot(.topLeft), kind: .resetBackup)
        park.park(topRightBackup, for: .slot(.topRight), kind: .resetBackup)

        var table = current()
        table[.slot(.topLeft)] = binding(keyCode: kVK_ANSI_X)
        // Top Right refused because an outside action holds its backup, so
        // it keeps this combo; Top Left must not take it in the same pass.
        table[.slot(.topRight)] = topLeftBackup
        table[.slot(.sixthTopLeft)] = topRightBackup
        let plan = park.snapshotRestorePlan(current: table)

        XCTAssertTrue(plan.accepted.isEmpty)
        XCTAssertEqual(
            Set(plan.remaining.keys), [.slot(.topLeft), .slot(.topRight)],
            "both entries remain available for a later press")
        XCTAssertEqual(
            Set(plan.skipped.map(\.action)), [.slot(.topLeft), .slot(.topRight)])
        XCTAssertEqual(
            plan.skipped.first { $0.action == .slot(.topLeft) }?.owners,
            [.slot(.topRight)],
            "the fixpoint names the refused entry that still visibly holds the combo")
    }

    func testParkNamespacesKeepTheirStoredPrefixesAndCodec() {
        let suite = "ShortcutParkTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let park = ShortcutPark(store: UserDefaultsParkStore(defaults: defaults))
        let section = binding(keyCode: kVK_ANSI_A)
        let snapshotDisabled = disabled()
        park.park(section, for: .slot(.topLeft), kind: .section)
        park.park(snapshotDisabled, for: .slot(.topRight), kind: .resetBackup)

        XCTAssertNotNil(
            defaults.dictionary(forKey: "parkedHotkey.topLeft"),
            "section parks keep the persisted parkedHotkey. prefix")
        XCTAssertNil(defaults.dictionary(forKey: "resetBackupHotkey.topLeft"))
        XCTAssertNotNil(
            defaults.dictionary(forKey: "resetBackupHotkey.topRight"),
            "reset snapshots keep the persisted resetBackupHotkey. prefix")
        XCTAssertNil(
            park.binding(for: .slot(.topRight), kind: .section),
            "a disabled entry is never offered as a section park")
        XCTAssertEqual(
            park.binding(for: .slot(.topRight), kind: .resetBackup), snapshotDisabled,
            "a reset snapshot restores disabled actions exactly")
        XCTAssertTrue(park.anyResetBackup())
    }

    func testCorruptParkEntryIsUnreadableInsteadOfTrapping() {
        let suite = "ShortcutParkTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let park = ShortcutPark(store: UserDefaultsParkStore(defaults: defaults))
        defaults.set(
            ["modifiers": -1, "keyCode": Int(kVK_ANSI_J)],
            forKey: "resetBackupHotkey.\(HotkeyAction.slot(.topLeft).storageKey)")

        XCTAssertNil(park.binding(for: .slot(.topLeft), kind: .resetBackup))
        XCTAssertFalse(park.anyResetBackup())
        XCTAssertEqual(park.footerTitle, "Reset Shortcuts")
    }

    func testFooterFollowsTheResetSnapshotTwoStateAnswer() {
        let park = ShortcutPark(store: InMemoryParkStore())
        XCTAssertEqual(park.footerTitle, "Reset Shortcuts")
        XCTAssertFalse(park.anyResetBackup())

        park.park(disabled(), for: .slot(.topLeft), kind: .resetBackup)
        XCTAssertTrue(
            park.anyResetBackup(),
            "an all-disabled snapshot is still a backup the footer offers to restore")
        XCTAssertEqual(park.footerTitle, "Restore Previous Shortcuts")

        park.clear(.slot(.topLeft), kind: .resetBackup)
        XCTAssertEqual(park.footerTitle, "Reset Shortcuts")
    }
}
