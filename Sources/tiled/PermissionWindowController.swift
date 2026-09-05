import AppKit

/// Launch permission window: explains why tiled needs Accessibility and
/// hands the user one button into the System Settings pane. Replaces the
/// automatic system prompt — the request arrives with the product's own
/// explanation, and granting is an explicit click, never a surprise
/// dialog the user can't attribute.
///
/// AppDelegate shows it at launch while untrusted and closes it from the
/// permission poll the moment trust arrives; the status menu keeps its
/// "Open System Settings" row as re-entry after a dismissal.
final class PermissionWindowController: NSWindowController {
    /// Opens the Accessibility pane. Injected so this controller stays
    /// free of URL/system knowledge (and tests can observe the click).
    var onOpenSettings: (() -> Void)?

    /// The one action the window offers, exposed for initial focus and
    /// for tests to click.
    let openSettingsButton: NSButton

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Accessibility Permission"
        window.center()
        window.isReleasedWhenClosed = false

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 12
        container.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        container.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(
                equalTo: window.contentView!.leadingAnchor),
            container.trailingAnchor.constraint(
                equalTo: window.contentView!.trailingAnchor),
            container.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            container.bottomAnchor.constraint(
                equalTo: window.contentView!.bottomAnchor),
        ])

        let headline = NSTextField(labelWithString: "tiled needs Accessibility permission")
        headline.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        container.addArrangedSubview(headline)

        let body = NSTextField(wrappingLabelWithString:
            "Tile, drag-resize, and track windows across apps — that is the whole " +
            "product, and macOS only allows it with Accessibility permission. " +
            "tiled reads window positions and sizes only, never window contents.")
        body.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        body.textColor = .secondaryLabelColor
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(body)

        let button = NSButton(title: "Open Accessibility Settings", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        container.addArrangedSubview(button)
        openSettingsButton = button

        super.init(window: window)
        // Target needs self, so it is wired after super.init.
        button.target = self
        button.action = #selector(openSettingsTapped(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the window and pulls the accessory app forward: this window
    /// is the launch's whole point while untrusted, so it must arrive
    /// front and center, not behind the user's work.
    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activateAsFrontmost()
        window?.makeFirstResponder(openSettingsButton)
    }

    @objc private func openSettingsTapped(_ sender: NSButton) {
        onOpenSettings?()
    }
}
