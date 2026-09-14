import Carbon.HIToolbox
import Foundation

/// A user-configurable global hotkey: Carbon modifiers + virtual keycode.
/// `keyCode == nil` means the slot is disabled (no hotkey registered).
struct HotkeyBinding: Equatable {
    var modifiers: UInt32
    var keyCode: UInt32?

    var isEnabled: Bool { keyCode != nil }

    /// Display label, e.g. "⌥⇧U" or "⌃⌥⇧⌘F5". nil when disabled.
    /// Modifiers always render in ⌃⌥⇧⌘ order.
    var label: String? {
        guard let keyCode else { return nil }
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        text += Self.keyLabel(for: keyCode)
        return text
    }

    /// Human-readable keycap for a virtual keycode. Letters render uppercase
    /// (matching the existing ⌥⇧U style); unknown codes fall back to hex so
    /// a binding never renders blank.
    static func keyLabel(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_ANSI_Minus: "-"
        case kVK_ANSI_Equal: "="
        case kVK_ANSI_LeftBracket: "["
        case kVK_ANSI_RightBracket: "]"
        case kVK_ANSI_Backslash: "\\"
        case kVK_ANSI_Semicolon: ";"
        case kVK_ANSI_Quote: "'"
        case kVK_ANSI_Comma: ","
        case kVK_ANSI_Period: "."
        case kVK_ANSI_Slash: "/"
        case kVK_ANSI_Grave: "`"
        case kVK_Space: "Space"
        case kVK_Tab: "Tab"
        case kVK_Return: "⏎"
        case kVK_Escape: "⎋"
        case kVK_Delete: "⌫"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        case kVK_F13: "F13"
        case kVK_F14: "F14"
        case kVK_F15: "F15"
        case kVK_F16: "F16"
        case kVK_F17: "F17"
        case kVK_F18: "F18"
        case kVK_F19: "F19"
        case kVK_F20: "F20"
        default: String(format: "0x%02X", keyCode)
        }
    }
}

/// Display names and menu groupings for slots. Lives beside the hotkey
/// model because nearly every consumer is hotkey UI (menu, Settings rows,
/// announcements); the one exception is the controller's two status
/// lines, which read through this too so wording changes in one place.
/// `Slot` itself keeps only geometry (cells, layout, overlap).
enum SlotPresentation {
    static func title(of slot: Slot) -> String {
        switch slot {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .sixthTopLeft: "Top Left Sixth"
        case .sixthTopMiddle: "Top Middle Sixth"
        case .sixthTopRight: "Top Right Sixth"
        case .sixthBottomLeft: "Bottom Left Sixth"
        case .sixthBottomMiddle: "Bottom Middle Sixth"
        case .sixthBottomRight: "Bottom Right Sixth"
        case .sixthLeft: "Left Third"
        case .sixthMiddle: "Middle Third"
        case .sixthRight: "Right Third"
        case .sixthsLeftTwoThirds: "Left Two-Thirds"
        case .sixthsRightTwoThirds: "Right Two-Thirds"
        }
    }

    /// Quarters submenu groupings: 6 flat items under one header push the
    /// chunking limit, so the menu splits them the same way sixths are
    /// chunked: quads first, then the two halves.
    static var quartersQuads: [Slot] {
        [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }

    static var quartersHalves: [Slot] {
        [.leftHalf, .rightHalf]
    }

    /// Sixths submenu groupings: 11 flat items exceed working memory at
    /// the moment of action, so the menu chunks them under disabled
    /// sub-headers mirroring these groups.
    static var sixthsCorners: [Slot] {
        [.sixthTopLeft, .sixthTopMiddle, .sixthTopRight,
         .sixthBottomLeft, .sixthBottomMiddle, .sixthBottomRight]
    }

    static var sixthsThirds: [Slot] {
        [.sixthLeft, .sixthMiddle, .sixthRight]
    }

    static var sixthsTwoThirds: [Slot] {
        [.sixthsLeftTwoThirds, .sixthsRightTwoThirds]
    }
}

/// Persists per-slot hotkey bindings in UserDefaults. Missing entries fall
/// back to the factory defaults (today's fixed ⌥⇧⌘ / ⌥⇧ set), so a fresh
/// install behaves exactly like the current hardcoded build.
final class HotkeyStore {
    /// What `apply` decided.
    enum ApplyResult: Equatable {
        case applied
        case duplicate(slots: [Slot])
        /// The combo belongs to one of Tiled's own fixed shortcuts
        /// (expand, evict, Settings, undo). Storing it would leave the
        /// slot with a hotkey that can never register, because the fixed
        /// combos register first.
        case reserved(name: String)
    }
    private let defaults: UserDefaults
    private static let prefix = "hotkey."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The factory default for a slot: today's fixed modifiers + key.
    static func defaultBinding(for slot: Slot) -> HotkeyBinding {
        HotkeyBinding(modifiers: slot.modifiers, keyCode: slot.keyCode)
    }

    func binding(for slot: Slot) -> HotkeyBinding {
        guard let dict = defaults.dictionary(forKey: Self.key(for: slot)),
              let modifiers = dict["modifiers"] as? Int,
              let code = dict["keyCode"] as? Int
        else {
            return Self.defaultBinding(for: slot)
        }
        // A negative keyCode is the disabled encoding; a negative modifiers
        // is corrupt data (never written by set) and must not reach
        // UInt32 (a trap). Fall back to the factory default like any
        // other unreadable entry.
        guard modifiers >= 0 else { return Self.defaultBinding(for: slot) }
        return HotkeyBinding(
            modifiers: UInt32(modifiers), keyCode: code >= 0 ? UInt32(code) : nil)
    }

    func set(_ binding: HotkeyBinding, for slot: Slot) {
        defaults.set(
            ["modifiers": Int(binding.modifiers), "keyCode": binding.keyCode.map(Int.init) ?? -1],
            forKey: Self.key(for: slot))
    }

    /// Drops every override; all slots return to factory defaults.
    func resetAll() {
        for slot in Slot.allCases {
            defaults.removeObject(forKey: Self.key(for: slot))
        }
    }

    /// Stores `candidate` for `slot` unless another slot already uses it
    /// or the combo belongs to a fixed shortcut. Rejected candidates leave
    /// the store untouched so the caller can shake and keep the old
    /// binding. Disabled bindings never collide.
    @discardableResult
    func apply(_ candidate: HotkeyBinding, for slot: Slot) -> ApplyResult {
        if let name = Self.reservedOwner(of: candidate) { return .reserved(name: name) }
        let clashes = duplicates(of: candidate, ignoring: slot)
        guard clashes.isEmpty else { return .duplicate(slots: clashes) }
        set(candidate, for: slot)
        return .applied
    }

    /// The four fixed combos slots may not take. The registrations live in
    /// `HotkeyService`; the store owns the conflict decision so the bulk
    /// restore paths cannot bypass it with `set`.
    static var reservedCombos: [(name: String, binding: HotkeyBinding)] {
        [
            ("Expand", HotkeyService.expandBinding),
            ("Evict", HotkeyService.evictBinding),
            ("Settings", HotkeyBinding(
                modifiers: HotkeyService.settingsModifiers,
                keyCode: HotkeyService.settingsKeyCode)),
            ("Undo", HotkeyBinding(
                modifiers: HotkeyService.undoModifiers,
                keyCode: HotkeyService.undoKeyCode)),
        ]
    }

    /// The fixed shortcut that owns `candidate`, if any.
    static func reservedOwner(of candidate: HotkeyBinding) -> String? {
        guard candidate.keyCode != nil else { return nil }
        return reservedCombos.first { $0.binding == candidate }?.name
    }

    /// Slots (other than `ignored`) whose stored binding equals `candidate`.
    /// Disabled bindings never collide with anything.
    func duplicates(of candidate: HotkeyBinding, ignoring ignored: Slot) -> [Slot] {
        guard candidate.keyCode != nil else { return [] }
        return Slot.allCases.filter { $0 != ignored && binding(for: $0) == candidate }
    }

    private static func key(for slot: Slot) -> String {
        prefix + slot.rawValue
    }
}
