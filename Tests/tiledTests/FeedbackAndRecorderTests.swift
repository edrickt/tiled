import AppKit
import Carbon.HIToolbox
import XCTest

@testable import tiled

/// The recorder's VoiceOver contract: each button names its slot (the row
/// label is a separate, unassociated static text) and exposes its binding
/// or recording state as the value, so the Shortcuts tab is seventeen
/// distinguishable controls, not seventeen anonymous buttons.
final class RecorderButtonAccessibilityTests: XCTestCase {
    func testInitLabelsTheSlot() {
        let button = RecorderButton(action: .slot(.topLeft))
        XCTAssertEqual(button.accessibilityLabel(), "Top Left shortcut")
    }

    func testValueCarriesTheBinding() {
        let button = RecorderButton(action: .slot(.topLeft))
        // keyCode 0 is kVK_ANSI_A: the value must carry the rendered label,
        // not just any non-nil string (e.g. "disabled").
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: 0))
        XCTAssertEqual(button.accessibilityValue() as? String, "A")
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: nil)) // disabled
        XCTAssertEqual(button.accessibilityValue() as? String, "disabled")
    }

    func testBeginRecordingMarksTheValueAsRecording() {
        let button = RecorderButton(action: .slot(.leftHalf))
        button.beginRecording { _ in }
        XCTAssertEqual(button.accessibilityValue() as? String, "recording")
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: nil))
    }

    func testDisabledInitRendersDisabledValue() {
        let button = RecorderButton(action: .slot(.sixthRight))
        XCTAssertEqual(button.accessibilityValue() as? String, "disabled")
    }
}

/// The failure HUD is gone: tiling feedback never pops a panel over the
/// workspace. Haptic + VoiceOver announcement + menu state carry every
/// outcome, so there is nothing here to test. This placeholder keeps the
/// file (and its recorder tests below) intact.


/// The recorder button's armed state machine, driven through the
/// extracted routing: a decisive key commits exactly once and disarms,
/// a non-decisive key is swallowed while staying armed, and a
/// pass-through key silently cancels (dropping the pending completion,
/// reverting the label, and firing onSilentCancel).
final class RecorderButtonRoutingTests: XCTestCase {
    private func keyDown(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode)!
    }

    func testDecisiveKeyFiresCompletionExactlyOnceAndDisarms() {
        let button = RecorderButton(action: .slot(.topLeft))
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: nil))
        var outcomes: [HotkeyRecorder.Outcome] = []
        button.beginRecording { outcomes.append($0) }
        XCTAssertTrue(button.isRecording)

        let passed = button.routeRecordedEvent(
            keyDown(keyCode: UInt16(kVK_ANSI_U), modifiers: [.option, .shift]))

        XCTAssertNil(passed, "the decisive keypress is swallowed")
        XCTAssertEqual(outcomes.count, 1, "completion fires exactly once")
        guard case .binding(let binding)? = outcomes.first else {
            return XCTFail("expected a binding outcome, got \(String(describing: outcomes.first))")
        }
        XCTAssertEqual(binding, HotkeyBinding(modifiers: UInt32(optionKey | shiftKey), keyCode: UInt32(kVK_ANSI_U)))
        XCTAssertFalse(button.isRecording, "the button disarms after the decision")

        // A second routed event after the decision passes through
        // untouched and never re-fires the (dropped) completion.
        XCTAssertNotNil(button.routeRecordedEvent(keyDown(keyCode: UInt16(kVK_ANSI_U))))
        XCTAssertEqual(outcomes.count, 1)
    }

    func testNonDecisiveKeyIsSwallowedAndStaysArmed() {
        let button = RecorderButton(action: .slot(.leftHalf))
        var fired = 0
        button.beginRecording { _ in fired += 1 }

        // A bare letter is neither decisive nor pass-through.
        let passed = button.routeRecordedEvent(keyDown(keyCode: UInt16(kVK_ANSI_A)))

        XCTAssertNil(passed, "non-decisive keys are swallowed")
        XCTAssertEqual(fired, 0, "no decision was made")
        XCTAssertTrue(button.isRecording, "the button stays armed")
    }

    func testPassThroughKeySilentlyCancels() {
        let button = RecorderButton(action: .slot(.sixthMiddle))
        let stored = HotkeyBinding(modifiers: UInt32(optionKey), keyCode: UInt32(kVK_ANSI_K))
        button.showBinding(stored)
        var silentCancels: [HotkeyAction] = []
        button.onSilentCancel = { silentCancels.append($0) }
        var fired = 0
        button.beginRecording { _ in fired += 1 }

        // Tab away mid-record: the event passes through so keyboard
        // navigation still works, and the recorder disarms undecided.
        let passed = button.routeRecordedEvent(keyDown(keyCode: UInt16(kVK_Tab)))

        XCTAssertNotNil(passed, "navigation keys pass through")
        XCTAssertEqual(fired, 0, "the pending completion is dropped, not fired")
        XCTAssertFalse(button.isRecording)
        XCTAssertEqual(silentCancels, [.slot(.sixthMiddle)])
        XCTAssertEqual(
            button.accessibilityValue() as? String, "⌥K",
            "the label reverts to the stored binding")
    }

    func testArmingAnnouncesAndDisarmRevertsTheDisabledLabel() {
        // Armed → silent cancel with no stored binding reverts to the
        // disabled label, and onArmed announced the capture window.
        let button = RecorderButton(action: .slot(.bottomRight))
        var armed: [HotkeyAction] = []
        button.onArmed = { armed.append($0) }
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: nil))

        button.beginRecording { _ in }
        XCTAssertEqual(armed, [.slot(.bottomRight)], "arming announces the capture window")
        XCTAssertEqual(button.accessibilityValue() as? String, "recording")

        _ = button.routeRecordedEvent(keyDown(keyCode: UInt16(kVK_Tab)))
        XCTAssertEqual(button.accessibilityValue() as? String, "disabled")
    }
}

/// The Enable-all bulk path must never silently destroy combos recorded
/// while the section was disabled: a stale park loses to a fresh edit,
/// and the tab says which slots it kept. Drives the real bulk button
/// (identifier "bulk-quarters") so the test covers the same path the
/// user clicks, including the rebuild that swaps the button itself.
/// Everything runs against a throwaway defaults suite: the park keys live
/// outside the store, so the tab's persistence is injected too; a leak
/// here would rewrite the developer's actual hotkeys.
final class ShortcutsBulkEnableTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: HotkeyStore!

    override func setUp() {
        super.setUp()
        suiteName = "ShortcutsBulkEnableTests-\(UUID().uuidString)"
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

    private func findButton(identifier: String, titledPrefix: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton,
           button.identifier?.rawValue == identifier,
           button.title.hasPrefix(titledPrefix)
        { return button }
        for subview in view.subviews {
            if let hit = findButton(identifier: identifier, titledPrefix: titledPrefix, in: subview) {
                return hit
            }
        }
        return nil
    }

    private func conflictText(in view: NSView) -> String? {
        if let field = view as? NSTextField,
           field.stringValue.contains("disabled:") {
            return field.stringValue
        }
        for subview in view.subviews {
            if let hit = conflictText(in: subview) { return hit }
        }
        return nil
    }

    /// The first visible label containing `needle`, for the reports that
    /// are not the park's "disabled:" advice (e.g. a restore's clash
    /// report).
    private func label(containing needle: String, in view: NSView) -> String? {
        if let field = view as? NSTextField, field.stringValue.contains(needle) {
            return field.stringValue
        }
        for subview in view.subviews {
            if let hit = label(containing: needle, in: subview) { return hit }
        }
        return nil
    }

    private func findRecorder(action: HotkeyAction, in view: NSView) -> RecorderButton? {
        if let button = view as? RecorderButton, button.hotkeyAction == action { return button }
        for subview in view.subviews {
            if let hit = findRecorder(action: action, in: subview) { return hit }
        }
        return nil
    }

    private func findRecorder(slot: Slot, in view: NSView) -> RecorderButton? {
        if let button = view as? RecorderButton, button.hotkeyAction == .slot(slot) { return button }
        for subview in view.subviews {
            if let hit = findRecorder(slot: slot, in: subview) { return hit }
        }
        return nil
    }

    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let hit = findButton(titled: title, in: subview) { return hit }
        }
        return nil
    }

    private func keyDown(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode)!
    }

    func testEnableAllKeepsEditsMadeWhileDisabled() {
        let tab = makeTab()
        var view = tab.build(size: NSSize(width: 440, height: 480), window: nil)

        // Disable the whole quarters section via its real bulk button.
        guard let disable = findButton(
            identifier: "bulk-quarters", titledPrefix: "Disable all", in: view)
        else { return XCTFail("expected a Disable-all bulk button") }
        disable.performClick(nil)

        // The click rebuilds content; re-resolve the enable button from a
        // fresh build (performClick above rebuilt synchronously).
        view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        XCTAssertEqual(
            store.binding(for: .topLeft).keyCode, nil,
            "section disabled: Top Left has no combo")

        // Record a fresh combo into the disabled slot (legitimate edit).
        let fresh = HotkeyBinding(modifiers: 0, keyCode: 6)
        XCTAssertEqual(store.apply(fresh, for: .topLeft), .applied)

        // Enable the section via its real bulk button.
        guard let enable = findButton(
            identifier: "bulk-quarters", titledPrefix: "Enable all", in: view)
        else { return XCTFail("expected an Enable-all bulk button after disabling") }
        enable.performClick(nil)

        XCTAssertEqual(
            store.binding(for: .topLeft), fresh,
            "the fresh edit wins over the stale park; no silent data loss")
        XCTAssertNil(
            defaults.dictionary(forKey: "parkedHotkey.topLeft"),
            "the stale park is dropped, not left to strike later")
    }

    func testEnableAllKeepsDisabledWhenTheParkedComboWasClaimed() {
        // A combo parked by Disable all can be claimed by another
        // section's edit while this one is disabled. Enable all must not
        // store it past the duplicate gate: the slot would render as
        // enabled and never register.
        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let disable = findButton(
            identifier: "bulk-quarters", titledPrefix: "Disable all", in: view)
        else { return XCTFail("expected a Disable-all bulk button") }
        let parked = store.binding(for: .topLeft)
        disable.performClick(nil)

        // Another section claims the parked combo while quarters is off.
        XCTAssertEqual(store.apply(parked, for: .sixthTopLeft), .applied)

        let view2 = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let enable = findButton(
            identifier: "bulk-quarters", titledPrefix: "Enable all", in: view2)
        else { return XCTFail("expected an Enable-all bulk button") }
        enable.performClick(nil)

        XCTAssertNil(
            store.binding(for: .topLeft).keyCode,
            "the claimed combo is not restored; the slot stays disabled")
        XCTAssertEqual(
            store.binding(for: .sixthTopLeft), parked,
            "the edit that claimed the combo keeps it")
        XCTAssertNotNil(
            defaults.dictionary(forKey: "parkedHotkey.topLeft"),
            "the park survives for when the clash is resolved")
    }

    func testStaleParkDoesNotClobberWhenNothingWasEdited() {
        // The complement: with no post-disable edits, Enable all restores
        // the parked combos exactly (the pre-existing contract).
        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let disable = findButton(
            identifier: "bulk-quarters", titledPrefix: "Disable all", in: view)
        else { return XCTFail("expected a Disable-all bulk button") }
        let before = store.binding(for: .topRight)
        disable.performClick(nil)
        XCTAssertEqual(store.binding(for: .topRight).keyCode, nil)

        let view2 = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let enable = findButton(
            identifier: "bulk-quarters", titledPrefix: "Enable all", in: view2)
        else { return XCTFail("expected an Enable-all bulk button") }
        enable.performClick(nil)
        XCTAssertEqual(
            store.binding(for: .topRight), before,
            "unedited slots restore their parked combos verbatim")
    }

    /// The bulk button states the action it will take, but decides that
    /// action from the store at click time. A recorder commit changes the
    /// section without rebuilding the view, so the installed label has to
    /// follow — otherwise it reads "Disable all 6" and then enables.
    func testRecorderClearFlipsTheInstalledBulkButtonToEnable() {
        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let bulk = findButton(
            identifier: "bulk-quarters", titledPrefix: "Disable all", in: view)
        else { return XCTFail("expected a Disable-all bulk button") }
        guard let recorder = findRecorder(slot: .topLeft, in: view)
        else { return XCTFail("expected a Top Left recorder") }

        // ⌫ while recording disables the slot: the same edit the bulk
        // button performs, one slot at a time.
        recorder.performClick(nil)
        XCTAssertTrue(recorder.isRecording, "the click arms the recorder")
        _ = recorder.routeRecordedEvent(keyDown(keyCode: UInt16(kVK_Delete)))

        XCTAssertNil(store.binding(for: .topLeft).keyCode, "the clear landed")
        XCTAssertTrue(
            bulk.title.hasPrefix("Enable all"),
            "the installed bulk button must state the action it will take, got \(bulk.title)")
        XCTAssertEqual(
            bulk.toolTip,
            "Restores parked combos; slots edited while disabled keep their edits")

        // The label is not just cosmetic: the click it is about to
        // receive really does enable.
        bulk.performClick(nil)
        XCTAssertNotNil(
            store.binding(for: .topLeft).keyCode,
            "the button labelled Enable all enabled the section")
    }

    func testClearingARecorderNamesTheEnableAllRecovery() throws {
        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let recorder = findRecorder(slot: .topLeft, in: view)
        else { return XCTFail("expected a Top Left recorder") }
        XCTAssertNotNil(store.binding(for: .topLeft).label)

        recorder.performClick(nil)
        _ = recorder.routeRecordedEvent(keyDown(keyCode: UInt16(kVK_Delete)))

        XCTAssertNil(store.binding(for: .topLeft).keyCode, "the clear landed")
        let advice = try XCTUnwrap(conflictText(in: view))
        XCTAssertTrue(
            advice.contains("Enable all 6"),
            "the clear advice must name the recovery that actually restores the park, got: \(advice)")
        XCTAssertFalse(
            advice.lowercased().contains("reset"),
            "Reset Shortcuts is not the park's recovery; it resets everything, got: \(advice)")
    }

    func testClearingAnAppActionAdvisesReRecordingNotABulkRestore() throws {
        // App Actions have no Enable-all button, so their cleared park has
        // no bulk restore; the advice must not promise one (or name Reset,
        // which resets everything).
        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let recorder = findRecorder(action: .expand, in: view)
        else { return XCTFail("expected an Expand recorder") }

        recorder.performClick(nil)
        _ = recorder.routeRecordedEvent(keyDown(keyCode: UInt16(kVK_Delete)))

        XCTAssertNil(store.binding(for: .expand).keyCode, "the clear landed")
        let advice = try XCTUnwrap(conflictText(in: view))
        XCTAssertTrue(advice.contains("re-record"), advice)
        XCTAssertFalse(
            advice.contains("Enable all"),
            "app actions have no bulk restore, got: \(advice)")
    }

    func testRecordingIntoTheLastDisabledSlotFlipsTheBulkButtonToDisable() {
        // Top Left is the only disabled Quarters slot, so the section
        // reads "Enable all 6". Recording a combo into it leaves no
        // disabled slot, and the installed button must flip the other way.
        store.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: .topLeft)
        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let bulk = findButton(
            identifier: "bulk-quarters", titledPrefix: "Enable all", in: view)
        else { return XCTFail("expected an Enable-all bulk button") }
        guard let recorder = findRecorder(slot: .topLeft, in: view)
        else { return XCTFail("expected a Top Left recorder") }

        recorder.performClick(nil)
        _ = recorder.routeRecordedEvent(
            keyDown(keyCode: UInt16(kVK_ANSI_K), modifiers: [.option, .shift, .command]))

        XCTAssertNotNil(store.binding(for: .topLeft).keyCode, "the recorded combo landed")
        XCTAssertTrue(
            bulk.title.hasPrefix("Disable all"),
            "no disabled slot remains, so the installed button must offer Disable, got \(bulk.title)")
        XCTAssertEqual(
            bulk.toolTip,
            "Disable every Quarters shortcut (keeps defaults for re-enable)")
    }

    // MARK: Corrupt parks (the codec's guard, exercised through the reader)

    func testCorruptParkedEntriesDoNotTrapEnableAll() {
        // Every corrupt entry in the shared table, parked under a slot:
        // Enable all must read each as no park and fall back to the factory
        // default, never trapping in UInt32.
        for entry in CorruptHotkeyEntries.all {
            store.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: .topLeft)
            defaults.set(entry, forKey: "parkedHotkey.topLeft")

            let tab = makeTab()
            let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
            guard let enable = findButton(
                identifier: "bulk-quarters", titledPrefix: "Enable all", in: view)
            else { return XCTFail("expected an Enable-all bulk button for \(entry)") }
            enable.performClick(nil)

            XCTAssertEqual(
                store.binding(for: .topLeft), HotkeyStore.defaultBinding(for: .topLeft),
                "a corrupt park (\(entry)) is ignored, so the disabled slot returns to default")
        }
    }

    func testDisabledSentinelParkIsNotRestored() {
        // A park never holds a disabled sentinel (Disable all only parks
        // live combos), so one is not a combo to restore: Enable all falls
        // back to the default rather than leaving the slot disabled.
        store.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: .topLeft)
        defaults.set(["modifiers": 0, "keyCode": -1], forKey: "parkedHotkey.topLeft")

        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let enable = findButton(
            identifier: "bulk-quarters", titledPrefix: "Enable all", in: view)
        else { return XCTFail("expected an Enable-all bulk button") }
        enable.performClick(nil)

        XCTAssertEqual(
            store.binding(for: .topLeft), HotkeyStore.defaultBinding(for: .topLeft),
            "the disabled sentinel is not a parked combo")
    }

    // MARK: Corrupt reset backups (the codec's guard, through the other reader)

    func testCorruptResetBackupEntriesAreSkippedWithoutTrapping() {
        // A valid backup makes the footer offer the restore; each corrupt
        // entry in the shared table, under another action's reset key, must
        // be skipped without trapping.
        for entry in CorruptHotkeyEntries.all {
            defaults.set(
                ["modifiers": Int(controlKey), "keyCode": Int(kVK_ANSI_F)],
                forKey: "resetBackupHotkey.action.expand")
            defaults.set(entry, forKey: "resetBackupHotkey.action.undo")

            let tab = makeTab()
            let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
            guard let restore = findButton(titled: "Restore Previous Shortcuts", in: view)
            else { return XCTFail("expected a Restore Previous Shortcuts button for \(entry)") }
            restore.performClick(nil)

            XCTAssertEqual(
                store.binding(for: .expand),
                HotkeyBinding(modifiers: UInt32(controlKey), keyCode: UInt32(kVK_ANSI_F)),
                "the valid backup is restored (\(entry))")
            XCTAssertEqual(
                store.binding(for: .undo), HotkeyService.undoDefaultBinding,
                "the corrupt backup (\(entry)) is skipped, leaving the action at its default")
        }
    }

    // MARK: Reset backup restore (the clash path)

    /// The reset backup is the Disable-all park's twin and must keep the
    /// same clash rule: a combo the restore cannot store past the
    /// duplicate gate is never destroyed with it. The state is the
    /// leftover steady state — one backup entry whose combo is claimed
    /// by an action with no entry of its own (a first restore clashed,
    /// then the user reassigned the combo again) — driven through the
    /// real footer button, mirroring the bulk-enable park test above.
    func testRestoreKeepsTheBackupEntryWhenTheComboWasClaimed() {
        let claimed = HotkeyAction.slot(.topLeft)
        let claimer = HotkeyAction.slot(.sixthTopLeft)
        let combo = HotkeyBinding(
            modifiers: UInt32(controlKey | optionKey), keyCode: UInt32(kVK_ANSI_J))
        defaults.set(
            HotkeyBindingCodec.encode(combo),
            forKey: "resetBackupHotkey.\(claimed.storageKey)")
        XCTAssertEqual(store.apply(combo, for: claimer), .applied)

        let tab = makeTab()
        // If the retry ever routes to the reset dialog again, fail fast
        // instead of hanging on the modal session the dialog would run.
        tab.confirmReset = { _ in
            XCTFail("the retry must take the restore path, not the reset dialog")
            return false
        }
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let restore = findButton(titled: "Restore Previous Shortcuts", in: view)
        else { return XCTFail("expected a Restore Previous Shortcuts button for the leftover entry") }
        restore.performClick(nil)

        XCTAssertEqual(
            store.binding(for: claimed), HotkeyStore.defaultBinding(for: claimed),
            "the claimed combo is not restored past the gate")
        XCTAssertEqual(
            store.binding(for: claimer), combo,
            "the edit that claimed the combo keeps it")
        XCTAssertEqual(
            label(containing: "Not restored", in: view),
            "Not restored: \(claimed.title) (taken by \(claimer.title)).",
            "the partial restore reports the clash by name, so the promise "
                + "stays checkable instead of quietly half-kept")
        XCTAssertNotNil(
            defaults.dictionary(forKey: "resetBackupHotkey.\(claimed.storageKey)"),
            "the backup entry survives for when the clash is resolved")
        XCTAssertEqual(
            restore.title, "Restore Previous Shortcuts",
            "the button keeps offering the restore while a backup entry remains")

        // Free the combo and press again: the kept entry is the retry's
        // whole reason to exist.
        store.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: claimer)
        restore.performClick(nil)

        XCTAssertEqual(
            store.binding(for: claimed), combo,
            "after the user frees the combo, pressing the button again restores it")
        XCTAssertNil(
            defaults.dictionary(forKey: "resetBackupHotkey.\(claimed.storageKey)"),
            "an applied entry is cleared")
        XCTAssertEqual(
            restore.title, "Reset Shortcuts",
            "no backup entry remains, so the button flips back to the reset")
    }

    /// The first-reset dialog's promise — "Your current combos are kept;
    /// use Restore Previous Shortcuts to get them back" — pinned against
    /// what the two presses really do: the reset keeps every combo in
    /// the backup, and the restore gives every one of them back.
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
        ], "with no backup the dialog promises the keep-and-restore recovery")
        for (action, kept) in zip(HotkeyAction.allCases, before) {
            XCTAssertEqual(
                HotkeyBindingCodec.decode(
                    defaults.dictionary(forKey: "resetBackupHotkey.\(action.storageKey)")),
                kept,
                "the reset keeps every current combo (\(action.title))")
        }
        XCTAssertEqual(
            reset.title, "Restore Previous Shortcuts",
            "a full backup, so the button offers its restore")

        // The same button, second press: the restore side of the sequence.
        reset.performClick(nil)

        XCTAssertEqual(
            HotkeyAction.allCases.map { store.binding(for: $0) }, before,
            "Restore Previous Shortcuts gives every kept combo back")
        XCTAssertTrue(
            HotkeyAction.allCases.allSatisfy {
                defaults.dictionary(forKey: "resetBackupHotkey.\($0.storageKey)") == nil
            },
            "every restored entry is cleared")
        XCTAssertEqual(
            reset.title, "Reset Shortcuts",
            "no backup entry remains, so the button flips back to the reset")
    }
}
