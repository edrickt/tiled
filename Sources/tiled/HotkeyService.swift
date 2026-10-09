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

    /// The registration seam's shape: register one combo under a hotkey
    /// id (filling the live registration ref), unregister one live
    /// registration. Injected at init, like `CarbonEventHandler`'s
    /// install/remove, so the register / reload / teardown lifecycle is
    /// pinnable without a live Carbon event loop.
    typealias Register = (
        _ keyCode: UInt32, _ modifiers: UInt32, _ hotKeyID: UInt32,
        _ ref: inout EventHotKeyRef?
    ) -> OSStatus
    typealias Unregister = (EventHotKeyRef) -> Void

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private let context = Context()
    /// The installed Carbon handler: retained context, removed on deinit,
    /// so a dead service never leaves a handler behind (and a replacement
    /// service always installs its own).
    private var eventHandler: CarbonEventHandler<Context>?
    private let store: HotkeyStore
    private let register: Register
    private let unregister: Unregister

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

    /// Creates a service and registers every enabled action's combo.
    ///
    /// The Carbon calls are injected — the same shape
    /// `CarbonEventHandler` takes for its handler's install/remove — so
    /// the register / reload / teardown lifecycle is pinnable without a
    /// live Carbon event loop. Production uses the live calls.
    init(
        store: HotkeyStore = HotkeyStore(),
        register: @escaping Register = HotkeyService.carbonRegister,
        unregister: @escaping Unregister = HotkeyService.carbonUnregister,
        install: (UnsafeMutableRawPointer, inout EventHandlerRef?) -> Void = HotkeyService.carbonInstall,
        remove: @escaping (EventHandlerRef) -> Void = HotkeyService.carbonRemove
    ) {
        self.store = store
        self.register = register
        self.unregister = unregister
        installEventHandler(install: install, remove: remove)
        registerHotkeys()
    }

    deinit {
        // A queued dispatch that already captured the context must find
        // nothing to call once the service is gone; the handler removal
        // in CarbonEventHandler.deinit is the other half (no new events).
        context.handler = nil
        // And every registration goes back to the system: a dead service
        // must leave no phantom combo swallowing keys system-wide, and a
        // replacement service must find the combos free to register once.
        unregisterAll()
    }

    /// Unregisters everything and registers from the store again.
    /// Called after the user edits bindings in Settings; failedActions is
    /// recomputed, so newly freed (or newly conflicted) actions surface
    /// in the menu without a relaunch.
    func reload() {
        unregisterAll()
        registerHotkeys()
    }

    /// Gives back every registration the service holds, through the
    /// injected unregister call. Teardown and reload both pass through
    /// here, so "nothing stays registered" is one rule, not two.
    private func unregisterAll() {
        for ref in hotKeyRefs {
            if let ref { unregister(ref) }
        }
        hotKeyRefs = []
    }

    private func registerHotkeys() {
        failedActions = []
        for action in HotkeyAction.allCases {
            let binding = store.binding(for: action)
            // A disabled action registers nothing and warns about nothing.
            guard let keyCode = binding.keyCode else { continue }
            var ref: EventHotKeyRef?
            let status = register(
                keyCode,
                binding.modifiers,
                action.hotkeyID,
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

    private func installEventHandler(
        install: (UnsafeMutableRawPointer, inout EventHandlerRef?) -> Void,
        remove: @escaping (EventHandlerRef) -> Void
    ) {
        eventHandler = CarbonEventHandler(
            payload: context,
            install: install,
            remove: remove)
    }

    // MARK: Live Carbon calls
    //
    // The defaults for the injected seams: the register/unregister pair
    // that owns the system-wide combos, and the install/remove pair
    // `CarbonEventHandler` takes. Every Carbon call the service makes
    // lives here.

    static func carbonRegister(
        keyCode: UInt32, modifiers: UInt32, hotKeyID: UInt32,
        ref: inout EventHotKeyRef?
    ) -> OSStatus {
        RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: signature, id: hotKeyID),
            GetApplicationEventTarget(),
            0,
            &ref)
    }

    static func carbonUnregister(_ ref: EventHotKeyRef) {
        UnregisterEventHotKey(ref)
    }

    static func carbonInstall(
        userData: UnsafeMutableRawPointer, ref: inout EventHandlerRef?
    ) {
        var eventType = Self.eventType
        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonCallback,
            1,
            &eventType,
            userData,
            &ref)
    }

    static func carbonRemove(_ ref: EventHandlerRef) {
        RemoveEventHandler(ref)
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
