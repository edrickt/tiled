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

    /// The expand toggle's menu row; the combo is user-configurable, so
    /// the label comes from the store. `expandState` names where an
    /// expanded focused window returns: a slot, its pre-expand frame, or
    /// nothing yet.
    static func expandItemTitle(
        label: String?, expandState: ExpandToggleState
    ) -> String {
        let combo = label.map { " · \($0)" } ?? ""
        switch expandState {
        case .expands:
            return "Expand to Fill Screen\(combo)"
        case .returnsToSlot(let slot):
            return "Return to \(SlotPresentation.title(of: slot))\(combo)"
        case .returnsToPreviousFrame:
            return "Return to Previous Frame\(combo)"
        }
    }

    /// The evict row; the combo is user-configurable, so the label comes
    /// from the store. Mirrors the expand row: the shortcut stays in the
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

    /// A hotkey lost registration. For app actions the sentence names the
    /// action and its recovery path (`registrationRecovery`); for slots
    /// it names the general suspects instead. `label` nil means the
    /// action has no readable binding; the warning names the action
    /// either way, without the self-contradicting “Disabled is already
    /// used” reading.
    static func hotkeyFailureWarning(
        label: String?, title: String, recovery: String? = nil
    ) -> String {
        guard let label else {
            return "The shortcut for “\(title)” could not be registered: it has no hotkey."
        }
        if let recovery {
            return "The \(title) shortcut (\(label)) could not be registered; \(recovery)"
        }
        return "\(label) could not be registered; “\(title)” has no hotkey. "
            + "Another Tiled shortcut or a system shortcut may already use it."
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

    /// A write was deferred because its canvas is on a Mission Control
    /// Space the user cannot see. Not a refusal: the intent stands and
    /// reconciles when the Space returns, so the wording promises that
    /// rather than blaming the app.
    static func deferredOffSpaceAnnouncement() -> String {
        "That Space isn't visible yet: the change will apply when you return to it."
    }

    // MARK: Action receipt announcements (one sentence per action)

    /// Evict succeeded: the focused window released its slot.
    static func evictedAnnouncement() -> String {
        "Focused window evicted."
    }

    /// Untile All succeeded on the focused canvas.
    static func untileAllAnnouncement() -> String {
        "All tiled windows restored."
    }

    /// Untile All found no tiled window on the canvas it acts on.
    static func nothingToUntileAnnouncement() -> String {
        "No tiled windows on this canvas."
    }

    /// One window's untile row succeeded; `nil` names the anonymous
    /// fallback rather than an empty sentence.
    static func untileWindowAnnouncement(windowName: String?) -> String {
        "\(windowName ?? "Window") untiled."
    }

    /// One window's untile row found no slot to release.
    static func nothingToUntileWindowAnnouncement() -> String {
        "That window isn't tiled: nothing to untile."
    }

    /// Undo restored the chapter.
    static func undoAnnouncement() -> String {
        "Evicted windows restored."
    }

    /// A background display's canvas refused an untile. The display name
    /// tells the user which display the menu row acted on; the focused
    /// display (or a single display) adds no name because it would
    /// distinguish nothing.
    static func untileWindowRefusalAnnouncement(
        displayName: String?, error: String
    ) -> String {
        guard let displayName else { return error }
        return "\(displayName): \(error)"
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
