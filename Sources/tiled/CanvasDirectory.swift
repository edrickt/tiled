import AppKit
import CoreGraphics

/// The one owner of display + Mission Control Space identity: the canvas
/// table, the stale marks, the last focused canvas, the last display the
/// cursor was seen on, visibility, the withheld-Space fallback, and the
/// one visible-canvas enumeration.
///
/// Every surface that used to answer "which canvas is this display
/// showing" resolved it privately and some disagreed. This type is that
/// one answer: `key(for:)` resolves a display's current canvas,
/// `focusedKey()` the canvas focus acts on, and `visibleKeys()` the ones
/// actions and the manage list enumerate without writing a hidden canvas
/// blind. Canvas records remain the only owner of which canvas a window
/// lives on; this table is keyed by display + Space, never by window.
final class CanvasDirectory {
    private let screens: ScreenProvider
    /// The Mission Control Space shown on a display, or nil when the
    /// window server withholds it.
    private let activeSpace: (CGDirectDisplayID) -> SpaceID?
    /// The focused window and its geometry: focus resolution needs the
    /// live frame, then the pre-tile frame.
    private let focusedWindow: () -> WindowHandle?
    private let frameOf: (WindowHandle) -> CGRect?
    private let preTileFrameOf: (WindowHandle) -> CGRect?

    /// Per-canvas tiling spaces: each display's each Mission Control
    /// Space runs its own occupancy, records, expansion, splitters, undo
    /// chapters, and transient notices.
    private var spaces: [TilingSpaceKey: TilingSpace] = [:]
    /// Known canvases whose geometry was invalidated by a display change
    /// while the Space was hidden. They are re-asserted when shown again:
    /// writing an off-Space window risks moving it to the active Space,
    /// so a hidden canvas waits instead of being corrected in the dark.
    private var staleSpaces: Set<TilingSpaceKey> = []
    /// Last focused canvas (display plus Mission Control Space) observed
    /// through the gateway. The first focus callback always reports; later
    /// moves within one canvas are filtered so an AX event per window
    /// switch never turns into UI work.
    private var lastFocusedSpace: TilingSpaceKey?
    private var hasResolvedFocusedSpace = false
    /// Last display the cursor was resolved on, mirroring the focus pair's
    /// first-report contract. This one value is both the dedupe baseline
    /// and the depicted display.
    private var lastCursorScreen: ScreenID?
    private var hasResolvedCursorScreen = false

    init(
        screens: @escaping ScreenProvider,
        activeSpace: @escaping (CGDirectDisplayID) -> SpaceID?,
        focusedWindow: @escaping () -> WindowHandle?,
        frameOf: @escaping (WindowHandle) -> CGRect?,
        preTileFrameOf: @escaping (WindowHandle) -> CGRect?
    ) {
        self.screens = screens
        self.activeSpace = activeSpace
        self.focusedWindow = focusedWindow
        self.frameOf = frameOf
        self.preTileFrameOf = preTileFrameOf
    }

    // MARK: Canvas table

    /// The canvas for `space`, for reading: an unknown key yields a fresh
    /// empty canvas rather than nil. Mutations go through `withCanvas` (or
    /// `modifyCanvas` for a canvas that must already exist); anything
    /// written into the returned value is discarded.
    func canvas(for space: TilingSpaceKey) -> TilingSpace {
        spaces[space] ?? TilingSpace()
    }

    func storedCanvas(for space: TilingSpaceKey) -> TilingSpace? {
        spaces[space]
    }

    var allCanvases: [TilingSpaceKey: TilingSpace] { spaces }

    var allKeys: [TilingSpaceKey] { Array(spaces.keys) }

    /// One canvas mutation funnel: an existing canvas is updated in
    /// place, a new one is established with its own display's visible
    /// frame. Every state change goes through here so no surface can
    /// write around the stored frame.
    @discardableResult
    func withCanvas<T>(
        _ space: TilingSpaceKey, _ body: (inout TilingSpace) -> T
    ) -> T {
        var value = spaces[space] ?? establishedCanvas(for: space)
        let result = body(&value)
        spaces[space] = value
        return result
    }

    /// Updates a canvas that already exists, without establishing one.
    func modifyCanvas(_ space: TilingSpaceKey, _ body: (inout TilingSpace) -> Void) {
        guard var value = spaces[space] else { return }
        body(&value)
        spaces[space] = value
    }

    /// Canvases whose display is attached and whose Space id the window
    /// server no longer lists. A key with no Space (withheld) or a display
    /// the inventory omits is never retired.
    func vanishedCanvases(
        known: [CGDirectDisplayID: Set<SpaceID>]
    ) -> [TilingSpaceKey] {
        guard !known.isEmpty else { return [] }
        let displayIDs = Dictionary(
            uniqueKeysWithValues: screens().map { ($0.id, $0.displayID) })
        return spaces.keys.filter { key in
            guard
                let screen = key.screen,
                let space = key.space,
                let displayID = displayIDs[screen],
                let existing = known[displayID]
            else { return false }
            return !existing.contains(space)
        }.sorted(by: Self.spaceOrder)
    }

    /// Drops a retired canvas and its identity bookkeeping. Ownership is
    /// derived from the canvas table, so the records go with it.
    func dropCanvas(_ space: TilingSpaceKey) {
        spaces[space] = nil
        staleSpaces.remove(space)
        if lastFocusedSpace == space { lastFocusedSpace = nil }
    }

    /// The canvas holding a managed window's record, or nil when untiled.
    /// Ownership is derived here and nowhere else.
    func owner(of id: WindowID) -> TilingSpaceKey? {
        spaces.first(where: { $0.value.record(of: id) != nil })?.key
    }

    // MARK: Display + Space resolution

    /// Canvas key for a display right now. A nil screen falls back to the
    /// main display, then the display-less key; an unknown screen keeps
    /// its own key (callers that must clamp check attachment first).
    func key(for screen: ScreenID?) -> TilingSpaceKey {
        let resolved = screen ?? screens().first?.id
        return TilingSpaceKey(
            screen: resolved, space: activeSpaceID(on: resolved))
    }

    /// Canvas for a tiling request: an owned canvas wins (a tiled window
    /// never migrates mid-session), else the display showing the live
    /// frame, else the pre-tile frame's display, else the focused canvas.
    func keyForRequester(
        owned: TilingSpaceKey?, frame: CGRect?, preTileFrame: CGRect?
    ) -> TilingSpaceKey {
        if let owned { return owned }
        if let frame, let info = screenInfo(for: frame) {
            return key(for: info.id)
        }
        if let preTileFrame, preTileFrame != .zero,
            let info = screenInfo(for: preTileFrame)
        {
            return key(for: info.id)
        }
        return focusedKey()
    }

    /// The canvas a hotkey acts on: the focused window's display plus the
    /// Space shown there.
    func focusedKey() -> TilingSpaceKey {
        actionKey(for: focusedScreenID())
    }

    /// The canvas a display-scoped read or action resolves: the named
    /// canvas when it holds anything, else the display's withheld-Space
    /// canvas. Without the fallback, the first successful Space lookup
    /// after a withheld period would strand every window tiled during it.
    func actionKey(for screen: ScreenID?) -> TilingSpaceKey {
        let identified = key(for: screen)
        if let canvas = spaces[identified], canvas.holdsAnything {
            return identified
        }
        return withheldCanvas(on: identified.screen) ?? identified
    }

    /// The focused display: the focused window's live frame's display,
    /// else its pre-tile frame's display, else the main display.
    func focusedScreenID() -> ScreenID? {
        let infos = screens()
        guard !infos.isEmpty else { return nil }
        if let handle = focusedWindow() {
            if let frame = frameOf(handle),
                let info = screenInfo(for: frame)
            { return info.id }
            if let frame = preTileFrameOf(handle), frame != .zero,
                let info = screenInfo(for: frame)
            { return info.id }
        }
        return infos.first?.id
    }

    /// The provider-backed screen owning `frame`, or the main screen when
    /// nothing overlaps (off-screen or inter-Space windows still tile
    /// somewhere sane). Nil only when the provider reports no displays.
    func screenInfo(for frame: CGRect) -> ScreenInfo? {
        let infos = screens()
        if let index = Self.owningScreenIndex(frames: infos.map(\.frame), for: frame) {
            return infos[index]
        }
        if let index = Self.midpointScreenIndex(frames: infos.map(\.frame), for: frame) {
            return infos[index]
        }
        return infos.first
    }

    /// The canvas currently shown on every display, in screen order, plus
    /// each display's withheld-Space canvas when it still holds windows or
    /// chapters. The named canvases come first — the manage list's order —
    /// then the withheld fallbacks, one display at a time. With no
    /// displays, every remembered canvas is enumerated (the manage list's
    /// historical view); with none remembered, the display-less fallback
    /// keeps actions working.
    func visibleKeys() -> [TilingSpaceKey] {
        let infos = screens()
        guard !infos.isEmpty else {
            if spaces.isEmpty { return [key(for: nil)] }
            return spaces.keys.sorted(by: Self.spaceOrder)
        }
        var keys: [TilingSpaceKey] = []
        for info in infos {
            let identified = key(for: info.id)
            if !keys.contains(identified) { keys.append(identified) }
        }
        for info in infos {
            // A withheld-Space canvas is visible like the identified one:
            // it is the same display, just unnamed.
            if let fallback = withheldCanvas(on: info.id),
                !keys.contains(fallback)
            {
                keys.append(fallback)
            }
        }
        return keys
    }

    /// Whether `space` is the canvas the user can see right now.
    ///
    /// A key with no display (headless tests, `TilingSpaceKey.displayless`)
    /// is genuinely display-less: there is no hidden canvas to protect, so
    /// it stays visible. A key whose display is no longer attached is never
    /// visible, even when its Space id is withheld: its stored frame may
    /// already belong to another display, so writing it would lay the
    /// window out against the wrong geometry. On an attached display a
    /// withheld Space id is the per-display fallback the user is looking
    /// at, so it stays visible; an identified canvas is visible when it is
    /// the Space shown there. When the window server cannot name the
    /// visible Space at all, the canvas is *unknown*, not hidden: the
    /// unnameable answer is the same fallback a withheld id is, so the
    /// canvas stays visible and the write proceeds.
    func isVisible(_ space: TilingSpaceKey) -> Bool {
        guard let screen = space.screen else { return true }
        guard screens().contains(where: { $0.id == screen }) else { return false }
        guard let id = space.space else { return true }
        // No answer names the visible Space: unknown, not different.
        guard let active = activeSpaceID(on: screen) else { return true }
        return active == id
    }

    /// The visible frame of a canvas's own display: the one geometry every
    /// rect on that canvas derives from. A display-less key uses the main
    /// screen, then the live main screen, then zero.
    func visibleFrame(for space: TilingSpaceKey) -> CGRect {
        if let screen = space.screen,
            let info = screens().first(where: { $0.id == screen })
        {
            return info.visibleFrame
        }
        return screens().first?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
    }

    // MARK: Stale marks and frame refresh

    /// Whether a canvas's own display is currently attached. A key with no
    /// screen is genuinely display-less: it has no display to be absent,
    /// so the main-screen fallback still applies.
    func isDisplayAttached(_ screen: ScreenID?) -> Bool {
        guard let screen else { return true }
        return screens().contains { $0.id == screen }
    }

    /// Re-resolves the stored visible frame of the named canvases: the
    /// refresh half of a display change and a swipe back. A canvas whose
    /// display is absent keeps the geometry it had; it is re-resolved on
    /// replug. Keys without a canvas yet resolve on first use.
    func refreshFrames(_ keys: [TilingSpaceKey]) {
        for key in keys where spaces[key] != nil {
            guard isDisplayAttached(key.screen) else { continue }
            spaces[key]?.visibleFrame = visibleFrame(for: key)
        }
    }

    func refreshAllFrames() {
        refreshFrames(allKeys)
    }

    func markStale(_ space: TilingSpaceKey) {
        staleSpaces.insert(space)
    }

    func markAllStale() {
        staleSpaces.formUnion(spaces.keys)
    }

    func clearStale(_ space: TilingSpaceKey) {
        staleSpaces.remove(space)
    }

    func isMarkedStale(_ space: TilingSpaceKey) -> Bool {
        staleSpaces.contains(space)
    }

    // MARK: Focus tracking

    /// Records the focused canvas, returning whether it moved from the
    /// last resolved one. The first callback always reports.
    func noteFocusedKey(_ key: TilingSpaceKey) -> Bool {
        guard !hasResolvedFocusedSpace || key != lastFocusedSpace else {
            return false
        }
        hasResolvedFocusedSpace = true
        lastFocusedSpace = key
        return true
    }

    // MARK: Cursor tracking

    /// Records the display the cursor is on, returning whether it moved
    /// from the last resolved one. The first resolution always reports;
    /// a point over no display (a seam gap, Mission Control zoom, a
    /// mid-rearrange) is ignored and never stored.
    func noteCursor(at point: CGPoint) -> Bool {
        let infos = screens()
        guard
            let index = Self.containingScreenIndex(frames: infos.map(\.frame), for: point),
            !hasResolvedCursorScreen || infos[index].id != lastCursorScreen
        else { return false }
        hasResolvedCursorScreen = true
        lastCursorScreen = infos[index].id
        return true
    }

    /// The canvas the status glyph depicts: the stored cursor display
    /// through the same `actionKey` fallback as every display-scoped read,
    /// so the withheld-Space fallback applies identically.
    func cursorKey() -> TilingSpaceKey {
        actionKey(for: isDisplayAttached(lastCursorScreen) ? lastCursorScreen : nil)
    }

    // MARK: Private resolution

    private func activeSpaceID(on screen: ScreenID?) -> SpaceID? {
        guard let screen,
            let info = screens().first(where: { $0.id == screen })
        else { return nil }
        return activeSpace(info.displayID)
    }

    /// A display's withheld-Space canvas, when it still holds windows or
    /// chapters. This is not a hidden Space: it is the canvas the window
    /// server would not name when those windows tiled, so it must stay
    /// reachable or its windows vanish from the menu and bulk actions.
    private func withheldCanvas(on screen: ScreenID?) -> TilingSpaceKey? {
        guard let screen else { return nil }
        let key = TilingSpaceKey(screen: screen, space: nil)
        guard let canvas = spaces[key], canvas.holdsAnything else { return nil }
        return key
    }

    /// A brand-new canvas with its visible frame resolved from its own
    /// display. Existing canvases keep their frame until a refresh event.
    private func establishedCanvas(for space: TilingSpaceKey) -> TilingSpace {
        var canvas = TilingSpace()
        canvas.visibleFrame = visibleFrame(for: space)
        return canvas
    }

    /// Stable menu order for canvases: display first, then Space.
    private static func spaceOrder(_ a: TilingSpaceKey, _ b: TilingSpaceKey) -> Bool {
        let left = a.screen?.rawValue ?? -1
        let right = b.screen?.rawValue ?? -1
        if left != right { return left < right }
        return (a.space?.rawValue ?? 0) < (b.space?.rawValue ?? 0)
    }

    // MARK: Pure screen ownership

    /// Index of the screen showing the largest share of `frame`, so
    /// straddles resolve to the mostly-visible side and never jitter on
    /// the midpoint. Compared by intersection *area*, not width:
    /// vertically stacked displays at equal widths produce equal-width
    /// intersections, so a width-only comparison always returns the first
    /// screen. Ties resolve to the first screen; zero-area intersections
    /// and zero-overlap yield nil, and the caller falls back to the
    /// midpoint screen, then main.
    static func owningScreenIndex(frames: [CGRect], for frame: CGRect) -> Int? {
        let areas = frames.map { rect -> CGFloat in
            let overlap = rect.intersection(frame)
            guard !overlap.isNull else { return 0 }
            return overlap.width * overlap.height
        }
        guard
            let largest = areas.enumerated().max(by: { $0.element < $1.element }),
            largest.element > 0
        else { return nil }
        return largest.offset
    }

    /// Index of the screen containing the frame's midpoint, used when no
    /// screen shows a majority share (off-screen or inter-Space windows
    /// still tile somewhere sane). Nil when no screen contains the
    /// midpoint; the caller falls back to the main screen.
    static func midpointScreenIndex(frames: [CGRect], for frame: CGRect) -> Int? {
        let point = CGPoint(x: frame.midX, y: frame.midY)
        return frames.firstIndex { $0.contains(point) }
    }

    /// Index of the screen whose frame contains `point`, for cursor
    /// resolution. Nil when the point is over no display; the caller
    /// holds the last depiction rather than guessing. Ties (an edge
    /// shared by adjacent displays) resolve to the first screen that
    /// contains the point.
    static func containingScreenIndex(frames: [CGRect], for point: CGPoint) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }
}
