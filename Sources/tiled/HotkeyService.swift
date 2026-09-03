import AppKit
import Carbon.HIToolbox

extension Slot {
    /// HIToolbox virtual keycode for this slot's hotkey.
    var keyCode: UInt32 {
        switch self {
        case .topLeft: UInt32(kVK_ANSI_U)
        case .topRight: UInt32(kVK_ANSI_O)
        case .bottomLeft: UInt32(kVK_ANSI_M)
        case .bottomRight: UInt32(kVK_ANSI_Period)
        case .leftHalf: UInt32(kVK_ANSI_J)
        case .rightHalf: UInt32(kVK_ANSI_L)
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
    private final class Context {
        var handler: ((Slot) -> Void)?
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

    var handler: ((Slot) -> Void)? {
        get { context.handler }
        set { context.handler = newValue }
    }

    init() {
        Self.installEventHandler(with: context)
        registerHotkeys()
    }

    private func registerHotkeys() {
        let modifiers = UInt32(shiftKey | optionKey)
        for slot in Slot.allCases {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                slot.keyCode,
                modifiers,
                EventHotKeyID(signature: Self.signature, id: slot.hotkeyID),
                GetApplicationEventTarget(),
                0,
                &ref)
            if status == noErr {
                hotKeyRefs.append(ref)
            } else {
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
        guard let slot = context.slotByID[hotKeyID.id] else { return OSStatus(eventNotHandledErr) }
        DispatchQueue.main.async { context.handler?(slot) }
        return noErr
    }
}
