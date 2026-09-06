/// User-visible strings for the status menu and feedback announcements,
/// extracted from `AppDelegate` so the composition rules — pluralization,
/// disabled labels, hotkey-failure warnings — are unit-testable without
/// building AppKit menus or running alerts.
enum MenuText {
    // MARK: Menu titles

    /// Undo title names what returns: the evicted windows.
    static func undoDisplacementTitle(evictedCount: Int) -> String {
        evictedCount == 1
            ? "Restore 1 Evicted Window" : "Restore \(evictedCount) Evicted Windows"
    }

    /// Bulk-action title names the consequence: restoring every window.
    /// Singular and plural stay symmetric ("Untile 1 Window" / "Untile 3 Windows").
    static func untileAllTitle(count: Int) -> String {
        count == 1 ? "Untile 1 Window" : "Untile \(count) Windows"
    }

    /// The expand toggle's menu row; the combo is fixed, so the label is
    /// always present in practice. `expandedSlot` names the slot an
    /// expanded focused window returns to: when a window is expanded the
    /// row says where the toggle goes back — a stateless toggle would
    /// leave the user guessing what "expand" means right now.
    static func expandItemTitle(label: String?, expandedSlot: Slot? = nil) -> String {
        let combo = label.map { " — \($0)" } ?? ""
        guard let expandedSlot else { return "Expand to Fill Screen\(combo)" }
        return "Return to \(SlotPresentation.title(of: expandedSlot))\(combo)"
    }

    /// The evict row; the combo is fixed, so the label is always present
    /// in practice. Mirrors the expand row: the shortcut stays in the
    /// title text, since a key equivalent would fire both.
    static func evictItemTitle(label: String?) -> String {
        let combo = label.map { " — \($0)" } ?? ""
        return "Evict Focused Window\(combo)"
    }

    /// Collapses N warnings into one summary row: the menu's first
    /// screenful is the everyday surface, not a troubleshooting essay.
    /// The count carries the severity; "Open Shortcuts…" carries the
    /// door; the full sentences already live in the Shortcuts tab.
    static func warningSummaryTitle(count: Int) -> String {
        count == 1
            ? "⚠ 1 shortcut problem — other apps own it"
            : "⚠ \(count) shortcut problems — other apps own them"
    }

    // MARK: Warnings

    /// The fallback Settings combo lost registration (owned by another app).
    static func settingsHotkeyWarning() -> String {
        "The Settings shortcut (\u{2303}\u{2325}\u{21E7}\u{2318},) is already used "
            + "by another app — quit and reopen tiled to get back to Settings while hidden."
    }

    /// A slot's global hotkey lost registration. `label` nil means the slot
    /// has no readable binding; the warning names the slot either way,
    /// without the self-contradicting “Disabled is already used” reading.
    static func hotkeyFailureWarning(label: String?, slot: Slot) -> String {
        let title = SlotPresentation.title(of: slot)
        guard let label else {
            return "The shortcut for “\(title)” is already used by another app — it has no hotkey."
        }
        return "\(label) is already used by another app — “\(title)” has no hotkey."
    }

    /// The fixed expand combo lost registration (owned by another app).
    static func expandHotkeyWarning() -> String {
        "The expand shortcut (⌥⇧⏎) is already used by another app — "
            + "quit and reopen tiled to try registering it again."
    }

    /// The fixed evict combo lost registration (owned by another app).
    static func evictHotkeyWarning() -> String {
        "The evict shortcut (⌥⇧⌫) is already used by another app — "
            + "quit and reopen tiled to try registering it again."
    }

    /// The fixed undo combo lost registration (owned by another app). The
    /// menu row still works, so the recovery is named, not a relaunch.
    static func undoHotkeyWarning() -> String {
        "The undo shortcut (⌃⌥⇧⌘Z) is already used by another app — "
            + "undo the last displacement from the tiled menu instead."
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
        "No focused window — click a window first."
    }

    /// Pressing undo with an empty stack: no destruction to reverse.
    /// Names the expiry honestly instead of staying silent — the one
    /// surface whose promise is "never silently disagree" must answer
    /// its own keypress.
    static func nothingToUndoAnnouncement() -> String {
        "Nothing to undo — a later change replaced it."
    }

    static func alreadyTiledAnnouncement(slot: Slot) -> String {
        "\(SlotPresentation.title(of: slot)) — already there."
    }

    static func refusedAnnouncement(windowName: String?) -> String {
        "\(windowName ?? "That window") couldn't be tiled — the app refused to resize it."
    }

    /// A ⌥⇧⏎ expand write was refused. Mirrors `refusedAnnouncement` but
    /// names the expand, not a tiling.
    static func expandRefusedAnnouncement(windowName: String?) -> String {
        "\(windowName ?? "That window") couldn't be expanded — the app refused to resize it."
    }

    /// Pressing evict on an untiled window: nothing holds a slot, so the
    /// key answers instead of staying silent — the hotkey path never
    /// no-ops quietly.
    static func nothingToEvictAnnouncement() -> String {
        "That window isn't tiled — nothing to evict."
    }

    /// An evict reflow write was refused. Mirrors `refusedAnnouncement`
    /// but names the evict, not a tiling.
    static func evictRefusedAnnouncement(windowName: String?) -> String {
        "\(windowName ?? "That window") couldn't be evicted — the app refused to resize it."
    }
}
