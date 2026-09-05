import AppKit

/// The Shortcuts tab: one recorder row per slot, grouped under collapsible
/// layout headers — mirroring the Tile Focused Window submenu so the two
/// never disagree about grouping.
///
/// Owns rows, sections, parked bindings, collapse state, the recorder
/// lifecycle, and conflict display + announcements. The shell reads
/// `firstRecorder` for initial-focus placement and refreshes labels via
/// `reload`; `onHotkeysChange` fires after any binding change so the
/// delegate can re-register hotkeys and refresh the menu.
final class ShortcutsTab: NSObject {
    private let hotkeyStore: HotkeyStore
    var onHotkeysChange: (() -> Void)?
    /// Live Accessibility trust probe: with permission off every recorder
    /// below is a dead end, so this tab leads with the same fix row the
    /// other tabs show.
    var isTrustedProvider: (() -> Bool)?
    /// Opens the Accessibility permission pane.
    var onOpenAccessibilitySettings: (() -> Void)?

    private var recorderButtons: [Slot: RecorderButton] = [:]
    private var conflictLabel: NSTextField!
    private var permissionRow: NSStackView?
    private var resetButton: NSButton!
    private weak var window: NSWindow?

    /// First visible recorder in slot order, for initial-focus placement.
    /// Top Left may not exist when Quarters is collapsed.
    var firstRecorder: RecorderButton? {
        Slot.allCases.lazy.compactMap { self.recorderButtons[$0] }.first
    }

    init(hotkeyStore: HotkeyStore) {
        self.hotkeyStore = hotkeyStore
    }

    func build(size: NSSize, window: NSWindow?) -> NSView {
        self.window = window
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: view.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let stack = TopAnchoredStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 16, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Permission warning leads the tab: with Accessibility off every
        // recorder below is a dead button, and this is often the tab a
        // troubleshooting user opens first. Same shape as General/Welcome.
        let permissionRow = NSStackView()
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 12
        permissionRow.alignment = .firstBaseline
        let warningText = NSTextField(wrappingLabelWithString:
            "tiled can't see or move windows — Accessibility permission is off.")
        warningText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warningText.textColor = .labelColor
        warningText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        permissionRow.addArrangedSubview(warningText)
        let grantButton = NSButton(
            title: "Open Accessibility Settings", target: self,
            action: #selector(grantPermissionTapped(_:)))
        grantButton.bezelStyle = .rounded
        grantButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        permissionRow.addArrangedSubview(grantButton)
        permissionRow.isHidden = isTrustedProvider?() ?? true
        stack.addArrangedSubview(permissionRow)
        permissionRow.trailingAnchor.constraint(
            equalTo: stack.trailingAnchor, constant: -24).isActive = true
        self.permissionRow = permissionRow

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

        // Headers show row counts so a collapsed section still communicates
        // its size. Bulk enable/disable lives in the small button beside
        // each header — deliberately separate from the disclosure control,
        // which only collapses.
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
            "Click a shortcut, press a new combo. Click again or Esc keeps the old one, ⌫ disables. " +
            "A clash keeps your old combo and names its owner above.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.addArrangedSubview(hint)
        stack.addArrangedSubview(footer)

        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            // No bottom constraint — a bottom pin (even >=) stretches the
            // stack to the viewport and sinks the footer; the flipped
            // document view keeps short content at the top instead.
        ])
        view.addSubview(scroll)
        return view
    }

    /// Refreshes every recorder label from the store (called on show and
    /// after any change, so rows always reflect persisted bindings).
    /// Also re-probes trust, so the permission row tracks reality every
    /// time the tab is shown or its content is rebuilt.
    func reload() {
        for (slot, button) in recorderButtons {
            button.showBinding(hotkeyStore.binding(for: slot))
        }
        permissionRow?.isHidden = isTrustedProvider?() ?? true
        clearConflict()
    }

    /// Drops all rows; the shell calls this before rebuilding the tab view
    /// so stale buttons never outlive their views.
    func reset() {
        recorderButtons = [:]
    }

    private func shortcutRow(for slot: Slot) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12

        let label = NSTextField(labelWithString: SlotPresentation.title(of: slot))
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
                "Capturing a shortcut for \(SlotPresentation.title(of: armedSlot)) — press a combo, or Esc to keep the old one.")
        }
        button.onSilentCancel = { [weak self] cancelledSlot in
            self?.announceRecorderState(
                "\(SlotPresentation.title(of: cancelledSlot)) kept its old shortcut.")
        }
        recorderButtons[slot] = button
        row.addArrangedSubview(button)
        return row
    }

    /// Section header row: a borderless chevron + title button (collapse
    /// only) plus a small Enable/Disable-all button with its scope in the
    /// title ("Enable all 6"). Two controls, two jobs — the header never
    /// pretends to be the bulk toggle.
    ///
    /// (Not a .disclosure bezel: that cell refuses to draw its title on
    /// current macOS — it renders a bare triangle no matter how the title
    /// is set, and never exposes it to accessibility. A borderless button
    /// with an SF Symbol chevron renders and reads reliably.)
    private func sectionHeader(for layout: LayoutKind) -> NSView {
        let name = layout == .quarters ? "Quarters" : "Sixths"
        let count = Slot.allCases.filter { $0.layout == layout }.count
        let collapsed = collapsedSections.contains(layout)
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let header = NSButton(
            title: "\(name) (\(count))",
            target: self, action: #selector(sectionToggled(_:)))
        header.isBordered = false
        header.setButtonType(.momentaryPushIn)
        header.image = NSImage(
            systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: nil)
        header.imagePosition = .imageLeading
        header.contentTintColor = .secondaryLabelColor
        header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        header.identifier = NSUserInterfaceItemIdentifier(layout.rawValue)
        header.toolTip = collapsed
            ? "Show \(name) shortcuts"
            : "Hide \(name) shortcuts"
        row.addArrangedSubview(header)

        // Enable-all restores up to a whole section at once: name the
        // scope on the button so the consequence is visible before click.
        let bulk = NSButton(
            title: sectionHasDisabledSlot(layout) ? "Enable all \(count)" : "Disable all \(count)",
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
        // The bulk button that triggered this lives in the old view.
        rebuildContent(restoringFocusTo: "bulk-\(layout.rawValue)")
        onHotkeysChange?()
    }

    /// Size for rebuilding the shortcuts view after collapse/bulk toggles.
    /// Set by the shell on every build; falls back to the window default.
    var buildSize = NSSize(width: 440, height: 480)
    /// The shell swaps the tab item's view with the rebuilt content.
    var onContentRebuilt: ((NSView) -> Void)?

    /// Rebuilds the shortcuts content so collapse/bulk take effect
    /// immediately, and hands the fresh view to the shell.
    ///
    /// `restoringFocusTo` names the identifier of the control that
    /// triggered the rebuild (a section header or bulk button): the old
    /// button is destroyed with the old view, so without restoration
    /// focus falls to the window and keyboard/VoiceOver users are
    /// stranded at the top of the tab. The replacement carries the same
    /// identifier, so restoration is one lookup away.
    private func rebuildContent(restoringFocusTo identifier: String? = nil) {
        reset()
        let view = build(size: buildSize, window: window)
        reload()
        onContentRebuilt?(view)
        if let identifier, let window,
           let replacement = Self.descendant(of: view, matching: identifier) {
            window.makeFirstResponder(replacement)
        }
    }

    /// Depth-first search for the button carrying `identifier` in the
    /// rebuilt view.
    private static func descendant(of view: NSView, matching id: String) -> NSButton? {
        if let button = view as? NSButton, button.identifier?.rawValue == id {
            return button
        }
        for subview in view.subviews {
            if let hit = descendant(of: subview, matching: id) { return hit }
        }
        return nil
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
        // The chevron is a momentary button: state lives in
        // collapsedSections, and the rebuild draws the new chevron.
        var collapsed = collapsedSections
        if collapsed.contains(layout) {
            collapsed.remove(layout)
        } else {
            collapsed.insert(layout)
        }
        collapsedSections = collapsed
        // The header that triggered this lives in the old view.
        rebuildContent(restoringFocusTo: layout.rawValue)
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
                let owners = slots.map { SlotPresentation.title(of: $0) }.joined(separator: ", ")
                let message =
                    "\(candidate.label ?? "That combo") is already used by \(owners) — " +
                    "\(SlotPresentation.title(of: slot)) kept its old shortcut."
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

    @objc private func grantPermissionTapped(_ sender: NSButton) {
        onOpenAccessibilitySettings?()
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
        reload()
        onHotkeysChange?()
    }

    /// Drops every parked combo: after a reset there is nothing to restore,
    /// so stale parks must not resurrect old combos on the next Enable all.
    private func clearAllParkedBindings() {
        for slot in Slot.allCases {
            clearParkedBinding(for: slot)
        }
    }
}
