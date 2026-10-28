import AppKit
import Carbon.HIToolbox

/// Interprets keypresses for the Shortcuts-tab recorder button.
///
/// Outcomes:
/// - `.binding`: a combo with ≥1 of ⌃⌥⇧⌘ plus a non-modifier key.
/// - `.clear`: bare ⌫/forward-delete disables that action.
/// - `.cancel`: bare ⎋ aborts the record, keeping the old binding.
/// - nil: keep recording (bare keys, lone modifiers, caps lock, repeats,
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

    /// Keycodes that must pass through to the responder chain even while
    /// armed: navigation keys are never bindings (a combo needs ≥1 of
    /// ⌃⌥⇧⌘), so swallowing them would trap keyboard users mid-record.
    /// Space rides along: with the recorder focused it re-activates the
    /// button, which is the same keep-the-old-binding cancel a second
    /// click performs, never a swallowed, uncued keypress.
    /// The monitor checks this first and returns the event unswallowed.
    static func shouldPassThrough(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              carbonFlags(from: event.modifierFlags) == 0
        else { return false }
        switch Int(event.keyCode) {
        case kVK_Tab, kVK_Return, kVK_Space,
            kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow,
            kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            return true
        default:
            return false
        }
    }

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
