/// The Open Settings shortcut's live state as the hide-icon recovery
/// surfaces narrate it. Hiding the menu bar icon destroys the only
/// visible handle on the app, so the destructive confirm and the
/// checkbox's standing hint must promise the recovery that actually
/// works: the shortcut as currently bound, with its real label, when it
/// is live — relaunch-only otherwise. Never the factory combo
/// hard-coded after a rebind or disable, and never "taken by another
/// app" for a shortcut that is merely not registered yet.
///
/// Pure decision logic behind `SettingsDependencies.settingsHotkeyState`:
/// the provider gathers the facts, this type decides the state and its
/// copy, so every state is pinned without building AppKit alerts.
enum SettingsHotkeyState: Equatable {
    /// How the shortcut's registration pass ended.
    enum Registration: Equatable {
        /// The pass has not run at all — it starts only with the
        /// Accessibility trust — so nothing is registered yet.
        case notStarted
        /// The pass ran and registered this binding.
        case registered
        /// The pass ran and this binding's registration was refused
        /// (the combo is likely owned by another app).
        case refused
    }

    /// Nothing is registered yet: the pending Accessibility permission
    /// — never a conflict — is the reason.
    case pendingPermission
    /// The shortcut is turned off: no combo exists to promise.
    case disabled
    /// Bound, but registration was refused: the label exists but
    /// pressing it does nothing for Tiled.
    case registrationLost(label: String)
    /// Bound and registered: `label` is a working recovery combo.
    case live(label: String)

    /// The inert healthy default — the factory binding, registered —
    /// for `SettingsDependencies` and an un-wired tab: a headless caller
    /// sees the everyday recovery promise and overrides only what it
    /// asserts.
    static let healthyDefault: SettingsHotkeyState = .current(
        binding: HotkeyService.settingsDefaultBinding, registration: .registered)

    /// Decides the state from the facts the dependency provider gathers.
    /// Precedence: "nothing registered yet" first — before that pass no
    /// binding outcome exists to report — then the binding (disabled
    /// wins over any registration story: there is no combo at all), then
    /// the registration outcome.
    static func current(
        binding: HotkeyBinding, registration: Registration
    ) -> SettingsHotkeyState {
        switch registration {
        case .notStarted:
            return .pendingPermission
        case .registered, .refused:
            guard let label = binding.label else {
                // Disabled ≠ failed: a disabled action registers nothing
                // and warns about nothing.
                return .disabled
            }
            return registration == .refused
                ? .registrationLost(label: label)
                : .live(label: label)
        }
    }

    /// The confirm's recovery promise: the sentence that starts
    /// "To get back, …". The non-live states pair the relaunch recovery
    /// with the reason there is no combo ("and says so"): a destructive
    /// confirm must never leave the reader looking for a shortcut.
    var confirmRecovery: String {
        switch self {
        case .live(let label):
            return "To get back, press \(label) anywhere "
                + "or quit and reopen Tiled; Settings opens automatically."
        case .disabled:
            return "To get back, quit and reopen Tiled; "
                + "Settings opens automatically. "
                + "(The \(HotkeyAction.settings.title) shortcut is turned off, "
                + "so this is the only way back.)"
        case .registrationLost(let label):
            return "To get back, quit and reopen Tiled; "
                + "Settings opens automatically. "
                + "(The \(label) shortcut is already used by another app, "
                + "so this is the only way back.)"
        case .pendingPermission:
            return "To get back, quit and reopen Tiled; "
                + "Settings opens automatically. "
                + "(No shortcut is registered yet: Accessibility permission "
                + "is still pending, so this is the only way back.)"
        }
    }

    /// The checkbox's standing hint: the same promise, at rest.
    var hint: String {
        switch self {
        case .live(let label):
            return "When the icon is hidden, press \(label) anywhere "
                + "or quit and reopen Tiled to get back here; "
                + "Settings opens automatically. "
                + "Hiding asks first, so this never happens by accident."
        case .disabled, .registrationLost, .pendingPermission:
            return "When the icon is hidden, quit and reopen Tiled "
                + "to get back here; Settings opens automatically. "
                + "Hiding asks first, so this never happens by accident."
        }
    }

    /// The checkbox's tooltip: the short form of the same promise.
    var toolTip: String {
        switch self {
        case .live(let label):
            return "The icon disappears immediately; press \(label) to get back."
        case .disabled, .registrationLost, .pendingPermission:
            return "The icon disappears immediately; "
                + "quit and reopen Tiled to get back."
        }
    }
}
