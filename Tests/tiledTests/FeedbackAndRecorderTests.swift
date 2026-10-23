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
        let button = RecorderButton(action: .slotKey(.topLeft))
        XCTAssertEqual(button.accessibilityLabel(), "Top Left shortcut")
    }

    func testValueCarriesTheBinding() {
        let button = RecorderButton(action: .slotKey(.topLeft))
        // keyCode 0 is kVK_ANSI_A: the value must carry the rendered label,
        // not just any non-nil string (e.g. "disabled").
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: 0))
        XCTAssertEqual(button.accessibilityValue() as? String, "A")
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: nil)) // disabled
        XCTAssertEqual(button.accessibilityValue() as? String, "disabled")
    }

    func testValueCarriesAModifiedArrowKeycap() {
        // VoiceOver reads the same rendered label the menu shows: a
        // modified arrow must not become "⌥0x7C".
        let button = RecorderButton(action: .slotKey(.topLeft))
        button.showBinding(
            HotkeyBinding(modifiers: UInt32(optionKey), keyCode: UInt32(kVK_RightArrow)))
        XCTAssertEqual(button.accessibilityValue() as? String, "⌥→")
    }

    func testBeginRecordingMarksTheValueAsRecording() {
        let button = RecorderButton(action: .slotKey(.leftColumn))
        button.beginRecording { _ in }
        XCTAssertEqual(button.accessibilityValue() as? String, "recording")
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: nil))
    }

    func testDisabledInitRendersDisabledValue() {
        let button = RecorderButton(action: .slotKey(.rightColumn))
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
        let button = RecorderButton(action: .slotKey(.topLeft))
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
        let button = RecorderButton(action: .slotKey(.leftColumn))
        var fired = 0
        button.beginRecording { _ in fired += 1 }

        // A bare letter is neither decisive nor pass-through.
        let passed = button.routeRecordedEvent(keyDown(keyCode: UInt16(kVK_ANSI_A)))

        XCTAssertNil(passed, "non-decisive keys are swallowed")
        XCTAssertEqual(fired, 0, "no decision was made")
        XCTAssertTrue(button.isRecording, "the button stays armed")
    }

    func testPassThroughKeySilentlyCancels() {
        let button = RecorderButton(action: .slotKey(.middleColumn))
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
        XCTAssertEqual(silentCancels, [.slotKey(.middleColumn)])
        XCTAssertEqual(
            button.accessibilityValue() as? String, "⌥K",
            "the label reverts to the stored binding")
    }

    func testArmingAnnouncesAndDisarmRevertsTheDisabledLabel() {
        // Armed → silent cancel with no stored binding reverts to the
        // disabled label, and onArmed announced the capture window.
        let button = RecorderButton(action: .slotKey(.bottomRight))
        var armed: [HotkeyAction] = []
        button.onArmed = { armed.append($0) }
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: nil))

        button.beginRecording { _ in }
        XCTAssertEqual(armed, [.slotKey(.bottomRight)], "arming announces the capture window")
        XCTAssertEqual(button.accessibilityValue() as? String, "recording")

        _ = button.routeRecordedEvent(keyDown(keyCode: UInt16(kVK_Tab)))
        XCTAssertEqual(button.accessibilityValue() as? String, "disabled")
    }
}

/// The Enable-all bulk path must never silently destroy combos recorded
/// while the section was disabled: a stale park loses to a fresh edit,
/// and the tab says which slots it kept. Drives the real bulk button
/// (identifier "bulk-slotKeys") so the test covers the same path the
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

    private func findRecorder(key: SlotKey, in view: NSView) -> RecorderButton? {
        if let button = view as? RecorderButton, button.hotkeyAction == .slotKey(key) { return button }
        for subview in view.subviews {
            if let hit = findRecorder(key: key, in: subview) { return hit }
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

        // Disable the whole slot-key section via its real bulk button.
        guard let disable = findButton(
            identifier: "bulk-slotKeys", titledPrefix: "Disable all", in: view)
        else { return XCTFail("expected a Disable-all bulk button") }
        disable.performClick(nil)

        // The click rebuilds content; re-resolve the enable button from a
        // fresh build (performClick above rebuilt synchronously).
        view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        XCTAssertEqual(
            store.binding(for: .topLeft).keyCode, nil,
            "section disabled: Top Left has no combo")

        // Record a fresh combo into the disabled key (legitimate edit).
        let fresh = HotkeyBinding(modifiers: 0, keyCode: 6)
        XCTAssertEqual(store.apply(fresh, for: .topLeft), .applied)

        // Enable the section via its real bulk button.
        guard let enable = findButton(
            identifier: "bulk-slotKeys", titledPrefix: "Enable all", in: view)
        else { return XCTFail("expected an Enable-all bulk button after disabling") }
        enable.performClick(nil)

        XCTAssertEqual(
            store.binding(for: .topLeft), fresh,
            "the fresh edit wins over the stale park; no silent data loss")
        XCTAssertNil(
            defaults.dictionary(forKey: "parkedHotkey.sixthTopLeft"),
            "the stale park is dropped, not left to strike later")
    }

    func testEnableAllKeepsDisabledWhenTheParkedComboWasClaimed() {
        // A combo parked by Disable all can be claimed by another key's
        // edit while the section is disabled. Enable all must not
        // store it past the duplicate gate: the key would render as
        // enabled and never register.
        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let disable = findButton(
            identifier: "bulk-slotKeys", titledPrefix: "Disable all", in: view)
        else { return XCTFail("expected a Disable-all bulk button") }
        let parked = store.binding(for: .topLeft)
        disable.performClick(nil)

        // Another key claims the parked combo while the section is disabled.
        XCTAssertEqual(store.apply(parked, for: .topMiddle), .applied)

        let view2 = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let enable = findButton(
            identifier: "bulk-slotKeys", titledPrefix: "Enable all", in: view2)
        else { return XCTFail("expected an Enable-all bulk button") }
        enable.performClick(nil)

        XCTAssertNil(
            store.binding(for: .topLeft).keyCode,
            "the claimed combo is not restored; the key stays disabled")
        XCTAssertEqual(
            store.binding(for: .topMiddle), parked,
            "the edit that claimed the combo keeps it")
        XCTAssertNotNil(
            defaults.dictionary(forKey: "parkedHotkey.sixthTopLeft"),
            "the park survives for when the clash is resolved")
    }

    func testStaleParkDoesNotClobberWhenNothingWasEdited() {
        // The complement: with no post-disable edits, Enable all restores
        // the parked combos exactly (the pre-existing contract).
        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let disable = findButton(
            identifier: "bulk-slotKeys", titledPrefix: "Disable all", in: view)
        else { return XCTFail("expected a Disable-all bulk button") }
        let before = store.binding(for: .topRight)
        disable.performClick(nil)
        XCTAssertEqual(store.binding(for: .topRight).keyCode, nil)

        let view2 = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let enable = findButton(
            identifier: "bulk-slotKeys", titledPrefix: "Enable all", in: view2)
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
            identifier: "bulk-slotKeys", titledPrefix: "Disable all", in: view)
        else { return XCTFail("expected a Disable-all bulk button") }
        guard let recorder = findRecorder(key: .topLeft, in: view)
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
            "Restores parked combos; keys edited while disabled keep their edits")

        // The label is not just cosmetic: the click it is about to
        // receive really does enable.
        bulk.performClick(nil)
        XCTAssertNotNil(
            store.binding(for: .topLeft).keyCode,
            "the button labelled Enable all enabled the section")
    }

    func testRecordingIntoTheLastDisabledSlotFlipsTheBulkButtonToDisable() {
        // Top Left is the only disabled slot key, so the section
        // reads "Enable all 11". Recording a combo into it leaves no
        // disabled slot, and the installed button must flip the other way.
        store.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: .topLeft)
        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let bulk = findButton(
            identifier: "bulk-slotKeys", titledPrefix: "Enable all", in: view)
        else { return XCTFail("expected an Enable-all bulk button") }
        guard let recorder = findRecorder(key: .topLeft, in: view)
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
            "Disable every slot key (parks the current combos; Enable all restores them)")
    }
}
