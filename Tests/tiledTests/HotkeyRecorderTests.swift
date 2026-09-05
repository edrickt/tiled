import AppKit
import Carbon.HIToolbox
import XCTest
@testable import tiled

/// Phase 3, slice A: the Shortcuts-tab recorder turns a keypress into an
/// outcome. Pure function over synthesized NSEvents — no UI needed.
final class HotkeyRecorderTests: XCTestCase {
    private func keyDown(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
        characters: String = "", isARepeat: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: isARepeat, keyCode: keyCode)!
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

    func testAutoRepeatIsIgnored() {
        // Holding a valid combo must not retrigger the recorder.
        XCTAssertNil(HotkeyRecorder.outcome(for: keyDown(
            keyCode: UInt16(kVK_ANSI_U), modifiers: [.option, .shift], isARepeat: true)))
    }

    // MARK: Pass-through (keyboard accessibility while armed)

    func testBareNavigationKeysPassThroughWhileArmed() {
        let codes = [
            kVK_Tab, kVK_Return, kVK_Space,
            kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow,
            kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
        ]
        for code in codes {
            XCTAssertTrue(
                HotkeyRecorder.shouldPassThrough(keyDown(keyCode: UInt16(code))),
                "bare keyCode \(code) must reach the responder chain")
        }
    }

    func testModifiedNavigationKeysDoNotPassThrough() {
        // ⌥Tab is a potential binding, not navigation.
        XCTAssertFalse(HotkeyRecorder.shouldPassThrough(
            keyDown(keyCode: UInt16(kVK_Tab), modifiers: [.option])))
    }

    func testBareNonNavigationKeysDoNotPassThrough() {
        XCTAssertFalse(HotkeyRecorder.shouldPassThrough(
            keyDown(keyCode: UInt16(kVK_ANSI_U))))
    }

    func testNonKeyDownEventsNeverPassThrough() {
        let keyUp = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_Tab))!
        XCTAssertFalse(HotkeyRecorder.shouldPassThrough(keyUp))
    }
}
