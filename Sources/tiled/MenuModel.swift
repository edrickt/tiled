/// Platform-free description of the status menu, extracted from
/// `AppDelegate` so the structure contracts — warning precedence over the
/// status line, slot grouping, empty states, undo visibility, the
/// untrusted block — are testable without building NSMenu items.
/// `AppDelegate` maps these onto NSMenu/NSMenuItem one-for-one.
enum MenuModel {
    /// What a clickable item does when chosen. `AppDelegate` maps each
    /// case to its @objc selector and representedObject.
    enum Action: Equatable {
        case tileSlot(Slot)
        case toggleExpand
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

        static func separator() -> Item { Item(title: "", isSeparator: true) }
    }

    /// Everything the menu structure reads, gathered from the controller,
    /// hotkey service, and store in one immutable pass.
    struct Snapshot {
        var isTrusted: Bool
        var warnings: [String]
        var notice: String?
        var layoutTitle: String
        var tiledWindows: [TiledWindow]
        var canUndoSwitch: Bool
        var evictedCount: Int

        struct TiledWindow: Equatable {
            var id: WindowID
            var slot: Slot
            var appName: String?
        }
    }

    /// Builds the full menu from a snapshot. `binding` supplies each
    /// slot's live label so custom bindings show and disabled slots
    /// render without a combo.
    static func items(
        snapshot: Snapshot, binding: (Slot) -> HotkeyBinding
    ) -> [Item] {
        var items: [Item] = []

        // 1. Status: warnings if any, else notice + layout/count. The
        // count line doubles as the empty state: "0 tiled" reads as a
        // status, so no separate "No tiled windows" row that would
        // contradict an undo notice above it.
        if !snapshot.warnings.isEmpty {
            for warning in snapshot.warnings {
                items.append(Item(title: warning, isEnabled: false))
            }
        } else if snapshot.isTrusted {
            if let notice = snapshot.notice {
                items.append(Item(title: notice, isEnabled: false))
            }
            items.append(Item(
                title: "Layout: \(snapshot.layoutTitle) · \(snapshot.tiledWindows.count) tiled",
                isEnabled: false))
        }
        items.append(.separator())

        // 2. Act + 3. Manage.
        if snapshot.isTrusted {
            var tileChildren: [Item] = [Item(title: "Quarters", isEnabled: false, isHeader: true)]
            for slot in Slot.allCases where slot.layout == .quarters {
                tileChildren.append(tileItem(slot, binding))
            }
            tileChildren.append(.separator())
            // Sixths sub-groups mirror the thirds/two-thirds naming in
            // Settings: 11 flat items exceed working memory at the moment
            // of action, so chunk them into corners, thirds, two-thirds.
            tileChildren.append(Item(title: "Sixths \u{2014} Corners", isEnabled: false, isHeader: true))
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
            items.append(Item(title: "Tile Focused Window", children: tileChildren))
            items.append(Item(
                title: MenuText.expandItemTitle(label: HotkeyService.expandBinding.label),
                action: .toggleExpand))
            items.append(.separator())

            // Empty state needs no row — the status line already
            // reports "0 tiled".
            if !snapshot.tiledWindows.isEmpty {
                for window in snapshot.tiledWindows {
                    items.append(windowItem(window, binding))
                }
                items.append(.separator())
                if snapshot.canUndoSwitch {
                    items.append(Item(
                        title: MenuText.undoSwitchTitle(evictedCount: snapshot.evictedCount),
                        keyEquivalent: "z",
                        action: .undoSwitch))
                }
                items.append(Item(
                    title: MenuText.untileAllTitle(count: snapshot.tiledWindows.count),
                    action: .untileAll))
                items.append(Item(title: "Reset Dividers", action: .resetDividers))
            }
        } else {
            items.append(Item(title: "Waiting for Accessibility permission…", isEnabled: false))
            items.append(Item(title: "Open System Settings", action: .openAccessibilitySettings))
        }

        // 4. App.
        items.append(.separator())
        items.append(Item(title: "tiled Guide", action: .showGuide))
        items.append(Item(title: "Settings…", keyEquivalent: ",", action: .showSettings))
        items.append(Item(title: "Quit tiled", keyEquivalent: "q", action: .quit))
        return items
    }

    /// One clickable equivalent per global hotkey: the shortcut stays in
    /// the title text, since firing both would tile-then-untile.
    private static func tileItem(
        _ slot: Slot, _ binding: (Slot) -> HotkeyBinding
    ) -> Item {
        Item(
            title: MenuText.tileItemTitle(slot: slot, label: binding(slot).label),
            action: .tileSlot(slot))
    }

    /// One row of the tiled-windows list: a submenu wearing the window's
    /// back. The row itself doesn't act (no click-focus surprise); the
    /// submenu leads with the distinctive action so opening it pays off.
    private static func windowItem(
        _ window: Snapshot.TiledWindow, _ binding: (Slot) -> HotkeyBinding
    ) -> Item {
        Item(
            title: MenuText.windowLine(
                slot: window.slot, appName: window.appName,
                label: binding(window.slot).label),
            children: [
                Item(title: "Untile This Window", action: .untileWindow(window.id)),
                Item(title: "Focus \(window.appName ?? "Window")", action: .focusWindow(window.id)),
                Item(title: "Tile Focused Window Here", action: .tileHere(window.slot)),
            ])
    }
}
