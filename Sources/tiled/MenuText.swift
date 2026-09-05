/// User-visible strings for the status menu and feedback announcements,
/// extracted from `AppDelegate` so the composition rules — pluralization,
/// disabled labels, hotkey-failure warnings — are unit-testable without
/// building AppKit menus or running alerts.
enum MenuText {
    // MARK: Menu titles

    /// Undo title names what returns: the evicted windows.
    static func undoSwitchTitle(evictedCount: Int) -> String {
        evictedCount == 1
            ? "Restore 1 Evicted Window" : "Restore \(evictedCount) Evicted Windows"
    }

    /// Bulk-action title names the consequence: restoring every window.
    static func untileAllTitle(count: Int) -> String {
        count == 1 ? "Untile 1 Window" : "Untile All \(count) Windows"
    }

    // MARK: Warnings

    /// The fallback Settings combo lost registration (owned by another app).
    static func settingsHotkeyWarning() -> String {
        "The Settings shortcut (\u{2303}\u{2325}\u{21E7}\u{2318},) is already used "
            + "by another app — relaunch tiled to get back to Settings while hidden."
    }

    /// A slot's global hotkey lost registration. `label` nil means the slot
    /// has no readable binding; the warning names the slot either way.
    static func hotkeyFailureWarning(label: String?, slot: Slot) -> String {
        "\(label ?? "Disabled") is already used by another app — "
            + "“\(SlotPresentation.title(of: slot))” has no hotkey."
    }

    // MARK: Menu rows

    /// One line of the tiled-windows list: slot, app, and live combo.
    static func windowLine(slot: Slot, appName: String?, label: String?) -> String {
        let name = appName ?? "window"
        if let label {
            return "\(SlotPresentation.title(of: slot)) — \(name) (\(label))"
        }
        return "\(SlotPresentation.title(of: slot)) — \(name)"
    }

    /// One clickable equivalent per global hotkey. The shortcut stays in
    /// the title text rather than a key equivalent: firing both would
    /// tile-then-untile in one keypress. Disabled slots show no combo.
    static func tileItemTitle(slot: Slot, label: String?) -> String {
        label.map { "\(SlotPresentation.title(of: slot)) — \($0)" }
            ?? SlotPresentation.title(of: slot)
    }

    // MARK: Feedback announcements (haptic + VoiceOver text)

    static func noFocusedWindowAnnouncement() -> String {
        "No focused window — click a window first, then tile."
    }

    static func alreadyTiledAnnouncement(slot: Slot) -> String {
        "\(SlotPresentation.title(of: slot)) — already there."
    }

    static func refusedAnnouncement(windowName: String?) -> String {
        "\(windowName ?? "That window") couldn't be tiled — the app refused to resize it."
    }
}
