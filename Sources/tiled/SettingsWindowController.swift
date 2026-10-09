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

        /// Selects by identifier: the Welcome tab shifts indices when
        /// present, so raw values are never positions.
        var identifier: String {
            switch self {
            case .welcome: "welcome"
            case .general: "general"
            case .shortcuts: "shortcuts"
            }
        }

        var label: String {
            switch self {
            case .welcome: "Welcome"
            case .general: "General"
            case .shortcuts: "Shortcuts"
            }
        }

        /// The tabs present, in display order. Welcome leads when it is
        /// showing; General is the default landing spot otherwise.
        static func startingOrder(showWelcome: Bool) -> [Tab] {
            showWelcome ? [.welcome, .general, .shortcuts] : [.general, .shortcuts]
        }
    }

    private let settings: AppSettings
    private let welcomeTab: WelcomeTab
    private let generalTab: GeneralTab
    private let shortcutsTab: ShortcutsTab
    private var tabView: NSTabView!

    init(
        settings: AppSettings,
        hotkeyStore: HotkeyStore = HotkeyStore(),
        dependencies: SettingsDependencies = SettingsDependencies()
    ) {
        self.settings = settings
        self.welcomeTab = WelcomeTab(hotkeyStore: hotkeyStore)
        self.generalTab = GeneralTab(settings: settings)
        self.shortcutsTab = ShortcutsTab(hotkeyStore: hotkeyStore)
        super.init(window: Self.makeWindow())
        // One wiring point: each tab gets the slice of the dependency
        // value it reads. The closures come from the delegate already
        // weak-captured, so no indirection through the shell is needed.
        generalTab.isTrustedProvider = dependencies.isTrusted
        generalTab.settingsHotkeyStateProvider = dependencies.settingsHotkeyState
        generalTab.onHideIconChange = dependencies.hideIconChange
        generalTab.onGapChange = dependencies.gapChange
        welcomeTab.isTrustedProvider = dependencies.isTrusted
        shortcutsTab.isTrustedProvider = dependencies.isTrusted
        welcomeTab.onOpenAccessibilitySettings = dependencies.openAccessibilitySettings
        generalTab.onOpenAccessibilitySettings = dependencies.openAccessibilitySettings
        shortcutsTab.onOpenAccessibilitySettings = dependencies.openAccessibilitySettings
        shortcutsTab.failedActionsProvider = dependencies.failedActions
        welcomeTab.onDismiss = { [weak self] in self?.dismissWelcome() }
        generalTab.onShowGuide = { [weak self] in self?.showWelcomeAgain() }
        // A binding edit can change the Welcome tab's taught combo; refresh
        // it before telling the delegate to re-register.
        let hotkeysChange = dependencies.hotkeysChange
        shortcutsTab.onHotkeysChange = { [weak self] in
            self?.welcomeTab.refreshShortcutInstructions()
            hotkeysChange()
        }
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
        if let item = tabView.tabViewItems.first(where: {
            ($0.identifier as? String) == tab.identifier
        }) {
            tabView.selectTabViewItem(item)
        }
    }

    // MARK: Testable tab lifecycle

    /// The tab identifiers present, in display order.
    var tabIdentifiers: [String] {
        tabView.tabViewItems.compactMap { $0.identifier as? String }
    }

    /// The identifier of the selected tab, or nil before a tab view exists.
    var selectedTabIdentifier: String? {
        tabView.selectedTabViewItem?.identifier as? String
    }

    /// The view currently hosting a tab, or nil when the tab is absent.
    func tabContent(of tab: Tab) -> NSView? {
        tabView.tabViewItems.first { ($0.identifier as? String) == tab.identifier }?.view
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
        let showWelcome = !settings.didDismissWelcome || forceWelcomeOnce
        for tab in Tab.startingOrder(showWelcome: showWelcome) {
            let item = NSTabViewItem(identifier: tab.identifier)
            item.label = tab.label
            item.view = makeTabContent(for: tab, size: frame.size)
            tabs.addTabViewItem(item)
        }
        return tabs
    }

    /// Builds one tab's content at the given size. Shortcuts needs the
    /// window so it can restore focus and size its own rebuilds.
    private func makeTabContent(for tab: Tab, size: NSSize) -> NSView {
        switch tab {
        case .welcome: welcomeTab.build(size: size)
        case .general: generalTab.build(size: size)
        case .shortcuts: shortcutsTab.build(size: size, window: window)
        }
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
        welcomeTab.refreshShortcutInstructions()
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
    /// buildTabView with a one-shot override: no duplicated tab code.
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
        welcomeTab.refreshShortcutInstructions()
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
}
