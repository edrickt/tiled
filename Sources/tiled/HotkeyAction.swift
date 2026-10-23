/// One configurable global-hotkey action: a physical slot key or one of the
/// app actions (expand, evict, reset splitters, switch layout, Settings,
/// undo). This is the single identity every layer shares — the store
/// persists per action, the Carbon registration routes per action, and the
/// Shortcuts tab and status menu render per action — so a new hotkey can
/// never exist in one layer and silently vanish from the others.
///
/// A slot key is not a `Slot`: U means "top left" in whichever layout the
/// canvas is showing, so there is one identity per keycap rather than one
/// per layout's slot.
enum HotkeyAction: Hashable {
    case slotKey(SlotKey)
    case expand
    case evict
    case resetSplitters
    case switchLayout
    case settings
    case undo
}

extension HotkeyAction {
    /// Every configurable action, in display order: the eleven slot keys
    /// first (they are the Shortcuts tab's slot-key section and the
    /// initial-focus path), then the app actions.
    ///
    /// Declared by hand: `CaseIterable` refuses enums with associated
    /// values, and the order is itself a contract (firstRecorder resolves
    /// to Top Left, as it always has).
    static let allCases: [HotkeyAction] =
        SlotKey.allCases.map { .slotKey($0) } + appActions

    /// The six non-slot actions, in menu order.
    static let appActions: [HotkeyAction] =
        [.expand, .evict, .resetSplitters, .switchLayout, .settings, .undo]

    /// Human title: Shortcuts tab row labels, conflict messages, and the
    /// failure warnings that name the action whose combo was lost.
    var title: String {
        switch self {
        case .slotKey(let key): key.title
        case .expand: "Expand to Fill Screen"
        case .evict: "Evict Focused Window"
        case .resetSplitters: "Reset Splitters"
        case .switchLayout: "Switch Layout"
        case .settings: "Open Settings"
        case .undo: "Undo Last Displacement"
        }
    }

    /// Stable storage suffix under the store's "hotkey." prefix. A slot
    /// key keeps the sixths slot's raw value, so overrides written by
    /// earlier builds still resolve without a migration; app actions are
    /// namespaced to stay clear of slot names.
    var storageKey: String {
        switch self {
        case .slotKey(let key): key.storageKey
        case .expand: "action.expand"
        case .evict: "action.evict"
        case .resetSplitters: "action.resetSplitters"
        case .switchLayout: "action.switchLayout"
        case .settings: "action.settings"
        case .undo: "action.undo"
        }
    }

    /// The factory default binding. Slot keys share one ⌥⇧ set; app
    /// actions keep the combos the fixed build shipped with.
    var defaultBinding: HotkeyBinding {
        switch self {
        case .slotKey(let key): key.defaultBinding
        case .expand: HotkeyService.expandDefaultBinding
        case .evict: HotkeyService.evictDefaultBinding
        case .resetSplitters: HotkeyService.resetSplittersDefaultBinding
        case .switchLayout: HotkeyService.switchLayoutDefaultBinding
        case .settings: HotkeyService.settingsDefaultBinding
        case .undo: HotkeyService.undoDefaultBinding
        }
    }

    /// Stable id used in Carbon hotkey events: slot keys occupy
    /// 1...11, app actions the reserved 994–999 range.
    var hotkeyID: UInt32 {
        switch self {
        case .slotKey(let key): key.hotkeyID
        case .expand: HotkeyService.expandHotkeyID
        case .evict: HotkeyService.evictHotkeyID
        case .resetSplitters: HotkeyService.resetSplittersHotkeyID
        case .switchLayout: HotkeyService.switchLayoutHotkeyID
        case .settings: HotkeyService.settingsHotkeyID
        case .undo: HotkeyService.undoHotkeyID
        }
    }

    /// Recovery advice appended to a registration-failure warning, in
    /// action-specific words (nil for slot keys, whose warning names the
    /// general suspects instead).
    var registrationRecovery: String? {
        switch self {
        case .slotKey: nil
        case .expand, .evict: "quit and reopen Tiled to try again."
        case .resetSplitters: "reset splitters from the Tiled menu instead."
        case .switchLayout: "switch layouts from the Tiled menu instead."
        case .settings: "quit and reopen Tiled to get back to Settings while hidden."
        case .undo: "undo the last displacement from the Tiled menu instead."
        }
    }
}
