/// User-visible strings for the status menu and feedback announcements,
/// extracted from `AppDelegate` so the composition rules (pluralization,
/// disabled labels, hotkey-failure warnings) are unit-testable without
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
    /// row says where the toggle goes back: a stateless toggle would
    /// leave the user guessing what "expand" means right now.
    static func expandItemTitle(label: String?, expandedSlot: Slot? = nil) -> String {
        let combo = label.map { " · \($0)" } ?? ""
        guard let expandedSlot else { return "Expand to Fill Screen\(combo)" }
        return "Return to \(SlotPresentation.title(of: expandedSlot))\(combo)"
    }

    /// The evict row; the combo is fixed, so the label is always present
    /// in practice. Mirrors the expand row: the shortcut stays in the
    /// title text, since a key equivalent would fire both.
    static func evictItemTitle(label: String?) -> String {
        let combo = label.map { " · \($0)" } ?? ""
        return "Evict Focused Window\(combo)"
    }

    /// Collapses N warnings into one summary row: the menu's first
    /// screenful is the everyday surface, not a troubleshooting essay.
    /// The count carries the severity; "Open Shortcuts…" carries the
    /// door; the full sentences already live in the Shortcuts tab.
    static func warningSummaryTitle(count: Int) -> String {
        count == 1
            ? "⚠ 1 shortcut problem: a combo is taken"
            : "⚠ \(count) shortcut problems: combos are taken"
    }

    // MARK: Warnings

    /// The fallback Settings combo lost registration. Carbon reports only
    /// a same-process collision through `eventHotKeyExistsErr`; another
    /// app's non-exclusive registration neither blocks nor reports, so
    /// the wording must not blame an app that cannot be detected.
    static func settingsHotkeyWarning() -> String {
        "The Settings shortcut (\u{2303}\u{2325}\u{21E7}\u{2318},) could not be registered; "
            + "quit and reopen Tiled to get back to Settings while hidden."
    }

    /// A slot's global hotkey lost registration. `label` nil means the slot
    /// has no readable binding; the warning names the slot either way,
    /// without the self-contradicting “Disabled is already used” reading.
    static func hotkeyFailureWarning(label: String?, slot: Slot) -> String {
        let title = SlotPresentation.title(of: slot)
        guard let label else {
            return "The shortcut for “\(title)” could not be registered: it has no hotkey."
        }
        return "\(label) could not be registered; “\(title)” has no hotkey. "
            + "Another Tiled shortcut or a system shortcut may already use it."
    }

    /// The fixed expand combo lost registration.
    static func expandHotkeyWarning() -> String {
        "The expand shortcut (⌥⇧⏎) could not be registered; "
            + "quit and reopen Tiled to try again."
    }

    /// The fixed evict combo lost registration.
    static func evictHotkeyWarning() -> String {
        "The evict shortcut (⌥⇧⌫) could not be registered; "
            + "quit and reopen Tiled to try again."
    }

    /// The fixed undo combo lost registration. The menu row still works,
    /// so the recovery is named, not a relaunch.
    static func undoHotkeyWarning() -> String {
        "The undo shortcut (⌃⌥⇧⌘Z) could not be registered; "
            + "undo the last displacement from the Tiled menu instead."
    }

    // MARK: Menu rows

    /// One line of the tiled-windows list: slot, app, and live combo.
    static func windowLine(slot: Slot, appName: String?, label: String?) -> String {
        let name = appName ?? "window"
        if let label {
            return "\(SlotPresentation.title(of: slot)) · \(name) (\(label))"
        }
        return "\(SlotPresentation.title(of: slot)) · \(name)"
    }

    /// One clickable equivalent per global hotkey. The shortcut stays in
    /// the title text rather than a key equivalent: firing both would
    /// tile-then-untile in one keypress. Disabled slots show no combo.
    static func tileItemTitle(slot: Slot, label: String?) -> String {
        label.map { "\(SlotPresentation.title(of: slot)) · \($0)" }
            ?? SlotPresentation.title(of: slot)
    }

    // MARK: Feedback announcements (haptic + VoiceOver text)

    static func noFocusedWindowAnnouncement() -> String {
        "No focused window: click a window first."
    }

    /// Pressing undo with an empty stack: no destruction to reverse.
    /// Names the expiry honestly instead of staying silent: the one
    /// surface whose promise is "never silently disagree" must answer
    /// its own keypress.
    static func nothingToUndoAnnouncement() -> String {
        "Nothing to undo: a later change replaced it."
    }

    static func alreadyTiledAnnouncement(slot: Slot) -> String {
        "\(SlotPresentation.title(of: slot)): already there."
    }

    static func refusedAnnouncement(windowName: String?) -> String {
        "\(windowName ?? "That window") couldn't be tiled: the app refused to resize it."
    }

    /// A ⌥⇧⏎ expand write was refused. Mirrors `refusedAnnouncement` but
    /// names the expand, not a tiling.
    static func expandRefusedAnnouncement(windowName: String?) -> String {
        "\(windowName ?? "That window") couldn't be expanded: the app refused to resize it."
    }

    /// Pressing evict on an untiled window: nothing holds a slot, so the
    /// key answers instead of staying silent: the hotkey path never
    /// no-ops quietly.
    static func nothingToEvictAnnouncement() -> String {
        "That window isn't tiled: nothing to evict."
    }

    // MARK: Restore failures

    /// A window's pre-tile frame could not be restored. Names the window
    /// when there is exactly one, so the reader knows which app refused;
    /// the plural states the count instead of listing names.
    static func restoreFailureMessage(_ failures: [String]) -> String {
        if failures.count == 1 {
            return "Couldn't restore “\(failures[0])”: it may still be sitting in its old tile."
        }
        return "Couldn't restore \(failures.count) windows: they may still be sitting in their old tiles."
    }

    /// Undo found nothing restorable: the chapter's windows all closed
    /// before it ran, so there is no window left to write.
    static let restoreEvictedWindowsFailure = "Couldn't restore the evicted windows."
}
