import CoreGraphics

/// Stable identity for one display. The live provider derives these from
/// screen order; tests inject their own. Per-display tiling state keys on
/// this alongside the macOS Space, so each monitor runs an independent
/// layout.
struct ScreenID: Hashable {
    let rawValue: Int
}

/// Identity of one macOS Mission Control Space: the desktop a user
/// reaches by swiping up with three fingers. These are window-server
/// ids, stable while the Space exists and opaque to the app: tiling
/// state keys on them, never on their numeric value. Nil (where the
/// OS withholds an id) degrades to the old per-display behavior.
struct SpaceID: Hashable {
    let rawValue: UInt64
}

/// One independent tiling canvas: a display's current Mission Control
/// Space. Occupancy, layout, splitters, undo chapters, and notices all
/// key on this, so every Space is independent of every other Space and
/// of every other display. A key with a nil `space` is the per-display
/// fallback used when the OS cannot identify the Space (headless tests
/// and older/unknown window servers).
struct TilingSpaceKey: Hashable {
    /// Display hosting this canvas; nil only for a display-less
    /// environment (headless tests), which keeps one shared canvas.
    let screen: ScreenID?
    /// Mission Control Space shown on that display right now; nil means
    /// "unknown", the per-display fallback.
    let space: SpaceID?
}

/// One display's geometry for tiling: full frame plus visible frame
/// (excluding menu bar and Dock). AppKit-free so tests inject synthetic
/// multi-monitor setups without attached displays. `displayID` lets the
/// live gateway map a canvas key back to the window server's Space
/// table; tests leave it 0 when Space identity is not under test.
struct ScreenInfo {
    let id: ScreenID
    let frame: CGRect
    let visibleFrame: CGRect
    var name: String?
    var displayID: CGDirectDisplayID = 0
}

/// One tiling canvas's state: its occupancy, undo chapters, transient
/// notices, and splitter backup. The grid itself lives in the tracker
/// (keyed by the same `TilingSpaceKey`); this owns everything else so
/// each display's each Space tiles, switches, drags, and undoes
/// independently.
struct CanvasState {
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
    /// within one configuration. `displayID` is the CoreGraphics display
    /// number the window server's Space table keys on.
    init(appKit screen: NSScreen, index: Int) {
        let displayID = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        self.init(
            id: ScreenID(rawValue: index),
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            name: screen.localizedName,
            displayID: displayID)
    }
}
#endif
