import AppKit

/// Transient on-screen feedback for global-hotkey outcomes (tiling
/// refusals, no-ops, missing focus). A sighted keyboard user otherwise
/// gets only a haptic while the explanatory `MenuText` string hides in a
/// menu they have no reason to open — the HUD is the visual twin of the
/// VoiceOver announcement, never a replacement for it.
///
/// A borderless floating panel in the HUD vibrancy material, pinned
/// top-center of the main screen, dismissing itself after `dismissDelay`
/// seconds. Rapid outcomes coalesce: the text is replaced and the clock
/// restarts, so a stubborn app never stacks panels.
final class FeedbackHUD: NSObject {
    static let shared = FeedbackHUD()

    /// Seconds before the HUD dismisses itself. Overridable for tests.
    var dismissDelay: TimeInterval = 2.5
    /// The text currently on screen, nil when dismissed.
    private(set) var currentText: String?

    private var panel: NSPanel?
    private var label: NSTextField?
    private var dismissItem: DispatchWorkItem?

    deinit {
        dismissItem?.cancel()
    }

    /// Shows `text`, replacing whatever is on screen and restarting the
    /// dismiss clock. Never steals focus (nonactivating) or mouse events.
    /// - Parameter screen: the display to pin to. The controller passes
    ///   the requester window's screen so feedback about display 2's
    ///   workspace appears where the workspace changed; nil (default)
    ///   keeps the historical main-screen behavior.
    /// - Parameter sticky: when true, the panel stays up until the next
    ///   `show`, an explicit `hide`, or the expiry below — whichever
    ///   comes first. Reserved for destructive outcomes (evictions,
    ///   layout switches): a 2.5s toast is too small a window for "your
    ///   workspace just moved." Sticky panels still coalesce — the next
    ///   outcome replaces, never stacks.
    /// - Parameter stickySeconds: how long a sticky panel may outstay its
    ///   welcome. Reassurance that never leaves curdles into nagging —
    ///   an immortal banner is stale status, worse than none — so even
    ///   sticky notices expire. Long enough to survive looking away;
    ///   short enough to never become furniture. Default 12s.
    func show(
        _ text: String, on screen: NSScreen? = nil, sticky: Bool = false,
        stickySeconds: TimeInterval = 12
    ) {
        currentText = text
        dismissItem?.cancel()
        dismissItem = nil
        let panel = panel ?? makePanel()
        label?.stringValue = text
        layoutPanel(panel, for: text, on: screen)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
        // Timed panels dismiss on schedule; sticky ones dismiss late.
        // Both set the item here so a replacement always restarts the
        // clock instead of stacking panels.
        let delay = sticky ? stickySeconds : dismissDelay
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        dismissItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Dismisses immediately (orderOut, no fade): a disappearing toast
    /// should never linger on an animation.
    func hide() {
        dismissItem?.cancel()
        dismissItem = nil
        currentText = nil
        panel?.orderOut(nil)
    }

    /// Whether the panel is currently on screen. Internal for tests.
    var isVisible: Bool { panel?.isVisible == true }

    // MARK: Construction

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        // Follows the user across spaces (tiling lives everywhere) and
        // ignores clicks: feedback is read-only, never interactive.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        panel.contentView = effect

        let label = NSTextField(wrappingLabelWithString: "")
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.alignment = .center
        effect.addSubview(label)
        self.label = label
        self.panel = panel
        return panel
    }

    /// Sizes the panel to the text (capped at 480pt so a long refusal
    /// never spans the screen) and pins it top-center of the given
    /// screen's visible frame — defaulting to the main screen when the
    /// caller doesn't know better.
    private func layoutPanel(_ panel: NSPanel, for text: String, on screen: NSScreen?) {
        guard let label else { return }
        let screen = screen ?? NSScreen.main
        guard let screen else { return }
        let font = label.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let maxWidth: CGFloat = 480
        let padding = NSSize(width: 44, height: 30)
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let textWidth = min(maxWidth, ceil(measured.width))
        let textHeight = ceil(measured.height)
        let width = textWidth + padding.width
        let height = textHeight + padding.height
        label.frame = NSRect(
            x: padding.width / 2, y: padding.height / 2,
            width: textWidth, height: textHeight)
        let frame = screen.visibleFrame
        panel.setFrame(
            NSRect(
                x: frame.midX - width / 2,
                y: frame.maxY - height - 24,
                width: width, height: height),
            display: true)
    }
}
