import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let gateway = LiveWindowGateway()
    private lazy var controller = TilingController(
        gateway: gateway, observeMouseUp: TilingController.observeLeftMouseUp)
    private let hotkeyStore = HotkeyStore()
    private var hotkeys: HotkeyService?
    private var permissionTimer: Timer?
    private let settings = AppSettings()
    private var settingsController: SettingsWindowController?
    /// The launch permission explainer. Closed automatically by the
    /// permission poll the moment trust arrives.
    private var permissionWindowController: PermissionWindowController?
    private var menuOpen = false
    /// Snapshot the current status menu was built from. Diffed on every
    /// refresh so the menu is rebuilt only when something it reads moved.
    private var lastMenuSnapshot: MenuModel.Snapshot?
    /// What the status icon currently depicts (layout plus fill), so it
    /// redraws when windows come and go within one layout, not just when
    /// the layout itself flips 2×2 ↔ 3×2.
    private var lastIconSnapshot: StatusIcon.Snapshot?
    /// App activation moves focus, and focus picks the display the status
    /// icon depicts and the window the menu rows describe. The
    /// controller's change callback only runs for tiling actions, so
    /// without this the menu bar can keep describing the app the user
    /// just left until the next tile.
    private var activationObserver: NSObjectProtocol?

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        controller.onChange = { [weak self] in self?.refreshMenu() }
        controller.onFocusedSpaceChange = { [weak self] in self?.refreshFocusedDisplay() }
        controller.onFeedback = { [weak self] feedback in
            DispatchQueue.main.async { self?.signalFeedback(feedback) }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refreshMenu() }
        if !settings.hideMenuBarIcon {
            setupStatusItem()
        }

        if gateway.isTrusted {
            start()
        } else {
            // Register with TCC first (no dialog): without this call the
            // app may not appear in System Settings' list at all, and
            // the button would open a pane that can't grant anything.
            gateway.registerAccessibilityInterest()
            // The product's own explainer with one explicit button,
            // never the bare system prompt: the request arrives with the
            // reason attached, and granting is a deliberate click.
            showPermissionWindow()
            pollForPermission()
        }
        refreshMenu()
        // First run: land on Welcome so the one demonstrated combo plus
        // lit geometry teaches before the 17-row Shortcuts tab does.
        let firstRun = !settings.didDismissWelcome
        if firstRun {
            // Trusted path: present immediately. Permission-waiting path:
            // present on grant (see start(afterPermissionWait)).
            if gateway.isTrusted {
                showSettings(selecting: .welcome)
            }
        } else if settings.hideMenuBarIcon {
            // Hidden-icon recovery: with no status item there is no other
            // way back in, so a fresh launch opens Settings automatically.
            showSettings(nil)
        }
    }

    // Quitting leaves windows where they are. The manager must not
    // rearrange the user's workspace on the way out.

    // MARK: Permission

    /// Keyboard equivalents for the accessory app: LSUIElement apps have
    /// no visible menu bar, but NSApp.mainMenu key equivalents work
    /// whenever the app is active: without this, ⌘Q/⌘W are dead while
    /// Settings has focus (the status item's Quit only applies while
    /// that menu is open).
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Tiled",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        // HIG: Settings belongs in the app menu. The status menu keeps its
        // own Settings… row for the icon-first path; this row makes ⌘, work
        // whenever the app is active, not only with the status menu open.
        let settingsItem = appMenu.addItem(
            withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Tiled", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Tiled", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func showPermissionWindow() {
        let controller = PermissionWindowController()
        controller.onOpenSettings = { [weak self] in
            self?.openAccessibilitySettings(nil)
        }
        permissionWindowController = controller
        controller.show()
    }

    private func start(afterPermissionWait: Bool = false) {
        permissionTimer?.invalidate()
        permissionTimer = nil
        // Trust arrived (or was already there): the explainer's job is
        // done and it must not linger over the working app.
        permissionWindowController?.close()
        permissionWindowController = nil
        let service = HotkeyService(store: hotkeyStore)
        // One entry point for every global hotkey, slot or app action:
        // the switch is exhaustive, so a new action can never be
        // registered and then silently dropped here.
        service.handler = { [weak self] action in
            guard let self else { return }
            switch action {
            case .slot(let slot): controller.handle(slot: slot)
            case .expand: controller.handleExpandToggle()
            case .evict: controller.handleEvict()
            case .settings: self.showSettings(nil)
            case .undo: self.performUndoSwitch()
            case .resetSplitters: controller.resetDividers()
            }
        }
        hotkeys = service
        // Focus moving to another window can change which display drives
        // the glyph with no tiling action at all. The gateway re-targets
        // as apps activate; this subscribes now that AX is trusted.
        controller.observeFocus()
        refreshMenu()
        // Permission-grant teaching moment: the user waited at the
        // highest-friction step with no picture of the product, so open
        // Welcome once instead of leaving them at the menu.
        if afterPermissionWait, !settings.didDismissWelcome {
            showSettings(selecting: .welcome)
        } else {
            // An already-open Settings window must re-probe now: its
            // permission rows are only refreshed on show() otherwise.
            settingsController?.permissionStateDidChange()
        }
    }

    private func pollForPermission() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if gateway.isTrusted {
                self.start(afterPermissionWait: true)
            }
            self.refreshMenu()
        }
    }

    // MARK: Status item / menu

    private func setupStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let snapshot = iconSnapshot()
        item.button?.image = Self.statusIcon(snapshot)
        lastIconSnapshot = snapshot
        item.menu = menu()
        statusItem = item
    }

    /// One immutable pass over the state the icon reads: the active
    /// layout plus which icon cells are covered. The focused canvas
    /// (display plus Mission Control Space) is resolved once and both
    /// reads scope to it, so focus moving between the two lookups can
    /// never mix two canvases' geometry and occupancy. Expanded
    /// windows keep their slot (an expanded window still owns its tile),
    /// so they still light it. The focused canvas drives the glyph, so
    /// the icon depicts the layout the next hotkey acts on, whether the
    /// user got there by focusing another display or swiping Spaces.
    private func iconSnapshot() -> StatusIcon.Snapshot {
        Self.iconSnapshot(
            canvasKey: { controller.focusedTilingSpace },
            canvas: { controller.canvas(for: $0) },
            displayName: { controller.displayName(for: $0) })
    }

    /// The icon half of a refresh pass that already resolved its one canvas
    /// key: the glyph is built from that same key, so the menu and the icon
    /// can never describe different canvases when focus moves mid-pass.
    private func iconSnapshot(space: TilingSpaceKey) -> StatusIcon.Snapshot {
        Self.iconSnapshot(
            canvasKey: { space },
            canvas: { controller.canvas(for: $0) },
            displayName: { controller.displayName(for: $0) })
    }

    /// Builds one icon pass from a single resolved canvas key. The key is
    /// read exactly once, here, and both the occupancy map and the spoken
    /// display name derive from it, so a focus move landing mid-pass can
    /// never pair one canvas's glyph with another canvas's name. The three
    /// lookups are parameters so a test can count the reads without a live
    /// controller.
    static func iconSnapshot(
        canvasKey: () -> TilingSpaceKey,
        canvas: (TilingSpaceKey) -> TilingSpace,
        displayName: (TilingSpaceKey) -> String?
    ) -> StatusIcon.Snapshot {
        let key = canvasKey()
        let focused = canvas(key)
        return StatusIcon.snapshot(
            layout: focused.state.activeLayout,
            occupants: focused.state.occupants,
            displayName: displayName(key))
    }

    /// The menu-bar glyph states the product's core idea twice over: the
    /// current layout's geometry, and which of its slots are occupied. The
    /// stock square.grid.2x2 symbol can't express the quarters/sixths
    /// duality and goes stale on a layout switch, so draw a small template
    /// grid (2×2 for quarters, 3×2 for sixths) with each cell solid only
    /// while a tiled window actually covers that spot, dimmed solid otherwise.
    /// An empty space reads as an empty frame; a full one reads solid.
    private static func statusIcon(_ snapshot: StatusIcon.Snapshot) -> NSImage {
        let cells = StatusIcon.cells(for: snapshot.layout)
        let columns = snapshot.layout == .quarters ? 2 : 3
        // One shared canvas for both layouts: with a variable-length
        // status item, per-layout widths would shove neighboring icons
        // sideways on every layout switch.
        let size = NSSize(width: 22, height: 16)
        let filled = Set(snapshot.filled)
        let image = NSImage(size: size, flipped: false) { _ in
            let margin: CGFloat = 1.5
            let gap: CGFloat = 1
            let rowCount = 2
            let cellW = (size.width - margin * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let cellH = (size.height - margin * 2 - gap) / CGFloat(rowCount)
            NSColor.black.setFill()
            // One rounded frame subdivided: only each corner cell's outer
            // corner rounds (the top-left cell's top-left corner, and so
            // on); every inner edge stays square. Middle-column cells in
            // sixths touch no outer corner and stay fully square.
            let cornerRadius: CGFloat = 2.5
            for (index, cell) in cells.enumerated() {
                let col = index % columns
                let row = index / columns
                let x = margin + CGFloat(col) * (cellW + gap)
                let y = margin + CGFloat(1 - row) * (cellH + gap)
                let rect = NSRect(x: x, y: y, width: cellW, height: cellH)
                var corners: Set<IconCorner> = []
                if col == 0, row == 0 { corners.insert(.topLeft) }
                if col == columns - 1, row == 0 { corners.insert(.topRight) }
                if col == 0, row == rowCount - 1 { corners.insert(.bottomLeft) }
                if col == columns - 1, row == rowCount - 1 { corners.insert(.bottomRight) }
                if filled.contains(cell) {
                    NSColor.black.setFill()
                    Self.cellPath(
                        rect: rect, roundedCorners: corners, radius: cornerRadius
                    ).fill()
                } else {
                    // Idle cells render as dimmed solids, not hollow
                    // outlines: a template image carries alpha only, so
                    // reduced-opacity black composites as grey against the
                    // menu bar. Same rect as an occupied cell, so the grid
                    // never shifts weight between states.
                    NSColor.black.withAlphaComponent(0.35).setFill()
                    Self.cellPath(
                        rect: rect, roundedCorners: corners, radius: cornerRadius
                    ).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = statusIconDescription(snapshot)
        return image
    }

    /// Which outer corner(s) of a status-icon cell round. Inner edges
    /// always stay square so the grid reads as one subdivided frame.
    enum IconCorner: Hashable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Cell outline with only the given outer corners rounded. A zero
    /// radius (or no corners) is a plain rect.
    ///
    /// The arcs sweep clockwise (the path walks clockwise): the two-arg
    /// `appendArc` overload defaults to the counter-clockwise sweep, which
    /// balloons into the cell and punches a circular bite out of every
    /// rounded corner.
    static func cellPath(
        rect: NSRect, roundedCorners: Set<IconCorner>, radius: CGFloat
    ) -> NSBezierPath {
        guard radius > 0, !roundedCorners.isEmpty else {
            return NSBezierPath(rect: rect)
        }
        let minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        let path = NSBezierPath()
        // Start just past the top-left corner and walk clockwise.
        if roundedCorners.contains(.topLeft) {
            path.move(to: NSPoint(x: minX + radius, y: maxY))
        } else {
            path.move(to: NSPoint(x: minX, y: maxY))
        }
        if roundedCorners.contains(.topRight) {
            path.line(to: NSPoint(x: maxX - radius, y: maxY))
            path.appendArc(
                withCenter: NSPoint(x: maxX - radius, y: maxY - radius),
                radius: radius, startAngle: 90, endAngle: 0, clockwise: true)
        } else {
            path.line(to: NSPoint(x: maxX, y: maxY))
        }
        if roundedCorners.contains(.bottomRight) {
            path.line(to: NSPoint(x: maxX, y: minY + radius))
            path.appendArc(
                withCenter: NSPoint(x: maxX - radius, y: minY + radius),
                radius: radius, startAngle: 0, endAngle: 270, clockwise: true)
        } else {
            path.line(to: NSPoint(x: maxX, y: minY))
        }
        if roundedCorners.contains(.bottomLeft) {
            path.line(to: NSPoint(x: minX + radius, y: minY))
            path.appendArc(
                withCenter: NSPoint(x: minX + radius, y: minY + radius),
                radius: radius, startAngle: 270, endAngle: 180, clockwise: true)
        } else {
            path.line(to: NSPoint(x: minX, y: minY))
        }
        if roundedCorners.contains(.topLeft) {
            path.line(to: NSPoint(x: minX, y: maxY - radius))
            path.appendArc(
                withCenter: NSPoint(x: minX + radius, y: maxY - radius),
                radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
        } else {
            path.line(to: NSPoint(x: minX, y: maxY))
        }
        path.close()
        return path
    }

    /// VoiceOver line for the occupancy map: layout plus how many windows
    /// are tiled, so the state isn't sight-only.
    private static func statusIconDescription(_ snapshot: StatusIcon.Snapshot) -> String {
        StatusIcon.accessibilityDescription(snapshot)
    }

    /// Renders a snapshot on the status button. Whether to redraw is the
    /// refresh plan's decision; this only draws. Called from `refreshMenu`
    /// (every state change) and from `menuNeedsUpdate` as the menu opens.
    private func drawStatusIcon(_ snapshot: StatusIcon.Snapshot) {
        guard let button = statusItem?.button else { return }
        button.image = Self.statusIcon(snapshot)
        lastIconSnapshot = snapshot
    }

    /// Focus moved between windows, displays, or Mission Control Spaces
    /// with no tiling action: redraw only the glyph. The menu aggregates
    /// every canvas and is rebuilt from a fresh snapshot when it opens,
    /// so there is nothing to push here; rebuilding it from an AX
    /// callback would be churn. An open menu defers, exactly like
    /// `refreshPlan`, and `menuDidClose` catches up.
    private func refreshFocusedDisplay() {
        guard !menuOpen, statusItem != nil else { return }
        let icon = iconSnapshot()
        guard lastIconSnapshot != icon || statusItem?.button?.image == nil else { return }
        drawStatusIcon(icon)
    }

    /// Toggles the menu-bar icon live when the Settings checkbox changes.
    private func setIconHidden(_ hidden: Bool) {
        if hidden {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        } else {
            setupStatusItem()
        }
    }

    /// What one refresh pass must do.
    ///
    /// Extracted pure because the two halves are independent, and the
    /// hazard is in the ordering: the status icon reads focus-scoped state
    /// (the focused display's occupancy) that the menu snapshot
    /// deliberately aggregates across every display, so a focus move can
    /// change the glyph while leaving the menu snapshot equal. The glyph
    /// must therefore drive its own redraw, never ride the menu diff. An
    /// icon change alone never justifies rebuilding the menu, and an open
    /// menu defers both: rebuilding mid-open flickers or dismisses it, and
    /// the close handler runs a fresh pass.
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

    private func refreshMenu(force: Bool = false) {
        // Destructive outcomes stay in the menu (notice + undo row), not
        // on screen: tiling feedback never pops a panel over the workspace.
        // Rebuilding the menu while it's open flickers or dismisses it;
        // the close handler picks up whatever changed meanwhile.
        //
        // Diff before building: drag-resize fires change callbacks every
        // runloop tick, and the permission poll fires once a second, but
        // the menu only cares about state, warnings, and window rows.
        // Building an NSMenu with submenus on every tick is pure waste.
        // One canvas key for the whole pass: the menu and the glyph are two
        // views of the same canvas, so a focus move landing between building
        // them can never leave them describing different canvases.
        let space = controller.focusedTilingSpace
        let snapshot = menuSnapshot(space: space)
        let icon = iconSnapshot(space: space)
        let plan = Self.refreshPlan(
            menuChanged: force || snapshot != lastMenuSnapshot || statusItem?.menu == nil,
            iconChanged: lastIconSnapshot != icon || statusItem?.button?.image == nil,
            menuOpen: menuOpen)
        if plan.redrawIcon { drawStatusIcon(icon) }
        guard plan.rebuildMenu else { return }
        lastMenuSnapshot = snapshot
        statusItem?.menu = menu(from: snapshot)
    }

    private func menu() -> NSMenu {
        let snapshot = menuSnapshot()
        lastMenuSnapshot = snapshot
        return menu(from: snapshot)
    }

    private func menu(from snapshot: MenuModel.Snapshot) -> NSMenu {
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
        for model in MenuModel.items(snapshot: snapshot, binding: { hotkeyStore.binding(for: $0) }) {
            menu.addItem(makeItem(model))
        }
    }

    /// One immutable pass over the app state the menu reads.
    /// Fresh destructive-outcome notices (eviction, layout switch) live
    /// in the menu beside the undo row that reverses them: the canvas's
    /// `notice` clears on every new action, so the menu carries each
    /// outcome until the next one replaces it.
    private func menuSnapshot() -> MenuModel.Snapshot {
        menuSnapshot(space: controller.focusedTilingSpace)
    }

    /// Menu snapshot from an already-resolved canvas key. A refresh pass
    /// resolves the key once and hands the same one to the menu and the
    /// icon, so the two halves can never describe different canvases.
    private func menuSnapshot(space: TilingSpaceKey) -> MenuModel.Snapshot {
        // One canvas read for the whole pass: every unscoped field
        // describes the focused canvas's own surface.
        let canvas = controller.canvas(for: space)
        let warnings = activeWarnings
        let rows = controller.tiledWindowsInfo
        let presentation = Self.monitorPresentation(
            rows: rows,
            layoutForScreen: { screen in
                // A row with no display tag describes the focused canvas
                // (headless/legacy); tagged rows read their own screen.
                if let screen {
                    return controller.canvas(for: screen).state.activeLayout
                }
                return canvas.state.activeLayout
            })
        return MenuModel.Snapshot(
            isTrusted: controller.isTrusted,
            warnings: warnings.hotkeyWarnings,
            notice: canvas.notice,
            layoutTitle: presentation.statusLine,
            activeLayout: canvas.state.activeLayout,
            tileError: warnings.tileError,
            hasHotkeyWarnings: hasHotkeyWarnings,
            hasSplitterBackup: canvas.hasSplitterBackup,
            hasFocusedWindow: gateway.isTrusted && gateway.focusedWindow() != nil,
            expandedSlot: controller.expandedFocusedSlot,
            tiledWindows: presentation.tiledWindows,
            canUndoDisplacement: !canvas.undoStack.isEmpty,
            evictedCount: canvas.evictedCount,
            untileCount: controller.focusedTiledWindowsInfo.count,
            monitorSections: presentation.sections)
    }

    /// Pure multi-monitor grouping for the manage list, extracted from
    /// menuSnapshot so tests pin it without a live controller. The
    /// grouping key is the display's `ScreenID` (identity); the display
    /// name is used only for the header text. One section per display
    /// that has windows, in controller order. Two same-named monitors
    /// stay separate because identity, not the name, groups them. Single
    /// monitor (or no screen tags) renders the flat legacy list.
    static func monitorPresentation(
        rows: [TilingController.TiledWindowInfo],
        layoutForScreen: (ScreenID?) -> LayoutKind
    ) -> (sections: [MenuModel.Snapshot.MonitorSection],
          tiledWindows: [MenuModel.Snapshot.TiledWindow],
          statusLine: String) {
        let grouped = Dictionary(grouping: rows, by: \.screen)
        let sections: [MenuModel.Snapshot.MonitorSection]
        let orderedRows: [MenuModel.Snapshot.TiledWindow]
        if grouped.count > 1 || (grouped.count == 1 && grouped.keys.first != nil) {
            var built: [MenuModel.Snapshot.MonitorSection] = []
            var ordered: [MenuModel.Snapshot.TiledWindow] = []
            for row in rows {
                if !built.contains(where: { $0.key == row.screen }) {
                    let count = rows.filter { $0.screen == row.screen }.count
                    let layout = layoutForScreen(row.screen)
                    let display = row.screenName ?? "Display"
                    let noun = count == 1 ? "1 tiled" : "\(count) tiled"
                    built.append(.init(
                        title: "\(display) · \(layout.title) · \(noun)",
                        key: row.screen))
                }
                ordered.append(.init(
                    id: row.id, slot: row.slot, appName: row.appName,
                    screen: row.screen))
            }
            sections = built
            orderedRows = ordered
        } else {
            sections = []
            orderedRows = rows.map {
                .init(id: $0.id, slot: $0.slot, appName: $0.appName)
            }
        }
        // Status line: one monitor reads as before; two read per
        // display ("Display 1 · Quarters · 2 tiled + Display 2 · Sixths
        // · 1 tiled") so the compass never hides a background monitor.
        let statusLine: String
        if sections.isEmpty {
            statusLine = "Layout: \(layoutForScreen(nil).title) · \(rows.count) tiled"
        } else {
            statusLine = sections.map(\.title).joined(separator: " + ")
        }
        return (sections, orderedRows, statusLine)
    }

    /// Pure Action → selector wiring, extracted from makeItem so a table
    /// test pins every case: a selector typo or cast mistake here
    /// degrades to a silent no-op row, which no UI test would catch.
    static func menuWiring(
        for action: MenuModel.Action
    ) -> (selector: Selector, representedObject: Any?, targetsSelf: Bool) {
        switch action {
        case .tileSlot(let slot):
            return (#selector(AppDelegate.tileSlot(_:)), slot.rawValue, true)
        case .switchToQuarters:
            return (#selector(AppDelegate.switchToQuarters(_:)), nil, true)
        case .switchToSixths:
            return (#selector(AppDelegate.switchToSixths(_:)), nil, true)
        case .toggleExpand:
            return (#selector(AppDelegate.expandFocusedWindow(_:)), nil, true)
        case .evictFocusedWindow:
            return (#selector(AppDelegate.evictFocusedWindow(_:)), nil, true)
        case .untileWindow(let id):
            return (#selector(AppDelegate.untileTiledWindow(_:)), id, true)
        case .focusWindow(let id):
            return (#selector(AppDelegate.focusTiledWindow(_:)), id, true)
        case .tileHere(let slot):
            return (#selector(AppDelegate.tileFocusedHere(_:)), slot.rawValue, true)
        case .undoSwitch:
            return (#selector(AppDelegate.undoSwitch(_:)), nil, true)
        case .untileAll:
            return (#selector(AppDelegate.untileAll(_:)), nil, true)
        case .resetDividers:
            return (#selector(AppDelegate.resetDividers(_:)), nil, true)
        case .showGuide:
            return (#selector(AppDelegate.showGuide(_:)), nil, true)
        case .showSettings:
            return (#selector(AppDelegate.showSettings(_:)), nil, true)
        case .openAccessibilitySettings:
            return (#selector(AppDelegate.openAccessibilitySettings(_:)), nil, true)
        case .openShortcuts:
            return (#selector(AppDelegate.openShortcuts(_:)), nil, true)
        case .quit:
            // Quit rides the responder chain like the app menu's Quit;
            // everything else targets this delegate.
            return (#selector(NSApplication.terminate(_:)), nil, false)
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
            let wiring = Self.menuWiring(for: action)
            item.action = wiring.selector
            if let represented = wiring.representedObject {
                item.representedObject = represented
            }
            if wiring.targetsSelf {
                item.target = self
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

    /// Undo title names what returns: the evicted windows.
    private var undoDisplacementTitle: String {
        let canvas = controller.canvas(for: controller.focusedTilingSpace)
        return MenuText.undoDisplacementTitle(
            evictedCount: canvas.evictedCount)
    }

    /// Bulk-action title names the consequence: restoring every window.
    private var untileAllTitle: String {
        MenuText.untileAllTitle(count: controller.tiledWindowsInfo.count)
    }

    /// User-visible problems, split by kind: the last tiling failure
    /// (a refusal narrative, rendered verbatim) versus hotkey
    /// registration losses (counted into the summary row with their
    /// Open Shortcuts door). Mixing the two misdiagnosed refusals as
    /// shortcut problems: the menu's headline row pointed users at the
    /// wrong subsystem. Failures are reported here, never only logged.
    /// Labels come from the store so they reflect custom bindings.
    private var activeWarnings: (tileError: String?, hotkeyWarnings: [String]) {
        let hotkeyWarnings = (hotkeys?.failedActions ?? []).map { action in
            MenuText.hotkeyFailureWarning(
                label: hotkeyStore.binding(for: action).label,
                title: action.title,
                recovery: action.registrationRecovery)
        }
        return (tileError: controller.canvas(for: controller.focusedTilingSpace).error,
                hotkeyWarnings: hotkeyWarnings)
    }

    // MARK: Actions

    @objc private func openShortcuts(_ sender: Any?) {
        showSettings(selecting: .shortcuts)
    }

    @objc private func showSettings(_ sender: Any?) {
        showSettings(selecting: nil)
    }

    /// Opens Settings, optionally landing on a specific tab. The Welcome
    /// tab is selectable here (first run, permission grant, hidden-icon
    /// recovery); the no-arg path keeps the General default.
    private func showSettings(selecting tab: SettingsWindowController.Tab?) {
        ensureSettingsController()
        if let tab {
            settingsController?.show(selecting: tab)
        } else {
            settingsController?.show()
        }
    }

    /// Lazily builds the Settings controller once (shared by Settings
    /// and Guide entry points so Help never flashes General first).
    private func ensureSettingsController() {
        if settingsController == nil {
            let controller = SettingsWindowController(
                settings: settings, hotkeyStore: hotkeyStore)
            controller.onHideIconChange = { [weak self] hidden in
                self?.setIconHidden(hidden)
            }
            controller.isTrustedProvider = { [weak self] in self?.gateway.isTrusted ?? false }
            controller.onOpenAccessibilitySettings = { [weak self] in
                self?.openAccessibilitySettings(nil)
            }
            controller.onHotkeysChange = { [weak self] in
                self?.hotkeys?.reload()
                // Binding labels live in menu titles but not in the
                // snapshot, so a label-only change would diff clean.
                // Force past the diff on any binding edit.
                self?.refreshMenu(force: true)
            }
            // The Shortcuts tab surfaces cross-app registration failures
            // beside the recorder that accepted the combo, not only in
            // the status menu.
            controller.failedActionsProvider = { [weak self] in
                self?.hotkeys?.failedActions ?? []
            }
            // General's hide-icon confirm names a recovery combo only when
            // it is actually registered: never a dead promise while
            // removing the last visible handle to the app.
            controller.isSettingsHotkeyRegisteredProvider = { [weak self] in
                guard let hotkeys = self?.hotkeys else { return false }
                return !hotkeys.failedActions.contains(.settings)
            }
            settingsController = controller
        }
    }

    /// True when at least one global hotkey lost registration: the menu
    /// then pairs its warnings with an "Open Shortcuts…" action row.
    private var hasHotkeyWarnings: Bool {
        !(hotkeys?.failedActions ?? []).isEmpty
    }

    @objc private func showGuide(_ sender: Any?) {
        ensureSettingsController()
        settingsController?.showWelcomeAgain()
    }

    @objc private func tileSlot(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let slot = Slot(rawValue: raw)
        else { return }
        controller.handle(slot: slot)
    }

    /// Collapsed layout-switch rows: honest about focus. With a focused
    /// window this tiles into the destination's top-left, performing the
    /// switch through the engine's mutual-exclusion rule (identical to
    /// pressing that layout's own hotkey: same undo notice, same
    /// reversibility). With no focused window the row is disabled, not a
    /// no-op: a menu row must not promise a switch it cannot perform.
    @objc private func switchToQuarters(_ sender: Any?) {
        controller.handle(slot: .topLeft)
    }

    @objc private func switchToSixths(_ sender: Any?) {
        controller.handle(slot: .sixthTopLeft)
    }

    @objc private func expandFocusedWindow(_ sender: Any?) {
        controller.handleExpandToggle()
    }

    @objc private func evictFocusedWindow(_ sender: Any?) {
        controller.handleEvict()
        announce("Focused window evicted.", fallback: "Focused window evicted.")
    }

    @objc private func untileAll(_ sender: NSMenuItem) {
        // No modal: Untile All restores every window to its pre-tile
        // frame, and the eviction-undo snapshot behind it makes the
        // whole operation one ⌃⌥⇧⌘Z from reversal. The sticky notice +
        // undo row ARE the safety: a modal here would tax the daily
        // user for protection the design already provides structurally.
        controller.untileAll()
        announce("All tiled windows restored.", fallback: "All tiled windows restored.")
    }

    @objc private func resetDividers(_ sender: NSMenuItem) {
        // Two actions in sequence, like Reset Shortcuts: a reversible
        // reset first (fractions parked), then a restore of the backup.
        if controller.canvas(for: controller.focusedTilingSpace).hasSplitterBackup {
            controller.restoreSplitters()
            announce(
                "Splitters restored to their pre-reset positions.",
                fallback: "Splitters restored to their pre-reset positions.")
            return
        }
        guard confirmBulkAction(
            message: "Reset every splitter to even splits?",
            detail: "Custom drag positions in both layouts are replaced. "
                + "Your current positions are kept; use Restore Previous Splitters to get them back.",
            button: "Reset Splitters")
        else { return }
        controller.resetDividers()
        announce("Splitters reset to even splits.", fallback: "Splitters reset to even splits.")
    }

    /// Confirms a destructive bulk action with the consequence in the
    /// message and on the button itself: never a bare OK.
    private func confirmBulkAction(message: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// VoiceOver announcement for actions whose feedback is otherwise
    /// visual-only (menu titles, shakes, status lines). Posts against the
    /// status-item button when present; the Settings window when the icon
    /// is hidden (the one configuration where the menu isn't a glance
    /// away and spoken feedback matters most); logs only when neither
    /// exists. The state change is never visual-only, and never
    /// announcement-less, either.
    private func announce(_ text: String, fallback noticeText: String? = nil) {
        let element: Any? =
            statusItem?.button ?? settingsController?.window ?? NSApp
        if let element {
            NSAccessibility.post(
                element: element,
                notification: .announcementRequested,
                userInfo: [.announcement: text,
                           .priority: NSAccessibilityPriorityLevel.high.rawValue])
        } else if let noticeText {
            NSLog("Tiled: %@", noticeText)
        }
    }

    /// Subtle confirmation for ineffective hotkey presses: the safe no-op
    /// stays silent in state and menu, but the hand gets a haptic and
    /// VoiceOver users get an announcement: pressing harder is never the
    /// answer, and now the app says so. No on-screen panel: tiling
    /// feedback stays out of the way; the menu carries the details.
    private func signalFeedback(_ feedback: TilingController.Feedback) {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic, performanceTime: .default)
        let text: String
        let noticeFallback: String?
        switch feedback {
        case .noFocusedWindow:
            text = MenuText.noFocusedWindowAnnouncement()
            noticeFallback = "No focused window."
        case .nothingToUndo:
            text = MenuText.nothingToUndoAnnouncement()
            noticeFallback = "Nothing to undo."
        case .alreadyTiled(let slot):
            text = MenuText.alreadyTiledAnnouncement(slot: slot)
            noticeFallback = "Already in \(SlotPresentation.title(of: slot))."
        case .refused(let name):
            text = MenuText.refusedAnnouncement(windowName: name)
            noticeFallback = controller.canvas(for: controller.focusedTilingSpace).error
            announce(text, fallback: noticeFallback)
            refreshMenu()
            return
        case .expandRefused(let name):
            text = MenuText.expandRefusedAnnouncement(windowName: name)
            noticeFallback = controller.canvas(for: controller.focusedTilingSpace).error
            announce(text, fallback: noticeFallback)
            refreshMenu()
            return
        case .nothingToEvict:
            text = MenuText.nothingToEvictAnnouncement()
            noticeFallback = "Window isn't tiled."
        }
        announce(text, fallback: noticeFallback)
        refreshMenu()
    }

    @objc private func undoSwitch(_ sender: NSMenuItem) {
        performUndoSwitch()
    }

    /// The global ⌃⌥⇧⌘Z combo and the menu's ⌘Z row share one path: the
    /// switch is triggered by global hotkeys while other apps are
    /// frontmost, so the undo works from anywhere, not only with the
    /// status menu open.
    private func performUndoSwitch() {
        controller.undoLastDisplacement()
        announce("Evicted windows restored.", fallback: "Evicted windows restored.")
    }

    @objc private func untileTiledWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? WindowID else { return }
        let name = controller.tiledWindowsInfo.first { $0.id == id }?.appName
        controller.untile(window: id)
        announce("\(name ?? "Window") untiled.", fallback: "Window untiled.")
    }

    @objc private func focusTiledWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? WindowID else { return }
        controller.focus(window: id)
    }

    @objc private func tileFocusedHere(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let slot = Slot(rawValue: raw)
        else { return }
        controller.handle(slot: slot)
    }

    @objc private func openAccessibilitySettings(_ sender: Any?) {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
    }

    /// Refreshes the rows in place as the menu opens.
    ///
    /// Focus moves with no tiling action at all (click another window,
    /// swipe another Space), and the rows' enabled state, undo title, and
    /// status line all read the focused window; the icon reads the
    /// focused canvas. Nothing
    /// else fires on that transition, so the open is the last point where
    /// the menu can still be made to describe the window the user is
    /// looking at. Replacing `statusItem.menu` here would be too late —
    /// AppKit has already retained the menu it is about to show — so the
    /// same menu is emptied and refilled, which is what this delegate call
    /// is for (menuWillOpen explicitly must not restructure).
    ///
    /// Deliberately not gated on `menuOpen`: AppKit does not document
    /// whether this runs before or after menuWillOpen, and the update must
    /// not depend on that order.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        let snapshot = menuSnapshot()
        populate(menu, from: snapshot)
        lastMenuSnapshot = snapshot
        let icon = iconSnapshot()
        if lastIconSnapshot != icon { drawStatusIcon(icon) }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        refreshMenu()
    }
}
