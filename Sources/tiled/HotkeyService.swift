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
    /// Reserved Carbon id for the Settings fallback hotkey (⌃⌥⇧⌘,).
    /// Slot ids occupy 1...allCases.count, so this can never collide.
    static let settingsHotkeyID: UInt32 = 999
    /// The fallback combo: deliberately over-modified so it collides with
    /// nothing (all four modifiers + comma).
    static let settingsModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    static let settingsKeyCode = UInt32(kVK_ANSI_Comma)

    private final class Context {
        var handler: ((Slot) -> Void)?
        var settingsHandler: (() -> Void)?
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

    /// Fired by the ⌃⌥⇧⌘, fallback combo: opens Settings even when the
    /// menu-bar icon is hidden (the icon is otherwise the only handle).
    var settingsHandler: (() -> Void)? {
        get { context.settingsHandler }
        set { context.settingsHandler = newValue }
    }

    /// Whether the fallback combo registered (false = owned by another app).
    private(set) var settingsHotkeyFailed = false

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
        if hotKeyID.id == HotkeyService.settingsHotkeyID {
            DispatchQueue.main.async { context.settingsHandler?() }
            return noErr
        }
        guard let slot = context.slotByID[hotKeyID.id] else { return OSStatus(eventNotHandledErr) }
        DispatchQueue.main.async { context.handler?(slot) }
        return noErr
    }
}
