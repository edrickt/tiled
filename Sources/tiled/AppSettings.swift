import Foundation

/// App-level settings backed by UserDefaults. Reference type over an
/// injected defaults suite so tests can use an isolated suite.
final class AppSettings {
    private let defaults: UserDefaults
    private static let hideIconKey = "hideMenuBarIcon"
    private static let welcomeKey = "didDismissWelcome"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// When true the status item is removed; a fresh launch auto-opens
    /// Settings so the user always has a way back in (relaunch recovery).
    var hideMenuBarIcon: Bool {
        get { defaults.bool(forKey: Self.hideIconKey) }
        set { defaults.set(newValue, forKey: Self.hideIconKey) }
    }

    /// The first-run Welcome tab, dismissed for good via its button.
    var didDismissWelcome: Bool {
        get { defaults.bool(forKey: Self.welcomeKey) }
        set { defaults.set(newValue, forKey: Self.welcomeKey) }
    }
}
