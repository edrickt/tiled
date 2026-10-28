import AppKit

/// One refresh pass's whole presentation model: the menu rows and the
/// status glyph. The halves describe different canvases by design — the
/// menu follows keyboard focus, the glyph follows the cursor — and each
/// half derives its canvas, notice, occupancy, and display name from its
/// own key alone. Equatable so the presenter can diff one value instead
/// of two drifting ones.
struct MenuBarSnapshot: Equatable {
    var menu: MenuModel.Snapshot
    var icon: StatusIcon.Snapshot
}

/// Owns the status item and its menu: the last snapshot rendered, the
/// open-menu deferral, NSMenu construction, and show/hide. The delegate
/// keeps launch, permissions, the settings/hotkey lifecycle, action
/// selectors, and receipt presentation; this type reads the controller
/// and store but never the AX gateway, so a refresh pass resolves the
/// focused key for the menu and the cursor key for the glyph, each
/// exactly once, and derives each view from its own key.
final class MenuBarPresenter: NSObject, NSMenuDelegate {
    /// What one refresh pass must do. Extracted pure because the two
    /// halves are independent, and the hazard is in the ordering: the
    /// icon follows the cursor and the menu follows focus — different
    /// canvases by design — so a cursor move can change the glyph while
    /// leaving the menu snapshot equal. The glyph must therefore drive
    /// its own redraw, never ride the menu diff. An icon change alone
    /// never justifies rebuilding the menu, and an open menu defers
    /// both: rebuilding mid-open flickers or dismisses it, and the
    /// close handler runs a fresh pass.
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
    /// The latest receipt's overlay, bounded to the focus and generation it
    /// was presented against.
    private var notices = NoticePresentation()
    private var statusItem: NSStatusItem?
    /// The last snapshot actually rendered. The menu and icon halves are
    /// compared separately so an icon-only change never rebuilds the menu.
    private var lastSnapshot: MenuBarSnapshot?
    private(set) var menuOpen = false

    init(
        controller: TilingController,
        hotkeyStore: HotkeyStore,
        hotkeyService: @escaping () -> HotkeyService?,
        actionTarget: AnyObject
    ) {
        self.controller = controller
        self.hotkeyStore = hotkeyStore
        self.hotkeyService = hotkeyService
        self.actionTarget = actionTarget
    }

    /// A controller change: the receipt a later action presents is bounded
    /// to the generation after this change, and the menu and glyph refresh.
    func stateDidChange() {
        notices.stateDidChange()
        refresh()
    }

    /// Focus moved: supersede any background receipt. The menu rebuilds
    /// from a fresh snapshot when it opens, and the glyph follows the
    /// cursor, so nothing else refreshes here.
    func focusDidChange() {
        notices.clear()
    }

    /// Presents one action's receipt: the menu carries its notice even when
    /// the action touched a background canvas, then the snapshot refreshes.
    /// The delegate still owns the haptic and the one spoken sentence.
    func present(_ receipt: ActionReceipt) {
        notices.present(receipt, focusedSpace: controller.focusedTilingSpace)
        refresh()
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
        // Seed the cursor display before the first draw: no mouse-move
        // event may have arrived yet, and the glyph must depict the
        // display the cursor is on from the start.
        controller.noteCursorFromMouseLocation()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let snapshot = snapshot(
            menu: controller.focusedTilingSpace,
            icon: controller.cursorTilingSpace)
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

    /// One refresh pass: resolves the focused key for the menu and the
    /// cursor key for the glyph, each exactly once, so a display, focus,
    /// or cursor change landing between the reads can never cross the
    /// halves' canvases.
    func refresh() {
        let snapshot = snapshot(
            menu: controller.focusedTilingSpace,
            icon: controller.cursorTilingSpace)
        // Destructive outcomes stay in the menu (notice + undo row), not
        // on screen: a tiling outcome never pops a panel over the workspace.
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

    /// The cursor moved to another display: redraw only the glyph, which
    /// follows the cursor. The menu follows focus and stays as it is.
    /// An open menu defers, exactly like `refresh`, and `menuDidClose`
    /// catches up.
    func refreshCursorDisplay() {
        guard !menuOpen, statusItem != nil else { return }
        let snapshot = snapshot(
            menu: controller.focusedTilingSpace,
            icon: controller.cursorTilingSpace)
        guard lastSnapshot?.icon != snapshot.icon
            || statusItem?.button?.image == nil
        else { return }
        draw(snapshot.icon)
        lastSnapshot?.icon = snapshot.icon
    }

    /// Builds one presentation snapshot from two already-resolved canvas
    /// keys. Both are direct parameters, not resolvers the caller might
    /// call twice: the menu half derives its canvas, notice, occupancy,
    /// and display name from `focus` alone, the icon half from `cursor`
    /// alone, so a focus or cursor move landing mid-pass can never pair
    /// one canvas's rows with another canvas's glyph.
    func snapshot(menu focus: TilingSpaceKey, icon cursor: TilingSpaceKey) -> MenuBarSnapshot {
        let reads = MenuReads(
            space: focus,
            controller: controller,
            failedActions: hotkeyService()?.failedActions ?? [],
            binding: { self.hotkeyStore.binding(for: $0) })
        return MenuBarSnapshot(
            menu: MenuModel.Snapshot(
                reads: reads,
                notice: notices.overlay(
                    canvasNotice: reads.canvas.notice,
                    focusedSpace: focus)),
            icon: Self.iconSnapshot(
                space: cursor,
                canvas: { self.controller.canvas(for: $0) },
                displayName: { self.controller.displayName(for: $0) }))
    }

    /// Builds one icon pass from an already-resolved canvas key. The key is
    /// a direct parameter, not a resolver the caller might call twice, and
    /// both the occupancy map and the spoken display name derive from that
    /// one key, so a cursor move landing mid-pass can never pair one
    /// canvas's glyph with another canvas's name.
    static func iconSnapshot(
        space: TilingSpaceKey,
        canvas: (TilingSpaceKey) -> TilingSpace,
        displayName: (TilingSpaceKey) -> String?
    ) -> StatusIcon.Snapshot {
        let focused = canvas(space)
        return StatusIcon.snapshot(
            layout: focused.state.layout,
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
    /// status line all read the focused window; the glyph reads the
    /// cursor's canvas. Nothing else fires on that transition, so the
    /// open is the last point where the menu can still be made to
    /// describe the window the user is looking at. Replacing
    /// `statusItem.menu` here would be too late — AppKit has already
    /// retained the menu it is about to show — so the same menu is
    /// emptied and refilled, which is what this delegate call is for
    /// (menuWillOpen explicitly must not restructure).
    ///
    /// Deliberately not gated on `menuOpen`: AppKit does not document
    /// whether this runs before or after menuWillOpen, and the update must
    /// not depend on that order.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        // Event delivery during menu tracking is not guaranteed to reach
        // the monitors, so seed the cursor display from the live mouse
        // location before resolving the glyph's key.
        controller.noteCursorFromMouseLocation()
        // One pair of canvas keys for the whole pass, exactly as
        // `refresh`: resolving each once and handing it to its own half
        // is what keeps the menu and the glyph from describing crossed
        // canvases when a display, focus, or cursor change lands mid-pass.
        let snapshot = snapshot(
            menu: controller.focusedTilingSpace,
            icon: controller.cursorTilingSpace)
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
