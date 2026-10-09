import Foundation

/// Everything the Settings window needs from the app, injected as one
/// value: the live Accessibility probe, the recovery actions, and the
/// hotkey/registration facts the tabs read.
///
/// One value instead of six independently-settable closures keeps the
/// wiring in a single place (the delegate's `ensureSettingsController`):
/// the tabs are handed their slice at construction, so nothing can set
/// half the wires and leave a tab reading a stale probe. The defaults are
/// inert, so a headless caller (tests, previews) can construct the shell
/// with `SettingsDependencies()` and override only what it asserts.
struct SettingsDependencies {
    /// Live Accessibility trust probe; every tab shows its permission row
    /// from this.
    var isTrusted: () -> Bool = { true }
    /// Opens the Accessibility permission pane.
    var openAccessibilitySettings: () -> Void = {}
    /// Fired when "Hide menu bar icon" commits, so the delegate can
    /// remove/restore the status item immediately.
    var hideIconChange: (Bool) -> Void = { _ in }
    /// Fired when the tile gap changes, so the delegate can re-place
    /// every tiled window under the new inset immediately.
    var gapChange: (Double) -> Void = { _ in }
    /// Fired after any binding change so the delegate can re-register
    /// hotkeys and refresh the menu.
    var hotkeysChange: () -> Void = {}
    /// Actions whose global hotkey lost registration, so the Shortcuts tab
    /// can surface the failure beside the recorder that accepted it.
    var failedActions: () -> [HotkeyAction] = { [] }
    /// The Open Settings shortcut's live state, so the hide-icon confirm
    /// and the checkbox's standing hint name the recovery that actually
    /// works: the current binding's real combo when it is live,
    /// relaunch-only otherwise (see `SettingsHotkeyState`).
    var settingsHotkeyState: () -> SettingsHotkeyState = { .healthyDefault }
}
