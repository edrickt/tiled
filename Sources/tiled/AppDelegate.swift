import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let controller = TilingController()
    private let hotkeyStore = HotkeyStore()
    private var hotkeys: HotkeyService?
    private var permissionTimer: Timer?
    private let settings = AppSettings()
    private var settingsController: SettingsWindowController?
    private var menuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.onChange = { [weak self] in self?.refreshMenu() }
        if !settings.hideMenuBarIcon {
            setupStatusItem()
        }

        if AXKit.promptIfUntrusted() {
            start()
        } else {
            pollForPermission()
        }
        refreshMenu()
        // Hidden-icon recovery: with no status item there is no other way
        // back in, so a fresh launch opens Settings automatically.
        if settings.hideMenuBarIcon {
            showSettings(nil)
        }
    }

    // Quitting leaves windows where they are. The manager must not
    // rearrange the user's workspace on the way out.

    // MARK: Permission

    private func start() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        let service = HotkeyService(store: hotkeyStore)
        service.handler = { [weak self] slot in self?.controller.handle(slot: slot) }
        hotkeys = service
        refreshMenu()
    }

    private func pollForPermission() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if AXKit.isTrusted {
                self.start()
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

        // 1. Status: warnings if any, else layout + tiled count.
        let warnings = activeWarnings
        if !warnings.isEmpty {
            for warning in warnings {
                menu.addItem(disabledItem(warning))
            }
        } else if controller.isTrusted {
            let count = controller.tiledWindowsInfo.count
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
            submenu.addItem(disabledItem("Sixths"))
            for slot in Slot.allCases where slot.layout == .sixths {
                submenu.addItem(tileItem(for: slot))
            }
            tile.submenu = submenu
            menu.addItem(tile)
            menu.addItem(.separator())

            // 3. Manage: the tiled windows plus bulk actions.
            let tiled = controller.tiledWindowsInfo
            if tiled.isEmpty {
                let item = NSMenuItem(title: "No tiled windows", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                for info in tiled {
                    menu.addItem(disabledItem(windowLine(for: info)))
                }
                menu.addItem(.separator())
                let untile = NSMenuItem(
                    title: "Untile All", action: #selector(untileAll(_:)), keyEquivalent: "")
                untile.target = self
                menu.addItem(untile)
                let reset = NSMenuItem(
                    title: "Reset Layout", action: #selector(resetGrid(_:)), keyEquivalent: "")
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

    /// User-visible problems: the last tiling failure, plus any hotkeys
    /// owned by another app. Failures are reported here, never only logged.
    /// Labels come from the store so they reflect custom bindings.
    private var activeWarnings: [String] {
        var warnings: [String] = []
        if let error = controller.lastTileError {
            warnings.append(error)
        }
        for slot in hotkeys?.failedSlots ?? [] {
            let label = hotkeyStore.binding(for: slot).label ?? "Disabled"
            warnings.append(
                "\(label) is already used by another app — “\(slot.title)” has no hotkey.")
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
            title: label.map { "\(slot.title) — \($0)" } ?? slot.title,
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
            return "\(info.slot.title) — \(name) (\(label))"
        }
        return "\(info.slot.title) — \(name)"
    }

    // MARK: Actions

    @objc private func showSettings(_ sender: Any?) {
        if settingsController == nil {
            let controller = SettingsWindowController(
                settings: settings, hotkeyStore: hotkeyStore)
            controller.onHideIconChange = { [weak self] hidden in
                self?.setIconHidden(hidden)
            }
            controller.onHotkeysChange = { [weak self] in
                self?.hotkeys?.reload()
                self?.refreshMenu()
            }
            settingsController = controller
        }
        settingsController?.show()
    }

    @objc private func tileSlot(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let slot = Slot(rawValue: raw)
        else { return }
        controller.handle(slot: slot)
    }

    @objc private func untileAll(_ sender: NSMenuItem) {
        controller.untileAll()
    }

    @objc private func resetGrid(_ sender: NSMenuItem) {
        controller.resetGrid()
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
