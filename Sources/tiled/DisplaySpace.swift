import CoreGraphics

/// Stable identity for one display. Live screens use their CoreGraphics
/// display number, so a canvas follows the physical monitor when the
/// provider's order changes; tests and display-less environments use the
/// injected value or the provider index. Per-display tiling state keys on
/// this alongside the macOS Space, so each monitor runs an independent
/// layout.
struct ScreenID: Hashable {
    let rawValue: Int

    /// Identity for injected/headless display sets, where there is no
    /// CoreGraphics display number to key on.
    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Identity for a live display: its CoreGraphics display number when
    /// the OS reports one. Screens without a number (headless test
    /// doubles) fall back to the provider's list index, the only
    /// identity then available.
    init(displayID: CGDirectDisplayID, fallbackIndex: Int) {
        self.rawValue = displayID == 0 ? fallbackIndex : Int(displayID)
    }
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
/// live gateway map a canvas key back to the window server's Space table
/// and gives the live `id` a stable physical-display identity; tests
/// leave it 0 when Space identity is not under test.
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
    /// One entry per live display. The `ScreenID` comes from the
    /// CoreGraphics display number, so a monitor's canvas survives
    /// `NSScreen.screens` reordering; `index` is only the fallback for
    /// screens the OS cannot number. `displayID` is also the key the
    /// window server's Space table uses.
    init(appKit screen: NSScreen, index: Int) {
        let displayID = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        self.init(
            id: ScreenID(displayID: displayID, fallbackIndex: index),
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            name: screen.localizedName,
            displayID: displayID)
    }
}
#endif
