import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let gateway = LiveWindowGateway()
    private lazy var controller = TilingController(gateway: gateway)
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
    /// What the status icon currently depicts — layout plus fill — so it
    /// redraws when windows come and go within one layout, not just when
    /// the layout itself flips 2×2 ↔ 3×2.
    private var lastIconSnapshot: StatusIcon.Snapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        controller.onChange = { [weak self] in self?.refreshMenu() }
        controller.onFeedback = { [weak self] feedback in
            DispatchQueue.main.async { self?.signalFeedback(feedback) }
        }
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
    /// whenever the app is active — without this, ⌘Q/⌘W are dead while
    /// Settings has focus (the status item's Quit only applies while
    /// that menu is open).
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About tiled",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        // HIG: Settings belongs in the app menu. The status menu keeps its
        // own Settings… row for the icon-first path; this row makes ⌘, work
        // whenever the app is active, not only with the status menu open.
        let settingsItem = appMenu.addItem(
            withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide tiled", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit tiled", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        service.handler = { [weak self] slot in self?.controller.handle(slot: slot) }
        service.expandHandler = { [weak self] in self?.controller.handleExpandToggle() }
        service.settingsHandler = { [weak self] in self?.showSettings(nil) }
        service.undoHandler = { [weak self] in self?.performUndoSwitch() }
        hotkeys = service
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
    /// layout plus which icon cells are covered. Occupancy keyed by slot —
    /// the pure input `StatusIcon Snapshot` needs — derives from the
    /// controller's window rows; expanded windows keep their slot (an
    /// expanded window still owns its tile), so they still light it.
    private func iconSnapshot() -> StatusIcon.Snapshot {
        var occupants: [Slot: WindowID] = [:]
        for info in controller.tiledWindowsInfo {
            occupants[info.slot] = info.id
        }
        return StatusIcon.snapshot(layout: controller.activeLayout, occupants: occupants)
    }

    /// The menu-bar glyph states the product's core idea twice over: the
    /// current layout's geometry, and which of its slots are occupied. The
    /// stock square.grid.2x2 symbol can't express the quarters/sixths
    /// duality and goes stale on a layout switch, so draw a small template
    /// grid — 2×2 for quarters, 3×2 for sixths — with each cell solid only
    /// while a tiled window actually covers that spot, hollow otherwise.
    /// An empty space reads as an empty frame; a full one reads solid.
    private static func statusIcon(_ snapshot: StatusIcon.Snapshot) -> NSImage {
        let cells = StatusIcon.cells(for: snapshot.layout)
        let columns = snapshot.layout == .quarters ? 2 : 3
        let size = NSSize(width: 16, height: 12)
        let filled = Set(snapshot.filled)
        let image = NSImage(size: size, flipped: false) { _ in
            let margin: CGFloat = 1
            let gap: CGFloat = 1.5
            let rows: CGFloat = 2
            let cellW = (size.width - margin * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let cellH = (size.height - margin * 2 - gap) / rows
            NSColor.black.setFill()
            NSColor.black.setStroke()
            for (index, cell) in cells.enumerated() {
                let col = index % columns
                let row = index / columns
                let x = margin + CGFloat(col) * (cellW + gap)
                let y = margin + CGFloat(1 - row) * (cellH + gap)
                let rect = NSRect(x: x, y: y, width: cellW, height: cellH)
                let path = NSBezierPath(
                    roundedRect: rect,
                    xRadius: 1.5, yRadius: 1.5
                )
                if filled.contains(cell) {
                    path.fill()
                } else {
                    // A stroke centers on its path, so an unstroked-size
                    // rect would bleed half the line width outside on every
                    // side and read larger than its filled siblings. Inset
                    // by half the width (and shrink the radius to match) so
                    // the outer edge lands exactly on the filled rect.
                    let lineWidth: CGFloat = 1
                    let outline = NSBezierPath(
                        roundedRect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                        xRadius: 1, yRadius: 1
                    )
                    outline.lineWidth = lineWidth
                    outline.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = statusIconDescription(snapshot)
        return image
    }

    /// VoiceOver line for the occupancy map: layout plus how many of its
    /// slots are taken, so the state isn't sight-only.
    private static func statusIconDescription(_ snapshot: StatusIcon.Snapshot) -> String {
        let total = StatusIcon.cells(for: snapshot.layout).count
        return "tiled \(snapshot.layout.title) layout, "
            + "\(snapshot.filled.count) of \(total) slots occupied"
    }

    /// Redraws the status icon when its snapshot moved — a layout switch
    /// or a window tiled/untiled within one layout. Called from
    /// refreshMenu, which fires on every state change.
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let snapshot = iconSnapshot()
        guard lastIconSnapshot != snapshot || button.image == nil else { return }
        button.image = Self.statusIcon(snapshot)
        lastIconSnapshot = snapshot
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

    private func refreshMenu(force: Bool = false) {
        // Destructive outcomes stay in the menu (notice + undo row), not
        // on screen: tiling feedback never pops a panel over the workspace.
        // Rebuilding the menu while it's open flickers or dismisses it;
        // the menuDidClose rebuild picks up whatever changed meanwhile.
        guard !menuOpen else { return }
        // Diff before building: drag-resize fires change callbacks every
        // runloop tick, and the permission poll fires once a second, but
        // the menu only cares about state, warnings, and window rows.
        // Building an NSMenu with submenus on every tick is pure waste.
        let snapshot = menuSnapshot()
        if !force, snapshot == lastMenuSnapshot, statusItem?.menu != nil { return }
        lastMenuSnapshot = snapshot
        statusItem?.menu = menu(from: snapshot)
        updateStatusIcon()
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
        for model in MenuModel.items(snapshot: snapshot, binding: { hotkeyStore.binding(for: $0) }) {
            menu.addItem(makeItem(model))
        }
        return menu
    }

    /// One immutable pass over the app state the menu reads.
    /// Fresh destructive-outcome notices (eviction, layout switch) live
    /// in the menu beside the undo row that reverses them. `lastNotice`
    /// clears on every new action; the menu carries each outcome until
    /// the next one replaces it.
    private func menuSnapshot() -> MenuModel.Snapshot {
        let warnings = activeWarnings
        return MenuModel.Snapshot(
            isTrusted: controller.isTrusted,
            warnings: warnings.hotkeyWarnings,
            notice: controller.lastNotice,
            layoutTitle: controller.activeLayout.title,
            activeLayout: controller.activeLayout,
            tileError: warnings.tileError,
            hasHotkeyWarnings: hasHotkeyWarnings,
            hasSplitterBackup: controller.hasSplitterBackup,
            hasFocusedWindow: gateway.isTrusted && gateway.focusedWindow() != nil,
            expandedSlot: controller.expandedFocusedSlot,
            tiledWindows: controller.tiledWindowsInfo.map {
                .init(id: $0.id, slot: $0.slot, appName: $0.appName)
            },
            canUndoDisplacement: controller.canUndoDisplacement,
            evictedCount: controller.evictedCount)
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
            switch action {
            case .tileSlot(let slot):
                item.action = #selector(tileSlot(_:))
                item.representedObject = slot.rawValue
            case .switchToQuarters:
                item.action = #selector(switchToQuarters(_:))
            case .switchToSixths:
                item.action = #selector(switchToSixths(_:))
            case .toggleExpand:
                item.action = #selector(expandFocusedWindow(_:))
            case .untileWindow(let id):
                item.action = #selector(untileTiledWindow(_:))
                item.representedObject = id
            case .focusWindow(let id):
                item.action = #selector(focusTiledWindow(_:))
                item.representedObject = id
            case .tileHere(let slot):
                item.action = #selector(tileFocusedHere(_:))
                item.representedObject = slot.rawValue
            case .undoSwitch:
                item.action = #selector(undoSwitch(_:))
            case .untileAll:
                item.action = #selector(untileAll(_:))
            case .resetDividers:
                item.action = #selector(resetDividers(_:))
            case .showGuide:
                item.action = #selector(showGuide(_:))
            case .showSettings:
                item.action = #selector(showSettings(_:))
            case .openAccessibilitySettings:
                item.action = #selector(openAccessibilitySettings(_:))
            case .openShortcuts:
                item.action = #selector(openShortcuts(_:))
            case .quit:
                item.action = #selector(NSApplication.terminate(_:))
            }
            // Quit rides the responder chain like the app menu's Quit;
            // everything else targets this delegate.
            if action != .quit {
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
        MenuText.undoDisplacementTitle(evictedCount: controller.evictedCount)
    }

    /// Bulk-action title names the consequence: restoring every window.
    private var untileAllTitle: String {
        MenuText.untileAllTitle(count: controller.tiledWindowsInfo.count)
    }

    /// User-visible problems, split by kind: the last tiling failure
    /// (a refusal narrative, rendered verbatim) versus hotkey
    /// registration losses (counted into the summary row with their
    /// Open Shortcuts door). Mixing the two misdiagnosed refusals as
    /// shortcut problems — the menu's headline row pointed users at the
    /// wrong subsystem. Failures are reported here, never only logged.
    /// Labels come from the store so they reflect custom bindings.
    private var activeWarnings: (tileError: String?, hotkeyWarnings: [String]) {
        var hotkeyWarnings: [String] = []
        if hotkeys?.settingsHotkeyFailed == true {
            hotkeyWarnings.append(MenuText.settingsHotkeyWarning())
        }
        if hotkeys?.undoHotkeyFailed == true {
            hotkeyWarnings.append(MenuText.undoHotkeyWarning())
        }
        if hotkeys?.expandHotkeyFailed == true {
            hotkeyWarnings.append(MenuText.expandHotkeyWarning())
        }
        for slot in hotkeys?.failedSlots ?? [] {
            let label = hotkeyStore.binding(for: slot).label
            hotkeyWarnings.append(MenuText.hotkeyFailureWarning(label: label, slot: slot))
        }
        return (tileError: controller.lastTileError, hotkeyWarnings: hotkeyWarnings)
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
    /// recovery) — the no-arg path keeps the General default.
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
            controller.failedSlotsProvider = { [weak self] in
                self?.hotkeys?.failedSlots ?? []
            }
            // General's hide-icon confirm names a recovery combo only when
            // it is actually registered — never a dead promise while
            // removing the last visible handle to the app.
            controller.isSettingsHotkeyRegisteredProvider = { [weak self] in
                guard let hotkeys = self?.hotkeys else { return false }
                return !hotkeys.settingsHotkeyFailed
            }
            settingsController = controller
        }
    }

    /// True when at least one global hotkey lost registration: the menu
    /// then pairs its warnings with an "Open Shortcuts…" action row.
    private var hasHotkeyWarnings: Bool {
        hotkeys?.settingsHotkeyFailed == true
            || hotkeys?.expandHotkeyFailed == true
            || hotkeys?.undoHotkeyFailed == true
            || !(hotkeys?.failedSlots ?? []).isEmpty
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
    /// pressing that layout's own hotkey — same undo notice, same
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

    @objc private func untileAll(_ sender: NSMenuItem) {
        // No modal: Untile All restores every window to its pre-tile
        // frame, and the eviction-undo snapshot behind it makes the
        // whole operation one ⌃⌥⇧⌘Z from reversal. The sticky notice +
        // undo row ARE the safety — a modal here would tax the daily
        // user for protection the design already provides structurally.
        controller.untileAll()
        announce("All tiled windows restored.", fallback: "All tiled windows restored.")
    }

    @objc private func resetDividers(_ sender: NSMenuItem) {
        // Two actions in sequence, like Reset Shortcuts: a reversible
        // reset first (fractions parked), then a restore of the backup.
        if controller.hasSplitterBackup {
            controller.restoreSplitters()
            announce(
                "Splitters restored to their pre-reset positions.",
                fallback: "Splitters restored to their pre-reset positions.")
            return
        }
        guard confirmBulkAction(
            message: "Reset every splitter to even splits?",
            detail: "Custom drag positions in both layouts are replaced. "
                + "Your current positions are kept — use Restore Previous Splitters to get them back.",
            button: "Reset Splitters")
        else { return }
        controller.resetDividers()
        announce("Splitters reset to even splits.", fallback: "Splitters reset to even splits.")
    }

    /// Confirms a destructive bulk action with the consequence in the
    /// message and on the button itself — never a bare OK.
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
    /// exists. The state change is never visual-only — and never
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
            NSLog("tiled: %@", noticeText)
        }
    }

    /// Subtle confirmation for ineffective hotkey presses: the safe no-op
    /// stays silent in state and menu, but the hand gets a haptic and
    /// VoiceOver users get an announcement — pressing harder is never the
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
            noticeFallback = controller.lastTileError
            announce(text, fallback: noticeFallback)
            refreshMenu()
            return
        case .expandRefused(let name):
            text = MenuText.expandRefusedAnnouncement(windowName: name)
            noticeFallback = controller.lastTileError
            announce(text, fallback: noticeFallback)
            refreshMenu()
            return
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

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        refreshMenu()
    }
}
