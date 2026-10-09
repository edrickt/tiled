import AppKit
import ServiceManagement

/// The General tab: two checkboxes plus the guide re-entry.
///
/// Owns its controls and their actions; the shell reads `firstControl`
/// for initial-focus placement and refreshes values via `loadValues`.
/// `onHideIconChange` fires when the toggle commits so the delegate can
/// remove/restore the status item immediately.
final class GeneralTab: NSObject {
    private let settings: AppSettings
    var onHideIconChange: ((Bool) -> Void)?
    /// Fires when the tile gap commits, so the delegate can re-place every
    /// tiled window under the new inset immediately.
    var onGapChange: ((Double) -> Void)?
    /// Reopens the Welcome tab (the General tab's "Show Tiled Guide"
    /// button). The shell owns tab switching.
    var onShowGuide: (() -> Void)?
    /// The Open Settings shortcut's live state, so the hide-icon confirm
    /// and this checkbox's standing hint name a recovery that actually
    /// works — the current binding's real combo, or relaunch-only — never
    /// a dead combo while removing the last visible handle to the app.
    var settingsHotkeyStateProvider: (() -> SettingsHotkeyState)?
    /// Live Accessibility trust probe, injected by the shell: with the
    /// menu-bar icon hidden this tab is the app's only visible surface,
    /// so permission loss must be legible here.
    var isTrustedProvider: (() -> Bool)?
    /// Opens the Accessibility permission pane.
    var onOpenAccessibilitySettings: (() -> Void)?

    private var launchAtLoginCheckbox: NSButton!
    private var hideIconCheckbox: NSButton!
    private var gapStepper: NSStepper!
    private var gapValueLabel: NSTextField!
    private var permissionRow: NSStackView!
    private var loginFailureLabel: NSTextField!
    /// The hide-icon recovery hint; stored so `loadValues` can re-render
    /// it when the Open Settings binding changed while the window is open.
    private var hideIconHintLabel: NSTextField!
    /// Last probed trust state, so a visible permission-row flip can be
    /// announced instead of being a silent layout jump.
    private var lastKnownTrusted: Bool?

    /// First control, for the shell's initial-focus placement.
    var firstControl: NSButton? { launchAtLoginCheckbox }

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Builds the tab inside a scroll view: the window's own minimum
    /// size (400×300) is smaller than this content, and larger
    /// accessibility text grows it further; without scrolling the tail
    /// clips silently.
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
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            // No bottom constraint: a bottom pin (even >=) forces the
            // stack to stretch to the viewport and NSStackView's
            // gravityAreas pins the last views to the bottom edge. The
            // flipped document view keeps short content at the top.
        ])
        view.addSubview(scroll)

        // Permission warning: first in the stack so an untrusted install
        // leads with the reason every hotkey press does nothing. Hidden
        // when trusted (loadValues toggles it).
        permissionRow = NSStackView()
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 12
        permissionRow.alignment = .firstBaseline
        let warningText = NSTextField(wrappingLabelWithString:
            "Tiled can't see or move windows: Accessibility permission is off.")
        warningText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warningText.textColor = .labelColor
        // The label wraps; the button never shrinks. Without this the
        // row's single-line intrinsic width overflows the inset area and
        // shoves the button against the window edge.
        warningText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        permissionRow.addArrangedSubview(warningText)
        let grantButton = NSButton(
            title: "Open Accessibility Settings", target: self, action: #selector(grantPermissionTapped(_:)))
        grantButton.bezelStyle = .rounded
        grantButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        permissionRow.addArrangedSubview(grantButton)
        permissionRow.isHidden = true
        stack.addArrangedSubview(permissionRow)
        // Cap the row to the inset content width (leading comes from the
        // stack's .leading alignment): the button holds the 24pt inset at
        // any window width instead of riding on the label's intrinsic
        // single-line width. Activated after the row joins the stack, since
        // constraints need a common ancestor.
        permissionRow.trailingAnchor.constraint(
            equalTo: stack.trailingAnchor, constant: -24).isActive = true

        launchAtLoginCheckbox = NSButton(
            checkboxWithTitle: "Launch at login",
            target: self, action: #selector(launchAtLoginToggled(_:)))
        launchAtLoginCheckbox.toolTip = "Start Tiled automatically when you log in."
        stack.addArrangedSubview(launchAtLoginCheckbox)

        // Inline failure explanation: when SMAppService throws (e.g. a
        // raw `swift run` binary), the checkbox reverts; this label says
        // why, so the toggle never silently "doesn't work".
        loginFailureLabel = NSTextField(wrappingLabelWithString: "")
        loginFailureLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        loginFailureLabel.textColor = .secondaryLabelColor
        loginFailureLabel.isHidden = true
        stack.addArrangedSubview(loginFailureLabel)

        hideIconCheckbox = NSButton(
            checkboxWithTitle: "Hide menu bar icon",
            target: self, action: #selector(hideIconToggled(_:)))
        stack.addArrangedSubview(hideIconCheckbox)

        // Recovery consequence sits with its checkbox, not below the
        // guide: proximity groups it with the control it explains,
        // instead of orphaning it a divider and a section away. The copy
        // is decided from the Open Settings shortcut's live state, so it
        // names the recovery that actually works (see
        // `SettingsHotkeyState`), never a hard-coded combo.
        hideIconHintLabel = NSTextField(wrappingLabelWithString: "")
        hideIconHintLabel.textColor = .secondaryLabelColor
        hideIconHintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(hideIconHintLabel)
        refreshHideIconRecoveryCopy()

        let gapHeading = NSTextField(labelWithString: "Tile gap")
        gapHeading.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        gapHeading.textColor = .secondaryLabelColor
        stack.addArrangedSubview(gapHeading)

        let gapRow = NSStackView()
        gapRow.orientation = .horizontal
        gapRow.spacing = 8
        gapRow.alignment = .firstBaseline
        let gapText = NSTextField(wrappingLabelWithString:
            "Space left around tiled windows, in points.")
        gapText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        gapText.textColor = .secondaryLabelColor
        gapText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        gapRow.addArrangedSubview(gapText)

        gapValueLabel = NSTextField(labelWithString: "")
        gapValueLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        gapValueLabel.setContentHuggingPriority(.required, for: .horizontal)
        gapValueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        gapRow.addArrangedSubview(gapValueLabel)

        gapStepper = NSStepper()
        gapStepper.minValue = AppSettings.tileGapRange.lowerBound
        gapStepper.maxValue = AppSettings.tileGapRange.upperBound
        gapStepper.increment = 1
        gapStepper.valueWraps = false
        gapStepper.target = self
        gapStepper.action = #selector(gapChanged(_:))
        gapStepper.toolTip = "Points of space between tiled windows "
            + "(\(Int(AppSettings.tileGapRange.lowerBound))–"
            + "\(Int(AppSettings.tileGapRange.upperBound)))."
        gapStepper.setAccessibilityLabel("Tile gap")
        gapRow.addArrangedSubview(gapStepper)
        stack.addArrangedSubview(gapRow)
        // Same cap as the permission and guide rows: the trailing control
        // holds the 24pt inset at any window width instead of riding on
        // the label's intrinsic single-line width.
        gapRow.trailingAnchor.constraint(
            equalTo: stack.trailingAnchor, constant: -24).isActive = true

        let divider = NSBox()
        divider.boxType = .separator
        stack.addArrangedSubview(divider)

        let guideLabel = NSTextField(labelWithString: "First-run guide")
        guideLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        guideLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(guideLabel)

        let guideRow = NSStackView()
        guideRow.orientation = .horizontal
        guideRow.spacing = 12
        let guideText = NSTextField(wrappingLabelWithString:
            "Replay the three-step introduction with the tile preview.")
        guideText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        guideText.textColor = .secondaryLabelColor
        guideRow.addArrangedSubview(guideText)
        let guideButton = NSButton(
            title: "Show Tiled Guide", target: self, action: #selector(showGuideTapped(_:)))
        guideButton.bezelStyle = .rounded
        guideButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        guideRow.addArrangedSubview(guideButton)
        stack.addArrangedSubview(guideRow)
        // Same cap as the permission row: button holds the inset.
        guideText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        guideRow.trailingAnchor.constraint(
            equalTo: stack.trailingAnchor, constant: -24).isActive = true

        return view
    }

    func loadValues() {
        launchAtLoginCheckbox?.state = currentLaunchAtLogin ? .on : .off
        hideIconCheckbox?.state = settings.hideMenuBarIcon ? .on : .off
        gapStepper?.doubleValue = settings.tileGap
        refreshGapValueLabel()
        refreshPermissionState()
        // The binding may have changed in the Shortcuts tab since this
        // copy was rendered; the hint must show the current binding.
        refreshHideIconRecoveryCopy()
    }

    /// Re-renders the hide-icon recovery copy (hint and tooltip) from
    /// the Open Settings shortcut's live state; the confirm reads the
    /// same state at toggle time.
    private func refreshHideIconRecoveryCopy() {
        let state = settingsHotkeyStateProvider?() ?? .healthyDefault
        hideIconCheckbox?.toolTip = state.toolTip
        hideIconHintLabel?.stringValue = state.hint
    }

    /// The stepper's value is already clamped on write; read it back so the
    /// label always matches what geometry will receive.
    private func refreshGapValueLabel() {
        // The stepper yields integers, but a hand-edited defaults value may
        // not: round rather than truncate so the label never reads a value
        // the geometry won't receive.
        gapValueLabel?.stringValue = "\(Int(settings.tileGap.rounded())) pt"
    }

    @objc private func gapChanged(_ sender: NSStepper) {
        settings.tileGap = sender.doubleValue
        sender.doubleValue = settings.tileGap
        refreshGapValueLabel()
        onGapChange?(settings.tileGap)
    }

    /// Re-probes trust so the permission row tracks reality without
    /// waiting for the next show(); the shell's permission poll calls
    /// this when trust may have flipped.
    func refreshPermissionState() {
        let trusted = isTrustedProvider?() ?? true
        permissionRow?.isHidden = trusted
        // Only a visible-state flip is announced; the first probe just
        // sets the baseline. Post against the row itself; announcements
        // for non-visible elements are dropped by the system anyway.
        if let previous = lastKnownTrusted, previous != trusted, let row = permissionRow {
            NSAccessibility.post(
                element: row,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: trusted
                        ? "Accessibility permission granted; tiled can see and move windows now."
                        : "Tiled can't see or move windows: Accessibility permission is off.",
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
        lastKnownTrusted = trusted
    }

    @objc private func grantPermissionTapped(_ sender: NSButton) {
        onOpenAccessibilitySettings?()
    }

    private var currentLaunchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func showGuideTapped(_ sender: NSButton) {
        onShowGuide?()
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        let enable = sender.state == .on
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginFailureLabel.isHidden = true
        } catch {
            // SMAppService can fail outside a properly bundled app (e.g. a
            // raw `swift run` binary); say why inline, not only in the log.
            NSLog("Tiled: Launch at Login %@ failed: %@", enable ? "enable" : "disable", "\(error)")
            sender.state = enable ? .off : .on
            loginFailureLabel.stringValue =
                "Launch at login couldn't be \(enable ? "enabled" : "disabled"): " +
                "Tiled must be running as an installed app bundle for it to work."
            loginFailureLabel.isHidden = false
        }
    }

    @objc private func hideIconToggled(_ sender: NSButton) {
        let hidden = sender.state == .on
        if hidden {
            // Hiding removes the only visible handle to the app (including
            // Quit), so confirm with a recovery path that actually works:
            // the state's copy names the Open Settings shortcut as
            // currently bound — with its real label — or the relaunch-only
            // recovery with the reason no combo exists, never a hard-coded
            // or dead combo.
            let state = settingsHotkeyStateProvider?() ?? .healthyDefault
            let alert = NSAlert()
            alert.messageText = "Hide the menu bar icon?"
            alert.informativeText =
                "The icon disappears immediately. \(state.confirmRecovery)"
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
