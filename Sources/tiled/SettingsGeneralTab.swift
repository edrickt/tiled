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
    /// Reopens the Welcome tab (the General tab's "Show tiled Guide"
    /// button). The shell owns tab switching.
    var onShowGuide: (() -> Void)?
    /// Live probe of the Settings fallback hotkey, so the hide-icon
    /// confirm can name a recovery that is actually registered — never a
    /// dead combo while removing the last visible handle to the app.
    var isSettingsHotkeyRegisteredProvider: (() -> Bool)?
    /// Live Accessibility trust probe, injected by the shell: with the
    /// menu-bar icon hidden this tab is the app's only visible surface,
    /// so permission loss must be legible here.
    var isTrustedProvider: (() -> Bool)?
    /// Opens the Accessibility permission pane.
    var onOpenAccessibilitySettings: (() -> Void)?

    private var launchAtLoginCheckbox: NSButton!
    private var hideIconCheckbox: NSButton!
    private var permissionRow: NSStackView!
    private var loginFailureLabel: NSTextField!
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
    /// accessibility text grows it further — without scrolling the tail
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
            "tiled can't see or move windows — Accessibility permission is off.")
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
        // single-line width. Activated after the row joins the stack —
        // constraints need a common ancestor.
        permissionRow.trailingAnchor.constraint(
            equalTo: stack.trailingAnchor, constant: -24).isActive = true

        launchAtLoginCheckbox = NSButton(
            checkboxWithTitle: "Launch at login",
            target: self, action: #selector(launchAtLoginToggled(_:)))
        launchAtLoginCheckbox.toolTip = "Start tiled automatically when you log in."
        stack.addArrangedSubview(launchAtLoginCheckbox)

        // Inline failure explanation: when SMAppService throws (e.g. a
        // raw `swift run` binary), the checkbox reverts — this label says
        // why, so the toggle never silently "doesn't work".
        loginFailureLabel = NSTextField(wrappingLabelWithString: "")
        loginFailureLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        loginFailureLabel.textColor = .secondaryLabelColor
        loginFailureLabel.isHidden = true
        stack.addArrangedSubview(loginFailureLabel)

        hideIconCheckbox = NSButton(
            checkboxWithTitle: "Hide menu bar icon",
            target: self, action: #selector(hideIconToggled(_:)))
        hideIconCheckbox.toolTip = "The icon disappears immediately; press \u{2303}\u{2325}\u{21E7}\u{2318}, to get back."
        stack.addArrangedSubview(hideIconCheckbox)

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
            title: "Show tiled Guide", target: self, action: #selector(showGuideTapped(_:)))
        guideButton.bezelStyle = .rounded
        guideButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        guideRow.addArrangedSubview(guideButton)
        stack.addArrangedSubview(guideRow)
        // Same cap as the permission row: button holds the inset.
        guideText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        guideRow.trailingAnchor.constraint(
            equalTo: stack.trailingAnchor, constant: -24).isActive = true

        let hint = NSTextField(wrappingLabelWithString:
            "When the icon is hidden, press \u{2303}\u{2325}\u{21E7}\u{2318}, anywhere " +
            "or quit and reopen tiled to get back here — Settings opens automatically. " +
            "Hiding asks first, so this never happens by accident.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(hint)

        return view
    }

    func loadValues() {
        launchAtLoginCheckbox?.state = currentLaunchAtLogin ? .on : .off
        hideIconCheckbox?.state = settings.hideMenuBarIcon ? .on : .off
        refreshPermissionState()
    }

    /// Re-probes trust so the permission row tracks reality without
    /// waiting for the next show(); the shell's permission poll calls
    /// this when trust may have flipped.
    func refreshPermissionState() {
        let trusted = isTrustedProvider?() ?? true
        permissionRow?.isHidden = trusted
        // Only a visible-state flip is announced; the first probe just
        // sets the baseline. Post against the row itself — announcements
        // for non-visible elements are dropped by the system anyway.
        if let previous = lastKnownTrusted, previous != trusted, let row = permissionRow {
            NSAccessibility.post(
                element: row,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: trusted
                        ? "Accessibility permission granted — tiled can see and move windows now."
                        : "tiled can't see or move windows — Accessibility permission is off.",
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
        lastKnownTrusted = trusted
    }

    @objc private func grantPermissionTapped(_ sender: NSButton) {
        onOpenAccessibilitySettings?()
    }

    private var currentLaunchAtLogin: Bool {
        (try? SMAppService.mainApp.status) == .enabled
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
            NSLog("tiled: Launch at Login %@ failed: %@", enable ? "enable" : "disable", "\(error)")
            sender.state = enable ? .off : .on
            loginFailureLabel.stringValue =
                "Launch at login couldn't be \(enable ? "enabled" : "disabled") — " +
                "tiled must be running as an installed app bundle for it to work."
            loginFailureLabel.isHidden = false
        }
    }

    @objc private func hideIconToggled(_ sender: NSButton) {
        let hidden = sender.state == .on
        if hidden {
            // Hiding removes the only visible handle to the app (including
            // Quit), so confirm with a recovery path that is actually
            // registered: if the Settings fallback hotkey lost to another
            // app, the dialog must not promise ⌃⌥⇧⌘, — it names the
            // relaunch path instead.
            let settingsHotkeyAlive = isSettingsHotkeyRegisteredProvider?() ?? true
            let recovery = settingsHotkeyAlive
                ? "To get back, press \u{2303}\u{2325}\u{21E7}\u{2318}, anywhere "
                    + "or quit and reopen tiled — Settings opens automatically."
                : "To get back, quit and reopen tiled — Settings opens automatically. "
                    + "(The \u{2303}\u{2325}\u{21E7}\u{2318}, fallback is "
                    + "already used by another app.)"
            let alert = NSAlert()
            alert.messageText = "Hide the menu bar icon?"
            alert.informativeText =
                "The icon disappears immediately. \(recovery)"
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
