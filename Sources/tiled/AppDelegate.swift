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
    private var menuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        controller.onChange = { [weak self] in self?.refreshMenu() }
        controller.onFeedback = { [weak self] feedback in
            DispatchQueue.main.async { self?.signalFeedback(feedback) }
        }
        if !settings.hideMenuBarIcon {
            setupStatusItem()
        }

        if gateway.promptIfUntrusted() {
            start()
        } else {
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
        appMenu.addItem(withTitle: "About tiled", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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

    private func start(afterPermissionWait: Bool = false) {
        permissionTimer?.invalidate()
        permissionTimer = nil
        let service = HotkeyService(store: hotkeyStore)
        service.handler = { [weak self] slot in self?.controller.handle(slot: slot) }
        service.settingsHandler = { [weak self] in self?.showSettings(nil) }
        hotkeys = service
        refreshMenu()
        // Permission-grant teaching moment: the user waited at the
        // highest-friction step with no picture of the product, so open
        // Welcome once instead of leaving them at the menu.
        if afterPermissionWait, !settings.didDismissWelcome {
            showSettings(selecting: .welcome)
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

    private func refreshMenu() {
        // Rebuilding the menu while it's open flickers or dismisses it;
        // the menuDidClose rebuild picks up whatever changed meanwhile.
        guard !menuOpen else { return }
        statusItem?.menu = menu()
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // 1. Status: notices and warnings if any, else layout + tiled count.
        let warnings = activeWarnings
        if !warnings.isEmpty {
            for warning in warnings {
                menu.addItem(disabledItem(warning))
            }
        } else if controller.isTrusted {
            if let notice = controller.lastNotice {
                menu.addItem(disabledItem(notice))
            }
            let count = controller.tiledWindowsInfo.count
            // The count line doubles as the empty state: "0 tiled" reads
            // as a status, so no separate "No tiled windows" row that
            // would contradict an undo notice above it.
            menu.addItem(disabledItem(
                "Layout: \(controller.activeLayout.title) · \(count) tiled"))
        }
        menu.addItem(.separator())

        if controller.isTrusted {
            // 2. Act: tile the focused window.
            let tile = NSMenuItem(title: "Tile Focused Window", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.addItem(disabledItem("Quarters"))
            for slot in Slot.allCases where slot.layout == .quarters {
                submenu.addItem(tileItem(for: slot))
            }
            submenu.addItem(.separator())
            // Sixths sub-groups mirror the thirds/two-thirds naming in
            // Settings: 11 flat items exceed working memory at the moment
            // of action, so chunk them into corners, thirds, two-thirds.
            submenu.addItem(disabledItem("Sixths \u{2014} Corners"))
            for slot in SlotPresentation.sixthsCorners {
                submenu.addItem(tileItem(for: slot))
            }
            submenu.addItem(disabledItem("Thirds"))
            for slot in SlotPresentation.sixthsThirds {
                submenu.addItem(tileItem(for: slot))
            }
            submenu.addItem(disabledItem("Two-Thirds"))
            for slot in SlotPresentation.sixthsTwoThirds {
                submenu.addItem(tileItem(for: slot))
            }
            tile.submenu = submenu
            menu.addItem(tile)
            menu.addItem(.separator())

            // 3. Manage: the tiled windows plus bulk actions. Empty state
            // needs no row — the status line already reports "0 tiled".
            let tiled = controller.tiledWindowsInfo
            if !tiled.isEmpty {
                for info in tiled {
                    menu.addItem(windowItem(for: info))
                }
                menu.addItem(.separator())
                if controller.canUndoSwitch {
                    let undo = NSMenuItem(
                        title: undoSwitchTitle,
                        action: #selector(undoSwitch(_:)), keyEquivalent: "z")
                    undo.target = self
                    menu.addItem(undo)
                }
                let untile = NSMenuItem(
                    title: untileAllTitle, action: #selector(untileAll(_:)), keyEquivalent: "")
                untile.target = self
                menu.addItem(untile)
                let reset = NSMenuItem(
                    title: "Reset Dividers", action: #selector(resetDividers(_:)),
                    keyEquivalent: "")
                reset.target = self
                menu.addItem(reset)
            }
        } else {
            let item = NSMenuItem(
                title: "Waiting for Accessibility permission…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            let settings = NSMenuItem(
                title: "Open System Settings", action: #selector(openAccessibilitySettings(_:)),
                keyEquivalent: "")
            settings.target = self
            menu.addItem(settings)
        }

        // 4. App.
        menu.addItem(.separator())
        let help = NSMenuItem(
            title: "tiled Guide", action: #selector(showGuide(_:)),
            keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(showSettings(_:)),
            keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quit = NSMenuItem(
            title: "Quit tiled", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    /// One row of the tiled-windows list: a submenu wearing the window's
    /// back. The row itself doesn't act (no click-focus surprise); the
    /// submenu leads with the distinctive action so opening it pays off.
    private func windowItem(for info: TilingController.TiledWindowInfo) -> NSMenuItem {
        let item = NSMenuItem(
            title: windowLine(for: info),
            action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let untile = NSMenuItem(
            title: "Untile This Window",
            action: #selector(untileTiledWindow(_:)), keyEquivalent: "")
        untile.target = self
        untile.representedObject = info.id
        submenu.addItem(untile)
        let focus = NSMenuItem(
            title: "Focus \(info.appName ?? "Window")",
            action: #selector(focusTiledWindow(_:)), keyEquivalent: "")
        focus.target = self
        focus.representedObject = info.id
        submenu.addItem(focus)
        let move = NSMenuItem(
            title: "Tile Focused Window Here",
            action: #selector(tileFocusedHere(_:)), keyEquivalent: "")
        move.target = self
        move.representedObject = info.slot.rawValue
        submenu.addItem(move)
        item.submenu = submenu
        return item
    }

    /// Undo title names what returns: the evicted windows.
    private var undoSwitchTitle: String {
        let count = controller.evictedCount
        return count == 1 ? "Restore 1 Evicted Window" : "Restore \(count) Evicted Windows"
    }

    /// Bulk-action title names the consequence: restoring every window.
    private var untileAllTitle: String {
        let count = controller.tiledWindowsInfo.count
        return count == 1 ? "Untile 1 Window" : "Untile All \(count) Windows"
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
            warnings.append(
                "The Settings shortcut (\u{2303}\u{2325}\u{21E7}\u{2318},) is already used " +
                "by another app — relaunch tiled to get back to Settings while hidden.")
        }
        for slot in hotkeys?.failedSlots ?? [] {
            let label = hotkeyStore.binding(for: slot).label ?? "Disabled"
            warnings.append(
                "\(label) is already used by another app — “\(SlotPresentation.title(of: slot))” has no hotkey.")
        }
        return warnings
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// One clickable equivalent per global hotkey. The shortcut itself stays
    /// in the title text rather than a key equivalent: firing both would
    /// tile-then-untile in one keypress. Labels come from the store so
    /// custom bindings show live; disabled slots show no combo.
    private func tileItem(for slot: Slot) -> NSMenuItem {
        let label = hotkeyStore.binding(for: slot).label
        let item = NSMenuItem(
            title: label.map { "\(SlotPresentation.title(of: slot)) — \($0)" } ?? SlotPresentation.title(of: slot),
            action: #selector(tileSlot(_:)),
            keyEquivalent: "")
        item.target = self
        item.representedObject = slot.rawValue
        return item
    }

    /// One line of the tiled-windows list: slot, app, and live combo.
    private func windowLine(for info: TilingController.TiledWindowInfo) -> String {
        let name = info.appName ?? "window"
        if let label = hotkeyStore.binding(for: info.slot).label {
            return "\(SlotPresentation.title(of: info.slot)) — \(name) (\(label))"
        }
        return "\(SlotPresentation.title(of: info.slot)) — \(name)"
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
                self?.openAccessibilitySettings(NSMenuItem())
            }
            controller.onHotkeysChange = { [weak self] in
                self?.hotkeys?.reload()
                self?.refreshMenu()
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
                "No focused window — click a window first, then tile.",
                fallback: "No focused window.")
        case .alreadyTiled(let slot):
            announce(
                "\(SlotPresentation.title(of: slot)) — already there.",
                fallback: "Already in \(SlotPresentation.title(of: slot)).")
        case .refused(let name):
            announce(
                "\(name ?? "That window") couldn't be tiled — the app refused to resize it.",
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

    @objc private func openAccessibilitySettings(_ sender: NSMenuItem) {
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
