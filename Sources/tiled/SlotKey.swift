import Carbon.HIToolbox

/// One physical ⌥⇧ slot key, shared by both layouts.
///
/// A key names a position rather than a slot: U is "top left" whether the
/// canvas shows quarters or sixths, and the active layout decides which
/// `Slot` the press means. That is why the eleven keys live here instead of
/// on `Slot`: quarters and sixths would otherwise need separate identities
/// for the same physical key, and rebinding one layout's copy would not
/// move the other's.
///
/// `storageKey` is the sixths slot's raw value, derived from
/// `Slot.allCases`. Sixths overrides, parked combos, and reset backups were
/// written under those names, so deriving (rather than introducing a second
/// persisted namespace) keeps every existing entry resolving without a
/// migration.
enum SlotKey: String, CaseIterable, Hashable {
    // Corners: left to right, top row then bottom row.
    case topLeft, topMiddle, topRight
    case bottomLeft, bottomMiddle, bottomRight
    // Full-height thirds, left to right.
    case leftColumn, middleColumn, rightColumn
    // The two wide spans.
    case leftTwoThirds, rightTwoThirds

    /// HIToolbox virtual keycode for this physical key.
    var keyCode: UInt32 {
        switch self {
        case .topLeft: UInt32(kVK_ANSI_U)
        case .topMiddle: UInt32(kVK_ANSI_I)
        case .topRight: UInt32(kVK_ANSI_O)
        case .bottomLeft: UInt32(kVK_ANSI_M)
        case .bottomMiddle: UInt32(kVK_ANSI_Comma)
        case .bottomRight: UInt32(kVK_ANSI_Period)
        case .leftColumn: UInt32(kVK_ANSI_J)
        case .middleColumn: UInt32(kVK_ANSI_K)
        case .rightColumn: UInt32(kVK_ANSI_L)
        case .leftTwoThirds: UInt32(kVK_ANSI_H)
        case .rightTwoThirds: UInt32(kVK_ANSI_Semicolon)
        }
    }

    /// The position's name, used wherever the key speaks for itself (the
    /// Shortcuts tab and the inert-key receipt). Slot titles live in
    /// `SlotPresentation` because they name the geometry; this names the
    /// keycap.
    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topMiddle: "Top Middle"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomMiddle: "Bottom Middle"
        case .bottomRight: "Bottom Right"
        case .leftColumn: "Left Column"
        case .middleColumn: "Middle Column"
        case .rightColumn: "Right Column"
        case .leftTwoThirds: "Left Two-Thirds"
        case .rightTwoThirds: "Right Two-Thirds"
        }
    }

    /// The persisted identity, derived from the one slot mapping table.
    ///
    /// Every key has exactly one sixths slot (the mapping test pins that
    /// bijection), so the raw value always exists; a missing sixths slot is
    /// a broken declaration, not a user state to recover from.
    var storageKey: String {
        slot(in: .sixths)!.rawValue
    }

    /// The slot this key names in `layout`, or nil when the layout has no
    /// such position: quarters has no top/bottom middle, no full-height
    /// middle column, and no two-thirds.
    func slot(in layout: LayoutKind) -> Slot? {
        Slot.allCases.first { $0.layout == layout && $0.key == self }
    }

    /// ⌥⇧ plus the physical key: one modifier set for both layouts, so a
    /// layout switch never changes the combo.
    var defaultBinding: HotkeyBinding {
        HotkeyBinding(modifiers: UInt32(shiftKey | optionKey), keyCode: keyCode)
    }

    /// Stable id used in Carbon hotkey events, from declaration order.
    var hotkeyID: UInt32 {
        UInt32(Self.allCases.firstIndex(of: self)!) + 1
    }

    /// The keys Quarters has no slot for: the two middles, the middle
    /// column, and the two two-thirds. Derived from the one slot mapping
    /// so the Settings caption can never drift from the engine.
    static var quartersInert: [SlotKey] {
        allCases.filter { $0.slot(in: .quarters) == nil }
    }
}
