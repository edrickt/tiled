import Carbon.HIToolbox
import Foundation

extension Slot {
    /// Modifier set for this slot's hotkey: quarters add ⌘, sixths use ⌥⇧.
    var modifiers: UInt32 {
        switch layout {
        case .quarters: UInt32(shiftKey | optionKey | cmdKey)
        case .sixths: UInt32(shiftKey | optionKey)
        }
    }

    /// HIToolbox virtual keycode for this slot's hotkey.
    var keyCode: UInt32 {
        switch self {
        case .topLeft, .sixthTopLeft: UInt32(kVK_ANSI_U)
        case .sixthTopMiddle: UInt32(kVK_ANSI_I)
        case .topRight, .sixthTopRight: UInt32(kVK_ANSI_O)
        case .bottomLeft, .sixthBottomLeft: UInt32(kVK_ANSI_M)
        case .sixthBottomMiddle: UInt32(kVK_ANSI_Comma)
        case .bottomRight, .sixthBottomRight: UInt32(kVK_ANSI_Period)
        case .leftHalf, .sixthLeft: UInt32(kVK_ANSI_J)
        case .sixthMiddle: UInt32(kVK_ANSI_K)
        case .rightHalf, .sixthRight: UInt32(kVK_ANSI_L)
        case .sixthsLeftTwoThirds: UInt32(kVK_ANSI_H)
        case .sixthsRightTwoThirds: UInt32(kVK_ANSI_Semicolon)
        }
    }

    /// Stable id used in Carbon hotkey events.
    var hotkeyID: UInt32 {
        UInt32(Slot.allCases.firstIndex(of: self)!) + 1
    }
}

/// Registers the global hotkeys via Carbon's RegisterEventHotKey (still
/// the most reliable global hotkey mechanism on macOS). Every action —
/// slots and app actions alike — registers from the store, so a user
/// rebinds ⌥⇧R or ⌃⌥⇧⌘Z exactly like ⌥⇧U.
final class HotkeyService {
    // MARK: App-action Carbon ids
    //
    // Reserved ids for the five app actions. Slot ids occupy
    // 1...allCases.count, so 995–999 can never collide with them (or each
    // other); the table tests pin that.

    /// Expand toggle (default ⌥⇧⏎).
    static let expandHotkeyID: UInt32 = 998
    /// Evict focused window (default ⌥⇧⌫).
    static let evictHotkeyID: UInt32 = 996
    /// Reset splitters (default ⌥⇧R).
    static let resetSplittersHotkeyID: UInt32 = 995
    /// Settings fallback (default ⌃⌥⇧⌘,): opens Settings even when the
    /// menu-bar icon is hidden.
    static let settingsHotkeyID: UInt32 = 999
    /// Global undo (default ⌃⌥⇧⌘Z).
    static let undoHotkeyID: UInt32 = 997

    // MARK: App-action factory defaults
    //
    // The combos the fixed build shipped with. They are defaults now, not
    // constants: the store resolves each action's live binding, and the
    // Shortcuts tab can change any of them. The expand/evict/reset
    // combos sit beside the sixths ⌥⇧ set but on keys no slot defaults
    // to; Settings and undo are deliberately over-modified (all four
    // modifiers) so they collide with nothing out of the box.

    static let expandModifiers = UInt32(shiftKey | optionKey)
    static let expandKeyCode = UInt32(kVK_Return)
    static let expandDefaultBinding = HotkeyBinding(
        modifiers: expandModifiers, keyCode: expandKeyCode)

    static let evictModifiers = UInt32(shiftKey | optionKey)
    static let evictKeyCode = UInt32(kVK_Delete)
    static let evictDefaultBinding = HotkeyBinding(
        modifiers: evictModifiers, keyCode: evictKeyCode)

    static let resetSplittersModifiers = UInt32(shiftKey | optionKey)
    static let resetSplittersKeyCode = UInt32(kVK_ANSI_R)
    static let resetSplittersDefaultBinding = HotkeyBinding(
        modifiers: resetSplittersModifiers, keyCode: resetSplittersKeyCode)

    static let settingsModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    static let settingsKeyCode = UInt32(kVK_ANSI_Comma)
    static let settingsDefaultBinding = HotkeyBinding(
        modifiers: settingsModifiers, keyCode: settingsKeyCode)

    static let undoModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    static let undoKeyCode = UInt32(kVK_ANSI_Z)
    static let undoDefaultBinding = HotkeyBinding(
        modifiers: undoModifiers, keyCode: undoKeyCode)

    /// Pure id → action mapping over the slot table the callback holds.
    /// Extracted from carbonCallback so a table test pins it: a routing
    /// typo here turns a global hotkey into a dead key while the menu
    /// still advertises it. Unknown ids return nil (the callback answers
    /// eventNotHandledErr, letting the event fall through to other apps).
    static func route(
        forHotKeyID id: UInt32, slotByID: [UInt32: Slot]
    ) -> HotkeyAction? {
        if let slot = slotByID[id] { return .slot(slot) }
        switch id {
        case expandHotkeyID: return .expand
        case evictHotkeyID: return .evict
        case settingsHotkeyID: return .settings
        case undoHotkeyID: return .undo
        case resetSplittersHotkeyID: return .resetSplitters
        default: return nil
        }
    }

    private final class Context {
        var handler: ((HotkeyAction) -> Void)?
        let actionByID: [UInt32: HotkeyAction]

        init() {
            actionByID = Dictionary(
                uniqueKeysWithValues: HotkeyAction.allCases.map { ($0.hotkeyID, $0) })
        }
    }

    private static let signature = OSType(0x54_49_4C_44) // 'TILD'
    private static let eventType = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed))

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private let context = Context()
    private static var handlerInstalled = false
    private let store: HotkeyStore

    /// Actions whose global hotkey could not be registered (likely owned
    /// by another app). Surfaced in the status menu and the Shortcuts tab;
    /// never just logged.
    private(set) var failedActions: [HotkeyAction] = []

    /// Fired for every registered hotkey. The handler switches on the
    /// action; one entry point replaces the per-combo handler properties
    /// so adding an action can never forget a dispatch branch (the
    /// switch is exhaustive).
    var handler: ((HotkeyAction) -> Void)? {
        get { context.handler }
        set { context.handler = newValue }
    }

    init(store: HotkeyStore = HotkeyStore()) {
        self.store = store
        Self.installEventHandler(with: context)
        registerHotkeys()
    }

    /// Unregisters everything and registers from the store again.
    /// Called after the user edits bindings in Settings; failedActions is
    /// recomputed, so newly freed (or newly conflicted) actions surface
    /// in the menu without a relaunch.
    func reload() {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs = []
        registerHotkeys()
    }

    private func registerHotkeys() {
        failedActions = []
        for action in HotkeyAction.allCases {
            let binding = store.binding(for: action)
            // A disabled action registers nothing and warns about nothing.
            guard let keyCode = binding.keyCode else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                keyCode,
                binding.modifiers,
                EventHotKeyID(signature: Self.signature, id: action.hotkeyID),
                GetApplicationEventTarget(),
                0,
                &ref)
            if status == noErr {
                hotKeyRefs.append(ref)
            } else {
                failedActions.append(action)
                NSLog(
                    "Tiled: failed to register hotkey for %@ (osstatus %d)",
                    action.title, status)
            }
        }
    }

    private static func installEventHandler(with context: Context) {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        let userData = Unmanaged.passUnretained(context).toOpaque()
        var eventType = Self.eventType
        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonCallback,
            1,
            &eventType,
            userData,
            nil)
    }

    private static let carbonCallback: EventHandlerUPP = { _, event, userData in
        guard let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID)
        guard status == noErr else { return status }
        let context = Unmanaged<Context>.fromOpaque(userData!).takeUnretainedValue()
        guard let action = context.actionByID[hotKeyID.id] else {
            return OSStatus(eventNotHandledErr)
        }
        DispatchQueue.main.async { context.handler?(action) }
        return noErr
    }
}
