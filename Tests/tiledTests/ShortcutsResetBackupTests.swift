import AppKit
import Carbon.HIToolbox
import XCTest

@testable import tiled

/// The one-step Reset Shortcuts backup must restore as one snapshot: a pair
/// of actions that swapped their defaults is a valid prior state, not two
/// separate recordings that conflict with each other.
final class ShortcutsResetBackupTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: HotkeyStore!

    override func setUp() {
        super.setUp()
        suiteName = "ShortcutsResetBackupTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = HotkeyStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        store = nil
        super.tearDown()
    }

    private func makeTab() -> ShortcutsTab {
        let tab = ShortcutsTab(hotkeyStore: store, defaults: defaults)
        tab.onContentRebuilt = { _ in }
        return tab
    }

    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let hit = findButton(titled: title, in: subview) { return hit }
        }
        return nil
    }

    private func park(_ binding: HotkeyBinding, for action: HotkeyAction) {
        defaults.set(
            ["modifiers": Int(binding.modifiers),
             "keyCode": binding.keyCode.map(Int.init) ?? -1],
            forKey: "resetBackupHotkey.\(action.storageKey)")
    }

    private func backup(for action: HotkeyAction) -> HotkeyBinding? {
        guard let dict = defaults.dictionary(forKey: "resetBackupHotkey.\(action.storageKey)"),
              let modifiers = dict["modifiers"] as? Int,
              let code = dict["keyCode"] as? Int,
              modifiers >= 0
        else { return nil }
        return HotkeyBinding(
            modifiers: UInt32(modifiers), keyCode: code >= 0 ? UInt32(code) : nil)
    }

    private func label(containing text: String, in view: NSView) -> String? {
        if let field = view as? NSTextField, field.stringValue.contains(text) {
            return field.stringValue
        }
        for subview in view.subviews {
            if let hit = label(containing: text, in: subview) { return hit }
        }
        return nil
    }

    func testRestorePreviousShortcutsRestoresASwappedPair() {
        // The factory pair is Top Left U / Top Right O. The backup is the
        // valid prior state where they had traded keys.
        let topLeft = HotkeyBinding(
            modifiers: UInt32(cmdKey | optionKey | shiftKey),
            keyCode: UInt32(kVK_ANSI_O))
        let topRight = HotkeyBinding(
            modifiers: UInt32(cmdKey | optionKey | shiftKey),
            keyCode: UInt32(kVK_ANSI_U))
        park(topLeft, for: .slotKey(.topLeft))
        park(topRight, for: .slotKey(.topRight))

        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let restore = findButton(titled: "Restore Previous Shortcuts", in: view)
        else { return XCTFail("expected a Restore Previous Shortcuts button") }

        restore.performClick(nil)

        XCTAssertEqual(
            store.binding(for: .topLeft), topLeft,
            "the snapshot's Top Left combo lands even though Top Right still holds it")
        XCTAssertEqual(
            store.binding(for: .topRight), topRight,
            "the snapshot's Top Right combo lands even though Top Left still holds it")
        XCTAssertNil(backup(for: .slotKey(.topLeft)), "the applied entry is cleared")
        XCTAssertNil(backup(for: .slotKey(.topRight)), "the applied entry is cleared")
    }

    func testRestoreKeepsTheBackupEntryWhenTheComboWasClaimed() {
        let claimed = HotkeyAction.slotKey(.topLeft)
        let claimer = HotkeyAction.expand
        let combo = HotkeyBinding(
            modifiers: UInt32(controlKey | optionKey), keyCode: UInt32(kVK_ANSI_J))
        park(combo, for: claimed)
        XCTAssertEqual(store.apply(combo, for: .expand), .applied)

        let tab = makeTab()
        tab.confirmReset = { _ in
            XCTFail("the retry must take the restore path, not the reset dialog")
            return false
        }
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let restore = findButton(titled: "Restore Previous Shortcuts", in: view)
        else { return XCTFail("expected a Restore Previous Shortcuts button") }

        restore.performClick(nil)

        XCTAssertEqual(
            store.binding(for: .topLeft), HotkeyStore.defaultBinding(for: .topLeft),
            "the claimed combo is not restored past the gate")
        XCTAssertEqual(
            store.binding(for: .expand), combo,
            "the action that claimed the combo keeps it")
        XCTAssertEqual(
            label(containing: "Not restored", in: view),
            "Not restored: Top Left (taken by Expand to Fill Screen).",
            "the partial restore names the clash")
        XCTAssertEqual(
            backup(for: claimed), combo,
            "the clash-reported backup survives for a retry")
        XCTAssertEqual(
            restore.title, "Restore Previous Shortcuts",
            "the button keeps offering the restore while a backup remains")

        // Free the combo and press again: the retained entry is the retry.
        store.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: .expand)
        restore.performClick(nil)

        XCTAssertEqual(store.binding(for: .topLeft), combo)
        XCTAssertNil(backup(for: claimed), "an applied entry is cleared")
        XCTAssertEqual(restore.title, "Reset Shortcuts")
    }

    func testCorruptResetBackupModifiersAreIgnoredInsteadOfTrapping() {
        defaults.set(
            ["modifiers": -1, "keyCode": Int(kVK_ANSI_J)],
            forKey: "resetBackupHotkey.\(HotkeyAction.slotKey(.topLeft).storageKey)")

        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)

        XCTAssertNotNil(
            findButton(titled: "Reset Shortcuts", in: view),
            "an unreadable backup is not offered as a restore")
    }

    func testCorruptSectionParkFallsBackToTheDefaultInsteadOfTrapping() {
        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let disable = findButton(titled: "Disable all 11", in: view)
        else { return XCTFail("expected the slot-key bulk button") }
        disable.performClick(nil)
        defaults.set(
            ["modifiers": -1, "keyCode": Int(kVK_ANSI_J)],
            forKey: "parkedHotkey.\(HotkeyAction.slotKey(.topLeft).storageKey)")
        let rebuilt = tab.build(size: NSSize(width: 440, height: 480), window: nil)

        guard let enable = findButton(titled: "Enable all 11", in: rebuilt)
        else { return XCTFail("expected the slot-key bulk button to flip") }
        enable.performClick(nil)

        XCTAssertEqual(
            store.binding(for: .topLeft),
            HotkeyStore.defaultBinding(for: .topLeft),
            "the corrupt park falls back to the factory default")
    }

    func testRestoreClashKeepsTheRegistrationFailureVisible() {
        let claimed = HotkeyAction.slotKey(.topLeft)
        let claimer = HotkeyAction.expand
        let combo = HotkeyBinding(
            modifiers: UInt32(controlKey | optionKey), keyCode: UInt32(kVK_ANSI_J))
        park(combo, for: claimed)
        XCTAssertEqual(store.apply(combo, for: .expand), .applied)

        let tab = makeTab()
        tab.failedActionsProvider = { [.expand] }
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let restore = findButton(titled: "Restore Previous Shortcuts", in: view)
        else { return XCTFail("expected a Restore Previous Shortcuts button") }

        restore.performClick(nil)

        let message = label(containing: "Not restored", in: view) ?? ""
        XCTAssertTrue(
            message.contains("Not restored: Top Left (taken by Expand to Fill Screen)."),
            "the partial restore names the clash")
        XCTAssertTrue(
            message.contains("Expand to Fill Screen") && message.contains("could not be registered"),
            "the registration failure stays visible beside the restore result")
    }

    func testFooterFollowsTheResetSnapshotOnReload() {
        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        XCTAssertNotNil(
            findButton(titled: "Reset Shortcuts", in: view),
            "no snapshot: the footer offers Reset")

        park(
            HotkeyBinding(modifiers: UInt32(optionKey), keyCode: UInt32(kVK_ANSI_J)),
            for: .slotKey(.topLeft))
        tab.reload()
        XCTAssertNotNil(
            findButton(titled: "Restore Previous Shortcuts", in: view),
            "a snapshot created outside the button still flips the footer on reload")

        defaults.removeObject(
            forKey: "resetBackupHotkey.\(HotkeyAction.slotKey(.topLeft).storageKey)")
        tab.reload()
        XCTAssertNotNil(
            findButton(titled: "Reset Shortcuts", in: view),
            "clearing the snapshot returns the footer to Reset")
    }

    func testResetControlIsTwoStateAndNeverOffersASecondReset() {
        let custom = HotkeyBinding(
            modifiers: UInt32(controlKey | optionKey), keyCode: UInt32(kVK_ANSI_J))
        store.set(custom, for: .topLeft)
        let before = HotkeyAction.allCases.map { store.binding(for: $0) }

        let tab = makeTab()
        var promises: [String] = []
        tab.confirmReset = { promises.append($0); return true }
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let reset = findButton(titled: "Reset Shortcuts", in: view)
        else { return XCTFail("expected a Reset Shortcuts button") }

        reset.performClick(nil)

        XCTAssertEqual(promises, [
            "Your current combos are kept; use Restore Previous Shortcuts to get them back.",
        ])
        for (action, kept) in zip(HotkeyAction.allCases, before) {
            XCTAssertEqual(
                backup(for: action), kept,
                "the reset parks one complete snapshot (\(action.title))")
        }
        XCTAssertEqual(
            reset.title, "Restore Previous Shortcuts",
            "the same control now offers the snapshot, not a second reset")

        reset.performClick(nil)

        XCTAssertEqual(
            promises.count, 1,
            "the second press restores; it never asks to overwrite the snapshot")
        XCTAssertEqual(
            HotkeyAction.allCases.map { store.binding(for: $0) }, before,
            "the snapshot restores as the state it was taken from")
        XCTAssertTrue(
            HotkeyAction.allCases.allSatisfy { backup(for: $0) == nil },
            "a fully restored snapshot leaves no backup behind")
        XCTAssertEqual(reset.title, "Reset Shortcuts")
    }

    func testResetDialogsPromiseHoldsThroughTheRestore() {
        store.set(
            HotkeyBinding(modifiers: UInt32(controlKey | optionKey), keyCode: UInt32(kVK_ANSI_J)),
            for: .topLeft)
        store.set(
            HotkeyBinding(modifiers: UInt32(controlKey | optionKey), keyCode: UInt32(kVK_ANSI_K)),
            for: .expand)
        let before = HotkeyAction.allCases.map { store.binding(for: $0) }

        let tab = makeTab()
        var promises: [String] = []
        tab.confirmReset = { promises.append($0); return true }
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let reset = findButton(titled: "Reset Shortcuts", in: view)
        else { return XCTFail("expected a Reset Shortcuts button") }

        reset.performClick(nil)

        XCTAssertEqual(promises, [
            "Your current combos are kept; use Restore Previous Shortcuts to get them back.",
        ])
        for (action, kept) in zip(HotkeyAction.allCases, before) {
            XCTAssertEqual(
                backup(for: action), kept,
                "the reset keeps every current combo (\(action.title))")
        }
        XCTAssertEqual(reset.title, "Restore Previous Shortcuts")

        reset.performClick(nil)

        XCTAssertEqual(
            HotkeyAction.allCases.map { store.binding(for: $0) }, before,
            "Restore Previous Shortcuts gives every kept combo back")
        XCTAssertTrue(
            HotkeyAction.allCases.allSatisfy { backup(for: $0) == nil },
            "every restored entry is cleared")
        XCTAssertEqual(reset.title, "Reset Shortcuts")
    }
}
