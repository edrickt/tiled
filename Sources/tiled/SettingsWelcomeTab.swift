import AppKit

/// The first-run Welcome tab: one demonstration, not seventeen combos.
/// Dismissing removes the tab for this launch (persisted); it stays
/// re-openable from General, so the teaching moment is never lost — the
/// tab is one-time per launch, not one-time forever.
final class WelcomeTab: NSObject {
    private let hotkeyStore: HotkeyStore
    /// Fired by the dismiss button. The shell removes the tab, lands on
    /// General, and persists the dismissal.
    var onDismiss: (() -> Void)?
    /// Live Accessibility trust probe: the three steps below are exactly
    /// what an untrusted install cannot do, so the warning leads the tab.
    var isTrustedProvider: (() -> Bool)?
    /// Opens the Accessibility permission pane.
    var onOpenAccessibilitySettings: (() -> Void)?

    /// The dismiss button of the last built view, for initial-focus
    /// placement on open.
    private(set) var dismissButton: NSButton?
    private var permissionRow: NSStackView!

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
            // No bottom constraint — see TopAnchoredStackView.
        ])
        view.addSubview(scroll)

        let title = NSTextField(labelWithString: "Tile a window in one keypress")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        stack.addArrangedSubview(title)

        // Permission warning, before the steps: an untrusted install
        // cannot do step 1 ("click any window" works, but tiled sees no
        // focused window), so lead with the fix, not a broken promise.
        permissionRow = NSStackView()
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 12
        permissionRow.alignment = .firstBaseline
        let warningText = NSTextField(wrappingLabelWithString:
            "tiled can't see or move windows — Accessibility permission is off.")
        warningText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warningText.textColor = .labelColor
        // Label wraps, button never shrinks — and the row is capped to
        // the inset width below, so the button holds the 24pt inset at
        // any window width (see GeneralTab for the same pattern).
        warningText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        permissionRow.addArrangedSubview(warningText)
        let grantButton = NSButton(
            title: "Open Settings", target: self, action: #selector(grantPermissionTapped(_:)))
        grantButton.bezelStyle = .rounded
        grantButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        permissionRow.addArrangedSubview(grantButton)
        permissionRow.isHidden = isTrustedProvider?() ?? true
        stack.addArrangedSubview(permissionRow)
        permissionRow.trailingAnchor.constraint(
            equalTo: stack.trailingAnchor, constant: -24).isActive = true

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
            target: self, action: #selector(dismissTapped(_:)))
        dismiss.bezelStyle = .rounded
        dismissButton = dismiss
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

    @objc private func dismissTapped(_ sender: NSButton) {
        onDismiss?()
    }

    @objc private func grantPermissionTapped(_ sender: NSButton) {
        onOpenAccessibilitySettings?()
    }
}
