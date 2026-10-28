/// Platform-free description of the status menu, extracted from the
/// delegate so the structure contracts (warning precedence over the
/// status line, slot grouping, empty states, undo visibility, the
/// untrusted block) are testable without building NSMenu items.
/// `MenuBarPresenter` maps these onto NSMenu/NSMenuItem one-for-one.
enum MenuModel {
    /// What a clickable item does when chosen. `MenuBarPresenter` maps
    /// each case to its @objc selector and representedObject.
    enum Action: Equatable {
        case tileSlot(SlotKey)
        case toggleExpand
        case evictFocusedWindow
        /// One top-level row inside the trusted block: the explicit layout
        /// switch. Always enabled, because an empty canvas can switch too.
        case switchLayout(to: LayoutKind)
        case untileWindow(WindowID)
        case focusWindow(WindowID)
        case tileHere(SlotKey)
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
    /// The memberwise initializer keeps direct construction working:
    /// `monitorSections` defaults to [] (single monitor, no headers).
    struct Snapshot: Equatable {
        var isTrusted: Bool
        var warnings: [String]
        var notice: String?
        var layoutTitle: String
        /// The layout currently on screen. The tile submenu lists only
        /// the *active* layout's slot keys, labelled by physical position;
        /// the other layout is one explicit switch row.
        var activeLayout: LayoutKind
        /// A one-off tiling refusal (an app that wouldn't resize), kept
        /// separate from hotkey failures: rendering a refusal under a
        /// "shortcut problem" summary would misdiagnose it and point
        /// the user at the wrong subsystem.
        var tileError: String?
        /// Whether a splitter backup is parked: the manage row reads
        /// "Restore Previous Splitters" instead of "Reset Splitters".
        var hasSplitterBackup: Bool
        /// What the focused window's expand toggle does right now,
        /// driving the expand row's stateful title.
        var expandState: ExpandToggleState
        var tiledWindows: [TiledWindow]
        var canUndoDisplacement: Bool
        /// The freshest chapter's displaced windows: evictees, a moved
        /// requester, and any reflow survivors share one chapter. Named
        /// for displacement because a swap chapter evicts nobody.
        var displacedCount: Int
        /// Windows on the focused canvas: the scope Untile All acts on.
        /// Distinct from `tiledWindows`, which spans every visible canvas
        /// for the manage list, because the row's count must match the
        /// action it performs.
        var untileCount: Int
        /// Per-monitor section headers for the tiled-windows list, in
        /// menu order. Empty = single monitor (no headers rendered).
        var monitorSections: [MonitorSection] = []
        /// The live combo label for each action that has one. Absent means
        /// the action is disabled, so its row renders without a combo. The
        /// labels travel in the snapshot, not through a live store read at
        /// item-build time, so a label-only remap changes snapshot equality
        /// and the ordinary diff rebuilds the menu.
        var labels: [HotkeyAction: String] = [:]

        func label(for action: HotkeyAction) -> String? {
            labels[action]
        }

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

    /// Builds the full menu from a snapshot. The snapshot carries each
    /// action's live label, so this is a pure function of its input: custom
    /// bindings show, disabled actions render without a combo, and a
    /// label-only remap is an ordinary snapshot difference.
    static func items(snapshot: Snapshot) -> [Item] {
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
        // Untrusted has no status block above, so it must not lead with a
        // separator; every other shape still separates status from Act.
        if !items.isEmpty { items.append(.separator()) }

        // 2. Act + 3. Manage.
        if snapshot.isTrusted {
            var tileChildren: [Item] = []
            if snapshot.activeLayout == .quarters {
                // The everyday decision set: quads + halves, never the
                // sixths 11. Each row carries the physical key it shares
                // with the other layout.
                tileChildren.append(Item(title: "Quarters · Quads", isEnabled: false, isHeader: true))
                for slot in SlotPresentation.quartersQuads {
                    tileChildren.append(tileItem(slot, snapshot))
                }
                tileChildren.append(Item(title: "Halves", isEnabled: false, isHeader: true))
                for slot in SlotPresentation.quartersHalves {
                    tileChildren.append(tileItem(slot, snapshot))
                }
            } else {
                // Sixths sub-groups mirror the thirds/two-thirds naming in
                // Settings: 11 flat items exceed working memory at the moment
                // of action, so chunk them into corners, thirds, two-thirds.
                tileChildren.append(Item(title: "Sixths · Corners", isEnabled: false, isHeader: true))
                for slot in SlotPresentation.sixthsCorners {
                    tileChildren.append(tileItem(slot, snapshot))
                }
                tileChildren.append(Item(title: "Thirds", isEnabled: false, isHeader: true))
                for slot in SlotPresentation.sixthsThirds {
                    tileChildren.append(tileItem(slot, snapshot))
                }
                tileChildren.append(Item(title: "Two-Thirds", isEnabled: false, isHeader: true))
                for slot in SlotPresentation.sixthsTwoThirds {
                    tileChildren.append(tileItem(slot, snapshot))
                }
            }
            items.append(Item(title: "Tile Focused Window", children: tileChildren))
            // The explicit switch sits beside the everyday tile rows and
            // never needs focus: an empty canvas can switch too. Named for
            // where it lands, with the live combo.
            let switchTarget = snapshot.activeLayout.other
            items.append(Item(
                title: MenuText.switchLayoutItemTitle(
                    target: switchTarget, label: snapshot.label(for: .switchLayout)),
                action: .switchLayout(to: switchTarget)))
            items.append(Item(
                title: MenuText.expandItemTitle(
                    label: snapshot.label(for: .expand),
                    expandState: snapshot.expandState),
                action: .toggleExpand))
            items.append(Item(
                title: MenuText.evictItemTitle(label: snapshot.label(for: .evict)),
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
                        items.append(windowItem(window, snapshot))
                    }
                } else {
                    // Rows arrive in canvas order, which can interleave a
                    // display's identified and withheld canvases. Group
                    // each window under its own section's identity instead
                    // of consuming one contiguous run.
                    let sectionKeys = Set(snapshot.monitorSections.map(\.key))
                    for section in snapshot.monitorSections {
                        items.append(Item(
                            title: section.title, isEnabled: false, isHeader: true))
                        for window in snapshot.tiledWindows where window.screen == section.key {
                            items.append(windowItem(window, snapshot))
                        }
                    }
                    // Defensive: windows whose section key mismatched
                    // (stale snapshot) still render rather than vanish.
                    for window in snapshot.tiledWindows
                    where !(window.screen.map(sectionKeys.contains) ?? false) {
                        items.append(windowItem(window, snapshot))
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
                    title: MenuText.undoDisplacementTitle(
                        displacedCount: snapshot.displacedCount)
                        + (snapshot.label(for: .undo).map { " · \($0)" } ?? ""),
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
                        + (snapshot.label(for: .resetSplitters).map { " · \($0)" } ?? ""),
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
    /// the title text, since firing both would tile-then-untile. The title
    /// names the concrete slot the row places; the action carries the
    /// shared physical key, so a stale menu cannot commit a foreign slot.
    private static func tileItem(
        _ slot: Slot, _ snapshot: Snapshot
    ) -> Item {
        Item(
            title: MenuText.tileItemTitle(
                slot: slot, label: snapshot.label(for: .slotKey(slot.key))),
            action: .tileSlot(slot.key))
    }

    /// One row of the tiled-windows list: a submenu wearing the window's
    /// back. The row itself doesn't act (no click-focus surprise); the
    /// submenu leads with the distinctive action so opening it pays off.
    private static func windowItem(
        _ window: Snapshot.TiledWindow, _ snapshot: Snapshot
    ) -> Item {
        Item(
            title: MenuText.windowLine(
                slot: window.slot, appName: window.appName,
                label: snapshot.label(for: .slotKey(window.slot.key))),
            children: [
                Item(title: "Untile This Window", action: .untileWindow(window.id)),
                Item(title: "Focus \(window.appName ?? "Window")", action: .focusWindow(window.id)),
                Item(title: "Tile Focused Window Here", action: .tileHere(window.slot.key)),
            ])
    }
}

extension MenuModel.Snapshot {
    /// Derives the menu's presentation fields from one scoped read.
    /// Pure: no controller, store, or gateway is touched here, so the
    /// snapshot cannot borrow another canvas's truth while it is built.
    init(reads: MenuReads, notice: String?) {
        let presentation = MenuReads.monitorPresentation(
            rows: reads.rows,
            layoutForScreen: { reads.layout(for: $0) })
        self.init(
            isTrusted: reads.isTrusted,
            warnings: reads.hotkeyWarnings,
            notice: notice,
            layoutTitle: presentation.statusLine,
            activeLayout: reads.canvas.state.layout,
            tileError: reads.tileError,
            hasSplitterBackup: reads.canvas.hasSplitterBackup,
            expandState: reads.expandState,
            tiledWindows: presentation.tiledWindows,
            canUndoDisplacement: !reads.canvas.undoStack.isEmpty,
            displacedCount: reads.canvas.displacedCount,
            untileCount: reads.canvas.tiledCount,
            monitorSections: presentation.sections,
            labels: reads.labels)
    }
}
