import Carbon.HIToolbox
import Foundation

extension Slot {
    /// Modifier set for this slot's hotkey: quarters use ⌥⇧, sixths add ⌘.
    var modifiers: UInt32 {
        switch layout {
        case .quarters: UInt32(shiftKey | optionKey)
        case .sixths: UInt32(shiftKey | optionKey | cmdKey)
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

/// Registers the global ⌥⇧ hotkeys via Carbon's RegisterEventHotKey
/// (still the most reliable global hotkey mechanism on macOS).
final class HotkeyService {
    /// Reserved Carbon id for the fixed expand toggle hotkey (⌥⇧⏎).
    /// Slot ids occupy 1...allCases.count and the Settings fallback id is
    /// 999, so 998 can never collide.
    static let expandHotkeyID: UInt32 = 998
    /// The expand combo: ⌥⇧⏎, fixed — slot shortcuts are remappable, this
    /// one rides beside them like the Settings fallback.
    static let expandModifiers = UInt32(shiftKey | optionKey)
    static let expandKeyCode = UInt32(kVK_Return)

    /// The fixed expand binding, for menu labels and registration.
    static let expandBinding = HotkeyBinding(modifiers: expandModifiers, keyCode: expandKeyCode)

    /// Reserved Carbon id for the fixed evict hotkey (⌥⇧⌫). Slot ids
    /// occupy 1...allCases.count and the other fixed ids are 997-999,
    /// so 996 can never collide.
    static let evictHotkeyID: UInt32 = 996
    /// The evict combo: ⌥⇧⌫, fixed — slot shortcuts are remappable, this
    /// one rides beside them like the expand toggle.
    static let evictModifiers = UInt32(shiftKey | optionKey)
    static let evictKeyCode = UInt32(kVK_Delete)

    /// The fixed evict binding, for menu labels and registration.
    static let evictBinding = HotkeyBinding(modifiers: evictModifiers, keyCode: evictKeyCode)

    /// Reserved Carbon id for the Settings fallback hotkey (⌃⌥⇧⌘,).
    /// Slot ids occupy 1...allCases.count, so this can never collide.
    static let settingsHotkeyID: UInt32 = 999
    /// The fallback combo: deliberately over-modified so it collides with
    /// nothing (all four modifiers + comma).
    static let settingsModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    static let settingsKeyCode = UInt32(kVK_ANSI_Comma)

    /// Reserved Carbon id for the global undo hotkey (⌃⌥⇧⌘Z). Same
    /// over-modified pattern as the Settings fallback so it collides with
    /// nothing; 997 never collides with slot ids, 998, or 999.
    static let undoHotkeyID: UInt32 = 997
    static let undoModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    static let undoKeyCode = UInt32(kVK_ANSI_Z)

    private final class Context {
        var handler: ((Slot) -> Void)?
        var expandHandler: (() -> Void)?
        var evictHandler: (() -> Void)?
        var settingsHandler: (() -> Void)?
        var undoHandler: (() -> Void)?
        let slotByID: [UInt32: Slot]

        init() {
            var map: [UInt32: Slot] = [:]
            for slot in Slot.allCases {
                map[slot.hotkeyID] = slot
            }
            slotByID = map
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

    /// Slots whose global hotkey could not be registered (likely owned by
    /// another app). Surfaced in the status menu; never just logged.
    private(set) var failedSlots: [Slot] = []

    var handler: ((Slot) -> Void)? {
        get { context.handler }
        set { context.handler = newValue }
    }

    /// Fired by the fixed ⌥⇧⏎ combo: toggles the focused window between
    /// expanded (fills the screen) and its previous tile.
    var expandHandler: (() -> Void)? {
        get { context.expandHandler }
        set { context.expandHandler = newValue }
    }

    /// Whether the expand combo registered (false = owned by another app).
    private(set) var expandHotkeyFailed = false

    /// Fired by the fixed ⌥⇧⌫ combo: evicts the focused window, growing
    /// the surviving column-mates into the freed cells.
    var evictHandler: (() -> Void)? {
        get { context.evictHandler }
        set { context.evictHandler = newValue }
    }

    /// Whether the evict combo registered (false = owned by another app).
    private(set) var evictHotkeyFailed = false

    /// Fired by the ⌃⌥⇧⌘, fallback combo: opens Settings even when the
    /// menu-bar icon is hidden (the icon is otherwise the only handle).
    var settingsHandler: (() -> Void)? {
        get { context.settingsHandler }
        set { context.settingsHandler = newValue }
    }

    /// Whether the fallback combo registered (false = owned by another app).
    private(set) var settingsHotkeyFailed = false

    /// Fired by the fixed ⌃⌥⇧⌘Z combo: undoes the last layout switch from
    /// anywhere. The switch is triggered by global hotkeys while other apps
    /// are frontmost, so the undo must be global too — a menu-open ⌘Z
    /// would undo in the wrong app.
    var undoHandler: (() -> Void)? {
        get { context.undoHandler }
        set { context.undoHandler = newValue }
    }

    /// Whether the undo combo registered (false = owned by another app).
    private(set) var undoHotkeyFailed = false

    init(store: HotkeyStore = HotkeyStore()) {
        self.store = store
        Self.installEventHandler(with: context)
        registerHotkeys()
    }

    /// Unregisters everything and registers from the store again.
    /// Called after the user edits bindings in Settings; failedSlots is
    /// recomputed, so newly freed (or newly conflicted) slots surface in
    /// the menu without a relaunch.
    func reload() {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs = []
        registerHotkeys()
    }

    private func registerHotkeys() {
        failedSlots = []
        settingsHotkeyFailed = false
        expandHotkeyFailed = false
        evictHotkeyFailed = false
        undoHotkeyFailed = false
        var evictRef: EventHotKeyRef?
        if RegisterEventHotKey(
            Self.evictKeyCode,
            Self.evictModifiers,
            EventHotKeyID(signature: Self.signature, id: Self.evictHotkeyID),
            GetApplicationEventTarget(),
            0,
            &evictRef) == noErr
        {
            hotKeyRefs.append(evictRef)
        } else {
            evictHotkeyFailed = true
            NSLog("tiled: failed to register evict hotkey")
        }
        var expandRef: EventHotKeyRef?
        if RegisterEventHotKey(
            Self.expandKeyCode,
            Self.expandModifiers,
            EventHotKeyID(signature: Self.signature, id: Self.expandHotkeyID),
            GetApplicationEventTarget(),
            0,
            &expandRef) == noErr
        {
            hotKeyRefs.append(expandRef)
        } else {
            expandHotkeyFailed = true
            NSLog("tiled: failed to register expand hotkey")
        }
        var settingsRef: EventHotKeyRef?
        if RegisterEventHotKey(
            Self.settingsKeyCode,
            Self.settingsModifiers,
            EventHotKeyID(signature: Self.signature, id: Self.settingsHotkeyID),
            GetApplicationEventTarget(),
            0,
            &settingsRef) == noErr
        {
            hotKeyRefs.append(settingsRef)
        } else {
            settingsHotkeyFailed = true
            NSLog("tiled: failed to register settings fallback hotkey")
        }
        var undoRef: EventHotKeyRef?
        if RegisterEventHotKey(
            Self.undoKeyCode,
            Self.undoModifiers,
            EventHotKeyID(signature: Self.signature, id: Self.undoHotkeyID),
            GetApplicationEventTarget(),
            0,
            &undoRef) == noErr
        {
            hotKeyRefs.append(undoRef)
        } else {
            undoHotkeyFailed = true
            NSLog("tiled: failed to register undo hotkey")
        }
        for slot in Slot.allCases {
            let binding = store.binding(for: slot)
            // A disabled slot registers nothing and warns about nothing.
            guard let keyCode = binding.keyCode else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                keyCode,
                binding.modifiers,
                EventHotKeyID(signature: Self.signature, id: slot.hotkeyID),
                GetApplicationEventTarget(),
                0,
                &ref)
            if status == noErr {
                hotKeyRefs.append(ref)
            } else {
                failedSlots.append(slot)
                NSLog("tiled: failed to register hotkey for %@ (osstatus %d)", slot.rawValue, status)
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
        if hotKeyID.id == HotkeyService.expandHotkeyID {
            DispatchQueue.main.async { context.expandHandler?() }
            return noErr
        }
        if hotKeyID.id == HotkeyService.evictHotkeyID {
            DispatchQueue.main.async { context.evictHandler?() }
            return noErr
        }
        if hotKeyID.id == HotkeyService.settingsHotkeyID {
            DispatchQueue.main.async { context.settingsHandler?() }
            return noErr
        }
        if hotKeyID.id == HotkeyService.undoHotkeyID {
            DispatchQueue.main.async { context.undoHandler?() }
            return noErr
        }
        guard let slot = context.slotByID[hotKeyID.id] else { return OSStatus(eventNotHandledErr) }
        DispatchQueue.main.async { context.handler?(slot) }
        return noErr
    }
}
