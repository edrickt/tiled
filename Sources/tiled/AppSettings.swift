import Foundation

/// App-level settings backed by UserDefaults. Reference type over an
/// injected defaults suite so tests can use an isolated suite.
final class AppSettings {
    private let defaults: UserDefaults
    private static let hideIconKey = "hideMenuBarIcon"
    private static let welcomeKey = "didDismissWelcome"
    private static let tileGapKey = "tileGap"

    /// The gap setting's allowed range, in points, shared with the
    /// settings control so the slider/stepper and the clamp agree.
    static let tileGapRange: ClosedRange<Double> = 0...40
    /// The gap a fresh install starts with, in points.
    static let defaultTileGap: Double = 5

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

    /// The gap in points left around every tiled window: a uniform inset
    /// of half this value on each side, so a shared edge shows the full
    /// gap and a screen edge shows half. Clamped to `tileGapRange` on
    /// both read and write, so hand-edited defaults can't reach geometry
    /// as a negative inset.
    var tileGap: Double {
        get {
            let raw = defaults.object(forKey: Self.tileGapKey) as? Double
                ?? Self.defaultTileGap
            return min(max(raw, Self.tileGapRange.lowerBound), Self.tileGapRange.upperBound)
        }
        set {
            let clamped = min(
                max(newValue, Self.tileGapRange.lowerBound), Self.tileGapRange.upperBound)
            defaults.set(clamped, forKey: Self.tileGapKey)
        }
    }
}
