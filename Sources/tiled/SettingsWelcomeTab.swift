import AppKit

/// The first-run Welcome tab: one demonstration, not seventeen combos.
/// Dismissing removes the tab for this launch (persisted); it stays
/// re-openable from General, so the teaching moment is never lost; the
/// tab is one-time per launch, not one-time forever.
final class WelcomeTab: NSObject {
    private let hotkeyStore: HotkeyStore
    /// Fired by the dismiss button. The shell removes the tab, lands on
    /// General, and persists the dismissal.
    var onDismiss: (() -> Void)?
    /// Live Accessibility trust probe: the three steps below are exactly
    /// what an untrusted install cannot do, so the warning leads the tab.
    var isTrustedProvider: (() -> Bool)?
    /// Actions whose global hotkey lost registration. The guide must
    /// teach the menu path instead of a stored combo that does nothing;
    /// nil means no hotkey service ran (treat as no failures).
    var failedActionsProvider: (() -> [HotkeyAction])?
    /// Opens the Accessibility permission pane.
    var onOpenAccessibilitySettings: (() -> Void)?
    /// Test seam: receives the permission-flip sentence the row announces.
    var onAnnouncement: ((String) -> Void)?
    /// Baseline for the flip announcement; nil until the first probe.
    private var lastKnownTrusted: Bool?

    /// The dismiss button of the last built view, for initial-focus
    /// placement on open.
    private(set) var dismissButton: NSButton?
    private var permissionRow: NSStackView!
    private var stepsField: NSTextField?
    private var behaviorNoteField: NSTextField?

    init(hotkeyStore: HotkeyStore) {
        self.hotkeyStore = hotkeyStore
    }

    /// Builds the tab inside a scroll view (same reasoning as General:
    /// the window's minimum size and larger accessibility text both
    /// exceed this content's height at times).
    func build(size: NSSize) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: view.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let stack = TopAnchoredStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            // No bottom constraint (see TopAnchoredStackView).
        ])
        view.addSubview(scroll)

        let title = NSTextField(labelWithString: "Tile your first window")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        stack.addArrangedSubview(title)

        // Permission warning, before the steps: an untrusted install
        // cannot do step 1 ("click any window" works, but Tiled sees no
        // focused window), so lead with the fix, not a broken promise.
        permissionRow = NSStackView()
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 12
        permissionRow.alignment = .firstBaseline
        let warningText = NSTextField(wrappingLabelWithString:
            "Tiled can't see or move windows: Accessibility permission is off.")
        warningText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warningText.textColor = .labelColor
        // Label wraps, button never shrinks, and the row is capped to
        // the inset width below, so the button holds the 24pt inset at
        // any window width (see GeneralTab for the same pattern).
        warningText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        permissionRow.addArrangedSubview(warningText)
        let grantButton = NSButton(
            title: "Open Accessibility Settings", target: self, action: #selector(grantPermissionTapped(_:)))
        grantButton.bezelStyle = .rounded
        grantButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        permissionRow.addArrangedSubview(grantButton)
        permissionRow.isHidden = isTrustedProvider?() ?? true
        stack.addArrangedSubview(permissionRow)
        permissionRow.trailingAnchor.constraint(
            equalTo: stack.trailingAnchor, constant: -24).isActive = true

        let steps = NSTextField(wrappingLabelWithString: "")
        stepsField = steps
        refreshShortcutInstructions()
        steps.font = .systemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(steps)


        // Spatial previews, side by side: quarters beside sixths, so
        // "three columns instead of two" is a comparison the eye makes
        // instead of a sentence the reader must imagine. Drawn from the
        // same TileCell sets as the layout engine, so they cannot disagree.
        // Tertiary (not quaternary) track: at this small size the
        // quaternary fill renders near-invisible in Dark Mode.
        let previews = NSStackView()
        previews.orientation = .horizontal
        previews.spacing = 16
        previews.alignment = .top
        stack.addArrangedSubview(previews)

        let previewColumn = NSStackView()
        previewColumn.orientation = .vertical
        previewColumn.spacing = 4
        previews.addArrangedSubview(previewColumn)
        let preview = SlotPreviewView(
            highlighted: [.topLeft], trackColor: .tertiaryLabelColor,
            displayColumns: 2)
        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: 160),
            preview.heightAnchor.constraint(equalToConstant: 100),
        ])
        // A bare NSView is not an accessibility element, so without the
        // next two lines the caption below would never reach VoiceOver.
        preview.setAccessibilityElement(true)
        preview.setAccessibilityRole(.image)
        preview.setAccessibilityLabel("Preview: Top Left covers the top-left quarter")
        previewColumn.addArrangedSubview(preview)
        let quartersCaption = NSTextField(labelWithString: "Quarters: two columns")
        quartersCaption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        quartersCaption.textColor = .secondaryLabelColor
        // Center under the 160pt preview: the column stretches past it,
        // and a leading-aligned label would hang off the preview's edge.
        quartersCaption.alignment = .center
        previewColumn.addArrangedSubview(quartersCaption)
        quartersCaption.widthAnchor.constraint(equalToConstant: 160).isActive = true

        // The middle third is lit because it's the slot that only exists
        // in sixths.
        let sixthsColumn = NSStackView()
        sixthsColumn.orientation = .vertical
        sixthsColumn.spacing = 4
        previews.addArrangedSubview(sixthsColumn)
        let sixthsPreview = SlotPreviewView(
            highlighted: [.sixthMiddle], trackColor: .tertiaryLabelColor,
            displayColumns: 3)
        sixthsPreview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sixthsPreview.widthAnchor.constraint(equalToConstant: 160),
            sixthsPreview.heightAnchor.constraint(equalToConstant: 100),
        ])
        sixthsPreview.setAccessibilityElement(true)
        sixthsPreview.setAccessibilityRole(.image)
        sixthsPreview.setAccessibilityLabel(
            "Preview: Sixths split the screen into three columns; the middle third covers the center column")
        sixthsColumn.addArrangedSubview(sixthsPreview)
        let sixthsCaption = NSTextField(labelWithString: "Sixths: three columns")
        sixthsCaption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sixthsCaption.textColor = .secondaryLabelColor
        sixthsCaption.alignment = .center
        sixthsColumn.addArrangedSubview(sixthsCaption)
        sixthsCaption.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let sixthsLabel = NSTextField(wrappingLabelWithString:
            "Sixths work the same way: three columns instead of two. " +
            "Find your current shortcuts in Settings → Shortcuts.")
        sixthsLabel.textColor = .secondaryLabelColor
        sixthsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(sixthsLabel)

        // The two behaviors that look like bugs on first encounter, stated
        // where the user can meet them before they happen: drag-out's
        // snap-back ("my window snapped back!") and Expand's
        // cover-don't-release semantics ("did it break my layout?"). One
        // sentence each; the README holds the full rules. The expand combo
        // is read live: a remapped binding teaches itself, never ⌥⇧⏎.
        behaviorNoteField = NSTextField(wrappingLabelWithString: "")
        let behaviorNote = behaviorNoteField!
        refreshBehaviorNote(failedActions: failedActions)
        behaviorNote.textColor = .secondaryLabelColor
        behaviorNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(behaviorNote)

        let dismiss = NSButton(
            title: "Got it, show General next time",
            target: self, action: #selector(dismissTapped(_:)))
        dismiss.bezelStyle = .rounded
        dismissButton = dismiss
        stack.addArrangedSubview(dismiss)
        // Re-entry: Welcome removes itself per launch, but a persistent
        // menu-bar item reopens it (see showWelcomeAgain). One-time
        // moment, permanently reachable.
        let revisit = NSTextField(wrappingLabelWithString:
            "You can reopen this guide anytime from the menu bar menu → Tiled Guide.")
        revisit.textColor = .secondaryLabelColor
        revisit.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(revisit)

        return view
    }

    @objc private func dismissTapped(_ sender: NSButton) {
        onDismiss?()
    }

    /// The guide may already be built when Shortcuts changes a binding.
    /// Re-read it instead of keeping first-launch instructions indefinitely.
    func refreshShortcutInstructions() {
        let failed = failedActions
        let topLeft = hotkeyStore.registeredLabel(
            for: .slotKey(.topLeft), failedActions: failed)
        if let topLeft {
            stepsField?.stringValue =
                "1. Click any window to focus it.\n" +
                "2. Press \(topLeft) to tile it into the top-left slot.\n" +
                "3. Press it again; the window stays in its slot.\n" +
                "Every slot is also in the menu bar → Tile Focused Window."
        } else if failed.contains(.slotKey(.topLeft)) {
            // The stored label is not a promise: another app can own the
            // combo, so the keypress does nothing. Teach the menu path and
            // name the failure instead of printing the dead combo.
            stepsField?.stringValue = topLeftInstructions(step3:
                "3. Choose it again; the window stays in its slot.\n" +
                "Top Left's shortcut couldn't be registered; use the menu bar instead.")
        } else {
            stepsField?.stringValue = topLeftInstructions(step3:
                "3. Set a shortcut in Settings → Shortcuts.\n" +
                "Top Left's shortcut is disabled.")
        }
        refreshBehaviorNote(failedActions: failed)
    }

    /// The menu route to Top Left, shared by the disabled and failed
    /// registration paths: both must teach the live row, never a combo.
    /// The same key means the matching position in whichever layout is
    /// showing; changing layout is its own menu row.
    private func topLeftInstructions(step3: String) -> String {
        "1. Click any window to focus it.\n" +
        "2. Menu bar → Tile Focused Window → Top Left.\n" +
        "   To change layouts, choose Switch to Sixths or Switch to Quarters.\n" +
        step3
    }

    /// Rewrites the behavior note from the store, so a remapped expand or
    /// switch combo teaches itself instead of the stale default. A disabled
    /// or unregistered combo is not a shortcut the user can press; the
    /// menu row is the live path, so the note teaches that instead.
    private func refreshBehaviorNote(failedActions: [HotkeyAction]) {
        let expand = hotkeyStore.registeredLabel(
            for: .expand, failedActions: failedActions)
        let expandSentence: String
        if let expand {
            expandSentence =
                "\(expand) expands a window without releasing its slot; press it again to return."
        } else {
            expandSentence =
                "Menu bar → Expand to Fill Screen expands a window without releasing its slot; " +
                "the same row returns it."
        }
        let switchLayout = hotkeyStore.registeredLabel(
            for: .switchLayout, failedActions: failedActions)
        let switchSentence: String
        if let switchLayout {
            switchSentence =
                "\(switchLayout) switches the canvas to the other layout and untiles every window; "
                + "undo puts them back."
        } else {
            switchSentence =
                "Menu bar → Switch to Sixths (or Switch to Quarters) switches the canvas's layout "
                + "and untiles every window; undo puts them back."
        }
        behaviorNoteField?.stringValue =
            "Drag a tiled window far and it comes untiled where you drop it; " +
            "a short drag snaps back into its tile. " + expandSentence + " " + switchSentence
    }

    /// Actions whose global hotkey lost registration. A nil provider means
    /// no hotkey service ran, so no failure is known; the stored binding is
    /// still taught until the service reports otherwise.
    private var failedActions: [HotkeyAction] {
        failedActionsProvider?() ?? []
    }

    /// Re-probes trust for an already-built Welcome view; the shell's
    /// permission poll calls this when trust may have flipped while the
    /// window sits open. A flip is announced, not a silent layout jump,
    /// matching the General and Shortcuts tabs' rows.
    func refreshPermissionState() {
        let trusted = isTrustedProvider?() ?? true
        permissionRow?.isHidden = trusted
        if let previous = lastKnownTrusted, previous != trusted {
            let sentence = trusted
                ? "Accessibility permission granted; tiled can see and move windows now."
                : "Tiled can't see and move windows: Accessibility permission is off."
            onAnnouncement?(sentence)
            if let row = permissionRow {
                NSAccessibility.post(
                    element: row,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: sentence,
                        .priority: NSAccessibilityPriorityLevel.high.rawValue,
                    ])
            }
        }
        lastKnownTrusted = trusted
    }

    @objc private func grantPermissionTapped(_ sender: NSButton) {
        onOpenAccessibilitySettings?()
    }
}
