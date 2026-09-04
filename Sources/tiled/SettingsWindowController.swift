import AppKit
import ServiceManagement

/// The tiled Settings window: a programmatic NSWindow with a tab view.
final class SettingsWindowController: NSWindowController {
    enum Tab: Int {
        case welcome
        case general
        case shortcuts
    }

    private let settings: AppSettings
    private let hotkeyStore: HotkeyStore
    private var launchAtLoginCheckbox: NSButton!
    private var hideIconCheckbox: NSButton!
    private var tabView: NSTabView!
    /// Welcome's dismiss button, for initial-focus placement on open.
    private var welcomeDismissButton: NSButton?

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
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "tiled"
        window.minSize = NSSize(width: 400, height: 300)
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
        selectTab(tab)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        focusInitialControl(for: tab)
    }

    /// Selects by identifier: the Welcome tab shifts indices when present,
    /// so raw values are never positions.
    private func selectTab(_ tab: Tab) {
        let id: String
        switch tab {
        case .welcome: id = "welcome"
        case .general: id = "general"
        case .shortcuts: id = "shortcuts"
        }
        if let item = tabView.tabViewItems.first(where: { ($0.identifier as? String) == id }) {
            tabView.selectTabViewItem(item)
        }
    }

    /// Keyboard/VoiceOver landing spot per tab: opening Settings must put
    /// focus somewhere deliberate, never wherever AppKit defaults drop it.
    /// Dismissing Welcome returns focus to General's first checkbox.
    private func focusInitialControl(for tab: Tab) {
        switch tab {
        case .welcome:
            // window-nil guard: selectTab no-ops when Welcome isn't in
            // the tab view, so never focus a detached button.
            if let button = welcomeDismissButton, button.window != nil {
                window?.makeFirstResponder(button)
            }
        case .general:
            if let checkbox = launchAtLoginCheckbox {
                window?.makeFirstResponder(checkbox)
            }
        case .shortcuts:
            // Top Left may not exist when Quarters is collapsed — fall
            // back to the first visible recorder in slot order, so focus
            // always lands somewhere deliberate.
            let first = Slot.allCases.lazy.compactMap { self.recorderButtons[$0] }.first
            if let first {
                window?.makeFirstResponder(first)
            }
        }
    }

    /// Index of the Shortcuts tab item, whatever the Welcome tab shifts.
    private var shortcutsItemIndex: Int? {
        tabView.tabViewItems.firstIndex(where: { ($0.identifier as? String) == "shortcuts" })
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

        // First-run tab: demonstrates one tiling instead of listing
        // seventeen combos. Removed per launch once dismissed; re-openable
        // from the menu bar menu → tiled Guide (via a one-shot build override).
        if !settings.didDismissWelcome || forceWelcomeOnce {
            let welcome = NSTabViewItem(identifier: "welcome")
            welcome.label = "Welcome"
            welcome.view = buildWelcomeView(size: frame.size)
            tabs.insertTabViewItem(welcome, at: 0)
        }
        return tabs
    }

    /// First-run tab: one demonstration, not seventeen combos. Dismissing
    /// removes the tab for this launch (persisted); it stays re-openable
    /// from General, so the teaching moment is never lost — the tab is
    /// one-time per launch, not one-time forever.
    private func buildWelcomeView(size: NSSize) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
        ])

        let title = NSTextField(labelWithString: "Tile a window in one keypress")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        stack.addArrangedSubview(title)

        let topLeft = hotkeyStore.binding(for: .topLeft).label ?? "\u{2325}\u{21E7}U"
        let steps = NSTextField(wrappingLabelWithString:
            "1. Click any window to focus it.\n" +
            "2. Press \(topLeft) to tile it top-left.\n" +
            "3. Press it again — tiling its own tile does nothing, safely.\n" +
            "Every combo lives under Tile Focused Window in the menu bar menu.")
        steps.font = .systemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(steps)

        // Spatial preview: the quarters grid with Top Left lit, so the
        // first slot name is geometry, not vocabulary. Drawn from the same
        // TileCell sets as the layout engine — it cannot disagree.
        // Tertiary (not quaternary) track: at this small size the
        // quaternary fill renders near-invisible in Dark Mode.
        let preview = SlotPreviewView(highlighted: [.topLeft], trackColor: .tertiaryLabelColor)
        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: 160),
            preview.heightAnchor.constraint(equalToConstant: 100),
        ])
        // A bare NSView is not an accessibility element, so without the
        // next two lines the label below would never reach VoiceOver.
        preview.setAccessibilityElement(true)
        preview.setAccessibilityRole(.image)
        preview.setAccessibilityLabel("Preview: Top Left covers the top-left quarter")
        stack.addArrangedSubview(preview)

        let sixthsPreview = NSTextField(wrappingLabelWithString:
            "Sixths work the same way: three columns instead of two.")
        sixthsPreview.textColor = .secondaryLabelColor
        sixthsPreview.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(sixthsPreview)

        let dismiss = NSButton(
            title: "Got it — show General next time",
            target: self, action: #selector(dismissWelcome(_:)))
        dismiss.bezelStyle = .rounded
        welcomeDismissButton = dismiss
        stack.addArrangedSubview(dismiss)
        // Re-entry: Welcome removes itself per launch, but a persistent
        // menu-bar item reopens it (see showWelcomeAgain). One-time
        // moment, permanently reachable.
        let revisit = NSTextField(wrappingLabelWithString:
            "You can reopen this guide anytime from the menu bar menu → tiled Guide.")
        revisit.textColor = .secondaryLabelColor
        revisit.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(revisit)

        return view
    }

    /// Reopens the Welcome tab on demand (menu-bar "tiled Guide" item,
    /// General's "Show tiled Guide" button). Builds the tab view with Welcome present without clearing
    /// the dismissal flag, so the next launch still opens on General.
    /// When the window is hidden, the tab view is rebuilt first so the
    /// Welcome item exists before selection (selectTab is identifier-safe
    /// and no-ops on a missing tab, never a wrong tab).
    func showWelcomeAgain() {
        if window?.isVisible != true {
            rebuildTabView(includingWelcome: true)
            loadValues()
            reloadShortcutRows()
            selectTab(.welcome)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            focusInitialControl(for: .welcome)
            return
        }
        if tabView.tabViewItems.contains(where: { ($0.identifier as? String) == "welcome" }) {
            selectTab(.welcome)
            focusInitialControl(for: .welcome)
            return
        }
        let frame = window?.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 440, height: 480)
        let welcome = NSTabViewItem(identifier: "welcome")
        welcome.label = "Welcome"
        welcome.view = buildWelcomeView(size: frame.size)
        tabView.insertTabViewItem(welcome, at: 0)
        selectTab(.welcome)
        focusInitialControl(for: .welcome)
    }

    /// Rebuilds the whole tab view (used when opening Welcome onto a
    /// hidden window whose tabs were built without it). Delegates to
    /// buildTabView with a one-shot override — no duplicated tab code.
    private var forceWelcomeOnce = false

    private func rebuildTabView(includingWelcome: Bool) {
        guard let contentView = window?.contentView else { return }
        let frame = contentView.bounds
        for subview in contentView.subviews {
            subview.removeFromSuperview()
        }
        recorderButtons = [:]
        forceWelcomeOnce = includingWelcome
        contentView.addSubview(buildTabView(frame: frame))
        forceWelcomeOnce = false
    }

    @objc private func showGuideFromSettings(_ sender: NSButton) {
        showWelcomeAgain()
    }

    @objc private func dismissWelcome(_ sender: NSButton) {
        settings.didDismissWelcome = true
        if let welcome =
            tabView.tabViewItems.first(where: { ($0.identifier as? String) == "welcome" })
        {
            tabView.removeTabViewItem(welcome)
        }
        selectTab(.general)
        // Focus leaves with the removed tab; land it on General's first
        // control instead of wherever AppKit defaults drop it.
        if let checkbox = launchAtLoginCheckbox {
            window?.makeFirstResponder(checkbox)
        }
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
        launchAtLoginCheckbox.toolTip = "Start tiled automatically when you log in."
        stack.addArrangedSubview(launchAtLoginCheckbox)

        hideIconCheckbox = NSButton(
            checkboxWithTitle: "Hide menu bar icon",
            target: self, action: #selector(hideIconToggled(_:)))
        hideIconCheckbox.toolTip = "The icon disappears immediately; press \u{2303}\u{2325}\u{21E7}\u{2318}, to get back."
        stack.addArrangedSubview(hideIconCheckbox)

        let divider = NSBox()
        divider.boxType = .separator
        stack.addArrangedSubview(divider)

        let guideLabel = NSTextField(labelWithString: "Guide")
        guideLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        guideLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(guideLabel)

        let guideRow = NSStackView()
        guideRow.orientation = .horizontal
        guideRow.spacing = 8
        let guideText = NSTextField(wrappingLabelWithString:
            "Replay the three-step introduction with the tile preview.")
        guideText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        guideText.textColor = .secondaryLabelColor
        guideRow.addArrangedSubview(guideText)
        let guideButton = NSButton(
            title: "Show tiled Guide", target: self, action: #selector(showGuideFromSettings(_:)))
        guideButton.bezelStyle = .rounded
        guideButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        guideRow.addArrangedSubview(guideButton)
        stack.addArrangedSubview(guideRow)

        let hint = NSTextField(wrappingLabelWithString:
            "When the icon is hidden, press \u{2303}\u{2325}\u{21E7}\u{2318}, anywhere " +
            "or relaunch tiled to get back here — Settings opens automatically. " +
            "Hiding asks first, so this never happens by accident.")
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
    private var conflictLabel: NSTextField!
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

        // Conflict line sits above the sections so a clash while Sixths
        // is collapsed never renders below the fold. Hidden until needed.
        conflictLabel = NSTextField(wrappingLabelWithString: "")
        // Warning semantics via bold labelColor, not hue: .systemOrange
        // fails 4.5:1 body-text contrast on a light window background.
        // The shake + VoiceOver announcement carry the alert; the text
        // itself must stay legible in both appearances.
        conflictLabel.textColor = .labelColor
        conflictLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        conflictLabel.isHidden = true
        conflictLabel.setAccessibilityLabel("Shortcut conflict")
        stack.addArrangedSubview(conflictLabel)

        // One row per slot, grouped under collapsible layout headers —
        // mirroring the Tile Focused Window submenu so the two never
        // disagree about grouping. Headers show row counts so a collapsed
        // section still communicates its size. Bulk enable/disable lives in
        // the small button beside each header — deliberately separate from
        // the disclosure control, which only collapses.
        for layout in [LayoutKind.quarters, LayoutKind.sixths] {
            stack.addArrangedSubview(sectionHeader(for: layout))
            if !collapsedSections.contains(layout) {
                for slot in Slot.allCases where slot.layout == layout {
                    stack.addArrangedSubview(shortcutRow(for: slot))
                }
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
            title: "Reset Shortcuts", target: self, action: #selector(resetShortcuts(_:)))
        resetButton.bezelStyle = .rounded
        footer.addArrangedSubview(resetButton)
        let hint = NSTextField(wrappingLabelWithString:
            "Click a shortcut, press a new combo. Click again or Esc keeps the old one, ⌫ disables.")
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
        // Armed/cancelled states change only the button title — announce
        // both, so keyboard and VoiceOver users get the same state the
        // mouse path sees. Fires on arm (the monitor starts listening)
        // and on silent tab-away cancel (no decision, no visual trace).
        button.onArmed = { [weak self] armedSlot in
            self?.announceRecorderState(
                "Capturing a shortcut for \(armedSlot.title) — press a combo, or Esc to keep the old one.")
        }
        button.onSilentCancel = { [weak self] cancelledSlot in
            self?.announceRecorderState(
                "\(cancelledSlot.title) kept its old shortcut.")
        }
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
        clearConflict()
    }

    /// Section header row: disclosure triangle (collapse only) plus a
    /// small Enable/Disable-all button (bulk action). Two controls, two
    /// jobs — the header never pretends to be the bulk toggle.
    private func sectionHeader(for layout: LayoutKind) -> NSView {
        let name = layout == .quarters ? "Quarters" : "Sixths"
        let count = Slot.allCases.filter { $0.layout == layout }.count
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let header = NSButton(
            title: "\(name) (\(count))",
            target: self, action: #selector(sectionToggled(_:)))
        header.bezelStyle = .disclosure
        header.setButtonType(.onOff)
        header.identifier = NSUserInterfaceItemIdentifier(layout.rawValue)
        header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        header.state = collapsedSections.contains(layout) ? .off : .on
        header.toolTip = collapsedSections.contains(layout)
            ? "Show \(name) shortcuts"
            : "Hide \(name) shortcuts"
        row.addArrangedSubview(header)

        let bulk = NSButton(
            title: sectionHasDisabledSlot(layout) ? "Enable all" : "Disable all",
            target: self, action: #selector(sectionBulkToggled(_:)))
        bulk.bezelStyle = .inline
        bulk.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        bulk.identifier = NSUserInterfaceItemIdentifier("bulk-\(layout.rawValue)")
        bulk.toolTip = sectionHasDisabledSlot(layout)
            ? "Restore every \(name) shortcut to its default combo"
            : "Disable every \(name) shortcut (keeps defaults for re-enable)"
        row.addArrangedSubview(bulk)
        return row
    }

    /// True when any slot in the section is currently disabled.
    private func sectionHasDisabledSlot(_ layout: LayoutKind) -> Bool {
        Slot.allCases.contains {
            $0.layout == layout && hotkeyStore.binding(for: $0).keyCode == nil
        }
    }

    /// Bulk toggle: Disable all parks current combos aside (persisted under
    /// a defaults key) and disables the section; Enable all restores them.
    /// Kept out of HotkeyStore — parking is UI state, not the binding model.
    @objc private func sectionBulkToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              id.hasPrefix("bulk-"),
              let layout = LayoutKind(rawValue: String(id.dropFirst(5)))
        else { return }
        if sectionHasDisabledSlot(layout) {
            for slot in Slot.allCases where slot.layout == layout {
                if let parked = parkedBinding(for: slot) {
                    hotkeyStore.set(parked, for: slot)
                    clearParkedBinding(for: slot)
                } else if hotkeyStore.binding(for: slot).keyCode == nil {
                    hotkeyStore.set(HotkeyStore.defaultBinding(for: slot), for: slot)
                }
            }
        } else {
            for slot in Slot.allCases where slot.layout == layout {
                let current = hotkeyStore.binding(for: slot)
                if current.keyCode != nil {
                    parkBinding(current, for: slot)
                }
                hotkeyStore.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: slot)
            }
        }
        rebuildShortcutsView()
        onHotkeysChange?()
    }

    private func parkedKey(for slot: Slot) -> String {
        "parkedHotkey.\(slot.rawValue)"
    }

    private func parkedBinding(for slot: Slot) -> HotkeyBinding? {
        guard let dict = UserDefaults.standard.dictionary(forKey: parkedKey(for: slot)),
              let modifiers = dict["modifiers"] as? Int,
              let code = dict["keyCode"] as? Int, code >= 0
        else { return nil }
        return HotkeyBinding(modifiers: UInt32(modifiers), keyCode: UInt32(code))
    }

    private func parkBinding(_ binding: HotkeyBinding, for slot: Slot) {
        UserDefaults.standard.set(
            ["modifiers": Int(binding.modifiers),
             "keyCode": binding.keyCode.map(Int.init) ?? -1],
            forKey: parkedKey(for: slot))
    }

    private func clearParkedBinding(for slot: Slot) {
        UserDefaults.standard.removeObject(forKey: parkedKey(for: slot))
    }

    /// Collapsible section state, persisted so the tab reopens as left.
    private var collapsedSections: Set<LayoutKind> {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: "collapsedShortcutSections") ?? []
            return Set(raw.compactMap(LayoutKind.init(rawValue:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: "collapsedShortcutSections")
        }
    }

    @objc private func sectionToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let layout = LayoutKind(rawValue: id) else {
            return
        }
        var collapsed = collapsedSections
        if sender.state == .on {
            collapsed.remove(layout)
        } else {
            collapsed.insert(layout)
        }
        collapsedSections = collapsed
        rebuildShortcutsView()
    }

    /// Rebuilds the Shortcuts tab content so collapsing a section takes
    /// effect immediately.
    private func rebuildShortcutsView() {
        guard let index = shortcutsItemIndex else { return }
        recorderButtons = [:]
        let size = tabView.tabViewItem(at: index).view?.bounds.size
            ?? window?.contentView?.bounds.size ?? NSSize(width: 440, height: 480)
        tabView.tabViewItem(at: index).view =
            buildShortcutsView(size: size)
        reloadShortcutRows()
    }

    @objc private func recorderClicked(_ sender: RecorderButton) {
        // Clicking the armed recorder again cancels: the click that would
        // otherwise re-arm it disarms it instead, so a stray click away
        // leaves nothing stuck mid-record.
        if sender.isRecording {
            sender.showBinding(hotkeyStore.binding(for: sender.slot))
            clearConflict()
            return
        }
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
            clearConflict()
        case .clear:
            hotkeyStore.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: slot)
            button.showBinding(hotkeyStore.binding(for: slot))
            clearConflict()
            onHotkeysChange?()
        case .binding(let candidate):
            switch hotkeyStore.apply(candidate, for: slot) {
            case .applied:
                button.showBinding(candidate)
                clearConflict()
                onHotkeysChange?()
            case .duplicate(let slots):
                // Keep the old binding and say, in words, who owns the
                // combo: a shake alone left users retrying the same combo
                // forever. Announced to VoiceOver, not just shown.
                button.showBinding(hotkeyStore.binding(for: slot))
                button.shake()
                let owners = slots.map(\.title).joined(separator: ", ")
                let message =
                    "\(candidate.label ?? "That combo") is already used by \(owners) — " +
                    "\(slot.title) kept its old shortcut."
                showConflict(message)
                NSLog("tiled: %@", message)
            }
        }
    }

    /// VoiceOver announcement for recorder state changes (arm, silent
    /// cancel). Posted against the conflict line's view — the Shortcuts
    /// tab's live region — consistent with duplicate announcements.
    /// Silently skipped when the window is hidden (announcements against
    /// a non-visible element are dropped by the system anyway, but the
    /// guard keeps the intent explicit).
    private func announceRecorderState(_ message: String) {
        guard window?.isVisible == true, let label = conflictLabel else { return }
        NSAccessibility.post(
            element: label,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Shows a persistent inline conflict message (VoiceOver-announced).
    private func showConflict(_ message: String) {
        conflictLabel?.stringValue = message
        conflictLabel?.isHidden = false
        NSAccessibility.post(
            element: conflictLabel as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func clearConflict() {
        conflictLabel?.stringValue = ""
        conflictLabel?.isHidden = true
    }

    @objc private func resetShortcuts(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Reset all 17 shortcuts to defaults?"
        alert.informativeText = "Every custom combo is replaced. This can't be undone."
        alert.addButton(withTitle: "Reset Shortcuts")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        hotkeyStore.resetAll()
        clearAllParkedBindings()
        reloadShortcutRows()
        onHotkeysChange?()
    }

    /// Drops every parked combo: after a reset there is nothing to restore,
    /// so stale parks must not resurrect old combos on the next Enable all.
    private func clearAllParkedBindings() {
        for slot in Slot.allCases {
            clearParkedBinding(for: slot)
        }
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
        if hidden {
            // Hiding removes the only visible handle to the app (including
            // Quit), so confirm with the recovery path named on the button.
            let alert = NSAlert()
            alert.messageText = "Hide the menu bar icon?"
            alert.informativeText =
                "The icon disappears immediately. To get back, press \u{2303}\u{2325}\u{21E7}\u{2318}, " +
                "anywhere or relaunch tiled — Settings opens automatically."
            alert.addButton(withTitle: "Hide Icon")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                sender.state = .off
                return
            }
        }
        settings.hideMenuBarIcon = hidden
        onHideIconChange?(hidden)
    }
}
