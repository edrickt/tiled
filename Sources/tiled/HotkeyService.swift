import Carbon.HIToolbox
import Foundation

/// One hotkey registration request: the live binding plus the Carbon
/// identity it must be registered under.
struct HotkeyRequest: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let hotKeyID: UInt32
    let signature: OSType
}

/// A live global-hotkey registration. The service keeps tokens opaque so
/// a fake can stand in for Carbon's `EventHotKeyRef`; only the production
/// adapter needs to know what the token represents.
protocol HotkeyRegistration: AnyObject {}

/// The Carbon boundary for global-hotkey registration. Injecting it lets
/// the suite pin disabled-skip, failure reporting, reload, and teardown
/// without a live process or the application event target.
protocol HotkeyRegistrar {
    func register(
        _ request: HotkeyRequest
    ) -> (status: OSStatus, registration: HotkeyRegistration?)
    func unregister(_ registration: HotkeyRegistration)
}

/// Production adapter over Carbon's `RegisterEventHotKey`. Its tokens are
/// `EventHotKeyRef`s; a token of any other type belongs to a test fake and
/// is left alone, so only a real registration reaches
/// `UnregisterEventHotKey`.
final class CarbonHotkeyRegistrar: HotkeyRegistrar {
    private final class CarbonHotkeyRegistration: HotkeyRegistration {
        let ref: EventHotKeyRef

        init(ref: EventHotKeyRef) {
            self.ref = ref
        }
    }

    func register(
        _ request: HotkeyRequest
    ) -> (status: OSStatus, registration: HotkeyRegistration?) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            request.keyCode,
            request.modifiers,
            EventHotKeyID(signature: request.signature, id: request.hotKeyID),
            GetApplicationEventTarget(),
            0,
            &ref)
        guard status == noErr, let ref else { return (status, nil) }
        return (status, CarbonHotkeyRegistration(ref: ref))
    }

    func unregister(_ registration: HotkeyRegistration) {
        guard let registration = registration as? CarbonHotkeyRegistration else {
            NSLog("Tiled: ignoring a foreign hotkey registration token")
            return
        }
        UnregisterEventHotKey(registration.ref)
    }
}

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

/// Registers the global hotkeys through a `HotkeyRegistrar`; the
/// production adapter wraps Carbon's RegisterEventHotKey (still the most
/// reliable global hotkey mechanism on macOS). Every action — slots and
/// app actions alike — registers from the store, so a user rebinds ⌥⇧R or
/// ⌃⌥⇧⌘Z exactly like ⌥⇧U.
///
/// One service owns the process-wide Carbon handler at a time; the shared
/// context keeps its callback valid across service replacement.
final class HotkeyService {
    // MARK: App-action Carbon ids
    //
    // Reserved ids for the five app actions. Slot ids occupy
    // 1...allCases.count, so 995–999 can never collide with them (or each
    // other); the id tests pin that.

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

    /// One routing declaration, consumed by the Carbon callback and its
    /// tests: every action's stable id maps back to that action. Derived
    /// from `allCases`, so an action cannot appear in one map and be
    /// missing from another. Unknown ids return nil (the callback answers
    /// eventNotHandledErr, letting the event fall through to other apps).
    static let actionByID: [UInt32: HotkeyAction] = Dictionary(
        uniqueKeysWithValues: HotkeyAction.allCases.map { ($0.hotkeyID, $0) })

    static func route(forHotKeyID id: UInt32) -> HotkeyAction? {
        actionByID[id]
    }

    private final class Context {
        var handler: ((HotkeyAction) -> Void)?
    }

    private static let signature = OSType(0x54_49_4C_44) // 'TILD'
    private static let eventType = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed))

    /// Tokens to retire on reload and deinit. The service never touches a
    /// Carbon ref directly; the registrar owns the token's meaning.
    private var registrations: [HotkeyRegistration] = []
    private let registrar: HotkeyRegistrar
    /// The Carbon callback's context is process-wide, like the once-only
    /// event handler that points at it. A per-service context would dangle
    /// as soon as a service deinits; a new service updates this shared
    /// handler instead of leaving Carbon aimed at freed memory.
    private static let sharedContext = Context()
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
        get { Self.sharedContext.handler }
        set { Self.sharedContext.handler = newValue }
    }

    init(
        store: HotkeyStore = HotkeyStore(),
        registrar: HotkeyRegistrar = CarbonHotkeyRegistrar(),
        eventHandlerInstaller: (() -> Void)? = nil
    ) {
        self.store = store
        self.registrar = registrar
        if let eventHandlerInstaller {
            eventHandlerInstaller()
        } else {
            Self.installEventHandler(with: Self.sharedContext)
        }
        registerHotkeys()
    }

    /// No registration may outlive the service: retire every token the
    /// registrar still considers live.
    deinit {
        retireRegistrations()
    }

    /// Unregisters everything and registers from the store again.
    /// Called after the user edits bindings in Settings; failedActions is
    /// recomputed, so newly freed (or newly conflicted) actions surface
    /// in the menu without a relaunch.
    func reload() {
        retireRegistrations()
        registerHotkeys()
    }

    private func retireRegistrations() {
        for registration in registrations {
            registrar.unregister(registration)
        }
        registrations.removeAll()
    }

    private func registerHotkeys() {
        // Reload must recompute failures, never retain a stale set.
        failedActions = []
        for action in HotkeyAction.allCases {
            let binding = store.binding(for: action)
            // A disabled action registers nothing and warns about nothing.
            guard let keyCode = binding.keyCode else { continue }
            let request = HotkeyRequest(
                keyCode: keyCode,
                modifiers: binding.modifiers,
                hotKeyID: action.hotkeyID,
                signature: Self.signature)
            let result = registrar.register(request)
            if result.status == noErr, let registration = result.registration {
                registrations.append(registration)
            } else {
                failedActions.append(action)
                NSLog(
                    "Tiled: failed to register hotkey for %@ (osstatus %d)",
                    action.title, result.status)
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
        guard let action = HotkeyService.route(forHotKeyID: hotKeyID.id) else {
            return OSStatus(eventNotHandledErr)
        }
        DispatchQueue.main.async { context.handler?(action) }
        return noErr
    }
}
