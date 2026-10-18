/// One configurable global-hotkey action: a tiling slot or one of the app
/// actions (expand, evict, reset splitters, Settings, undo). This is the
/// single identity every layer shares — the store persists per action, the
/// Carbon registration routes per action, and the Shortcuts tab and status
/// menu render per action — so a new hotkey can never exist in one layer
/// and silently vanish from the others.
enum HotkeyAction: Hashable {
    case slot(Slot)
    case expand
    case evict
    case resetSplitters
    case settings
    case undo
}

extension HotkeyAction {
    /// Every configurable action, in display order: slots first (they are
    /// the Shortcuts tab's layout sections and the initial-focus path),
    /// then the app actions.
    ///
    /// Declared by hand: `CaseIterable` refuses enums with associated
    /// values, and the order is itself a contract (firstRecorder resolves
    /// to Top Left, as it always has).
    static let allCases: [HotkeyAction] =
        Slot.allCases.map { .slot($0) } + appActions

    /// The five non-slot actions, in menu order.
    static let appActions: [HotkeyAction] =
        [.expand, .evict, .resetSplitters, .settings, .undo]

    /// Human title: Shortcuts tab row labels, conflict messages, and the
    /// failure warnings that name the action whose combo was lost.
    var title: String {
        switch self {
        case .slot(let slot): SlotPresentation.title(of: slot)
        case .expand: "Expand to Fill Screen"
        case .evict: "Evict Focused Window"
        case .resetSplitters: "Reset Splitters"
        case .settings: "Open Settings"
        case .undo: "Undo Last Displacement"
        }
    }

    /// Stable storage suffix under the store's "hotkey." prefix. Slots
    /// keep their raw value so overrides written by earlier builds still
    /// resolve; app actions are namespaced to stay clear of slot names.
    var storageKey: String {
        switch self {
        case .slot(let slot): slot.rawValue
        case .expand: "action.expand"
        case .evict: "action.evict"
        case .resetSplitters: "action.resetSplitters"
        case .settings: "action.settings"
        case .undo: "action.undo"
        }
    }

    /// The factory default binding. Slots derive it from their layout
    /// (⌥⇧⌘ / ⌥⇧) + key; app actions keep the combos the fixed build
    /// shipped with.
    var defaultBinding: HotkeyBinding {
        switch self {
        case .slot(let slot): HotkeyStore.defaultBinding(for: slot)
        case .expand: HotkeyService.expandDefaultBinding
        case .evict: HotkeyService.evictDefaultBinding
        case .resetSplitters: HotkeyService.resetSplittersDefaultBinding
        case .settings: HotkeyService.settingsDefaultBinding
        case .undo: HotkeyService.undoDefaultBinding
        }
    }

    /// Stable id used in Carbon hotkey events: slots occupy
    /// 1...allCases.count, app actions the reserved 995–999 range.
    var hotkeyID: UInt32 {
        switch self {
        case .slot(let slot): slot.hotkeyID
        case .expand: HotkeyService.expandHotkeyID
        case .evict: HotkeyService.evictHotkeyID
        case .resetSplitters: HotkeyService.resetSplittersHotkeyID
        case .settings: HotkeyService.settingsHotkeyID
        case .undo: HotkeyService.undoHotkeyID
        }
    }

    /// Recovery advice appended to a registration-failure warning, in
    /// action-specific words (nil for slots, whose warning names the
    /// general suspects instead).
    var registrationRecovery: String? {
        switch self {
        case .slot: nil
        case .expand, .evict: "quit and reopen Tiled to try again."
        case .resetSplitters: "reset splitters from the Tiled menu instead."
        case .settings: "quit and reopen Tiled to get back to Settings while hidden."
        case .undo: "undo the last displacement from the Tiled menu instead."
        }
    }
}
