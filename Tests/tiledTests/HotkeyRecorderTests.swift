import AppKit
import Carbon.HIToolbox
import XCTest
@testable import tiled

/// Phase 3, slice A: the Shortcuts-tab recorder turns a keypress into an
/// outcome. Pure function over synthesized NSEvents — no UI needed.
final class HotkeyRecorderTests: XCTestCase {
    private func keyDown(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
        characters: String = ""
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode)!
    }

    // MARK: Cancel / clear

    func testBareEscapeCancels() {
        XCTAssertEqual(
            HotkeyRecorder.outcome(for: keyDown(keyCode: UInt16(kVK_Escape))), .cancel)
    }

    func testEscapeWithModifiersIsABinding() {
        // ⌥⎋ is a legitimate combo, not a cancel.
        XCTAssertEqual(
            HotkeyRecorder.outcome(
                for: keyDown(keyCode: UInt16(kVK_Escape), modifiers: [.option])),
            .binding(HotkeyBinding(
                modifiers: UInt32(optionKey), keyCode: UInt32(kVK_Escape))))
    }

    func testBackspaceClears() {
        XCTAssertEqual(
            HotkeyRecorder.outcome(for: keyDown(keyCode: UInt16(kVK_Delete))), .clear)
    }

    func testForwardDeleteClears() {
        XCTAssertEqual(
            HotkeyRecorder.outcome(for: keyDown(keyCode: UInt16(kVK_ForwardDelete))), .clear)
    }

    func testDeleteWithModifiersIsABinding() {
        XCTAssertEqual(
            HotkeyRecorder.outcome(
                for: keyDown(keyCode: UInt16(kVK_Delete), modifiers: [.control])),
            .binding(HotkeyBinding(
                modifiers: UInt32(controlKey), keyCode: UInt32(kVK_Delete))))
    }

    // MARK: Valid combos

    func testOptionShiftUProducesBinding() {
        XCTAssertEqual(
            HotkeyRecorder.outcome(
                for: keyDown(
                    keyCode: UInt16(kVK_ANSI_U), modifiers: [.option, .shift])),
            .binding(HotkeyBinding(
                modifiers: UInt32(optionKey | shiftKey), keyCode: UInt32(kVK_ANSI_U))))
    }

    func testAllFourModifiersMapToCarbon() {
        let result = HotkeyRecorder.outcome(
            for: keyDown(
                keyCode: UInt16(kVK_ANSI_F),
                modifiers: [.control, .option, .shift, .command]))
        XCTAssertEqual(
            result,
            .binding(HotkeyBinding(
                modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
                keyCode: UInt32(kVK_ANSI_F))))
    }

    func testFunctionKeyCombo() {
        XCTAssertEqual(
            HotkeyRecorder.outcome(
                for: keyDown(keyCode: UInt16(kVK_F5), modifiers: [.control])),
            .binding(HotkeyBinding(
                modifiers: UInt32(controlKey), keyCode: UInt32(kVK_F5))))
    }

    // MARK: Ignored (keep recording)

    func testPlainKeyWithoutModifiersIsIgnored() {
        XCTAssertNil(HotkeyRecorder.outcome(
            for: keyDown(keyCode: UInt16(kVK_ANSI_U), characters: "u")))
    }

    func testModifierKeyAloneIsIgnored() {
        // Pressing ⇧ by itself must not complete a "⇧ + ⇧" binding.
        XCTAssertNil(HotkeyRecorder.outcome(
            for: keyDown(keyCode: 56, modifiers: [.shift])))
    }

    func testCapsLockDoesNotCountAsAModifier() {
        XCTAssertNil(HotkeyRecorder.outcome(
            for: keyDown(keyCode: UInt16(kVK_ANSI_U), modifiers: [.capsLock])))
    }

    func testNonKeyDownEventsAreIgnored() {
        let keyUp = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [.shift],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_U))!
        XCTAssertNil(HotkeyRecorder.outcome(for: keyUp))
    }
}
