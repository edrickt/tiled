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

    private var launchAtLoginCheckbox: NSButton!
    private var hideIconCheckbox: NSButton!

    /// First control, for the shell's initial-focus placement.
    var firstControl: NSButton? { launchAtLoginCheckbox }

    init(settings: AppSettings) {
        self.settings = settings
    }

    func build(size: NSSize) -> NSView {
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

        let guideLabel = NSTextField(labelWithString: "First-run guide")
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
            title: "Show tiled Guide", target: self, action: #selector(showGuideTapped(_:)))
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

    func loadValues() {
        launchAtLoginCheckbox?.state = currentLaunchAtLogin ? .on : .off
        hideIconCheckbox?.state = settings.hideMenuBarIcon ? .on : .off
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
