import AppKit
import Carbon.HIToolbox

/// interprets keypresses for the Shortcuts-tab recorder button.
///
/// Outcomes:
/// - `.binding` — a combo with ≥1 of ⌃⌥⇧⌘ plus a non-modifier key.
/// - `.clear` — bare ⌫/forward-delete disables the slot.
/// - `.cancel` — bare ⎋ aborts the record, keeping the old binding.
/// - nil — keep recording (bare keys, lone modifiers, caps lock, repeats,
///   mouse/wheel events).
enum HotkeyRecorder {
    enum Outcome: Equatable {
        case binding(HotkeyBinding)
        case clear
        case cancel
    }

    /// Virtual keycodes that are modifiers on their own: pressing one must
    /// never complete a "⇧ + ⇧"-style binding.
    private static let modifierKeyCodes: Set<UInt16> = [
        54, 55, // ⌘ right, left
        58, 61, // ⌥ right, left
        59, 62, // ^ right, left
        56, 60, // ⇧ right, left
        63, // fn
    ]

    static func outcome(for event: NSEvent) -> Outcome? {
        guard event.type == .keyDown, !event.isARepeat else { return nil }
        let carbonModifiers = carbonFlags(from: event.modifierFlags)
        let keyCode = event.keyCode

        if carbonModifiers == 0 {
            switch Int(keyCode) {
            case kVK_Escape: return .cancel
            case kVK_Delete, kVK_ForwardDelete: return .clear
            default: return nil // bare keys never bind, lone modifiers neither
            }
        }
        guard !modifierKeyCodes.contains(keyCode) else { return nil }
        return .binding(HotkeyBinding(
            modifiers: carbonModifiers, keyCode: UInt32(keyCode)))
    }

    /// Maps Cocoa flags to the Carbon set RegisterEventHotKey expects.
    /// Caps lock is deliberately excluded: it is a toggle, not a held combo.
    private static func carbonFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}
