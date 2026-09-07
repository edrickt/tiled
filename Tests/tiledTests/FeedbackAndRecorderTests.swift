import AppKit
import Carbon.HIToolbox
import XCTest

@testable import tiled

/// The recorder's VoiceOver contract: each button names its slot (the row
/// label is a separate, unassociated static text) and exposes its binding
/// or recording state as the value — so the Shortcuts tab is seventeen
/// distinguishable controls, not seventeen anonymous buttons.
final class RecorderButtonAccessibilityTests: XCTestCase {
    func testInitLabelsTheSlot() {
        let button = RecorderButton(slot: .topLeft)
        XCTAssertEqual(button.accessibilityLabel(), "Top Left shortcut")
    }

    func testValueCarriesTheBinding() {
        let button = RecorderButton(slot: .topLeft)
        // keyCode 0 is kVK_ANSI_A: the value must carry the rendered label,
        // not just any non-nil string (e.g. "disabled").
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: 0))
        XCTAssertEqual(button.accessibilityValue() as? String, "A")
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: nil)) // disabled
        XCTAssertEqual(button.accessibilityValue() as? String, "disabled")
    }

    func testBeginRecordingMarksTheValueAsRecording() {
        let button = RecorderButton(slot: .leftHalf)
        button.beginRecording { _ in }
        XCTAssertEqual(button.accessibilityValue() as? String, "recording")
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: nil))
    }

    func testDisabledInitRendersDisabledValue() {
        let button = RecorderButton(slot: .sixthRight)
        XCTAssertEqual(button.accessibilityValue() as? String, "disabled")
    }
}

/// The failure HUD is gone: tiling feedback never pops a panel over the
/// workspace. Haptic + VoiceOver announcement + menu state carry every
/// outcome — so there is nothing here to test. This placeholder keeps the
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
        let button = RecorderButton(slot: .topLeft)
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
        let button = RecorderButton(slot: .leftHalf)
        var fired = 0
        button.beginRecording { _ in fired += 1 }

        // A bare letter is neither decisive nor pass-through.
        let passed = button.routeRecordedEvent(keyDown(keyCode: UInt16(kVK_ANSI_A)))

        XCTAssertNil(passed, "non-decisive keys are swallowed")
        XCTAssertEqual(fired, 0, "no decision was made")
        XCTAssertTrue(button.isRecording, "the button stays armed")
    }

    func testPassThroughKeySilentlyCancels() {
        let button = RecorderButton(slot: .sixthMiddle)
        let stored = HotkeyBinding(modifiers: UInt32(optionKey), keyCode: UInt32(kVK_ANSI_K))
        button.showBinding(stored)
        var silentCancels: [Slot] = []
        button.onSilentCancel = { silentCancels.append($0) }
        var fired = 0
        button.beginRecording { _ in fired += 1 }

        // Tab away mid-record: the event passes through so keyboard
        // navigation still works, and the recorder disarms undecided.
        let passed = button.routeRecordedEvent(keyDown(keyCode: UInt16(kVK_Tab)))

        XCTAssertNotNil(passed, "navigation keys pass through")
        XCTAssertEqual(fired, 0, "the pending completion is dropped, not fired")
        XCTAssertFalse(button.isRecording)
        XCTAssertEqual(silentCancels, [.sixthMiddle])
        XCTAssertEqual(
            button.accessibilityValue() as? String, "⌥K",
            "the label reverts to the stored binding")
    }

    func testArmingAnnouncesAndDisarmRevertsTheDisabledLabel() {
        // Armed → silent cancel with no stored binding reverts to the
        // disabled label, and onArmed announced the capture window.
        let button = RecorderButton(slot: .bottomRight)
        var armed: [Slot] = []
        button.onArmed = { armed.append($0) }
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: nil))

        button.beginRecording { _ in }
        XCTAssertEqual(armed, [.bottomRight], "arming announces the capture window")
        XCTAssertEqual(button.accessibilityValue() as? String, "recording")

        _ = button.routeRecordedEvent(keyDown(keyCode: UInt16(kVK_Tab)))
        XCTAssertEqual(button.accessibilityValue() as? String, "disabled")
    }
}

/// The Enable-all bulk path must never silently destroy combos recorded
/// while the section was disabled: a stale park loses to a fresh edit,
/// and the tab says which slots it kept. Drives the real bulk button
/// (identifier "bulk-quarters") so the test covers the same path the
/// user clicks — including the rebuild that swaps the button itself.
/// Everything runs against a throwaway defaults suite: the park keys live
/// outside the store, so the tab's persistence is injected too — a leak
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
            "the fresh edit wins over the stale park — no silent data loss")
        XCTAssertNil(
            defaults.dictionary(forKey: "parkedHotkey.topLeft"),
            "the stale park is dropped, not left to strike later")
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
}
