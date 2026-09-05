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
        item.button?.image = NSImage(
            systemSymbolName: "square.grid.2x2",
            accessibilityDescription: "tiled")
        item.menu = menu()
        statusItem = item
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
    private func menuSnapshot() -> MenuModel.Snapshot {
        MenuModel.Snapshot(
            isTrusted: controller.isTrusted,
            warnings: activeWarnings,
            notice: controller.lastNotice,
            layoutTitle: controller.activeLayout.title,
            tiledWindows: controller.tiledWindowsInfo.map {
                .init(id: $0.id, slot: $0.slot, appName: $0.appName)
            },
            canUndoSwitch: controller.canUndoSwitch,
            evictedCount: controller.evictedCount)
    }

    /// Maps one model item onto NSMenuItem: selectors, represented
    /// objects, key equivalents, and submenus, recursively.
    private func makeItem(_ model: MenuModel.Item) -> NSMenuItem {
        if model.isSeparator { return .separator() }
        let item = NSMenuItem(
            title: model.title, action: nil, keyEquivalent: model.keyEquivalent)
        item.isEnabled = model.isEnabled
        if let action = model.action {
            switch action {
            case .tileSlot(let slot):
                item.action = #selector(tileSlot(_:))
                item.representedObject = slot.rawValue
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
    private var undoSwitchTitle: String {
        MenuText.undoSwitchTitle(evictedCount: controller.evictedCount)
    }

    /// Bulk-action title names the consequence: restoring every window.
    private var untileAllTitle: String {
        MenuText.untileAllTitle(count: controller.tiledWindowsInfo.count)
    }

    /// User-visible problems: the last tiling failure, plus any hotkeys
    /// owned by another app. Failures are reported here, never only logged.
    /// Labels come from the store so they reflect custom bindings.
    private var activeWarnings: [String] {
        var warnings: [String] = []
        if let error = controller.lastTileError {
            warnings.append(error)
        }
        if hotkeys?.settingsHotkeyFailed == true {
            warnings.append(MenuText.settingsHotkeyWarning())
        }
        if hotkeys?.expandHotkeyFailed == true {
            warnings.append(MenuText.expandHotkeyWarning())
        }
        for slot in hotkeys?.failedSlots ?? [] {
            let label = hotkeyStore.binding(for: slot).label
            warnings.append(MenuText.hotkeyFailureWarning(label: label, slot: slot))
        }
        return warnings
    }

    // MARK: Actions

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
            settingsController = controller
        }
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

    @objc private func expandFocusedWindow(_ sender: Any?) {
        controller.handleExpandToggle()
    }

    @objc private func untileAll(_ sender: NSMenuItem) {
        guard confirmBulkAction(
            message: "Untile every tiled window?",
            detail: "Each window returns to where it was before tiling.",
            button: untileAllTitle)
        else { return }
        controller.untileAll()
        announce("All tiled windows restored.", fallback: "All tiled windows restored.")
    }

    @objc private func resetDividers(_ sender: NSMenuItem) {
        guard confirmBulkAction(
            message: "Reset every divider to even splits?",
            detail: "Custom drag positions in both layouts are lost.",
            button: "Reset Dividers")
        else { return }
        controller.resetDividers()
        announce("Dividers reset to even splits.", fallback: "Dividers reset to even splits.")
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
    /// status-item button when present (mainMenu is nil for LSUIElement
    /// agents); falls back to the alert fallback text via the notice line.
    private func announce(_ text: String, fallback noticeText: String? = nil) {
        if let button = statusItem?.button {
            NSAccessibility.post(
                element: button,
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
    /// answer, and now the app says so.
    private func signalFeedback(_ feedback: TilingController.Feedback) {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic, performanceTime: .default)
        switch feedback {
        case .noFocusedWindow:
            announce(
                MenuText.noFocusedWindowAnnouncement(),
                fallback: "No focused window.")
        case .alreadyTiled(let slot):
            announce(
                MenuText.alreadyTiledAnnouncement(slot: slot),
                fallback: "Already in \(SlotPresentation.title(of: slot)).")
        case .refused(let name):
            announce(
                MenuText.refusedAnnouncement(windowName: name),
                fallback: controller.lastTileError)
        case .expandRefused(let name):
            announce(
                MenuText.expandRefusedAnnouncement(windowName: name),
                fallback: controller.lastTileError)
        }
        refreshMenu()
    }

    @objc private func undoSwitch(_ sender: NSMenuItem) {
        controller.undoLayoutSwitch()
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
