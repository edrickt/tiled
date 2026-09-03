import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let controller = TilingController()
    private var hotkeys: HotkeyService?
    private var permissionTimer: Timer?

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

    func applicationWillTerminate(_ notification: Notification) {
        // Restore everything the way we found it.
        controller.untileAll()
    }

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
        statusItem?.menu = menu()
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if controller.isTrusted {
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
        let quit = NSMenuItem(
            title: "Quit tiled", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    // MARK: Actions

    @objc private func untileAll(_ sender: NSMenuItem) {
        controller.untileAll()
    }

    @objc private func openAccessibilitySettings(_ sender: NSMenuItem) {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
    }
}
