import AppKit

/// The Shortcuts tab's collapsible sections: the six app actions, then the
/// eleven shared slot keys. Raw values persist in the
/// "collapsedShortcutSections" defaults array.
enum ShortcutSection: String {
    case appActions
    case slotKeys

    var title: String {
        switch self {
        case .appActions: "App Actions"
        case .slotKeys: "Slot Keys"
        }
    }

    var rowCount: Int {
        switch self {
        case .appActions: HotkeyAction.appActions.count
        case .slotKeys: SlotKey.allCases.count
        }
    }

    /// The actions a bulk Enable/Disable all covers, nil for App Actions
    /// (whose rows disable one at a time; no bulk button).
    var bulkActions: [HotkeyAction]? {
        switch self {
        case .appActions: nil
        case .slotKeys: SlotKey.allCases.map(HotkeyAction.slotKey)
        }
    }
}

/// The Shortcuts tab: one recorder row per configurable hotkey — the
/// eleven shared slot keys under one collapsible section (grouped by
/// physical position so it mirrors the tile submenu), plus an App Actions
/// section for the global combos (expand, evict, reset splitters, switch
/// layout, Settings, undo).
///
/// Owns rows, sections, parked bindings, collapse state, the recorder
/// lifecycle, and conflict display + announcements. The shell reads
/// `firstRecorder` for initial-focus placement and refreshes labels via
/// `reload`; `onHotkeysChange` fires after any binding change so the
/// delegate can re-register hotkeys and refresh the menu.
final class ShortcutsTab: NSObject {
    private let hotkeyStore: HotkeyStore
    /// Collapse persistence, and the UserDefaults the park adapter wraps.
    /// Injectable so tests can run the whole park lifecycle without
    /// touching the host's real preferences.
    /// The recorder's one contract sentence: the section hint and every
    /// button tooltip read the same literal.
    private static let recorderContract =
        "Click a shortcut, press a new combo; Esc keeps the old one, ⌫ disables."
    private let defaults: UserDefaults
    private let park: ShortcutPark
    var onHotkeysChange: (() -> Void)?
    /// Live Accessibility trust probe: with permission off every recorder
    /// below is a dead end, so this tab leads with the same fix row the
    /// other tabs show.
    var isTrustedProvider: (() -> Bool)?
    /// Actions whose global hotkey could not register (owned by another
    /// app). Probed after every re-registration and on show, so a combo
    /// the recorder accepted but the system refused never masquerades as
    /// a success in this tab.
    var failedActionsProvider: (() -> [HotkeyAction])?
    /// Opens the Accessibility permission pane.
    var onOpenAccessibilitySettings: (() -> Void)?
    /// The reset confirmation decision, receiving the dialog's promise and
    /// answering whether to reset. Injectable so tests can run the whole
    /// reset/restore lifecycle without a modal session; nil presents the
    /// real alert.
    var confirmReset: ((String) -> Bool)?

    private var recorderButtons: [HotkeyAction: RecorderButton] = [:]
    /// The per-section bulk buttons, so a binding change that does not
    /// rebuild the view (the recorder's clear or a recorded combo) can
    /// still refresh their labels. See `refreshBulkButtons`. The slot-key
    /// section is the only one with a bulk control; the App Actions rows
    /// disable one at a time.
    private var bulkButtons: [ShortcutSection: NSButton] = [:]
    private var conflictLabel: NSTextField!
    private var permissionRow: NSStackView?
    private var resetButton: NSButton!
    private weak var window: NSWindow?
    /// The notice currently painted in `conflictLabel`, and the last text
    /// identity actually announced. Keeping them apart lets a rebuild show
    /// a persistent failure again without speaking it again.
    private var renderedNotice: ShortcutNotice?
    private var announcedNotice: ShortcutNotice?
    /// Test seam: receives every text this tab would announce. The real
    /// sink stays `conflictLabel` plus `NSAccessibility`; this lets a
    /// hermetic test count notice identity changes without a visible window.
    var onAnnouncement: ((String) -> Void)?
    /// Last probed trust state, so a visible permission-row flip can be
    /// announced instead of being a silent layout jump.
    private var lastKnownTrusted: Bool?

    /// First visible recorder in action order, for initial-focus placement.
    /// Top Left may not exist when Quarters is collapsed.
    var firstRecorder: RecorderButton? {
        HotkeyAction.allCases.lazy.compactMap { self.recorderButtons[$0] }.first
    }

    init(hotkeyStore: HotkeyStore, defaults: UserDefaults = .standard) {
        self.hotkeyStore = hotkeyStore
        self.defaults = defaults
        self.park = ShortcutPark(store: UserDefaultsParkStore(defaults: defaults))
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
        // A rebuild replaces the label, so seed it from the notice already
        // rendered; `reload` then sees an equal identity and stays silent.
        conflictLabel.stringValue = renderedNotice?.text ?? ""
        conflictLabel.isHidden = renderedNotice == nil
        // No static accessibility label: the message IS the accessible
        // content. A fixed label would mask it on re-navigation; Sam
        // would hear "Shortcut conflict" with no way to re-read which
        // slot kept what. The live-region announcement covers the moment;
        // the text itself covers every moment after.
        stack.addArrangedSubview(conflictLabel)

        // Teach recording before the first control, not below the rows.
        let hint = NSTextField(wrappingLabelWithString:
            Self.recorderContract)
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(hint)
        hint.trailingAnchor.constraint(
            equalTo: stack.trailingAnchor, constant: -24).isActive = true
        stack.setCustomSpacing(12, after: hint)

        // Headers show row counts so a collapsed section still communicates
        // its size. The slot-key section carries one bulk enable/disable
        // button beside its header, deliberately separate from the
        // disclosure control, which only collapses. App Actions leads: the
        // six global combos are the fewest-used but hardest-to-discover
        // rows.
        for section in [ShortcutSection.appActions, .slotKeys] {
            let header = sectionHeader(for: section)
            stack.addArrangedSubview(header)
            if !collapsedSections.contains(section) {
                stack.setCustomSpacing(8, after: header)
                switch section {
                case .appActions:
                    for action in HotkeyAction.appActions {
                        stack.addArrangedSubview(shortcutRow(for: action))
                    }
                case .slotKeys:
                    // Derive the groups from the sixths geometry table, so
                    // the Settings grouping can never drift from the slots
                    // it describes; only the physical key names show.
                    let groups: [(title: String, keys: [SlotKey])] = [
                        ("Corners", SlotPresentation.sixthsCorners.map(\.key)),
                        ("Thirds", SlotPresentation.sixthsThirds.map(\.key)),
                        ("Two-Thirds", SlotPresentation.sixthsTwoThirds.map(\.key)),
                    ]
                    for (index, group) in groups.enumerated() {
                        if index > 0, let previous = stack.arrangedSubviews.last {
                            stack.setCustomSpacing(12, after: previous)
                        }
                        let label = NSTextField(labelWithString: group.title)
                        label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
                        label.textColor = .secondaryLabelColor
                        stack.addArrangedSubview(label)
                        for key in group.keys {
                            stack.addArrangedSubview(shortcutRow(for: .slotKey(key)))
                        }
                    }
                    let caption = NSTextField(wrappingLabelWithString: slotKeyCaption())
                    caption.textColor = .secondaryLabelColor
                    caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                    stack.addArrangedSubview(caption)
                    caption.trailingAnchor.constraint(
                        equalTo: stack.trailingAnchor, constant: -24).isActive = true
                }
            }
            if section == .appActions {
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
            title: "", target: self, action: #selector(resetShortcuts(_:)))
        resetButton.bezelStyle = .rounded
        footer.addArrangedSubview(resetButton)
        refreshFooter()
        stack.addArrangedSubview(footer)

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
    /// time the tab is shown or its content is rebuilt. The notice is
    /// recomputed from the current failure set, never appended to whatever
    /// used to be on the line.
    func reload() {
        reload(notice: ShortcutNotice(failures: hotkeyFailureMessages()))
    }

    private func reload(notice: ShortcutNotice?) {
        for (action, button) in recorderButtons {
            button.showBinding(hotkeyStore.binding(for: action))
        }
        refreshBulkButtons()
        refreshFooter()
        refreshPermissionState()
        render(notice)
    }

    /// The footer's one two-state answer: Reset when no reset snapshot is
    /// readable, Restore Previous Shortcuts when one is. Build and reload
    /// both call this, so a backup created or cleared anywhere can never
    /// leave the wrong action under the title (T11).
    private func refreshFooter() {
        resetButton?.title = park.footerTitle
    }

    /// The full binding table the pure plans resolve owners against.
    private func currentBindings() -> [HotkeyAction: HotkeyBinding] {
        Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map {
            ($0, hotkeyStore.binding(for: $0))
        })
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
        for (section, button) in bulkButtons {
            let presentation = bulkPresentation(for: section)
            button.title = presentation.title
            button.toolTip = presentation.toolTip
        }
    }

    /// The bulk button's label and tooltip for one section's current
    /// state. One source for the two places that render it (the header
    /// build and the refresh), so a refreshed button can never disagree
    /// with a freshly built one.
    private func bulkPresentation(for section: ShortcutSection) -> (title: String, toolTip: String) {
        let actions = section.bulkActions ?? []
        let count = actions.count
        return sectionHasDisabled(actions)
            ? ("Enable all \(count)",
               "Restores parked combos; keys edited while disabled keep their edits")
            : ("Disable all \(count)",
               "Disable every slot key (parks the current combos; Enable all restores them)")
    }

    /// The one-line caption naming the five keys Quarters has no slot for.
    /// Derived from the same mapping the engine uses, so it cannot list a
    /// key that actually works (or miss one that does not).
    private func slotKeyCaption() -> String {
        let names = SlotKey.quartersInert.map { "“\($0.title)”" }
        let list: String
        switch names.count {
        case 0: list = ""
        case 1: list = names[0]
        case 2: list = "\(names[0]) and \(names[1])"
        default: list = names.dropLast().joined(separator: ", ") + ", and " + names.last!
        }
        return "Quarters has no slot for \(list); those \(names.count) keys do nothing while "
            + "Quarters is showing. Switch layouts from the Tiled menu."
    }

    /// The registration-failure sentences, shared by every notice composer.
    /// A skipped restore must not erase them: both truths compete for the
    /// one live-region line, and the notice keeps failures first.
    private func hotkeyFailureMessages() -> [String] {
        guard let failedActionsProvider else { return [] }
        return failedActionsProvider().map { action in
            MenuText.hotkeyFailureWarning(
                label: hotkeyStore.binding(for: action).label,
                title: action.title,
                recovery: action.registrationRecovery)
        }
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

    private func shortcutRow(for action: HotkeyAction) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12

        let label = NSTextField(labelWithString: action.title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        row.addArrangedSubview(label)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        let button = RecorderButton(action: action)
        button.target = self
        button.action = #selector(recorderClicked(_:))
        // The leading paragraph explains the contract, but a tooltip meets
        // the user at the control itself.
        button.toolTip = Self.recorderContract
        // Armed/cancelled states change only the button title; announce
        // both, so keyboard and VoiceOver users get the same state the
        // mouse path sees. Fires on arm (the monitor starts listening)
        // and on silent tab-away cancel (no decision, no visual trace).
        button.onArmed = { [weak self] armedAction in
            self?.announce(
                "Capturing a shortcut for \(armedAction.title): press a combo, or Esc to keep the old one.")
        }
        button.onSilentCancel = { [weak self] cancelledAction in
            self?.announce("\(cancelledAction.title) kept its old shortcut.")
        }
        recorderButtons[action] = button
        row.addArrangedSubview(button)
        return row
    }

    /// Section header row: a borderless chevron + title button (collapse
    /// only) plus, for the layout sections, a small Enable/Disable-all
    /// button with its scope in the title ("Enable all 6"). Two controls,
    /// two jobs; the header never pretends to be the bulk toggle.
    ///
    /// (Not a .disclosure bezel: that cell refuses to draw its title on
    /// current macOS: it renders a bare triangle no matter how the title
    /// is set, and never exposes it to accessibility. A borderless button
    /// with an SF Symbol chevron renders and reads reliably.)
    private func sectionHeader(for section: ShortcutSection) -> NSView {
        let collapsed = collapsedSections.contains(section)
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let header = NSButton(
            title: "\(section.title) (\(section.rowCount))",
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
        header.identifier = NSUserInterfaceItemIdentifier(section.rawValue)
        header.toolTip = collapsed
            ? "Show \(section.title) shortcuts"
            : "Hide \(section.title) shortcuts"
        row.addArrangedSubview(header)

        // Enable-all restores up to a whole section at once: name the
        // scope on the button so the consequence is visible before click.
        // Rounded bezel, not inline: beside the bold borderless header,
        // unbordered gray text reads disabled, but this is the section's
        // second live control, and it must look like one.
        if section.bulkActions != nil {
            let bulk = NSButton(
                title: bulkPresentation(for: section).title,
                target: self, action: #selector(sectionBulkToggled(_:)))
            bulk.bezelStyle = .rounded
            bulk.controlSize = .small
            bulk.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            bulk.identifier = NSUserInterfaceItemIdentifier("bulk-\(section.rawValue)")
            bulk.toolTip = bulkPresentation(for: section).toolTip
            bulkButtons[section] = bulk
            row.addArrangedSubview(bulk)
        }
        return row
    }

    /// True when any action in the section is currently disabled.
    private func sectionHasDisabled(_ actions: [HotkeyAction]) -> Bool {
        actions.contains { hotkeyStore.binding(for: $0).keyCode == nil }
    }

    /// Bulk toggle: Disable all parks current combos aside and disables the
    /// section; Enable all applies the section's pure restore plan. Parking
    /// is a settings concern, not the binding model, so `ShortcutPark` owns
    /// it. A key edited while disabled keeps its edit: the park is stale
    /// the moment the recorder commits, so blindly restoring it would
    /// silently destroy a deliberate configuration, the only silent
    /// data-loss path the tab would otherwise have.
    @objc private func sectionBulkToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              id.hasPrefix("bulk-"),
              let section = ShortcutSection(rawValue: String(id.dropFirst(5))),
              let actions = section.bulkActions
        else { return }
        if sectionHasDisabled(actions) {
            let plan = park.bulkRestorePlan(for: actions, current: currentBindings())
            for entry in plan.restored {
                hotkeyStore.set(entry.binding, for: entry.action)
            }
            for action in plan.clearedParks {
                park.clear(action, kind: .section)
            }
            let clashes = plan.clashes.map { clash in
                let names = clash.owners.map(\.title).joined(separator: ", ")
                return "\(clash.action.title) (\(names))"
            }
            let keptEdits = plan.keptEdits.map(\.action.title)
            // Registration runs before the rebuild so the fresh rows can
            // surface the keys that failed to register, not the pre-toggle
            // failure set. The bulk button that triggered this lives in
            // the old view, so focus is restored after.
            onHotkeysChange?()
            var messages: [String] = []
            if !clashes.isEmpty {
                messages.append("Not restored, the combo is taken: \(clashes.joined(separator: ", ")).")
            }
            if !keptEdits.isEmpty {
                let names = keptEdits.joined(separator: ", ")
                messages.append(
                    "\(names) \(keptEdits.count == 1 ? "was" : "were") edited while disabled; " +
                    "kept the new \(keptEdits.count == 1 ? "combo" : "combos").")
            }
            rebuildContent(
                restoringFocusTo: "bulk-\(section.rawValue)",
                result: messages.isEmpty ? nil : messages.joined(separator: " "))
        } else {
            for action in actions {
                let current = hotkeyStore.binding(for: action)
                if current.keyCode != nil {
                    park.park(current, for: action, kind: .section)
                }
                hotkeyStore.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: action)
            }
            // Registration first: the rebuilt rows read the fresh
            // failedActions, not the pre-toggle set.
            onHotkeysChange?()
            rebuildContent(restoringFocusTo: "bulk-\(section.rawValue)")
        }
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
    /// a shell. `result` joins the registration failures on the one notice
    /// line when a bulk toggle has something to report.
    @discardableResult
    private func rebuildContent(
        restoringFocusTo identifier: String? = nil,
        result: String? = nil
    ) -> NSView {
        reset()
        let view = build(size: buildSize, window: window)
        reload(notice: ShortcutNotice(failures: hotkeyFailureMessages(), result: result))
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

    /// Collapsible section state, persisted so the tab reopens as left.
    /// Raw values are stable strings; the pre-shared-key "quarters"/"sixths"
    /// entries simply no longer resolve now that one slot-key section
    /// replaces them.
    private var collapsedSections: Set<ShortcutSection> {
        get {
            let raw = defaults.stringArray(forKey: "collapsedShortcutSections") ?? []
            return Set(raw.compactMap(ShortcutSection.init(rawValue:)))
        }
        set {
            defaults.set(newValue.map(\.rawValue), forKey: "collapsedShortcutSections")
        }
    }

    @objc private func sectionToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let section = ShortcutSection(rawValue: id)
        else { return }
        // The chevron is a momentary button: state lives in
        // collapsedSections, and the rebuild draws the new chevron.
        var collapsed = collapsedSections
        if collapsed.contains(section) {
            collapsed.remove(section)
        } else {
            collapsed.insert(section)
        }
        collapsedSections = collapsed
        // The header that triggered this lives in the old view.
        rebuildContent(restoringFocusTo: section.rawValue)
    }

    @objc private func recorderClicked(_ sender: RecorderButton) {
        // Clicking the armed recorder again cancels: the click that would
        // otherwise re-arm it disarms it instead, so a stray click away
        // leaves nothing stuck mid-record.
        if sender.isRecording {
            sender.showBinding(hotkeyStore.binding(for: sender.hotkeyAction))
            renderFailures()
            return
        }
        // End any other in-progress record first: exactly one recorder is
        // armed at a time.
        for (action, button) in recorderButtons where button.isRecording && button !== sender {
            button.showBinding(hotkeyStore.binding(for: action))
        }
        sender.beginRecording { [weak self, weak sender] outcome in
            guard let self, let sender else { return }
            self.finishRecording(sender, outcome: outcome)
        }
    }

    private func finishRecording(_ button: RecorderButton, outcome: HotkeyRecorder.Outcome) {
        let action = button.hotkeyAction
        switch outcome {
        case .cancel:
            button.showBinding(hotkeyStore.binding(for: action))
            renderFailures()
        case .clear:
            // A stray ⌫ must not silently discard a tuned combo. A slot
            // key's combo is parked in the section namespace, which Enable
            // all restores; an app action disables alone (CONTEXT: Parked
            // combo), so parking it there would orphan the entry, and the
            // promise must not name a restore no path performs.
            let previous = hotkeyStore.binding(for: action)
            let isSlotKey = !HotkeyAction.appActions.contains(action)
            if previous.keyCode != nil, isSlotKey {
                park.park(previous, for: action, kind: .section)
            }
            hotkeyStore.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: action)
            button.showBinding(hotkeyStore.binding(for: action))
            let result: String? = previous.label.map { label in
                isSlotKey
                    ? "\(action.title) disabled: its old combo (\(label)) is parked; Enable all restores it."
                    : "\(action.title) disabled: re-record it to restore a combo."
            }
            // Re-register first: the failure list this notice renders is
            // recomputed by the reload, and the old one names the combo
            // the action just gave up.
            onHotkeysChange?()
            render(ShortcutNotice(failures: hotkeyFailureMessages(), result: result))
        case .binding(let candidate):
            switch hotkeyStore.apply(candidate, for: action) {
            case .applied:
                button.showBinding(candidate)
                onHotkeysChange?()
                // Re-registration may have failed for this action (the
                // combo is owned by another app): say so here, where the
                // combo was just recorded, instead of letting the menu be
                // the only witness. A clean registration clears a resolved
                // conflict without erasing a still-live failure elsewhere.
                renderFailures()
            case .duplicate(let actions):
                // Keep the old binding and say, in words, who owns the
                // combo: a shake alone left users retrying the same combo
                // forever. Announced to VoiceOver, not just shown.
                button.showBinding(hotkeyStore.binding(for: action))
                button.shake()
                let owners = actions.map(\.title).joined(separator: ", ")
                let message =
                    "\(candidate.label ?? "That combo") is already used by \(owners); " +
                    "\(action.title) kept its old shortcut."
                render(ShortcutNotice(failures: hotkeyFailureMessages(), conflict: message))
                NSLog("Tiled: %@", message)
            }
        }
        // The tab is deliberately not rebuilt here: the button that just
        // committed is the one the reader is looking at. The bulk labels
        // still have to follow the binding that changed.
        refreshBulkButtons()
    }

    /// VoiceOver announcement for recorder state changes (arm, silent
    /// cancel), permission transitions, and notice identity changes. Posted
    /// against the conflict line's view (the Shortcuts tab's live region).
    /// Silently skipped when the window is hidden: the system would drop it
    /// anyway, but the guard keeps the intent explicit. `onAnnouncement`
    /// receives the text first so a hermetic test can count identity changes.
    private func announce(_ message: String) {
        onAnnouncement?(message)
        guard window?.isVisible == true, let label = conflictLabel else { return }
        NSAccessibility.post(
            element: label,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The one live-region write. The notice's whole content is its
    /// identity, so a reload that recomputes the same failure leaves both
    /// the label and the announcement alone. Clearing is silent; the same
    /// text appearing later is a new identity and announces again.
    private func render(_ notice: ShortcutNotice?) {
        if notice != renderedNotice {
            renderedNotice = notice
            conflictLabel?.stringValue = notice?.text ?? ""
            conflictLabel?.isHidden = notice == nil
        }
        guard let notice else {
            announcedNotice = nil
            return
        }
        guard notice != announcedNotice else { return }
        announcedNotice = notice
        announce(notice.text)
    }

    /// Recomputes the failure-only notice. Every caller that resolved a
    /// conflict or cancelled a recording uses this, so a persistent
    /// registration failure stays visible instead of being cleared by a
    /// transient result.
    private func renderFailures() {
        render(ShortcutNotice(failures: hotkeyFailureMessages()))
    }

    @objc private func grantPermissionTapped(_ sender: NSButton) {
        onOpenAccessibilitySettings?()
    }

    @objc private func resetShortcuts(_ sender: NSButton) {
        // The footer is one two-state control, not a hidden mode: while a
        // readable reset snapshot exists the same button says Restore
        // Previous Shortcuts and this route restores it. Reset is therefore
        // reachable only with no snapshot, so a second reset can never
        // overwrite the first one (T11).
        if park.anyResetBackup() {
            restoreResetBackup()
        } else {
            confirmAndReset()
        }
    }

    /// Resets everything to factory defaults, keeping the whole previous
    /// snapshot one press away. `resetShortcuts` routes to that restore
    /// whenever `park.anyResetBackup()` is true, so this method only runs
    /// with no snapshot and the promise can always say the combos are kept.
    private func confirmAndReset() {
        // The promise is the outcome's contract: the reset keeps every
        // current combo, and the footer's next title names the way back.
        let promise = "Your current combos are kept; use Restore Previous Shortcuts to get them back."
        let confirmed: Bool
        if let confirmReset {
            confirmed = confirmReset(promise)
        } else {
            let alert = NSAlert()
            alert.messageText = "Reset all \(HotkeyAction.allCases.count) shortcuts to defaults?"
            alert.informativeText = promise
            alert.addButton(withTitle: "Reset Shortcuts")
            alert.addButton(withTitle: "Cancel")
            confirmed = alert.runModal() == .alertFirstButtonReturn
        }
        guard confirmed else { return }
        for action in HotkeyAction.allCases {
            park.park(hotkeyStore.binding(for: action), for: action, kind: .resetBackup)
        }
        hotkeyStore.resetAll()
        onHotkeysChange?()
        reload()
    }

    /// Restores the combos parked by the last reset from one pure snapshot
    /// plan: an exact snapshot, including disabled actions. The snapshot is
    /// one prior state, not a sequence of independent recordings, so a pair
    /// that swapped their combos lands as a pair; only a combo owned by an
    /// action *outside* the snapshot is a clash. A clash-reported entry
    /// stays in the backup (the section park's rule) so a later press, once
    /// the combo is free, brings it back; only applied entries are cleared.
    private func restoreResetBackup() {
        let plan = park.snapshotRestorePlan(current: currentBindings())
        for (action, binding) in plan.accepted {
            hotkeyStore.set(binding, for: action)
            park.clear(action, kind: .resetBackup)
        }
        onHotkeysChange?()
        let result: String?
        if plan.skipped.isEmpty {
            result = nil
        } else {
            let names = plan.skipped
                .sorted { $0.action.title < $1.action.title }
                .map {
                    "\($0.action.title) (taken by \($0.owners.map(\.title).joined(separator: ", ")))"
                }
            result = "Not restored: \(names.joined(separator: ", "))."
        }
        // Registration failures outrank the restore result in the notice
        // and stay on the line beside it, so a skipped restore can never
        // erase the failure that the reload just re-read.
        reload(notice: ShortcutNotice(
            failures: hotkeyFailureMessages(), result: result))
    }
}
