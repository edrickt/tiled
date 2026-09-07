import AppKit

/// The tiled Settings window: a thin shell around three tab modules.
/// Owns tab assembly, selection, rebuild, and initial-focus placement;
/// every tab's content, state, and actions live in its own module
/// (WelcomeTab, GeneralTab, ShortcutsTab).
final class SettingsWindowController: NSWindowController {
    enum Tab: Int {
        case welcome
        case general
        case shortcuts
    }

    private let settings: AppSettings
    private let welcomeTab: WelcomeTab
    private let generalTab: GeneralTab
    private let shortcutsTab: ShortcutsTab
    private var tabView: NSTabView!

    /// Live Accessibility trust probe, forwarded to both teaching tabs
    /// so the permission warning tracks reality on every build.
    var isTrustedProvider: (() -> Bool)? {
        didSet {
            generalTab.isTrustedProvider = isTrustedProvider
            welcomeTab.isTrustedProvider = isTrustedProvider
            shortcutsTab.isTrustedProvider = isTrustedProvider
        }
    }
    /// Opens the Accessibility permission pane.
    var onOpenAccessibilitySettings: (() -> Void)? {
        didSet {
            generalTab.onOpenAccessibilitySettings = onOpenAccessibilitySettings
            welcomeTab.onOpenAccessibilitySettings = onOpenAccessibilitySettings
            shortcutsTab.onOpenAccessibilitySettings = onOpenAccessibilitySettings
        }
    }
    /// Called when the user toggles "Hide menu bar icon" so the delegate
    /// can remove/restore the status item immediately.
    var onHideIconChange: ((Bool) -> Void)?
    /// Called after any binding change so the delegate can re-register
    /// hotkeys and refresh the menu.
    var onHotkeysChange: (() -> Void)? {
        didSet { shortcutsTab.onHotkeysChange = onHotkeysChange }
    }
    /// Slots whose global hotkey lost registration (owned by another app),
    /// forwarded to the Shortcuts tab so a cross-app failure surfaces
    /// beside the recorder that accepted the combo, not only in the menu.
    var failedSlotsProvider: (() -> [Slot])? {
        didSet { shortcutsTab.failedSlotsProvider = failedSlotsProvider }
    }
    /// Whether the Settings fallback hotkey (⌃⌥⇧⌘,) is currently
    /// registered, forwarded to General so the hide-icon confirm never
    /// promises a dead recovery combo.
    var isSettingsHotkeyRegisteredProvider: (() -> Bool)? {
        didSet {
            generalTab.isSettingsHotkeyRegisteredProvider =
                isSettingsHotkeyRegisteredProvider
        }
    }

    init(settings: AppSettings, hotkeyStore: HotkeyStore = HotkeyStore()) {
        self.settings = settings
        self.welcomeTab = WelcomeTab(hotkeyStore: hotkeyStore)
        self.generalTab = GeneralTab(settings: settings)
        self.shortcutsTab = ShortcutsTab(hotkeyStore: hotkeyStore)
        super.init(window: Self.makeWindow())
        welcomeTab.onDismiss = { [weak self] in self?.dismissWelcome() }
        generalTab.onHideIconChange = { [weak self] in self?.onHideIconChange?($0) }
        generalTab.onShowGuide = { [weak self] in self?.showWelcomeAgain() }
        welcomeTab.onOpenAccessibilitySettings = { [weak self] in
            self?.onOpenAccessibilitySettings?()
        }
        shortcutsTab.onHotkeysChange = { [weak self] in self?.onHotkeysChange?() }
        shortcutsTab.onContentRebuilt = { [weak self] view in
            self?.replaceShortcutsView(view)
        }
        window?.contentView?.addSubview(buildTabView(frame: window?.contentView?.bounds ?? .zero))
        loadValues()
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Tiled"
        window.minSize = NSSize(width: 400, height: 300)
        window.center()
        // HIG convention: a settings window reopens where it was left.
        window.setFrameAutosaveName("TiledSettings")
        window.isReleasedWhenClosed = false
        return window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(selecting tab: Tab = .general) {
        loadValues()
        shortcutsTab.reload()
        selectTab(tab)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activateAsFrontmost()
        focusInitialControl(for: tab)
    }

    /// Selects by identifier: the Welcome tab shifts indices when present,
    /// so raw values are never positions.
    private func selectTab(_ tab: Tab) {
        let id: String
        switch tab {
        case .welcome: id = "welcome"
        case .general: id = "general"
        case .shortcuts: id = "shortcuts"
        }
        if let item = tabView.tabViewItems.first(where: { ($0.identifier as? String) == id }) {
            tabView.selectTabViewItem(item)
        }
    }

    /// Keyboard/VoiceOver landing spot per tab: opening Settings must put
    /// focus somewhere deliberate, never wherever AppKit defaults drop it.
    /// Dismissing Welcome returns focus to General's first checkbox.
    private func focusInitialControl(for tab: Tab) {
        switch tab {
        case .welcome:
            // window-nil guard: selectTab no-ops when Welcome isn't in
            // the tab view, so never focus a detached button.
            if let button = welcomeTab.dismissButton, button.window != nil {
                window?.makeFirstResponder(button)
            }
        case .general:
            if let checkbox = generalTab.firstControl {
                window?.makeFirstResponder(checkbox)
            }
        case .shortcuts:
            if let first = shortcutsTab.firstRecorder {
                window?.makeFirstResponder(first)
            }
        }
    }

    /// Index of the Shortcuts tab item, whatever the Welcome tab shifts.
    private var shortcutsItemIndex: Int? {
        tabView.tabViewItems.firstIndex(where: { ($0.identifier as? String) == "shortcuts" })
    }

    // MARK: Layout

    private func buildTabView(frame: NSRect) -> NSTabView {
        let tabs = NSTabView(frame: frame)
        tabs.autoresizingMask = [.width, .height]
        tabView = tabs

        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        general.view = generalTab.build(size: frame.size)
        tabs.addTabViewItem(general)

        let shortcuts = NSTabViewItem(identifier: "shortcuts")
        shortcuts.label = "Shortcuts"
        shortcuts.view = shortcutsView(size: frame.size)
        tabs.addTabViewItem(shortcuts)

        // First-run tab: demonstrates one tiling instead of listing
        // seventeen combos. Removed per launch once dismissed; re-openable
        // from the menu bar menu → Tiled Guide (via a one-shot build override).
        if !settings.didDismissWelcome || forceWelcomeOnce {
            let welcome = NSTabViewItem(identifier: "welcome")
            welcome.label = "Welcome"
            welcome.view = welcomeTab.build(size: frame.size)
            tabs.insertTabViewItem(welcome, at: 0)
        }
        return tabs
    }

    /// Builds the shortcuts content, remembering the size for later
    /// collapse/bulk rebuilds (the tab rebuilds itself on toggle).
    private func shortcutsView(size: NSSize) -> NSView {
        shortcutsTab.buildSize = size
        return shortcutsTab.build(size: size, window: window)
    }

    /// Swaps the Shortcuts tab item's view after a collapse/bulk rebuild.
    private func replaceShortcutsView(_ view: NSView) {
        guard let index = shortcutsItemIndex else { return }
        tabView.tabViewItem(at: index).view = view
    }

    /// Reopens the Welcome tab on demand (menu-bar "Tiled Guide" item,
    /// General's "Show Tiled Guide" button). Builds the tab view with Welcome present without clearing
    /// the dismissal flag, so the next launch still opens on General.
    /// When the window is hidden, the tab view is rebuilt first so the
    /// Welcome item exists before selection (selectTab is identifier-safe
    /// and no-ops on a missing tab, never a wrong tab).
    func showWelcomeAgain() {
        if window?.isVisible != true {
            rebuildTabView(includingWelcome: true)
            loadValues()
            shortcutsTab.reload()
            selectTab(.welcome)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activateAsFrontmost()
            focusInitialControl(for: .welcome)
            return
        }
        if tabView.tabViewItems.contains(where: { ($0.identifier as? String) == "welcome" }) {
            selectTab(.welcome)
            focusInitialControl(for: .welcome)
            return
        }
        let frame = window?.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 440, height: 480)
        let welcome = NSTabViewItem(identifier: "welcome")
        welcome.label = "Welcome"
        welcome.view = welcomeTab.build(size: frame.size)
        tabView.insertTabViewItem(welcome, at: 0)
        selectTab(.welcome)
        focusInitialControl(for: .welcome)
    }

    /// Rebuilds the whole tab view (used when opening Welcome onto a
    /// hidden window whose tabs were built without it). Delegates to
    /// buildTabView with a one-shot override - no duplicated tab code.
    private var forceWelcomeOnce = false

    private func rebuildTabView(includingWelcome: Bool) {
        guard let contentView = window?.contentView else { return }
        let frame = contentView.bounds
        for subview in contentView.subviews {
            subview.removeFromSuperview()
        }
        shortcutsTab.reset()
        forceWelcomeOnce = includingWelcome
        contentView.addSubview(buildTabView(frame: frame))
        forceWelcomeOnce = false
    }

    private func dismissWelcome() {
        settings.didDismissWelcome = true
        if let welcome =
            tabView.tabViewItems.first(where: { ($0.identifier as? String) == "welcome" })
        {
            tabView.removeTabViewItem(welcome)
        }
        selectTab(.general)
        // Focus leaves with the removed tab; land it on General's first
        // control instead of wherever AppKit defaults drop it.
        if let checkbox = generalTab.firstControl {
            window?.makeFirstResponder(checkbox)
        }
    }

    private func loadValues() {
        generalTab.loadValues()
    }

    /// The delegate's permission poll calls this when Accessibility
    /// trust may have flipped, so open windows re-probe immediately
    /// instead of showing a stale warning (or hiding a needed one)
    /// until the next show().
    func permissionStateDidChange() {
        welcomeTab.refreshPermissionState()
        generalTab.refreshPermissionState()
        shortcutsTab.refreshPermissionState()
    }

    /// Keeps the Shortcuts tab's rebuild size current during live
    /// resize; without this, a collapse/bulk rebuild after resizing
    /// would use the size captured at build time.
    func windowDidResize(_ notification: Notification) {
        if let size = window?.contentView?.bounds.size {
            shortcutsTab.buildSize = size
        }
    }
}
