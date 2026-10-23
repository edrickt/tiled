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
        park.park(oldTopLeft, for: .slotKey(.topLeft), kind: .section)
        park.park(parkedTopRight, for: .slotKey(.topRight), kind: .section)

        var table = current()
        table[.slotKey(.topLeft)] = edit
        table[.slotKey(.topRight)] = disabled()
        let plan = park.bulkRestorePlan(for: SlotKey.allCases.map(HotkeyAction.slotKey), current: table)

        XCTAssertEqual(
            plan.keptEdits, [BulkRestorePlan.KeptEdit(action: .slotKey(.topLeft), binding: edit)],
            "a slot edited while disabled keeps the edit, never the stale park")
        XCTAssertFalse(
            plan.restored.contains { $0.action == .slotKey(.topLeft) },
            "the stale park is not restored over the fresh edit")
        XCTAssertEqual(
            plan.restored, [BulkRestorePlan.Restored(action: .slotKey(.topRight), binding: parkedTopRight)],
            "the unedited disabled slot restores its parked combo")
        XCTAssertEqual(
            Set(plan.clearedParks), [.slotKey(.topLeft), .slotKey(.topRight)],
            "the applied park and the stale park are both consumed")
        XCTAssertTrue(plan.clashes.isEmpty)
    }

    func testBulkPlanRetainsAParkWhoseComboAnotherSectionClaimed() {
        let park = ShortcutPark(store: InMemoryParkStore())
        let combo = binding(keyCode: kVK_ANSI_J, modifiers: UInt32(controlKey | optionKey))
        park.park(combo, for: .slotKey(.topLeft), kind: .section)

        var table = current()
        table[.slotKey(.topLeft)] = disabled()
        table[.expand] = combo
        let plan = park.bulkRestorePlan(for: SlotKey.allCases.map(HotkeyAction.slotKey), current: table)

        XCTAssertTrue(plan.restored.isEmpty)
        XCTAssertEqual(
            plan.clashes,
            [BulkRestorePlan.Clash(
                action: .slotKey(.topLeft), binding: combo, owners: [.expand])],
            "an outside owner refuses the restore and is named")
        XCTAssertEqual(
            park.binding(for: .slotKey(.topLeft), kind: .section), combo,
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
        park.park(topLeft, for: .slotKey(.topLeft), kind: .resetBackup)
        park.park(topRight, for: .slotKey(.topRight), kind: .resetBackup)

        let plan = park.snapshotRestorePlan(current: current())

        XCTAssertEqual(
            plan.accepted,
            [.slotKey(.topLeft): topLeft, .slotKey(.topRight): topRight],
            "each combo currently belongs to the other snapshot action, which is not a clash")
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertTrue(plan.remaining.isEmpty, "a fully applied snapshot leaves no retry state")
    }

    func testSnapshotPlanRetainsAClashSkippedEntryForARetry() {
        let park = ShortcutPark(store: InMemoryParkStore())
        let combo = binding(keyCode: kVK_ANSI_J, modifiers: UInt32(controlKey | optionKey))
        park.park(combo, for: .slotKey(.topLeft), kind: .resetBackup)

        var table = current()
        table[.expand] = combo
        let plan = park.snapshotRestorePlan(current: table)

        XCTAssertTrue(plan.accepted.isEmpty)
        XCTAssertEqual(
            plan.skipped,
            [SnapshotRestorePlan.Skipped(
                action: .slotKey(.topLeft), owners: [.expand])])
        XCTAssertEqual(
            plan.remaining, [.slotKey(.topLeft): combo],
            "the skipped entry stays parked for the next Restore Previous Shortcuts")
        XCTAssertEqual(
            park.binding(for: .slotKey(.topLeft), kind: .resetBackup), combo,
            "the plan does not clear the retry state it reports")
    }

    func testSnapshotFixpointDemotesAnEntryWhoseComboARefusedEntryStillHolds() {
        let park = ShortcutPark(store: InMemoryParkStore())
        let topLeftBackup = binding(keyCode: kVK_ANSI_Y, modifiers: UInt32(optionKey))
        let topRightBackup = binding(keyCode: kVK_ANSI_Z, modifiers: UInt32(optionKey))
        park.park(topLeftBackup, for: .slotKey(.topLeft), kind: .resetBackup)
        park.park(topRightBackup, for: .slotKey(.topRight), kind: .resetBackup)

        var table = current()
        table[.slotKey(.topLeft)] = binding(keyCode: kVK_ANSI_X)
        // Top Right refused because an outside action holds its backup, so
        // it keeps this combo; Top Left must not take it in the same pass.
        table[.slotKey(.topRight)] = topLeftBackup
        table[.expand] = topRightBackup
        let plan = park.snapshotRestorePlan(current: table)

        XCTAssertTrue(plan.accepted.isEmpty)
        XCTAssertEqual(
            Set(plan.remaining.keys), [.slotKey(.topLeft), .slotKey(.topRight)],
            "both entries remain available for a later press")
        XCTAssertEqual(
            Set(plan.skipped.map(\.action)), [.slotKey(.topLeft), .slotKey(.topRight)])
        XCTAssertEqual(
            plan.skipped.first { $0.action == .slotKey(.topLeft) }?.owners,
            [.slotKey(.topRight)],
            "the fixpoint names the refused entry that still visibly holds the combo")
    }

    func testParkNamespacesKeepTheirStoredPrefixesAndCodec() {
        let suite = "ShortcutParkTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let park = ShortcutPark(store: UserDefaultsParkStore(defaults: defaults))
        let section = binding(keyCode: kVK_ANSI_A)
        let snapshotDisabled = disabled()
        park.park(section, for: .slotKey(.topLeft), kind: .section)
        park.park(snapshotDisabled, for: .slotKey(.topRight), kind: .resetBackup)

        XCTAssertNotNil(
            defaults.dictionary(forKey: "parkedHotkey.sixthTopLeft"),
            "section parks keep the persisted parkedHotkey. prefix")
        XCTAssertNil(defaults.dictionary(forKey: "resetBackupHotkey.topLeft"))
        XCTAssertNotNil(
            defaults.dictionary(forKey: "resetBackupHotkey.sixthTopRight"),
            "reset snapshots keep the persisted resetBackupHotkey. prefix")
        XCTAssertNil(
            park.binding(for: .slotKey(.topRight), kind: .section),
            "a disabled entry is never offered as a section park")
        XCTAssertEqual(
            park.binding(for: .slotKey(.topRight), kind: .resetBackup), snapshotDisabled,
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
            forKey: "resetBackupHotkey.\(HotkeyAction.slotKey(.topLeft).storageKey)")

        XCTAssertNil(park.binding(for: .slotKey(.topLeft), kind: .resetBackup))
        XCTAssertFalse(park.anyResetBackup())
        XCTAssertEqual(park.footerTitle, "Reset Shortcuts")
    }

    func testFooterFollowsTheResetSnapshotTwoStateAnswer() {
        let park = ShortcutPark(store: InMemoryParkStore())
        XCTAssertEqual(park.footerTitle, "Reset Shortcuts")
        XCTAssertFalse(park.anyResetBackup())

        park.park(disabled(), for: .slotKey(.topLeft), kind: .resetBackup)
        XCTAssertTrue(
            park.anyResetBackup(),
            "an all-disabled snapshot is still a backup the footer offers to restore")
        XCTAssertEqual(park.footerTitle, "Restore Previous Shortcuts")

        park.clear(.slotKey(.topLeft), kind: .resetBackup)
        XCTAssertEqual(park.footerTitle, "Reset Shortcuts")
    }
}
