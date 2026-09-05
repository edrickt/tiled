import CoreGraphics

/// Stable identity for one display. The live provider derives these from
/// screen order; tests inject their own. Per-monitor tiling state
/// (occupancy, splitters, undo chapters) keys on this, so each monitor
/// runs an independent layout.
struct ScreenID: Hashable {
    let rawValue: Int
}

/// One display's geometry for tiling: full frame plus visible frame
/// (excluding menu bar and Dock). AppKit-free so tests inject synthetic
/// multi-monitor setups without attached displays.
struct ScreenInfo {
    let id: ScreenID
    let frame: CGRect
    let visibleFrame: CGRect
    var name: String?
}

/// One monitor's tiling space: its occupancy, undo chapters, transient
/// notices, and splitter backup. The grid itself lives in the tracker
/// (keyed by the same `ScreenID`); this owns everything else so each
/// display tiles, switches, drags, and undoes independently.
struct MonitorSpace {
    var state = TilingState()
    var undoStack: [(snapshot: [EvictedWindow], requester: WindowID?)] = []
    var splitterBackup: GridLayout?
    var notice: String?
    var error: String?
}

/// Provides the current display set. The controller calls it on every
/// tiling action (never cached), so replugs and rearranges take effect
/// without an observer: a monitor's state appears on first use.
typealias ScreenProvider = () -> [ScreenInfo]

#if canImport(AppKit)
import AppKit

extension ScreenInfo {
    /// One entry per live display: stable order (mirroring
    /// `NSScreen.screens`), so a monitor's `ScreenID` survives calls
    /// within one configuration.
    init(appKit screen: NSScreen, index: Int) {
        self.init(
            id: ScreenID(rawValue: index),
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            name: screen.localizedName)
    }
}
#endif
