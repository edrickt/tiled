import AppKit
import Carbon.HIToolbox
import XCTest

@testable import tiled

/// The Shortcuts tab's inline conflict line, driven through the real
/// recorder controls and temporary defaults: duplicate recordings keep
/// the old binding and name the owner; a registration failure appears
/// where the combo was accepted; a later valid recording clears it.
final class ShortcutsConflictUITests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: HotkeyStore!

    override func setUp() {
        super.setUp()
        suiteName = "ShortcutsConflictUITests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = HotkeyStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        suiteName = ""
        super.tearDown()
    }

    private func makeTab() -> ShortcutsTab {
        let tab = ShortcutsTab(hotkeyStore: store, defaults: defaults)
        tab.onContentRebuilt = { _ in }
        return tab
    }

    private func findRecorder(slot: Slot, in view: NSView) -> RecorderButton? {
        if let button = view as? RecorderButton, button.hotkeyAction == .slot(slot) {
            return button
        }
        for subview in view.subviews {
            if let hit = findRecorder(slot: slot, in: subview) { return hit }
        }
        return nil
    }

    private func visibleLabel(_ text: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField,
           field.stringValue == text,
           !field.isHiddenOrHasHiddenAncestor
        {
            return field
        }
        for subview in view.subviews {
            if let hit = visibleLabel(text, in: subview) { return hit }
        }
        return nil
    }

    private func keyDown(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode)!
    }

    private func record(_ binding: HotkeyBinding, recorder: RecorderButton) {
        recorder.performClick(nil)
        var flags: NSEvent.ModifierFlags = []
        if binding.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if binding.modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if binding.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if binding.modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        _ = recorder.routeRecordedEvent(
            keyDown(keyCode: UInt16(binding.keyCode!), modifiers: flags))
    }

    func testDuplicateRecordingKeepsTheOldBindingAndNamesTheOwner() {
        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let recorder = findRecorder(slot: .topLeft, in: view)
        else { return XCTFail("expected a Top Left recorder") }
        let old = store.binding(for: .topLeft)
        let owner = store.binding(for: .topRight)

        record(owner, recorder: recorder)

        XCTAssertEqual(
            store.binding(for: .topLeft), old,
            "a rejected duplicate leaves the old binding in place")
        let message =
            "\(owner.label!) is already used by Top Right; "
            + "Top Left kept its old shortcut."
        XCTAssertNotNil(
            visibleLabel(message, in: view),
            "the tab shows who owns the combo and what was kept")
    }

    func testFailedRegistrationSurfacesBesideTheRecording() {
        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let recorder = findRecorder(slot: .topLeft, in: view)
        else { return XCTFail("expected a Top Left recorder") }
        tab.failedActionsProvider = { [.slot(.topLeft)] }
        let fresh = HotkeyBinding(
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            keyCode: UInt32(kVK_ANSI_Y))

        record(fresh, recorder: recorder)

        XCTAssertEqual(store.binding(for: .topLeft), fresh, "the recorder accepted it")
        let message =
            "⌃⌥⇧⌘Y could not be registered; “Top Left” has no hotkey. "
            + "Another Tiled shortcut or a system shortcut may already use it."
        XCTAssertNotNil(
            visibleLabel(message, in: view),
            "a combo the system refused is named where it was recorded")
    }

    func testAValidRecordingClearsTheConflictLine() {
        let tab = makeTab()
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let recorder = findRecorder(slot: .topLeft, in: view)
        else { return XCTFail("expected a Top Left recorder") }
        record(store.binding(for: .topRight), recorder: recorder)
        XCTAssertNotNil(
            visibleLabel(
                "⌥⇧⌘O is already used by Top Right; Top Left kept its old shortcut.",
                in: view))

        let resolved = HotkeyBinding(
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            keyCode: UInt32(kVK_ANSI_Y))
        record(resolved, recorder: recorder)

        XCTAssertEqual(store.binding(for: .topLeft), resolved)
        XCTAssertNil(
            visibleLabel(
                "⌥⇧⌘O is already used by Top Right; Top Left kept its old shortcut.",
                in: view),
            "a resolved conflict no longer occupies the live region")
    }
}
