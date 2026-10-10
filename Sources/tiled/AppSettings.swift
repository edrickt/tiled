import Foundation

/// App-level settings backed by UserDefaults. Reference type over an
/// injected defaults suite so tests can use an isolated suite.
final class AppSettings {
    private let defaults: UserDefaults
    private static let hideIconKey = "hideMenuBarIcon"
    private static let welcomeKey = "didDismissWelcome"
    private static let animateLayoutChangesKey = "animateLayoutChanges"

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

    /// Tiled-driven animation: Tiled steps a window's frame to its target
    /// so a layout change reads as motion rather than a jump. On by
    /// default, including for existing installs: the key's absence means
    /// "never chosen", and `UserDefaults.bool` would read that absence as
    /// off, so presence is checked explicitly. Persisted under its own
    /// key, so the choice survives relaunch. Reduce Motion always wins
    /// over this setting at the animator.
    var animateLayoutChanges: Bool {
        get {
            defaults.object(forKey: Self.animateLayoutChangesKey) == nil
                ? true
                : defaults.bool(forKey: Self.animateLayoutChangesKey)
        }
        set { defaults.set(newValue, forKey: Self.animateLayoutChangesKey) }
    }
}
