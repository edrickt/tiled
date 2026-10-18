/// Platform-free description of the status menu, extracted from
/// `AppDelegate` so the structure contracts (warning precedence over the
/// status line, slot grouping, empty states, undo visibility, the
/// untrusted block) are testable without building NSMenu items.
/// `AppDelegate` maps these onto NSMenu/NSMenuItem one-for-one.
enum MenuModel {
    /// What a clickable item does when chosen. `AppDelegate` maps each
    /// case to its @objc selector and representedObject.
    enum Action: Equatable {
        case tileSlot(Slot)
        case toggleExpand
        case evictFocusedWindow
        /// Layout-switch rows: collapsed replacement for the inactive
        /// layout's whole section. Tiling the focused window into the
        /// destination's top-left performs the switch through the engine's
        /// own mutual-exclusion rule, with the usual undo notice.
        case switchToQuarters
        case switchToSixths
        case untileWindow(WindowID)
        case focusWindow(WindowID)
        case tileHere(Slot)
        case undoSwitch
        case untileAll
        case resetDividers
        case showGuide
        case showSettings
        case openAccessibilitySettings
        case quit
        case openShortcuts
    }

    struct Item: Equatable {
        var title: String
        var isEnabled = true
        /// Disabled section header inside the tile submenu.
        var isHeader = false
        var keyEquivalent = ""
        var action: Action?
        var isSeparator = false
        var children: [Item]?
        /// Why a non-header item is disabled, in menu-title words (shown
        /// when enabled would be a lie: the precondition isn't met).
        /// Rendered by AppDelegate as the item's tooltip.
        var disabledReason: String?

        static func separator() -> Item { Item(title: "", isSeparator: true) }
    }

    /// Everything the menu structure reads, gathered from the controller,
    /// hotkey service, and store in one immutable pass. Equatable so the
    /// delegate can skip the NSMenu rebuild when nothing the menu reads
    /// changed (frame pushes during drag-resize fire change callbacks
    /// every tick; the menu only cares about state, warnings, rows).
    ///
    /// `memberwise` keeps the existing 15-arg construction working:
    /// `monitorSections` defaults to [] (single monitor, no headers).
    struct Snapshot: Equatable {
        var isTrusted: Bool
        var warnings: [String]
        var notice: String?
        var layoutTitle: String
        /// The layout currently on screen. The tile submenu lists only
        /// the *active* layout's slots; the inactive one collapses to a
        /// single switch row. Switching is destructive (it untiles
        /// everything) and rare, while the current layout's slots are
        /// the everyday decision set: one submenu, one layout's worth
        /// of scanning.
        var activeLayout: LayoutKind
        /// A one-off tiling refusal (an app that wouldn't resize), kept
        /// separate from hotkey failures: rendering a refusal under a
        /// "shortcut problem" summary would misdiagnose it and point
        /// the user at the wrong subsystem.
        var tileError: String?
        /// True when any warning names a lost global-hotkey registration
        /// (fixed combos or slots), as opposed to a one-off tiling error.
        /// Those rows get an actionable follow-up, not just prose.
        var hasHotkeyWarnings: Bool
        /// Whether a splitter backup is parked: the manage row reads
        /// "Restore Previous Splitters" instead of "Reset Splitters".
        var hasSplitterBackup: Bool
        /// Whether a window is focused right now. The collapsed switch
        /// rows need one to tile: disabled (with their reason stated)
        /// when nothing is focused, never a silent no-op.
        var hasFocusedWindow: Bool
        /// What the focused window's expand toggle does right now,
        /// driving the expand row's stateful title.
        var expandState: ExpandToggleState
        var tiledWindows: [TiledWindow]
        var canUndoDisplacement: Bool
        var evictedCount: Int
        /// Windows on the focused canvas: the scope Untile All acts on.
        /// Distinct from `tiledWindows`, which spans every visible canvas
        /// for the manage list, because the row's count must match the
        /// action it performs.
        var untileCount: Int
        /// Per-monitor section headers for the tiled-windows list, in
        /// menu order. Empty = single monitor (no headers rendered).
        /// Defaulted so the existing 15-arg construction keeps working.
        var monitorSections: [MonitorSection] = []

        struct TiledWindow: Equatable {
            var id: WindowID
            var slot: Slot
            var appName: String?
            /// Display the window tiles on, matched against
            /// `MonitorSection.key`: identity, never the display name, so
            /// two monitors sharing a name still separate. Nil for the
            /// legacy flat list.
            var screen: ScreenID? = nil
        }

        struct MonitorSection: Equatable {
            /// Header title, e.g. "Display 1 · Quarters · 2 tiled". The
            /// human-readable display name lives only here, as text.
            var title: String
            /// Display identity matching `TiledWindow.screen`.
            var key: ScreenID?
        }
    }

    /// Builds the full menu from a snapshot. `binding` supplies each
    /// action's live label so custom bindings show and disabled actions
    /// render without a combo.
    static func items(
        snapshot: Snapshot, binding: (HotkeyAction) -> HotkeyBinding
    ) -> [Item] {
        var items: [Item] = []

        // 1. Status: warnings never displace the compass, and the latest
        // outcome narrates even while warnings persist. The layout/count
        // line doubles as the empty state ("0 tiled" reads as a status, so
        // no separate "No tiled windows" row that would contradict an undo
        // notice above it) and always renders while trusted; trouble is
        // exactly when the user needs it.
        if snapshot.isTrusted {
            // A tiling refusal renders verbatim as its own row, never
            // folded into the shortcut summary. Squashing "Safari
            // couldn't be tiled" under "shortcut problem" would
            // misdiagnose it and point the user at the wrong subsystem.
            if let tileError = snapshot.tileError {
                items.append(Item(title: tileError, isEnabled: false))
            }
            // Hotkey failures collapse to one summary row with the count: full
            // sentences used to stack here (a tiling error + fixed-combo
            // failures + N slot failures), turning the menu's first
            // screenful into a troubleshooting essay. The summary keeps
            // its severity glyph and its door ("Open Shortcuts…"); the
            // full sentences live in the Shortcuts tab, where there is
            // room to fix them.
            if !snapshot.warnings.isEmpty {
                items.append(Item(
                    title: MenuText.warningSummaryTitle(count: snapshot.warnings.count),
                    isEnabled: false))
            }
            if snapshot.hasHotkeyWarnings {
                // A disabled row can't fix itself: offer the door. The
                // hotkey surface lives in Settings → Shortcuts, so the
                // row after a failure opens exactly that tab: the one
                // surface a hotkey-first user can act on.
                items.append(Item(title: "Open Shortcuts…", action: .openShortcuts))
            }
            // The latest outcome narrates below the warnings, never
            // suppressed by them: a lingering hotkey failure must not
            // permanently erase the record of what the workspace just did.
            // Warnings diagnose; the notice narrates; the status line
            // orients: three jobs, three rows, in that order.
            if let notice = snapshot.notice {
                items.append(Item(title: notice, isEnabled: false))
            }
            items.append(Item(title: snapshot.layoutTitle, isEnabled: false))
        }
        items.append(.separator())

        // 2. Act + 3. Manage.
        if snapshot.isTrusted {
            var tileChildren: [Item] = []
            if snapshot.activeLayout == .quarters {
                // The everyday decision set: quads + halves, never the
                // sixths 11. The inactive layout is one switch row, not
                // a section.
                tileChildren.append(Item(title: "Quarters · Quads", isEnabled: false, isHeader: true))
                for slot in SlotPresentation.quartersQuads {
                    tileChildren.append(tileItem(slot, binding))
                }
                tileChildren.append(Item(title: "Halves", isEnabled: false, isHeader: true))
                for slot in SlotPresentation.quartersHalves {
                    tileChildren.append(tileItem(slot, binding))
                }
                tileChildren.append(.separator())
                // Honest switch row: enabled only with a focused window to
                // tile, and titled for what it does: the focused window
                // moves into the destination's top-left as the switch
                // happens. The disabled form names its own precondition, so
                // the row never reads as broken. (The "…" stays off: no
                // dialog follows; the row acts immediately when ready.)
                tileChildren.append(Item(
                    title: "Switch to Sixths (focused window → Top Left Sixth)",
                    isEnabled: snapshot.hasFocusedWindow,
                    action: .switchToSixths,
                    disabledReason: snapshot.hasFocusedWindow
                        ? nil : "Needs a focused window: click a window first."))            } else {
                // Sixths sub-groups mirror the thirds/two-thirds naming in
                // Settings: 11 flat items exceed working memory at the moment
                // of action, so chunk them into corners, thirds, two-thirds.
                tileChildren.append(Item(title: "Sixths · Corners", isEnabled: false, isHeader: true))
                for slot in SlotPresentation.sixthsCorners {
                    tileChildren.append(tileItem(slot, binding))
                }
                tileChildren.append(Item(title: "Thirds", isEnabled: false, isHeader: true))
                for slot in SlotPresentation.sixthsThirds {
                    tileChildren.append(tileItem(slot, binding))
                }
                tileChildren.append(Item(title: "Two-Thirds", isEnabled: false, isHeader: true))
                for slot in SlotPresentation.sixthsTwoThirds {
                    tileChildren.append(tileItem(slot, binding))
                }
                tileChildren.append(.separator())
                tileChildren.append(Item(
                    title: "Switch to Quarters (focused window → Top Left)",
                    isEnabled: snapshot.hasFocusedWindow,
                    action: .switchToQuarters,
                    disabledReason: snapshot.hasFocusedWindow
                        ? nil : "Needs a focused window: click a window first."))
            }
            items.append(Item(title: "Tile Focused Window", children: tileChildren))
            items.append(Item(
                title: MenuText.expandItemTitle(
                    label: binding(.expand).label,
                    expandState: snapshot.expandState),
                action: .toggleExpand))
            items.append(Item(
                title: MenuText.evictItemTitle(label: binding(.evict).label),
                action: .evictFocusedWindow))
            // The window list stays aggregate across every visible canvas
            // (grouped per display). The focused-canvas rows follow the
            // focused canvas instead: undo, untile all, and splitters act
            // on it alone. Undo and a parked splitter restore are live
            // receipts, so they survive Untile All even when the focused
            // canvas has no tiled windows.
            let hasWindowRows = !snapshot.tiledWindows.isEmpty
            let hasFocusedCanvasRows =
                snapshot.canUndoDisplacement || snapshot.untileCount > 0
                || snapshot.hasSplitterBackup
            if hasWindowRows || hasFocusedCanvasRows {
                items.append(.separator())
            }
            if hasWindowRows {
                // Multi-monitor: group the manage list per display with a
                // disabled header per section ("Display 1 · Quarters · 2
                // tiled"). Single-monitor setups render the flat list.
                if snapshot.monitorSections.isEmpty {
                    for window in snapshot.tiledWindows {
                        items.append(windowItem(window, binding))
                    }
                } else {
                    var index = 0
                    for section in snapshot.monitorSections {
                        items.append(Item(
                            title: section.title, isEnabled: false, isHeader: true))
                        while index < snapshot.tiledWindows.count,
                              snapshot.tiledWindows[index].screen == section.key
                        {
                            items.append(windowItem(snapshot.tiledWindows[index], binding))
                            index += 1
                        }
                    }
                    // Defensive: windows whose section key mismatched
                    // (stale snapshot) still render rather than vanish.
                    while index < snapshot.tiledWindows.count {
                        items.append(windowItem(snapshot.tiledWindows[index], binding))
                        index += 1
                    }
                }
            }
            if hasWindowRows && hasFocusedCanvasRows {
                items.append(.separator())
            }
            if snapshot.canUndoDisplacement {
                // The combo lives in the title, not a key equivalent: the
                // global undo is a global hotkey, and a ⌘Z glyph here
                // would teach a combo that only works with this menu open
                // (and undoes in the wrong app everywhere else).
                items.append(Item(
                    title: MenuText.undoDisplacementTitle(evictedCount: snapshot.evictedCount)
                        + (binding(.undo).label.map { " · \($0)" } ?? ""),
                    action: .undoSwitch))
            }
            if snapshot.untileCount > 0 {
                // With no windows on the focused canvas, "Untile 0
                // Windows" would promise a click that does nothing.
                items.append(Item(
                    title: MenuText.untileAllTitle(count: snapshot.untileCount),
                    action: .untileAll))
            }
            if snapshot.untileCount > 0 || snapshot.hasSplitterBackup {
                // A reset needs a tiled edge to move; a parked backup is a
                // live one-step receipt, so its restore row survives
                // Untile All exactly as the undo row does.
                items.append(Item(
                    title: (snapshot.hasSplitterBackup
                        ? "Restore Previous Splitters" : "Reset Splitters")
                        + (binding(.resetSplitters).label.map { " · \($0)" } ?? ""),
                    action: .resetDividers))
            }
        } else {
            items.append(Item(title: "Waiting for Accessibility permission…", isEnabled: false))
            items.append(Item(title: "Open System Settings", action: .openAccessibilitySettings))
        }

        // 4. App.
        items.append(.separator())
        items.append(Item(title: "Tiled Guide", action: .showGuide))
        items.append(Item(title: "Settings…", keyEquivalent: ",", action: .showSettings))
        items.append(Item(title: "Quit Tiled", keyEquivalent: "q", action: .quit))
        return items
    }

    /// One clickable equivalent per global hotkey: the shortcut stays in
    /// the title text, since firing both would tile-then-untile.
    private static func tileItem(
        _ slot: Slot, _ binding: (HotkeyAction) -> HotkeyBinding
    ) -> Item {
        Item(
            title: MenuText.tileItemTitle(slot: slot, label: binding(.slot(slot)).label),
            action: .tileSlot(slot))
    }

    /// One row of the tiled-windows list: a submenu wearing the window's
    /// back. The row itself doesn't act (no click-focus surprise); the
    /// submenu leads with the distinctive action so opening it pays off.
    private static func windowItem(
        _ window: Snapshot.TiledWindow, _ binding: (HotkeyAction) -> HotkeyBinding
    ) -> Item {
        Item(
            title: MenuText.windowLine(
                slot: window.slot, appName: window.appName,
                label: binding(.slot(window.slot)).label),
            children: [
                Item(title: "Untile This Window", action: .untileWindow(window.id)),
                Item(title: "Focus \(window.appName ?? "Window")", action: .focusWindow(window.id)),
                Item(title: "Tile Focused Window Here", action: .tileHere(window.slot)),
            ])
    }
}
