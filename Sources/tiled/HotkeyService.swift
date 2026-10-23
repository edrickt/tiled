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

/// Registers the global hotkeys through a `HotkeyRegistrar`; the
/// production adapter wraps Carbon's RegisterEventHotKey (still the most
/// reliable global hotkey mechanism on macOS). Every action — slot keys
/// and app actions alike — registers from the store, so a user rebinds
/// ⌥⇧R or ⌃⌥⇧⌘Z exactly like ⌥⇧U.
///
/// Registration belongs to the service; the Carbon event tap belongs to the
/// process. `CarbonHotkeyEventRouter` owns that one tap, and a service claims
/// its action handler for as long as it lives.
final class HotkeyService {
    // MARK: App-action Carbon ids
    //
    // Reserved ids for the six app actions. Slot-key ids occupy 1...11,
    // so 994–999 can never collide with them (or each other); the id
    // tests pin that.

    /// Expand toggle (default ⌥⇧⏎).
    static let expandHotkeyID: UInt32 = 998
    /// Evict focused window (default ⌥⇧⌫).
    static let evictHotkeyID: UInt32 = 996
    /// Reset splitters (default ⌥⇧R).
    static let resetSplittersHotkeyID: UInt32 = 995
    /// Switch the focused canvas to the other layout (default ⌥⇧\).
    static let switchLayoutHotkeyID: UInt32 = 994
    /// Settings fallback (default ⌃⌥⇧⌘,): opens Settings even when the
    /// menu-bar icon is hidden.
    static let settingsHotkeyID: UInt32 = 999
    /// Global undo (default ⌃⌥⇧⌘Z).
    static let undoHotkeyID: UInt32 = 997

    // MARK: App-action factory defaults
    //
    // The combos the fixed build shipped with. They are defaults now, not
    // constants: the store resolves each action's live binding, and the
    // Shortcuts tab can change any of them. The expand/evict/reset/switch
    // combos sit beside the ⌥⇧ slot set but on keys no slot defaults to;
    // Settings and undo are deliberately over-modified (all four
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

    static let switchLayoutModifiers = UInt32(shiftKey | optionKey)
    static let switchLayoutKeyCode = UInt32(kVK_ANSI_Backslash)
    static let switchLayoutDefaultBinding = HotkeyBinding(
        modifiers: switchLayoutModifiers, keyCode: switchLayoutKeyCode)

    static let settingsModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    static let settingsKeyCode = UInt32(kVK_ANSI_Comma)
    static let settingsDefaultBinding = HotkeyBinding(
        modifiers: settingsModifiers, keyCode: settingsKeyCode)

    static let undoModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    static let undoKeyCode = UInt32(kVK_ANSI_Z)
    static let undoDefaultBinding = HotkeyBinding(
        modifiers: undoModifiers, keyCode: undoKeyCode)

    /// One routing declaration, consumed by `CarbonHotkeyEventRouter` and
    /// its tests: every action's stable id maps back to that action. Derived
    /// from `allCases`, so an action cannot appear in one map and be
    /// missing from another. Unknown ids return nil (the router answers
    /// eventNotHandledErr, letting the event fall through to other apps).
    static let actionByID: [UInt32: HotkeyAction] = Dictionary(
        uniqueKeysWithValues: HotkeyAction.allCases.map { ($0.hotkeyID, $0) })

    static func route(forHotKeyID id: UInt32) -> HotkeyAction? {
        actionByID[id]
    }

    private static let signature = OSType(0x54_49_4C_44) // 'TILD'

    /// Tokens to retire on reload and deinit. The service never touches a
    /// Carbon ref directly; the registrar owns the token's meaning.
    private var registrations: [HotkeyRegistration] = []
    private let registrar: HotkeyRegistrar
    /// The process-wide event tap. Production shares one router; tests
    /// inject their own with a no-op installer so no live Carbon target is
    /// touched.
    let router: CarbonHotkeyEventRouter
    private let store: HotkeyStore

    /// Actions whose global hotkey could not be registered (likely owned
    /// by another app). Surfaced in the status menu and the Shortcuts tab;
    /// never just logged.
    private(set) var failedActions: [HotkeyAction] = []

    init(
        store: HotkeyStore = HotkeyStore(),
        registrar: HotkeyRegistrar = CarbonHotkeyRegistrar(),
        router: CarbonHotkeyEventRouter? = nil,
        eventHandlerInstaller: (() -> Void)? = nil
    ) {
        self.store = store
        self.registrar = registrar
        if let router {
            self.router = router
        } else if let eventHandlerInstaller {
            self.router = CarbonHotkeyEventRouter(installer: eventHandlerInstaller)
        } else {
            self.router = .shared
        }
        registerHotkeys()
    }

    /// No registration may outlive the service, and neither may its action
    /// handler: the router is process-wide, so teardown clears only this
    /// service's claim and leaves a replacement's handler installed.
    deinit {
        retireRegistrations()
        router.clearHandler(ifOwner: self)
    }

    /// Hands this service's route to the Carbon router for its lifetime.
    func setHandler(_ handler: @escaping (HotkeyAction) -> Void) {
        router.setHandler(handler, owner: self)
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
}
