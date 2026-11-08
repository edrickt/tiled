import CoreGraphics
import Foundation

/// Stable identity for one display. A live screen is identified by its
/// CoreGraphics display UUID, which survives a display-number change (a
/// replug, a sleep/wake): the canvas keyed to it follows the physical
/// display, and a number the OS later reuses for another display never
/// adopts it. `rawValue` is the display number (or the provider index when
/// the OS reports none), kept for ordering and logging only — never for
/// identity. Tests and display-less environments key on the injected
/// number. Per-display tiling state keys on this alongside the macOS Space,
/// so each display runs an independent layout.
struct ScreenID: Hashable {
    /// The display number, or the provider index when the display has no
    /// number: ordering and logging only.
    let rawValue: Int
    /// The display's persistent CoreGraphics UUID. Nil for injected or
    /// headless display sets, which key on `rawValue` instead.
    let uuid: UUID?

    /// Identity for injected/headless display sets, where there is no
    /// CoreGraphics display UUID to key on. Number-keyed, so it never
    /// compares equal to a live display identity.
    init(rawValue: Int) {
        self.rawValue = rawValue
        self.uuid = nil
    }

    /// Identity for a live display: the CoreGraphics display number when
    /// the OS reports one, plus the display's persistent UUID when it can
    /// be read. Screens without a number (headless test doubles) fall back
    /// to the provider's list index, the only number then available.
    init(displayID: CGDirectDisplayID, fallbackIndex: Int, uuid: UUID? = nil) {
        self.rawValue = displayID == 0 ? fallbackIndex : Int(displayID)
        self.uuid = uuid
    }

    /// The two identity namespaces: a UUID-keyed live display and a
    /// number-keyed injected one. Keeping them distinct means `nil` never
    /// compares equal to a UUID, and a reused display number never matches
    /// the display that held it before.
    private enum Identity: Hashable {
        case display(UUID)
        case number(Int)
    }

    private var identity: Identity {
        uuid.map(Identity.display) ?? .number(rawValue)
    }

    static func == (lhs: ScreenID, rhs: ScreenID) -> Bool {
        lhs.identity == rhs.identity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
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

extension TilingSpaceKey {
    /// The display-less canvas: headless environments keep one shared
    /// canvas, and callers with no canvas at all resolve here. The
    /// visibility policy treats it as visible, so only the write
    /// policies that do not depend on Space identity apply.
    static let displayless = TilingSpaceKey(screen: nil, space: nil)
}

/// One display's geometry for tiling: full frame plus visible frame
/// (excluding menu bar and Dock). AppKit-free so tests inject synthetic
/// multi-display setups without attached displays. `id` is the persistent
/// identity canvas state keys on; `displayID` stays the live CoreGraphics
/// display number the window server's Space table uses — never derived
/// from `id.rawValue`, which may name an older number. Tests leave
/// `displayID` 0 when Space identity is not under test.
struct ScreenInfo {
    let id: ScreenID
    let frame: CGRect
    let visibleFrame: CGRect
    var name: String?
    var displayID: CGDirectDisplayID = 0
}

/// Provides the current display set. The controller calls it on every
/// tiling action (never cached), so replugs and rearranges take effect
/// without an observer: a display's state appears on first use.
typealias ScreenProvider = () -> [ScreenInfo]

#if canImport(AppKit)
import AppKit

extension ScreenInfo {
    /// One entry per live display. The `ScreenID` combines the
    /// CoreGraphics display UUID with the live display number, so a
    /// display's canvas survives both `NSScreen.screens` reordering and a
    /// renumber; `index` is only the fallback number for screens the OS
    /// cannot number. `displayID` stays the live number the window
    /// server's Space table uses.
    init(appKit screen: NSScreen, index: Int) {
        let displayID = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let uuid = Self.displayUUID(for: displayID)
        self.init(
            id: ScreenID(displayID: displayID, fallbackIndex: index, uuid: uuid),
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            name: screen.localizedName,
            displayID: displayID)
    }

    /// The persistent CoreGraphics identity for a display number, or nil
    /// when the OS cannot name one (a display-less test double). The
    /// number changes across a replug or sleep/wake; the UUID does not.
    private static func displayUUID(for displayID: CGDirectDisplayID) -> UUID? {
        guard displayID != 0,
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?
                .takeRetainedValue()
        else { return nil }
        return UUID(uuidString: CFUUIDCreateString(nil, uuid) as String)
    }
}
#endif
