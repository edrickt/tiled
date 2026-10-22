import AppKit

/// One refresh pass's whole presentation model: the menu rows and the
/// status glyph, both derived from the same resolved canvas key. Equatable
/// so the presenter can diff one value instead of two drifting ones.
struct MenuBarSnapshot: Equatable {
    var menu: MenuModel.Snapshot
    var icon: StatusIcon.Snapshot
}

/// Owns the status item and its menu: the last snapshot rendered, the
/// open-menu deferral, NSMenu construction, and show/hide. The delegate
/// keeps launch, permissions, the settings/hotkey lifecycle, action
/// selectors, and receipt presentation; this type reads the controller and
/// store but never the AX gateway, so a refresh pass resolves one canvas
/// key and derives both views from it.
final class MenuBarPresenter: NSObject, NSMenuDelegate {
    /// What one refresh pass must do. Extracted pure because the two halves
    /// are independent, and the hazard is in the ordering: the status icon
    /// reads focus-scoped state that the menu snapshot deliberately
    /// aggregates across every display, so a focus move can change the glyph
    /// while leaving the menu snapshot equal. The glyph must therefore drive
    /// its own redraw, never ride the menu diff. An icon change alone never
    /// justifies rebuilding the menu, and an open menu defers both:
    /// rebuilding mid-open flickers or dismisses it, and the close handler
    /// runs a fresh pass.
    struct RefreshPlan: Equatable {
        let redrawIcon: Bool
        let rebuildMenu: Bool
    }

    static func refreshPlan(
        menuChanged: Bool, iconChanged: Bool, menuOpen: Bool
    ) -> RefreshPlan {
        guard !menuOpen else { return RefreshPlan(redrawIcon: false, rebuildMenu: false) }
        return RefreshPlan(redrawIcon: iconChanged, rebuildMenu: menuChanged)
    }

    private let controller: TilingController
    private let hotkeyStore: HotkeyStore
    private let hotkeyService: () -> HotkeyService?
    /// The object carrying the menu's action selectors (the AppDelegate).
    private weak var actionTarget: AnyObject?
    /// The menu's sticky notice for one scoped read. The presenter owns the
    /// snapshot assembly; the delegate still owns the receipt that feeds it.
    private let noticeProvider: (MenuReads) -> String?
    private var statusItem: NSStatusItem?
    /// The last snapshot actually rendered. The menu and icon halves are
    /// compared separately so an icon-only change never rebuilds the menu.
    private var lastSnapshot: MenuBarSnapshot?
    private(set) var menuOpen = false

    init(
        controller: TilingController,
        hotkeyStore: HotkeyStore,
        hotkeyService: @escaping () -> HotkeyService?,
        actionTarget: AnyObject,
        noticeProvider: @escaping (MenuReads) -> String?
    ) {
        self.controller = controller
        self.hotkeyStore = hotkeyStore
        self.hotkeyService = hotkeyService
        self.actionTarget = actionTarget
        self.noticeProvider = noticeProvider
    }

    /// The status button, when the icon is visible: the anchor for the
    /// delegate's VoiceOver announcements.
    var statusButton: NSStatusBarButton? { statusItem?.button }

    var isVisible: Bool { statusItem != nil }

    /// Toggles the menu-bar icon live when the Settings checkbox changes.
    func setIconHidden(_ hidden: Bool) {
        if hidden {
            hideIcon()
        } else {
            showIcon()
        }
    }

    func showIcon() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let snapshot = snapshot(for: controller.focusedTilingSpace)
        item.button?.image = StatusIconRenderer.image(for: snapshot.icon)
        item.menu = makeMenu(from: snapshot.menu)
        statusItem = item
        lastSnapshot = snapshot
    }

    func hideIcon() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    /// One refresh pass over the focused canvas: resolves the key once and
    /// builds both views from it, so a display or focus change landing
    /// between the menu and the glyph can never leave them describing
    /// different canvases.
    func refresh() {
        let snapshot = snapshot(for: controller.focusedTilingSpace)
        // Destructive outcomes stay in the menu (notice + undo row), not
        // on screen: tiling feedback never pops a panel over the workspace.
        // Rebuilding the menu while it's open flickers or dismisses it;
        // the close handler picks up whatever changed meanwhile.
        //
        // Diff before building: drag-resize fires change callbacks every
        // runloop tick, and the permission poll fires once a second, but
        // the menu only cares about state, warnings, labels, and rows.
        // Building an NSMenu with submenus on every tick is pure waste.
        let plan = Self.refreshPlan(
            menuChanged: lastSnapshot?.menu != snapshot.menu || statusItem?.menu == nil,
            iconChanged:
                lastSnapshot?.icon != snapshot.icon || statusItem?.button?.image == nil,
            menuOpen: menuOpen)
        if plan.redrawIcon { draw(snapshot.icon) }
        if plan.rebuildMenu { statusItem?.menu = makeMenu(from: snapshot.menu) }
        // An open menu defers both halves; the close handler runs a fresh
        // pass, so the deferred snapshot must not become the baseline.
        if !menuOpen { lastSnapshot = snapshot }
    }

    /// Focus moved between windows, displays, or Mission Control Spaces
    /// with no tiling action: redraw only the glyph. The menu aggregates
    /// every canvas and is rebuilt from a fresh snapshot when it opens, so
    /// there is nothing to push here; rebuilding it from an AX callback
    /// would be churn. An open menu defers, exactly like `refresh`, and
    /// `menuDidClose` catches up.
    func refreshFocusedDisplay() {
        guard !menuOpen, statusItem != nil else { return }
        let snapshot = snapshot(for: controller.focusedTilingSpace)
        guard lastSnapshot?.icon != snapshot.icon
            || statusItem?.button?.image == nil
        else { return }
        draw(snapshot.icon)
        lastSnapshot?.icon = snapshot.icon
    }

    /// Builds one presentation snapshot from an already-resolved canvas
    /// key. The key is a direct parameter, not a resolver the caller might
    /// call twice, so the menu and glyph cannot pair two canvases.
    func snapshot(for space: TilingSpaceKey) -> MenuBarSnapshot {
        let reads = MenuReads(
            space: space,
            controller: controller,
            failedActions: hotkeyService()?.failedActions ?? [],
            binding: { self.hotkeyStore.binding(for: $0) })
        return MenuBarSnapshot(
            menu: MenuModel.Snapshot(reads: reads, notice: noticeProvider(reads)),
            icon: Self.iconSnapshot(
                space: space,
                canvas: { self.controller.canvas(for: $0) },
                displayName: { self.controller.displayName(for: $0) }))
    }

    /// Builds one icon pass from an already-resolved canvas key. The key is
    /// a direct parameter, not a resolver the caller might call twice, and
    /// both the occupancy map and the spoken display name derive from that
    /// one key, so a focus move landing mid-pass can never pair one
    /// canvas's glyph with another canvas's name.
    static func iconSnapshot(
        space: TilingSpaceKey,
        canvas: (TilingSpaceKey) -> TilingSpace,
        displayName: (TilingSpaceKey) -> String?
    ) -> StatusIcon.Snapshot {
        let focused = canvas(space)
        return StatusIcon.snapshot(
            layout: focused.state.activeLayout,
            occupants: focused.state.occupants,
            displayName: displayName(space))
    }

    private func draw(_ icon: StatusIcon.Snapshot) {
        statusItem?.button?.image = StatusIconRenderer.image(for: icon)
    }

    private func makeMenu(from snapshot: MenuModel.Snapshot) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        populate(menu, from: snapshot)
        return menu
    }

    /// Fills an existing menu from a snapshot. Shared by the build path
    /// (a fresh NSMenu) and the open path (an in-place update), so the two
    /// can never render different rows.
    private func populate(_ menu: NSMenu, from snapshot: MenuModel.Snapshot) {
        menu.removeAllItems()
        for model in MenuModel.items(snapshot: snapshot) {
            menu.addItem(makeItem(model))
        }
    }

    /// Maps one model item onto NSMenuItem: selectors, represented
    /// objects, key equivalents, and submenus, recursively.
    private func makeItem(_ model: MenuModel.Item) -> NSMenuItem {
        if model.isSeparator { return .separator() }
        let item = NSMenuItem(
            title: model.title, action: nil, keyEquivalent: model.keyEquivalent)
        item.isEnabled = model.isEnabled
        if let reason = model.disabledReason, !model.isEnabled {
            item.toolTip = reason
            // Tooltips are hover-only: keyboard and VoiceOver users never
            // reach them. The reason is the whole point of the disabled
            // row ("the row never reads as broken"), so expose it where
            // assistive tech looks. Both channels, one string.
            item.setAccessibilityHelp(reason)
        }
        if let action = model.action {
            let wiring = AppDelegate.menuWiring(for: action)
            item.action = wiring.selector
            if let represented = wiring.representedObject {
                item.representedObject = represented
            }
            if wiring.targetsSelf {
                item.target = actionTarget
            }
        }
        if let children = model.children {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for child in children {
                submenu.addItem(makeItem(child))
            }
            item.submenu = submenu
        }
        return item
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
    }

    /// Refreshes the rows in place as the menu opens.
    ///
    /// Focus moves with no tiling action at all (click another window,
    /// swipe another Space), and the rows' enabled state, undo title, and
    /// status line all read the focused window; the icon reads the
    /// focused canvas. Nothing else fires on that transition, so the open
    /// is the last point where the menu can still be made to describe the
    /// window the user is looking at. Replacing `statusItem.menu` here
    /// would be too late — AppKit has already retained the menu it is
    /// about to show — so the same menu is emptied and refilled, which is
    /// what this delegate call is for (menuWillOpen explicitly must not
    /// restructure).
    ///
    /// Deliberately not gated on `menuOpen`: AppKit does not document
    /// whether this runs before or after menuWillOpen, and the update must
    /// not depend on that order.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        // One canvas key for the whole pass, exactly as `refresh`:
        // resolving it once and handing it to both the menu and the glyph
        // is what keeps them from describing different canvases when a
        // display or focus change lands mid-pass.
        let snapshot = snapshot(for: controller.focusedTilingSpace)
        populate(menu, from: snapshot.menu)
        if lastSnapshot?.icon != snapshot.icon || statusItem?.button?.image == nil {
            draw(snapshot.icon)
        }
        lastSnapshot = snapshot
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        refresh()
    }
}
