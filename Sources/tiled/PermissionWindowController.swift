import AppKit

/// Launch permission window: explains why Tiled needs Accessibility and
/// hands the user one button into the System Settings pane. Replaces the
/// automatic system prompt: the request arrives with the product's own
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

    /// The three grant steps, exposed so tests can pin the promise that
    /// the window closes itself once trust arrives.
    let stepsField: NSTextField

    /// The ask headline, exposed so tests can pin the display scale:
    /// this window's whole job is the ask, so it carries the product's
    /// strongest title voice, not the small semibold of a settings row.
    let headlineField: NSTextField

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Accessibility Permission"
        window.center()
        window.isReleasedWhenClosed = false

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .centerX
        container.spacing = 16
        container.edgeInsets = NSEdgeInsets(top: 28, left: 48, bottom: 24, right: 48)
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

        // Hero: the Accessibility mark above the ask, centered. The
        // glyph names the System Settings pane the button opens, so the
        // request reads as one system step rather than a product plea.
        let hero = NSStackView()
        hero.orientation = .vertical
        hero.alignment = .centerX
        hero.spacing = 12
        container.addArrangedSubview(hero)
        let mark = NSImageView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 56),
            mark.heightAnchor.constraint(equalToConstant: 56),
        ])
        if let symbol = NSImage(
            systemSymbolName: "accessibility",
            accessibilityDescription: "Accessibility")
        {
            mark.image = symbol
            mark.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: 44, weight: .bold)
            mark.contentTintColor = .controlAccentColor
        }
        // Decorative: the headline below it carries the meaning, so it
        // stays out of the VoiceOver order.
        mark.setAccessibilityElement(false)
        hero.addArrangedSubview(mark)

        let ask = NSStackView()
        ask.orientation = .vertical
        ask.alignment = .centerX
        ask.spacing = 4
        hero.addArrangedSubview(ask)

        let headline = NSTextField(labelWithString: "Tiled needs Accessibility permission")
        headline.font = .systemFont(ofSize: NSFont.systemFontSize + 4, weight: .bold)
        headline.alignment = .center
        headlineField = headline
        ask.addArrangedSubview(headline)

        let body = NSTextField(wrappingLabelWithString:
            "Tiling, drag-resize, and window tracking run on the Accessibility API. " +
            "Tiled reads window positions and sizes only, never window contents.")
        body.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        // Own narrower measure: the centered stacks size to content, so
        // the container insets alone don't bind this line; without a
        // cap it spans the full content width, edge to edge.
        body.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ask.addArrangedSubview(body)

        // The grant as numbered steps, ending on the self-closing promise:
        // the poll dismisses this window the moment trust arrives, so say
        // so; nobody should wonder whether they must come back and
        // confirm.
        let steps = NSTextField(wrappingLabelWithString:
            "1. Open Accessibility Settings below.\n" +
            "2. Turn on Tiled.\n" +
            "3. Return here; this window closes itself.")
        steps.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        // Left-aligned text in a centered block: the field sizes to its
        // longest line and centers on the window, while the step numbers
        // scan down one edge instead of ragging across the middle.
        steps.alignment = .left
        stepsField = steps
        container.addArrangedSubview(steps)
        // Actions center the one grant button: with the container
        // centered, the row sizes to its button and sits in the middle.
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 12
        container.addArrangedSubview(actions)

        let button = NSButton(title: "Open Accessibility Settings", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        actions.addArrangedSubview(button)
        openSettingsButton = button
        // Default-button styling (the filled accent button): Return works
        // from anywhere in the window, and the primary action looks it.
        window.defaultButtonCell = button.cell as? NSButtonCell

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
