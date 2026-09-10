import AppKit

/// The Shortcuts tab: one recorder row per slot, grouped under collapsible
/// layout headers, mirroring the Tile Focused Window submenu so the two
/// never disagree about grouping.
///
/// Owns rows, sections, parked bindings, collapse state, the recorder
/// lifecycle, and conflict display + announcements. The shell reads
/// `firstRecorder` for initial-focus placement and refreshes labels via
/// `reload`; `onHotkeysChange` fires after any binding change so the
/// delegate can re-register hotkeys and refresh the menu.
final class ShortcutsTab: NSObject {
    private let hotkeyStore: HotkeyStore
    /// Park/backup/collapse persistence. Injectable so tests can run the
    /// whole park lifecycle without touching the host's real preferences.
    private let defaults: UserDefaults
    var onHotkeysChange: (() -> Void)?
    /// Live Accessibility trust probe: with permission off every recorder
    /// below is a dead end, so this tab leads with the same fix row the
    /// other tabs show.
    var isTrustedProvider: (() -> Bool)?
    /// Slots whose global hotkey could not register (owned by another
    /// app). Probed after every re-registration and on show, so a combo
    /// the recorder accepted but the system refused never masquerades as
    /// a success in this tab.
    var failedSlotsProvider: (() -> [Slot])?
    /// Opens the Accessibility permission pane.
    var onOpenAccessibilitySettings: (() -> Void)?

    private var recorderButtons: [Slot: RecorderButton] = [:]
    /// The per-section bulk buttons, so a binding change that does not
    /// rebuild the view (the recorder's clear or a recorded combo) can
    /// still refresh their labels. See `refreshBulkButtons`.
    private var bulkButtons: [LayoutKind: NSButton] = [:]
    private var conflictLabel: NSTextField!
    private var permissionRow: NSStackView?
    private var resetButton: NSButton!
    private weak var window: NSWindow?
    /// Last probed trust state, so a visible permission-row flip can be
    /// announced instead of being a silent layout jump.
    private var lastKnownTrusted: Bool?

    /// First visible recorder in slot order, for initial-focus placement.
    /// Top Left may not exist when Quarters is collapsed.
    var firstRecorder: RecorderButton? {
        Slot.allCases.lazy.compactMap { self.recorderButtons[$0] }.first
    }

    init(hotkeyStore: HotkeyStore, defaults: UserDefaults = .standard) {
        self.hotkeyStore = hotkeyStore
        self.defaults = defaults
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
            "Tiled can't see or move windows: Accessibility permission is off.")
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
        // No static accessibility label: the message IS the accessible
        // content. A fixed label would mask it on re-navigation; Sam
        // would hear "Shortcut conflict" with no way to re-read which
        // slot kept what. The live-region announcement covers the moment;
        // the text itself covers every moment after.
        stack.addArrangedSubview(conflictLabel)

        // Headers show row counts so a collapsed section still communicates
        // its size. Bulk enable/disable lives in the small button beside
        // each header, deliberately separate from the disclosure control,
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
        footer.alignment = .firstBaseline
        footer.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
        resetButton = NSButton(
            title: anyResetBackup() ? "Restore Previous Shortcuts" : "Reset Shortcuts",
            target: self, action: #selector(resetShortcuts(_:)))
        resetButton.bezelStyle = .rounded
        footer.addArrangedSubview(resetButton)
        let hint = NSTextField(wrappingLabelWithString:
            "Click a shortcut, press a new combo; Esc keeps the old one, ⌫ disables.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.addArrangedSubview(hint)
        stack.addArrangedSubview(footer)
        // Same inset-width cap as the permission row above (activated
        // after the row joins the stack; constraints need a common
        // ancestor): without it the hint's intrinsic single-line width
        // shoves the row wide.
        footer.trailingAnchor.constraint(
            equalTo: stack.trailingAnchor, constant: -24).isActive = true

        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            // No bottom constraint: a bottom pin (even >=) stretches the
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
        refreshBulkButtons()
        refreshPermissionState()
        clearConflict()
        surfaceHotkeyFailures()
    }

    /// Keeps each section's bulk button honest.
    ///
    /// The label is what the user decides on; the branch is re-read from
    /// the store at click time. Every path that changes a binding without
    /// rebuilding the view must therefore refresh the label too, or the
    /// button reads "Disable all" while performing an enable: clearing a
    /// slot with ⌫ adds a disabled slot to the section, and recording
    /// into the last disabled one removes it.
    private func refreshBulkButtons() {
        for (layout, button) in bulkButtons {
            let presentation = bulkPresentation(for: layout)
            button.title = presentation.title
            button.toolTip = presentation.toolTip
        }
    }

    /// The bulk button's label and tooltip for one section's current
    /// state. One source for the two places that render it (the header
    /// build and the refresh), so a refreshed button can never disagree
    /// with a freshly built one.
    private func bulkPresentation(for layout: LayoutKind) -> (title: String, toolTip: String) {
        let name = layout == .quarters ? "Quarters" : "Sixths"
        let count = Slot.allCases.filter { $0.layout == layout }.count
        return sectionHasDisabledSlot(layout)
            ? ("Enable all \(count)",
               "Restores parked combos; slots edited while disabled keep their edits")
            : ("Disable all \(count)",
               "Disable every \(name) shortcut (keeps defaults for re-enable)")
    }

    /// Surfaces cross-app registration failures beside the recorder rows.
    /// These are not in-app conflicts, but they are decided here: a combo
    /// the recorder accepted can still lose the global registration. The
    /// conflict line doubles as the live region, so the failure is
    /// announced, not just shown. Probed on every reload, since failures
    /// can predate this window (set at launch or while it was hidden).
    private func surfaceHotkeyFailures() {
        guard let failedSlotsProvider else { return }
        let failed = failedSlotsProvider()
        guard !failed.isEmpty else { return }
        let messages = failed.map {
            MenuText.hotkeyFailureWarning(
                label: hotkeyStore.binding(for: $0).label, slot: $0)
        }
        showConflict(messages.joined(separator: "\n"))
    }

    /// Re-probes trust without touching recorder labels or a visible
    /// conflict line; the shell's permission poll calls this when trust
    /// may have flipped while the window sits open.
    func refreshPermissionState() {
        let trusted = isTrustedProvider?() ?? true
        permissionRow?.isHidden = trusted
        // Only a visible-state flip is announced; the first probe just
        // sets the baseline. Announcements against a non-visible element
        // are dropped by the system anyway.
        if let previous = lastKnownTrusted, previous != trusted {
            announce(
                trusted
                    ? "Accessibility permission granted; tiled can see and move windows now."
                    : "Tiled can't see or move windows: Accessibility permission is off.")
        }
        lastKnownTrusted = trusted
    }

    /// Drops all rows; the shell calls this before rebuilding the tab view
    /// so stale buttons never outlive their views.
    func reset() {
        recorderButtons = [:]
        bulkButtons = [:]
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
        // The footer paragraph explains the contract, but a tooltip meets
        // the user at the control itself.
        button.toolTip = "Click to record a new combo; Esc keeps the old one, ⌫ disables."
        // Armed/cancelled states change only the button title; announce
        // both, so keyboard and VoiceOver users get the same state the
        // mouse path sees. Fires on arm (the monitor starts listening)
        // and on silent tab-away cancel (no decision, no visual trace).
        button.onArmed = { [weak self] armedSlot in
            self?.announce(
                "Capturing a shortcut for \(SlotPresentation.title(of: armedSlot)): press a combo, or Esc to keep the old one.")
        }
        button.onSilentCancel = { [weak self] cancelledSlot in
            self?.announce(
                "\(SlotPresentation.title(of: cancelledSlot)) kept its old shortcut.")
        }
        recorderButtons[slot] = button
        row.addArrangedSubview(button)
        return row
    }

    /// Section header row: a borderless chevron + title button (collapse
    /// only) plus a small Enable/Disable-all button with its scope in the
    /// title ("Enable all 6"). Two controls, two jobs; the header never
    /// pretends to be the bulk toggle.
    ///
    /// (Not a .disclosure bezel: that cell refuses to draw its title on
    /// current macOS: it renders a bare triangle no matter how the title
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
        // The chevron glyph carries the collapsed/expanded state only
        // visually; the value is what VoiceOver reads after the title.
        header.setAccessibilityValue(collapsed ? "collapsed" : "expanded")
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
        // Rounded bezel, not inline: beside the bold borderless header,
        // unbordered gray text reads disabled, but this is the section's
        // second live control, and it must look like one.
        let bulk = NSButton(
            title: bulkPresentation(for: layout).title,
            target: self, action: #selector(sectionBulkToggled(_:)))
        bulk.bezelStyle = .rounded
        bulk.controlSize = .small
        bulk.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        bulk.identifier = NSUserInterfaceItemIdentifier("bulk-\(layout.rawValue)")
        bulk.toolTip = bulkPresentation(for: layout).toolTip
        bulkButtons[layout] = bulk
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
    /// Kept out of HotkeyStore: parking is UI state, not the binding model.
    /// A slot edited while disabled keeps its edit: the park is stale the
    /// moment the recorder commits, so blindly restoring it would silently
    /// destroy a deliberate configuration, the only silent data-loss path
    /// the tab would otherwise have.
    @objc private func sectionBulkToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              id.hasPrefix("bulk-"),
              let layout = LayoutKind(rawValue: String(id.dropFirst(5)))
        else { return }
        if sectionHasDisabledSlot(layout) {
            var keptEdits: [String] = []
            for slot in Slot.allCases where slot.layout == layout {
                let current = hotkeyStore.binding(for: slot)
                if let parked = parkedBinding(for: slot) {
                    if current.keyCode != nil, current != parked {
                        // Edited after the disable: the park is stale,
                        // the edit wins. Drop the park, keep the combo,
                        // and say so; the live region exists for this.
                        clearParkedBinding(for: slot)
                        keptEdits.append(SlotPresentation.title(of: slot))
                    } else {
                        hotkeyStore.set(parked, for: slot)
                        clearParkedBinding(for: slot)
                    }
                } else if current.keyCode == nil {
                    hotkeyStore.set(HotkeyStore.defaultBinding(for: slot), for: slot)
                }
            }
            // The bulk button that triggered this lives in the old view.
            rebuildContent(restoringFocusTo: "bulk-\(layout.rawValue)")
            if !keptEdits.isEmpty {
                let names = keptEdits.joined(separator: ", ")
                showConflict(
                    "\(names) \(keptEdits.count == 1 ? "was" : "were") edited while disabled; " +
                    "kept the new \(keptEdits.count == 1 ? "combo" : "combos").")
            }
        } else {
            for slot in Slot.allCases where slot.layout == layout {
                let current = hotkeyStore.binding(for: slot)
                if current.keyCode != nil {
                    parkBinding(current, for: slot)
                }
                hotkeyStore.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: slot)
            }
            // The bulk button that triggered this lives in the old view.
            rebuildContent(restoringFocusTo: "bulk-\(layout.rawValue)")
        }
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
    ///
    /// Returns the rebuilt view (also delivered via `onContentRebuilt`)
    /// so headless callers (tests included) can drive the tab without
    /// a shell.
    @discardableResult
    private func rebuildContent(restoringFocusTo identifier: String? = nil) -> NSView {
        reset()
        let view = build(size: buildSize, window: window)
        reload()
        onContentRebuilt?(view)
        if let identifier, let window,
           let replacement = Self.descendant(of: view, matching: identifier) {
            window.makeFirstResponder(replacement)
        }
        return view
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
        guard let dict = defaults.dictionary(forKey: parkedKey(for: slot)),
              let modifiers = dict["modifiers"] as? Int,
              let code = dict["keyCode"] as? Int, code >= 0
        else { return nil }
        return HotkeyBinding(modifiers: UInt32(modifiers), keyCode: UInt32(code))
    }

    private func parkBinding(_ binding: HotkeyBinding, for slot: Slot) {
        defaults.set(
            ["modifiers": Int(binding.modifiers),
             "keyCode": binding.keyCode.map(Int.init) ?? -1],
            forKey: parkedKey(for: slot))
    }

    private func clearParkedBinding(for slot: Slot) {
        defaults.removeObject(forKey: parkedKey(for: slot))
    }

    /// Collapsible section state, persisted so the tab reopens as left.
    private var collapsedSections: Set<LayoutKind> {
        get {
            let raw = defaults.stringArray(forKey: "collapsedShortcutSections") ?? []
            return Set(raw.compactMap(LayoutKind.init(rawValue:)))
        }
        set {
            defaults.set(newValue.map(\.rawValue), forKey: "collapsedShortcutSections")
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
            // A stray ⌫ must not silently discard a tuned combo: park the
            // previous binding first (same keys as Disable-all, so the
            // next Enable-all restores it), and say what happened; the
            // footer names the owner on clashes; the clear path owes the
            // same courtesy.
            let previous = hotkeyStore.binding(for: slot)
            if previous.keyCode != nil {
                parkBinding(previous, for: slot)
            }
            hotkeyStore.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: slot)
            button.showBinding(hotkeyStore.binding(for: slot))
            if let label = previous.label {
                showConflict(
                    "\(SlotPresentation.title(of: slot)) disabled: " +
                    "its old combo (\(label)) is parked; Enable all restores it.")
            } else {
                clearConflict()
            }
            onHotkeysChange?()
        case .binding(let candidate):
            switch hotkeyStore.apply(candidate, for: slot) {
            case .applied:
                button.showBinding(candidate)
                clearConflict()
                onHotkeysChange?()
                // Re-registration may have failed for this slot (the
                // combo is owned by another app): say so here, where the
                // combo was just recorded, instead of letting the menu be
                // the only witness.
                if failedSlotsProvider?().contains(slot) == true {
                    showConflict(
                        MenuText.hotkeyFailureWarning(label: candidate.label, slot: slot))
                }
            case .duplicate(let slots):
                // Keep the old binding and say, in words, who owns the
                // combo: a shake alone left users retrying the same combo
                // forever. Announced to VoiceOver, not just shown.
                button.showBinding(hotkeyStore.binding(for: slot))
                button.shake()
                let owners = slots.map { SlotPresentation.title(of: $0) }.joined(separator: ", ")
                let message =
                    "\(candidate.label ?? "That combo") is already used by \(owners); " +
                    "\(SlotPresentation.title(of: slot)) kept its old shortcut."
                showConflict(message)
                NSLog("Tiled: %@", message)
            }
        }
        // The tab is deliberately not rebuilt here: the button that just
        // committed is the one the reader is looking at. The bulk labels
        // still have to follow the binding that changed.
        refreshBulkButtons()
    }

    /// VoiceOver announcement for recorder state changes (arm, silent
    /// cancel) and permission transitions. Posted against the conflict
    /// line's view (the Shortcuts tab's live region), consistent with
    /// duplicate announcements. Silently skipped when the window is
    /// hidden (announcements against a non-visible element are dropped
    /// by the system anyway, but the guard keeps the intent explicit).
    private func announce(_ message: String) {        guard window?.isVisible == true, let label = conflictLabel else { return }
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
        // The button is two actions in sequence: first a reversible reset
        // (backup kept), then a restore of that backup. Reversible beats
        // "can't be undone", especially when parking infrastructure
        // already exists for Disable all.
        if anyResetBackup() {
            restoreResetBackup(sender)
        } else {
            confirmAndReset(sender)
        }
    }

    /// Resets everything to factory defaults, keeping the previous combos
    /// one step away: the reset button becomes Restore Previous Shortcuts
    /// until the backup is restored (or overwritten by the next reset;
    /// the dialog says so when a backup already exists, so the second
    /// reset never silently destroys the first snapshot).
    private func confirmAndReset(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Reset all \(Slot.allCases.count) shortcuts to defaults?"
        alert.informativeText = anyResetBackup()
            ? "This replaces your previous backup; those combos will be gone. "
                + "Your current combos become the new backup."
            : "Your current combos are kept; use Restore Previous Shortcuts to get them back."
        alert.addButton(withTitle: "Reset Shortcuts")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for slot in Slot.allCases {
            parkResetBackup(hotkeyStore.binding(for: slot), for: slot)
        }
        hotkeyStore.resetAll()
        reload()
        onHotkeysChange?()
        sender.title = "Restore Previous Shortcuts"
    }

    /// Restores the combos parked by the last reset: an exact snapshot,
    /// including disabled slots.
    private func restoreResetBackup(_ sender: NSButton) {
        for slot in Slot.allCases {
            if let backup = resetBackupBinding(for: slot) {
                hotkeyStore.set(backup, for: slot)
                clearResetBackup(for: slot)
            }
        }
        reload()
        onHotkeysChange?()
        sender.title = "Reset Shortcuts"
    }

    /// Reset uses its own backup keys, never the Disable-all park keys:
    /// resetting must not corrupt a section park mid-flight.
    private func resetBackupKey(for slot: Slot) -> String {
        "resetBackupHotkey.\(slot.rawValue)"
    }

    private func resetBackupBinding(for slot: Slot) -> HotkeyBinding? {
        guard let dict = defaults.dictionary(forKey: resetBackupKey(for: slot)),
              let modifiers = dict["modifiers"] as? Int,
              let code = dict["keyCode"] as? Int
        else { return nil }
        return HotkeyBinding(modifiers: UInt32(modifiers), keyCode: code >= 0 ? UInt32(code) : nil)
    }

    private func parkResetBackup(_ binding: HotkeyBinding, for slot: Slot) {
        defaults.set(
            ["modifiers": Int(binding.modifiers),
             "keyCode": binding.keyCode.map(Int.init) ?? -1],
            forKey: resetBackupKey(for: slot))
    }

    private func clearResetBackup(for slot: Slot) {
        defaults.removeObject(forKey: resetBackupKey(for: slot))
    }

    private func anyResetBackup() -> Bool {
        Slot.allCases.contains { resetBackupBinding(for: $0) != nil }
    }
}
