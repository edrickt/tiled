import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let controller = TilingController()
    private var hotkeys: HotkeyService?
    private var permissionTimer: Timer?
    private var shortcutsWindow: NSWindow?
    private var menuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.onChange = { [weak self] in self?.refreshMenu() }
        setupStatusItem()

        if AXKit.promptIfUntrusted() {
            start()
        } else {
            pollForPermission()
        }
        refreshMenu()
    }

    // Quitting leaves windows where they are. The manager must not
    // rearrange the user's workspace on the way out.

    // MARK: Permission

    private func start() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        let service = HotkeyService()
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "square.grid.2x2",
            accessibilityDescription: "tiled")
        item.menu = menu()
        statusItem = item
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

        let warnings = activeWarnings
        if !warnings.isEmpty {
            for warning in warnings {
                menu.addItem(disabledItem(warning))
            }
            menu.addItem(.separator())
        }

        if controller.isTrusted {
            let tile = NSMenuItem(title: "Tile Focused Window", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.addItem(disabledItem("Quarters — hold ⌥⇧"))
            for slot in Slot.allCases where slot.layout == .quarters {
                submenu.addItem(tileItem(for: slot))
            }
            submenu.addItem(.separator())
            submenu.addItem(disabledItem("Sixths — hold ⌥⇧⌘"))
            for slot in Slot.allCases where slot.layout == .sixths {
                submenu.addItem(tileItem(for: slot))
            }
            tile.submenu = submenu
            menu.addItem(tile)
            menu.addItem(.separator())

            let layoutItem = NSMenuItem(
                title: "Layout: \(controller.activeLayout.title)", action: nil,
                keyEquivalent: "")
            layoutItem.isEnabled = false
            menu.addItem(layoutItem)
            menu.addItem(.separator())
            let tiled = controller.tiledWindowsInfo
            if tiled.isEmpty {
                let item = NSMenuItem(title: "No tiled windows", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                for info in tiled {
                    let name = info.appName ?? "window"
                    let item = NSMenuItem(
                        title: "\(info.slot.title) — \(name) (\(info.slot.hotkeyLabel))",
                        action: nil,
                        keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
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

        menu.addItem(.separator())
        let shortcuts = NSMenuItem(
            title: "Keyboard Shortcuts…", action: #selector(showShortcuts(_:)),
            keyEquivalent: "")
        shortcuts.target = self
        menu.addItem(shortcuts)
        let quit = NSMenuItem(
            title: "Quit tiled", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    /// User-visible problems: the last tiling failure, plus any hotkeys
    /// owned by another app. Failures are reported here, never only logged.
    private var activeWarnings: [String] {
        var warnings: [String] = []
        if let error = controller.lastTileError {
            warnings.append(error)
        }
        for slot in hotkeys?.failedSlots ?? [] {
            warnings.append(
                "\(slot.hotkeyLabel) is already used by another app — “\(slot.title)” has no hotkey.")
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
    /// tile-then-untile in one keypress.
    private func tileItem(for slot: Slot) -> NSMenuItem {
        let item = NSMenuItem(
            title: "\(slot.title) — \(slot.hotkeyLabel)",
            action: #selector(tileSlot(_:)),
            keyEquivalent: "")
        item.target = self
        item.representedObject = slot.rawValue
        return item
    }

    // MARK: Actions

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

    @objc private func showShortcuts(_ sender: NSMenuItem) {
        if shortcutsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "tiled Shortcuts"
            window.center()
            window.isReleasedWhenClosed = false

            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder

            let text = NSTextView(frame: scroll.contentView.bounds)
            text.string = Slot.cheatsheetText
            text.isEditable = false
            text.isSelectable = true
            text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            text.textContainerInset = NSSize(width: 16, height: 16)
            text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
            text.maxSize = NSSize(
                width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            scroll.documentView = text

            window.contentView?.addSubview(scroll)
            shortcutsWindow = window
        }
        shortcutsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
