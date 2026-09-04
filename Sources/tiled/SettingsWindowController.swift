import AppKit
import ServiceManagement

/// The tiled Settings window: a programmatic NSWindow with a tab view.
final class SettingsWindowController: NSWindowController {
    enum Tab: Int {
        case general
        case shortcuts
    }

    private let settings: AppSettings
    private let hotkeyStore: HotkeyStore
    private var launchAtLoginCheckbox: NSButton!
    private var hideIconCheckbox: NSButton!
    private var tabView: NSTabView!

    /// Called when the user toggles "Hide menu bar icon" so the delegate
    /// can remove/restore the status item immediately.
    var onHideIconChange: ((Bool) -> Void)?
    /// Called after any binding change so the delegate can re-register
    /// hotkeys and refresh the menu.
    var onHotkeysChange: (() -> Void)?

    init(settings: AppSettings, hotkeyStore: HotkeyStore = HotkeyStore()) {
        self.settings = settings
        self.hotkeyStore = hotkeyStore
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "tiled Settings"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView?.addSubview(buildTabView(frame: window.contentView!.bounds))
        loadValues()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(selecting tab: Tab = .general) {
        loadValues()
        reloadShortcutRows()
        tabView.selectTabViewItem(at: tab.rawValue)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Layout

    private func buildTabView(frame: NSRect) -> NSTabView {
        let tabs = NSTabView(frame: frame)
        tabs.autoresizingMask = [.width, .height]
        tabView = tabs

        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        general.view = buildGeneralView(size: frame.size)
        tabs.addTabViewItem(general)

        let shortcuts = NSTabViewItem(identifier: "shortcuts")
        shortcuts.label = "Shortcuts"
        shortcuts.view = buildShortcutsView(size: frame.size)
        tabs.addTabViewItem(shortcuts)
        return tabs
    }

    private func buildGeneralView(size: NSSize) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
        ])

        launchAtLoginCheckbox = NSButton(
            checkboxWithTitle: "Launch at Login",
            target: self, action: #selector(launchAtLoginToggled(_:)))
        stack.addArrangedSubview(launchAtLoginCheckbox)

        hideIconCheckbox = NSButton(
            checkboxWithTitle: "Hide menu bar icon",
            target: self, action: #selector(hideIconToggled(_:)))
        stack.addArrangedSubview(hideIconCheckbox)

        let hint = NSTextField(wrappingLabelWithString:
            "When the icon is hidden, relaunch tiled to get back here — " +
            "Settings opens automatically.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(hint)

        return view
    }

    private func loadValues() {
        launchAtLoginCheckbox?.state = currentLaunchAtLogin ? .on : .off
        hideIconCheckbox?.state = settings.hideMenuBarIcon ? .on : .off
    }

    // MARK: Shortcuts tab

    private var recorderButtons: [Slot: RecorderButton] = [:]
    private var resetButton: NSButton!

    private func buildShortcutsView(size: NSSize) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: view.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 16, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // One row per slot, grouped under layout headers — mirroring the
        // Tile Focused Window submenu so the two never disagree about
        // grouping.
        for layout in [LayoutKind.quarters, LayoutKind.sixths] {
            let header = NSTextField(labelWithString:
                layout == .quarters ? "Quarters" : "Sixths")
            header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            stack.addArrangedSubview(header)
            for slot in Slot.allCases where slot.layout == layout {
                stack.addArrangedSubview(shortcutRow(for: slot))
            }
            if layout == .quarters {
                let spacer = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 8))
                stack.addArrangedSubview(spacer)
            }
        }

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 12
        footer.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
        resetButton = NSButton(
            title: "Reset to Defaults", target: self, action: #selector(resetShortcuts(_:)))
        resetButton.bezelStyle = .rounded
        footer.addArrangedSubview(resetButton)
        let hint = NSTextField(wrappingLabelWithString:
            "Click a shortcut, press a new combo. Esc keeps the old one, ⌫ disables.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.addArrangedSubview(hint)
        stack.addArrangedSubview(footer)

        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        view.addSubview(scroll)
        return view
    }

    private func shortcutRow(for slot: Slot) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12

        let label = NSTextField(labelWithString: slot.title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        row.addArrangedSubview(label)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        let button = RecorderButton(slot: slot)
        button.target = self
        button.action = #selector(recorderClicked(_:))
        recorderButtons[slot] = button
        row.addArrangedSubview(button)
        return row
    }

    /// Refreshes every recorder label from the store (called on show and
    /// after any change, so rows always reflect persisted bindings).
    private func reloadShortcutRows() {
        for (slot, button) in recorderButtons {
            button.showBinding(hotkeyStore.binding(for: slot))
        }
    }

    @objc private func recorderClicked(_ sender: RecorderButton) {
        // End any other in-progress record first: exactly one recorder is
        // armed at a time.
        for (slot, button) in recorderButtons where button.isRecording && button !== sender {
            button.showBinding(hotkeyStore.binding(for: slot))
        }
        sender.beginRecording { [weak self, weak sender] outcome in
            guard let self, let sender else { return }
            self.finishRecording(sender, outcome: outcome)
        }
    }

    private func finishRecording(_ button: RecorderButton, outcome: HotkeyRecorder.Outcome) {
        let slot = button.slot
        switch outcome {
        case .cancel:
            button.showBinding(hotkeyStore.binding(for: slot))
        case .clear:
            hotkeyStore.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: slot)
            button.showBinding(hotkeyStore.binding(for: slot))
            onHotkeysChange?()
        case .binding(let candidate):
            switch hotkeyStore.apply(candidate, for: slot) {
            case .applied:
                button.showBinding(candidate)
                onHotkeysChange?()
            case .duplicate(let slots):
                // Keep the old binding and shake: silently stealing the
                // combo from its current slot would be worse than refusing.
                button.showBinding(hotkeyStore.binding(for: slot))
                button.shake()
                NSLog(
                    "tiled: %@ already used by %@ — keeping %@'s old shortcut",
                    candidate.label ?? "combo",
                    slots.map(\.title).joined(separator: ", "), slot.title)
            }
        }
    }

    @objc private func resetShortcuts(_ sender: NSButton) {
        hotkeyStore.resetAll()
        reloadShortcutRows()
        onHotkeysChange?()
    }

    // MARK: Actions

    private var currentLaunchAtLogin: Bool {
        (try? SMAppService.mainApp.status) == .enabled
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        let enable = sender.state == .on
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // SMAppService can fail outside a properly bundled app (e.g. a
            // raw `swift run` binary); say so and revert the checkbox.
            NSLog("tiled: Launch at Login %@ failed: %@", enable ? "enable" : "disable", "\(error)")
            sender.state = enable ? .off : .on
        }
    }

    @objc private func hideIconToggled(_ sender: NSButton) {
        let hidden = sender.state == .on
        settings.hideMenuBarIcon = hidden
        onHideIconChange?(hidden)
    }
}
