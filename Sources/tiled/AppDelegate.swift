import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let gateway = LiveWindowGateway()
    private lazy var controller = TilingController(
        gateway: gateway,
        observeMouseUp: TilingController.observeLeftMouseUp,
        observeMouseDown: TilingController.observeLeftMouseDown,
        observeMouseDragged: TilingController.observeLeftMouseDragged)
    /// The global-hotkey observer: forwards routes to the live controller
    /// and delegate. Lazy because it captures both.
    private lazy var hotkeyPerformer = AppHotkeyPerformer(
        controller: controller,
        present: { [weak self] in self?.present($0) },
        openSettings: { [weak self] in self?.showSettings(nil) },
        performUndo: { [weak self] in self?.performUndoSwitch() })
    private let hotkeyStore = HotkeyStore()
    private var hotkeys: HotkeyService?
    private var permissionTimer: Timer?
    private let settings = AppSettings()
    private var settingsController: SettingsWindowController?
    /// The launch permission explainer. Closed automatically by the
    /// permission poll the moment trust arrives.
    private var permissionWindowController: PermissionWindowController?
    /// The status item and its one presentation model. The delegate keeps
    /// lifecycle, actions, and receipt presentation; the presenter owns the
    /// snapshot, diff, menu construction, and show/hide.
    private lazy var menuBar = MenuBarPresenter(
        controller: controller,
        hotkeyStore: hotkeyStore,
        hotkeyService: { [weak self] in self?.hotkeys },
        actionTarget: self)
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
        controller.onChange = { [weak self] in
            self?.menuBar.stateDidChange()
        }
        controller.onFocusedSpaceChange = { [weak self] in
            self?.menuBar.focusDidChange()
        }
        controller.onLateReceipt = { [weak self] receipt in
            self?.present(receipt)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.menuBar.refresh() }
        if !settings.hideMenuBarIcon {
            menuBar.showIcon()
        }

        // One plan owns the launch branches: start versus permission wait,
        // first-run Welcome, and hidden-icon recovery. The trusted path
        // presents Welcome immediately; the permission-waiting path
        // presents it on grant (see start(afterPermissionWait)).
        let plan = AppLaunchPlan.make(
            isTrusted: gateway.isTrusted,
            didDismissWelcome: settings.didDismissWelcome,
            hideMenuBarIcon: settings.hideMenuBarIcon)
        plan.execute(
            startNow: { start() },
            waitForPermission: {
                // Register with TCC first (no dialog): without this call
                // the app may not appear in System Settings' list at all,
                // and the button would open a pane that can't grant
                // anything.
                gateway.registerAccessibilityInterest()
                // The product's own explainer with one explicit button,
                // never the bare system prompt: the request arrives with
                // the reason attached, and granting is a deliberate click.
                showPermissionWindow()
                pollForPermission()
            })
        menuBar.refresh()
        // First run: land on Welcome so the one demonstrated combo plus
        // lit geometry teaches before the 17-row Shortcuts tab does.
        if plan.showsWelcome {
            showSettings(selecting: .welcome)
        }
        if plan.showsSettings {
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
        // Retire the old quarter hotkey namespace once, before the service
        // reads the store: the shared keys inherit the sixths storage names,
        // so only the six quarter overrides, section parks, and reset entries
        // are deleted. One-way and idempotent; no marker or version key.
        hotkeyStore.removeRetiredSlotBindings()
        ShortcutPark().removeRetiredSlotParks()
        let service = HotkeyService(store: hotkeyStore)
        // One entry point for every global hotkey, slot or app action. The
        // Carbon router parses and hops; this closure owns the action route,
        // and holds the delegate weakly so the service never keeps the app
        // alive.
        service.setHandler { [weak self] action in
            guard let self else { return }
            HotkeyActionRouter(performer: self.hotkeyPerformer).dispatch(action)
        }
        hotkeys = service
        // The inert-key receipt names the live switch combo, and only when
        // that combo is actually registered; otherwise it teaches the menu
        // row. Wired here because the provider needs the running service.
        controller.switchLayoutLabelProvider = { [weak self] in
            guard let self, let hotkeys = self.hotkeys else { return nil }
            return self.hotkeyStore.registeredLabel(
                for: .switchLayout, failedActions: hotkeys.failedActions)
        }
        // Focus moving to another window can change which display drives
        // the glyph with no tiling action at all. The gateway re-targets
        // as apps activate; this subscribes now that AX is trusted.
        controller.observeFocus()
        menuBar.refresh()
        switch AppStartCompletion.make(
            afterPermissionWait: afterPermissionWait,
            didDismissWelcome: settings.didDismissWelcome
        ) {
        case .showWelcome:
            // Permission-grant teaching moment: the user waited at the
            // highest-friction step with no picture of the product, so
            // open Welcome once instead of leaving them at the menu.
            showSettings(selecting: .welcome)
        case .refreshPermissionRows:
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
            self.menuBar.refresh()
        }
    }

    /// Pure Action → selector wiring, extracted from makeItem so a table
    /// test pins every case: a selector typo or cast mistake here
    /// degrades to a silent no-op row, which no UI test would catch.
    static func menuWiring(
        for action: MenuModel.Action
    ) -> (selector: Selector, representedObject: Any?, targetsSelf: Bool) {
        switch action {
        case .tileSlot(let key):
            return (#selector(AppDelegate.tileSlot(_:)), key.rawValue, true)
        case .switchLayout(let target):
            return (#selector(AppDelegate.switchLayout(_:)), target.rawValue, true)
        case .toggleExpand:
            return (#selector(AppDelegate.expandFocusedWindow(_:)), nil, true)
        case .evictFocusedWindow:
            return (#selector(AppDelegate.evictFocusedWindow(_:)), nil, true)
        case .untileWindow(let id):
            return (#selector(AppDelegate.untileTiledWindow(_:)), id, true)
        case .focusWindow(let id):
            return (#selector(AppDelegate.focusTiledWindow(_:)), id, true)
        case .tileHere(let key):
            return (#selector(AppDelegate.tileFocusedHere(_:)), key.rawValue, true)
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
                self?.menuBar.setIconHidden(hidden)
            }
            controller.isTrustedProvider = { [weak self] in self?.gateway.isTrusted ?? false }
            controller.onOpenAccessibilitySettings = { [weak self] in
                self?.openAccessibilitySettings(nil)
            }
            controller.onHotkeysChange = { [weak self] in
                self?.hotkeys?.reload()
                // The labels ride in the snapshot, so a label-only remap
                // is an ordinary diff and rebuilds without a force path.
                self?.menuBar.refresh()
            }
            // The Shortcuts tab surfaces cross-app registration failures
            // beside the recorder that accepted the combo, not only in
            // the status menu.
            controller.failedActionsProvider = { [weak self] in
                self?.hotkeys?.failedActions ?? []
            }
            // General's hide-icon confirm names the user's live Settings
            // binding, and only when it is registered; without a running
            // hotkey service it names no combo at all.
            controller.settingsHotkeyLabelProvider = { [weak self] in
                guard let self, let hotkeys = self.hotkeys else { return nil }
                return self.hotkeyStore.registeredLabel(
                    for: .settings, failedActions: hotkeys.failedActions)
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
              let key = SlotKey(rawValue: raw)
        else { return }
        present(controller.handle(slotKey: key))
    }

    /// The explicit switch row: the destination was captured when the
    /// menu was built (`.other` of the focused canvas then), so the click
    /// means the layout the title promised.
    @objc private func switchLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let target = LayoutKind(rawValue: raw)
        else { return }
        present(controller.handleSwitchLayout(to: target))
    }

    @objc private func expandFocusedWindow(_ sender: Any?) {
        present(controller.handleExpandToggle())
    }

    @objc private func evictFocusedWindow(_ sender: Any?) {
        present(controller.handleEvict())
    }

    @objc private func untileAll(_ sender: NSMenuItem) {
        // No modal: Untile All restores every window to its pre-tile
        // frame, and the eviction-undo snapshot behind it makes the
        // whole operation one ⌃⌥⇧⌘Z from reversal. The sticky notice +
        // undo row ARE the safety: a modal here would tax the daily
        // user for protection the design already provides structurally.
        present(controller.untileAll())
    }

    @objc private func resetDividers(_ sender: NSMenuItem) {
        // A parked backup turns the row into its own undo: restore it
        // without another confirmation. A fresh reset needs the
        // confirmation, then the same controller action the hotkey uses.
        if !controller.canvas(for: controller.focusedTilingSpace).hasSplitterBackup {
            guard confirmBulkAction(
                message: "Reset every splitter to even splits?",
                detail: "Custom drag positions in both layouts are replaced. "
                    + "Your current positions are kept; use Restore Previous Splitters to get them back.",
                button: "Reset Splitters")
            else { return }
        }
        present(controller.resetOrRestoreSplitters())
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

    /// Presents one action's user-visible truth: the controller has already
    /// decided whether the action performed, which canvas owns it, what the
    /// menu carries, and the one sentence to speak. The delegate never
    /// reconstructs success from the keypress, so an empty undo or a refused
    /// restore cannot be announced as a win and then contradicted. One
    /// haptic point: a receipt with something to say gets the current
    /// haptic; a silent success stays silent.
    private func present(_ receipt: ActionReceipt) {
        menuBar.present(receipt)
        guard let announcement = receipt.announcement else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic, performanceTime: .default)
        announce(announcement)
    }

    /// VoiceOver announcement for actions whose outcome is otherwise
    /// visual-only (menu titles, status lines, the glyph). Posts against
    /// the status-item button when present; the Settings window when the
    /// icon is hidden (the one configuration where the menu isn't a glance
    /// away and the spoken outcome matters most). The app is always the
    /// last anchor, so there is no logging-only fallback.
    private func announce(_ text: String) {
        let element: Any =
            menuBar.statusButton ?? settingsController?.window ?? NSApp as Any
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [.announcement: text,
                       .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    @objc private func undoSwitch(_ sender: NSMenuItem) {
        performUndoSwitch()
    }

    /// The global ⌃⌥⇧⌘Z combo and the menu's ⌘Z row share one path: the
    /// switch is triggered by global hotkeys while other apps are
    /// frontmost, so the undo works from anywhere, not only with the
    /// status menu open. Both present the controller's receipt: a refused
    /// chapter speaks its error, never a success sentence.
    private func performUndoSwitch() {
        present(controller.undoAction())
    }

    @objc private func untileTiledWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? WindowID else { return }
        present(controller.untile(window: id))
    }

    @objc private func focusTiledWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? WindowID else { return }
        controller.focus(window: id)
    }

    @objc private func tileFocusedHere(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let key = SlotKey(rawValue: raw)
        else { return }
        present(controller.handle(slotKey: key))
    }

    @objc private func openAccessibilitySettings(_ sender: Any?) {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
    }
}
