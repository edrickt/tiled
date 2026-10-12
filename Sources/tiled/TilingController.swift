import AppKit

/// Glues the pure `TilingState` + `GridLayout` to real windows through a
/// `WindowGateway`, never touching AX types directly. All element
/// identity, coordinate conversion, observation, and activation live
/// behind the seam; the coordinator keeps focus and handle resolution,
/// the handle->id table, the visible-frame resolution, and the death
/// clock.
///
/// Each canvas's state (occupancy, records, expansion, splitters, undo
/// chapters, notices) lives in `TilingSpace`; this module routes each
/// action to the canvas that owns the window and applies the effects the
/// returned `Outcome` names. The live drag-resize loop lives in
/// `DragTracker` (echo suppression, edge detection, splitter moves, and a
/// drag-end decision); this module feeds it gateway callbacks, routes its
/// decision to the owning canvas, and reads the one effect the pure core
/// cannot: the dragged window's achieved frame.
final class TilingController {
    private let gateway: WindowGateway
    /// Drag-end debounce scheduler for the tracker's drag-out loop.
    /// Injectable so tests fire drag ends without waiting on the runloop.
    private let scheduleDragEnd: DragTracker.DragEndScheduler
    /// Convergence-check scheduler for the late silent-ignore verification.
    /// Injectable so tests fire verifications without waiting 3.5s.
    private let scheduleVerify: DragTracker.DragEndScheduler
    /// The one frame-write policy every push path shares: no-op skip,
    /// off-Space deferral, echo marking, and the convergence check each
    /// write declares. Lazy so its closures can capture self.
    private lazy var frameWriter = FrameWriter(
        gateway: gateway,
        isVisible: { [weak self] in self?.isVisible($0) ?? false },
        markStale: { [weak self] space in
            guard let self else { return }
            self.staleSpaces.insert(space)
        },
        markExpected: { [weak self] id, target in
            self?.tracker.markExpected(id, target)
        },
        scheduleCheck: { [weak self] id, space in
            self?.scheduleVerification(of: [id], on: space)
        },
        log: { [weak self] in self?.dbg($0) })

    /// The drag-resize loop. Lazy so its context closures can capture
    /// self: the tracker decides (echo, edges, splitters, and a drag-end
    /// decision), this module routes the decision to the owning canvas's
    /// reassert and serves record reads. Grids and visible frames live on
    /// the canvases and travel through `GridProvider`.
    private lazy var tracker: DragTracker = DragTracker(
        context: DragTracker.Context(
            slotOf: { [weak self] in self?.trackedSlot(of: $0) },
            occupants: { [weak self] in self?.trackedOccupants ?? [:] },
            spaceOf: { [weak self] in self?.spaceOf(window: $0) },
            occupantsOf: { [weak self] space in self?.trackedOccupants(on: space) ?? [:] },
            liveFrameOf: { [weak self] id in self?.liveFrameForTracker(id) }),
        gridProvider: DragTracker.GridProvider(
            grid: { [weak self] space in
                guard let self else { return GridLayout() }
                return self.spaces[space ?? .displayless]?.grid ?? GridLayout()
            },
            setGrid: { [weak self] updated, space in
                guard let self else { return }
                self.mutateSpace(space ?? .displayless) { $0.grid = updated }
            },
            visibleFrame: { [weak self] space in
                guard let self else { return .zero }
                return self.spaces[space ?? .displayless]?.visibleFrame ?? .zero
            }),
        onDragEnd: { [weak self] decision in self?.handleDragEnd(decision) },
        scheduleDragEnd: scheduleDragEnd,
        log: { [weak self] in self?.dbg($0) })

    /// Display set provider. Production returns one entry per NSScreen;
    /// tests inject synthetic multi-monitor setups. Called on every tiling
    /// action (never cached between them), so replugs and rearranges take
    /// effect without an observer.
    private let screens: ScreenProvider
    /// Per-canvas tiling spaces: each display's each Mission Control
    /// Space runs its own occupancy, records, expansion, splitters, undo
    /// chapters, and transient notices. Reads go through `canvas(for:)`;
    /// the coordinator keeps no derived second copy of any canvas.
    private var spaces: [TilingSpaceKey: TilingSpace] = [:]
    /// The coordinator's handle registry: one id per live handle. The
    /// record itself lives on the canvas holding the window; this table
    /// only answers "which id is this handle", and allocating a fresh id
    /// hands the window over to the handle->id space the canvases share.
    private var windowIDs: [WindowHandle: WindowID] = [:]
    private var nextID: WindowID = 1

    private var pruneTimer: Timer?
    private var screenObserver: NSObjectProtocol?

    /// Death must be confirmed across this window before a slot
    /// releases: a liveness probe that reads dead can be a transient,
    /// not a death. During a laptop lid close, AX answers
    /// `.invalidUIElement` for LIVE windows while the display tears
    /// down (observed on live AX: three tiled windows all pruned by
    /// one tick mid-transition) — the same error a genuinely closed
    /// window returns, so the error code alone cannot distinguish
    /// gone from unreachable. Requiring the dead reading to persist
    /// across `deathConfirmation` seconds (two prune ticks) lets a
    /// transient recover — the machine sleeps before a second tick
    /// can run, and on wake the probes answer again — while a really
    /// dead window releases its slot on the next tick.
    private let deathConfirmation: TimeInterval
    /// Wall clock for the pending-death log only. The confirmation
    /// window itself measures `uptime`. Injectable so tests can move
    /// the wall clock across a simulated sleep.
    private let now: () -> Date
    /// Monotonic awake clock for the confirmation window: seconds of
    /// uptime that do NOT include machine sleep. A wall clock would let
    /// a lid close add its sleeping hours to a pending death, so a
    /// `deadSince` entry left before sleep would confirm on the first
    /// post-wake tick and untile a live window. Uptime freezes across
    /// the sleep, so the window still needs its full `deathConfirmation`
    /// seconds with the machine awake. Injectable so tests advance it
    /// instead of waiting on real seconds.
    private let uptime: () -> TimeInterval
    /// Uptime at the first dead-probe sighting per window. Cleared when
    /// the probe recovers or the record goes away.
    private var deadSince: [WindowID: TimeInterval] = [:]
    /// Last focused canvas (display plus Mission Control Space) observed
    /// through `gateway`. The first focus callback always reports; later
    /// moves within one canvas are filtered so an AX event per window
    /// switch never turns into UI work.
    private var lastFocusedSpace: TilingSpaceKey?
    private var hasResolvedFocusedSpace = false
    /// Known canvases whose geometry was invalidated by a display change
    /// while the Space was hidden. They are re-asserted when shown again:
    /// writing an off-Space window risks moving it to the active Space,
    /// so a hidden canvas waits instead of being corrected in the dark.
    private var staleSpaces: Set<TilingSpaceKey> = []

    /// Called after any state change (for menu refresh).
    var onChange: (() -> Void)?

    /// Called when keyboard focus moves to a window on another display
    /// or another Mission Control Space without any tiling action. Both
    /// change which canvas the status icon depicts. The menu aggregates
    /// every canvas, but the icon is scoped to the focused one, so it
    /// needs this redraw route. A move within one canvas is ignored: the
    /// glyph's layout and occupancy cannot change.
    var onFocusedSpaceChange: (() -> Void)?

    /// Feedback for ineffective hotkey presses: the hotkey path is the
    /// primary interface, so silence trains users to press harder, not
    /// smarter. The delegate turns these into a haptic + announcement;
    /// state and menu side effects are unchanged (safe no-ops stay safe).
    enum Feedback {
        case noFocusedWindow
        case alreadyTiled(slot: Slot)
        /// The undo key was pressed with an empty stack: no destruction
        /// to reverse. Say so on every channel: a silent no-op from the
        /// surface whose promise is "never silently disagree" would be
        /// the one lie the app tells.
        case nothingToUndo
        /// A tiling write was refused. The delegate announces it; there
        /// is no on-screen panel; tiling feedback stays out of the way.
        case refused(windowName: String?)
        /// A ⌥⇧⏎ expand write was refused: same shape as `.refused` but
        /// the announcement must not say “tiled”.
        case expandRefused(windowName: String?)
        /// A tiling write was deferred: its canvas is on a Space the user
        /// cannot see, so the intent stands and reconciles on return.
        /// Never an app refusal: the app did nothing wrong.
        case deferred
        /// The ⌥⇧⌫ evict key was pressed on an untiled window: nothing
        /// holds a slot, so there is nothing to release. Answers instead
        /// of staying silent: the hotkey path never no-ops quietly.
        case nothingToEvict
    }

    var onFeedback: ((Feedback) -> Void)?

    private static let debugLogging = ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1"

    private func dbg(_ message: @autoclosure () -> String) {
        if Self.debugLogging {
            NSLog("Tiled: %@", message())
        }
    }

    init(
        gateway: WindowGateway = LiveWindowGateway(),
        pruneInterval: TimeInterval? = 5.0,
        scheduleDragEnd: @escaping DragTracker.DragEndScheduler = DragTracker.scheduleDragEndOnMain,
        scheduleVerify: @escaping DragTracker.DragEndScheduler = DragTracker.scheduleVerifyOnMain,
        screens: ScreenProvider? = nil,
        deathConfirmation: TimeInterval = 3.0,
        now: @escaping () -> Date = Date.init,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        observeMouseUp: (@escaping () -> Void) -> Void = { _ in }
    ) {
        self.gateway = gateway
        self.scheduleDragEnd = scheduleDragEnd
        self.scheduleVerify = scheduleVerify
        self.deathConfirmation = deathConfirmation
        self.now = now
        self.uptime = uptime
        self.screens = screens ?? { NSScreen.screens.enumerated().map { ScreenInfo(appKit: $0.element, index: $0.offset) } }
        // Windows closed while tiled otherwise linger as ghosts until the
        // next hotkey; release their slots within seconds instead.
        // `pruneInterval == nil` schedules no runloop timer: tests pass nil
        // so no live timer races a test run, and drive `pruneDeadWindows`
        // directly instead.
        if let pruneInterval {
            let prune = Timer.scheduledTimer(withTimeInterval: pruneInterval, repeats: true) {
                [weak self] _ in
                guard let self else { return }
                let before = self.allTiledWindows.count
                self.pruneDeadWindows()
                if self.allTiledWindows.count != before {
                    self.onChange?()
                }
            }
            // Fire in event-tracking modes too, so a long-open menu doesn't
            // stall cleanup; the menu rebuild is suppressed while open anyway.
            RunLoop.main.add(prune, forMode: .common)
            pruneTimer = prune
        } else {
            pruneTimer = nil
        }
        // Reassert the layout when displays change (unplug, rearrange,
        // resolution): splitter fractions stay valid, pixels don't.
        // Hidden Spaces cannot be corrected now (writing an off-Space
        // window can pull it onto the active Space), so they are marked
        // stale and re-asserted when the user swipes back to them.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.dbg("screens changed; reasserting visible canvases")
            self.refreshVisibleFrames(of: Array(self.spaces.keys))
            self.staleSpaces.formUnion(self.spaces.keys)
            self.applyAll()
            self.onChange?()
        }
        // Mouse-up commits the deferred neighbor re-pushes of an edge
        // drag (see DragTracker.mouseLifted). AppDelegate wires the
        // production monitor; the no-op default keeps tests from
        // installing real event monitors.
        observeMouseUp { [weak self] in self?.mouseLifted() }
        // Focus moving to another display or Space changes the status
        // glyph with no tiling action. Subscribe now when AX is already
        // trusted; the permission flow calls `observeFocus()` again
        // once it is. Space changes themselves need no trust: the
        // workspace notification is public.
        if gateway.isTrusted {
            observeFocus()
        }
        gateway.observeSpaceChanges { [weak self] in
            self?.activeSpaceMayHaveChanged()
        }
    }

    deinit {
        pruneTimer?.invalidate()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: Focus observation

    /// Subscribes to keyboard-focus moves through the gateway, replacing
    /// any previous subscription. Safe to call more than once: the
    /// permission flow calls it again once Accessibility trust arrives.
    func observeFocus() {
        gateway.observeFocusChanges { [weak self] in
            self?.focusedCanvasMayHaveChanged()
        }
    }

    /// One focus notification: report only when the canvas key moved,
    /// so switching between two windows on the same display and Space
    /// never redraws a glyph whose layout and occupancy are unchanged.
    private func focusedCanvasMayHaveChanged() {
        let key = focusedSpaceKey()
        guard !hasResolvedFocusedSpace || key != lastFocusedSpace else {
            return
        }
        hasResolvedFocusedSpace = true
        lastFocusedSpace = key
        onFocusedSpaceChange?()
    }

    /// One workspace notification: a swipe changed the Space shown on
    /// some display. The newly visible canvas may have missed a display
    /// reassertion while hidden, and the menu aggregates visible
    /// canvases, so both the stale reassert and the menu refresh are
    /// unconditional; only the glyph is scoped to the focused canvas.
    private func activeSpaceMayHaveChanged() {
        refreshVisibleFrames(of: activeSpaceKeys())
        reassertStaleActiveSpaces()
        let key = focusedSpaceKey()
        if !hasResolvedFocusedSpace || key != lastFocusedSpace {
            hasResolvedFocusedSpace = true
            lastFocusedSpace = key
            onFocusedSpaceChange?()
        }
        onChange?()
    }

    /// Re-applies every currently visible canvas that a display change
    /// marked stale, and clears the marks. One pass per screen; the
    /// active Space lookup is fresh, so a swipe is enough to know which
    /// canvas just appeared.
    private func reassertStaleActiveSpaces() {
        let stale = activeSpaceKeys().filter { staleSpaces.contains($0) }
        guard !stale.isEmpty else { return }
        for key in stale {
            dbg("reasserting stale canvas screen=\(key.screen?.rawValue ?? -1)")
            applyAll(on: key)
        }
    }

    // MARK: Hotkey entry point

    /// The requester for a slot hotkey and the canvas the request belongs
    /// to: prunes dead windows first, then resolves the focused window to
    /// its registry id. Nil (with feedback) when nothing is focused.
    private func requesterAndCanvas(
        for slot: Slot
    ) -> (id: WindowID, handle: WindowHandle, key: TilingSpaceKey)? {
        pruneDeadWindows()
        guard let handle = gateway.focusedWindow() else {
            dbg("no focused window for \(slot.rawValue)")
            onFeedback?(.noFocusedWindow)
            return nil
        }
        let id = windowID(for: handle)
        return (id, handle, spaceKeyForRequester(id, handle: handle))
    }

    func handle(slot: Slot) {
        guard let (id, handle, key) = requesterAndCanvas(for: slot) else { return }
        let context = placementContext(for: key)
        // An expanded window getting a slot hotkey comes back to earth
        // first: its own slot becomes the strict no-op below; a different
        // slot retiles from the collapsed state.
        let (collapse, outcome) = mutateSpace(key) { canvas in
            canvas.attach(id, handle: handle)
            let collapse = canvas.isExpanded(id)
                ? canvas.collapseExpanded(id, context: context)
                : nil
            return (collapse, canvas.apply(slot: slot, requester: id, context: context))
        }
        let collapsed = collapse != nil
        if let collapse { announce(collapse.result) }
        if case .alreadyTiled = outcome.result {
            // Already in that tile: a strict no-op; no state, error, or
            // menu side effects. Still signal it so the hotkey path can
            // confirm subtly (the Welcome tab teaches this as safety).
            dbg("noop win\(id) already in \(slot.rawValue)")
            onFeedback?(.alreadyTiled(slot: slot))
            // A collapse that ran just before the no-op already wrote a
            // frame, so the menu must refresh even though the placement
            // itself changed nothing.
            if collapsed { onChange?() }
            return
        }
        apply(outcome, on: key)
        announce(outcome.result)
        if collapsed { onChange?() }
        // The reflow's survivors share the event's undo chapter: undo
        // restores the pre-event world in one ⌃⇧⌘Z (a move with no
        // eviction has no chapter of its own, so the reflow starts one).
        // The canvas pushed the chapter; the coordinator refreshes.
        onChange?()
    }

    /// Maps one canvas outcome to the hotkey feedback channel: refusals
    /// are announced, everything else is silent (the canvas's notice/
    /// error carry the rest).
    private func announce(_ result: TilingSpace.Outcome.Result) {
        switch result {
        case .refused(let windowName):
            onFeedback?(.refused(windowName: windowName))
        case .expandRefused(let windowName):
            onFeedback?(.expandRefused(windowName: windowName))
        case .deferred:
            onFeedback?(.deferred)
        case .placed, .alreadyTiled, .nothingToEvict:
            break
        }
    }

    /// Applies one canvas action's coordinator effects: the handle
    /// registry, observation, raising, focus, and the convergence
    /// schedule. `notice`/`error` are already on the canvas.
    private func apply(_ outcome: TilingSpace.Outcome, on key: TilingSpaceKey) {
        // Restored-not-re-housed windows: untiled for good. A re-housed
        // window stayed tiled, so its record and observation survive.
        for evicted in outcome.forget {
            forgetBookkeeping(evicted)
        }
        for window in outcome.observe {
            observe(window: window)
        }
        // Restored windows sit BELOW the arrangement they left: an
        // evictee returns to its pre-tile frame and must never cover the
        // occupants that stayed (or the requester).
        if outcome.raise {
            raiseOccupants(on: key)
        }
        // A swap leaves the user's attention on the window that took the
        // requester's old tile: focus follows the displaced window.
        if let focusAfter = outcome.focusAfter, let handle = handle(of: focusAfter) {
            gateway.focus(handle)
        }
        if !outcome.verify.isEmpty {
            scheduleVerification(of: outcome.verify, on: key)
        }
    }

    /// The collaborators one action needs. A fresh context is built per
    /// action so a re-resolved canvas (a swipe, a focus move) is always
    /// reflected; the id allocator writes through to the handle table.
    private func placementContext(for key: TilingSpaceKey) -> TilingSpace.Context {
        TilingSpace.Context(
            gateway: gateway,
            frameWriter: frameWriter,
            tracker: tracker,
            space: key,
            allocateID: { [weak self] handle in
                guard let self else { return 0 }
                let id = self.nextID
                self.nextID += 1
                self.windowIDs[handle] = id
                return id
            },
            log: { [weak self] message in self?.dbg(message) })
    }

    /// Pending convergence checks by window: a newer placement for the
    /// same window supersedes (cancels) the older check, and forget paths
    /// cancel outright: a verification must never roll back a window
    /// that already moved on.
    private var pendingVerifications: [WindowID: () -> Void] = [:]

    /// Schedules one convergence check per window, superseding any pending
    /// check for the same window: only the latest write is ever judged.
    private func scheduleVerification(of placed: [WindowID], on space: TilingSpaceKey) {
        for window in placed {
            pendingVerifications[window]?()
            let checkSpace = space
            pendingVerifications[window] = scheduleVerify { [weak self] in
                self?.pendingVerifications[window] = nil
                self?.verifyConvergence(window, on: checkSpace)
            }
        }
    }

    private func cancelVerification(_ id: WindowID) {
        pendingVerifications[id]?()
        pendingVerifications[id] = nil
    }

    /// Late silent-ignore check: `scheduleVerification` fires this one
    /// verify-delay after the placement. Converged / inconclusive /
    /// re-placed windows are left alone; a window whose write drew total
    /// AX silence is rolled back exactly like a refused write (slot
    /// released, tracker entry cleared, standard refusal surfaced), so
    /// state and screen agree instead of disagreeing silently.
    private func verifyConvergence(_ id: WindowID, on space: TilingSpaceKey) {
        guard let errorSpace = spaceOf(window: id),
            spaces[errorSpace]?.state.slot(of: id) != nil
        else { return }
        guard tracker.convergence(for: id) == .ignored else { return }
        // Name the window before its record goes; the rollback itself
        // writes nothing (the write never took effect).
        let name = appName(for: id) ?? "That window"
        let hasError = mutateSpace(errorSpace) { canvas in
            canvas.discard(window: id, context: placementContext(for: errorSpace))
            return canvas.error != nil
        }
        forgetBookkeeping(id)
        // A later error (e.g. a newer refusal) wins over this late one.
        // Scoped to the window's own canvas: the placement may tile onto
        // a background display or Space while focus sits elsewhere.
        if !hasError {
            mutateSpace(errorSpace) {
                $0.error = TilingSpace.refusalMessage(windowName: name)
            }
        }
        onFeedback?(.refused(windowName: name))
        onChange?()
        dbg("verify FAILED win\(id): silent ignore, rolled back")
    }

    // MARK: Placement (delegated)

    /// Recomputes and pushes rects for all occupants (resize propagation).
    /// Each canvas reasserts its own occupants under its own grid and
    /// reports refusals: the push half of the tracker's decide/push
    /// split. Nil reasserts every currently visible canvas (display
    /// changes); a key scopes to one canvas (reset, restore, stale
    /// reassert). The splitters are already correct on every one of these
    /// paths, so the source is `.grid`.
    private func applyAll(on space: TilingSpaceKey? = nil) {
        let keys: [TilingSpaceKey] =
            if let space { [space] } else { activeSpaceKeys() }
        for key in keys {
            // The mark means "this canvas still owes a reassert", so it may
            // only be cleared by a reassert with real geometry to write
            // against: `reassert` early-returns on a degenerate visible
            // frame (and an absent display cannot be written), and clearing
            // the mark then would drop the deferred reassert for good.
            let hasGeometry = isDisplayAttached(key.screen)
                && (spaces[key]?.visibleFrame).map { $0.width > 0 && $0.height > 0 } == true
            mutateSpace(key) {
                $0.reassert(.grid, context: placementContext(for: key))
            }
            if hasGeometry {
                staleSpaces.remove(key)
            }
        }
    }

    /// The window's frame as the app reports it: the silent-convergence
    /// check consults it before calling echo silence an ignore. Never the
    /// tracker's intent, which equals the push target by definition.
    private func liveFrameForTracker(_ id: WindowID) -> CGRect? {
        guard let record = record(of: id) else { return nil }
        return gateway.frame(of: record.handle)
    }

    /// Pure screen-ownership rule, extracted for tests: index of the
    /// screen showing the largest share of `frame`, so straddles resolve
    /// to the mostly-visible side and never jitter on the midpoint.
    /// Compared by intersection *area*, not width: vertically stacked
    /// displays at equal widths produce equal-width intersections, so a
    /// width-only comparison always returns the first screen. Ties resolve
    /// to the first screen; zero-area intersections and zero-overlap yield
    /// nil, and the caller falls back to the midpoint screen, then main.
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

    /// Provider-backed screen info owning `frame` (same fallback chain
    /// as the screen-ownership rule): largest overlap, then midpoint,
    /// then main.
    private func visibleScreen(for frame: CGRect) -> ScreenInfo? {
        let infos = screens()
        if let index = Self.owningScreenIndex(frames: infos.map(\.frame), for: frame) {
            return infos[index]
        }
        if let index = Self.midpointScreenIndex(frames: infos.map(\.frame), for: frame) {
            return infos[index]
        }
        dbg("no screen overlaps \(frame); falling back to main")
        return mainScreenInfo(infos)
    }

    /// The provider's main screen: first entry, mirroring NSScreen.main
    /// order. Nil when the provider reports no displays; the caller then
    /// falls back to raw frames.
    private func mainScreenInfo(_ infos: [ScreenInfo]) -> ScreenInfo? {
        infos.first
    }

    /// The visible frame of the display a canvas lives on: the one
    /// geometry every rect on that canvas derives from, resolved from the
    /// canvas's own display and never from a window's frame. A display-less
    /// key (headless, withheld Space) uses the main screen, then the live
    /// main screen, then zero.
    private func visibleFrame(for space: TilingSpaceKey) -> CGRect {
        if let screen = space.screen,
            let info = screens().first(where: { $0.id == screen })
        {
            return info.visibleFrame
        }
        return mainScreenInfo(screens())?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
    }

    /// A brand-new canvas with its visible frame resolved from its own
    /// display. Existing canvases keep their frame until one of the
    /// refresh events; the coordinator never re-resolves per action.
    private func establishedCanvas(for space: TilingSpaceKey) -> TilingSpace {
        var canvas = TilingSpace()
        canvas.visibleFrame = visibleFrame(for: space)
        return canvas
    }

    /// Whether a canvas's own display is currently attached. A key with no
    /// screen is genuinely display-less (headless, withheld Space): it has
    /// no display to be absent, so the main-screen fallback still applies.
    private func isDisplayAttached(_ screen: ScreenID?) -> Bool {
        guard let screen else { return true }
        return screens().contains { $0.id == screen }
    }

    /// Re-resolves the stored visible frame of the named canvases: the
    /// refresh half of a display change and a swipe back. Keys without a
    /// canvas yet are left alone; they resolve on first use. A canvas whose
    /// display is absent keeps the geometry it had — it is re-resolved on
    /// replug — so a kept-for-replug canvas never adopts the main display's
    /// frame.
    private func refreshVisibleFrames(of keys: [TilingSpaceKey]) {
        for key in keys where spaces[key] != nil {
            guard isDisplayAttached(key.screen) else { continue }
            spaces[key]?.visibleFrame = visibleFrame(for: key)
        }
    }

    /// Canvas for a tiling request: a tiled window's own canvas wins (it
    /// never migrates mid-session), else the owning display's currently
    /// shown Space from the window's live frame, else its pre-tile frame,
    /// else the focused canvas. Untiled windows with no readable frame
    /// land on the focused canvas, never guessed from another monitor's
    /// geometry.
    private func spaceKeyForRequester(_ id: WindowID, handle: WindowHandle) -> TilingSpaceKey {
        if let owned = spaceOf(window: id) { return owned }
        if let frame = gateway.frame(of: handle),
           let info = screenInfo(for: frame)
        { return tilingKey(for: info.id) }
        if let record = record(of: id), record.preTileFrame != .zero,
           let info = screenInfo(for: record.preTileFrame)
        { return tilingKey(for: info.id) }
        return focusedSpaceKey()
    }

    /// Screen info owning `frame`, or the main screen when nothing
    /// overlaps (off-screen or inter-Space windows still tile somewhere
    /// sane). Nil only when the provider reports no displays at all.
    private func screenInfo(for frame: CGRect) -> ScreenInfo? {
        visibleScreen(for: frame)
    }

    /// Pure screen-fallback rule, extracted for tests: index of the screen
    /// containing the frame's midpoint, used when no screen shows a
    /// majority share (off-screen or inter-Space windows still tile
    /// somewhere sane). nil when no screen contains the midpoint; the
    /// caller falls back to the main screen.
    static func midpointScreenIndex(frames: [CGRect], for frame: CGRect) -> Int? {
        let point = CGPoint(x: frame.midX, y: frame.midY)
        return frames.firstIndex { $0.contains(point) }
    }

    // MARK: Registry

    private func windowID(for handle: WindowHandle) -> WindowID {
        // Reuse the table id only while the handle still has a record on
        // some canvas: a released window's next resolution is a fresh
        // window as far as the canvas state is concerned.
        if let existing = windowIDs[handle], spaceOf(window: existing) != nil {
            return existing
        }
        let id = nextID
        nextID += 1
        windowIDs[handle] = id
        return id
    }

    /// Existing id for a live handle whose record still lives on a
    /// canvas, without creating a stub.
    private func recordID(for handle: WindowHandle) -> WindowID? {
        guard let id = windowIDs[handle], spaceOf(window: id) != nil else { return nil }
        return id
    }

    /// Drops records whose handle is gone (window closed, app quit).
    /// Called lazily before each hotkey and by the prune timer; internal so
    /// tests can drive ghost cleanup without waiting on the runloop. Only
    /// confirmed deaths prune: a busy app's unanswerable probe is unknown,
    /// and pruning on a maybe would untile a live window.
    func pruneDeadWindows() {
        var dead: [(key: TilingSpaceKey, id: WindowID, handle: WindowHandle)] = []
        for (key, canvas) in spaces {
            for (id, record) in canvas.records
            where gateway.liveness(of: record.handle) == .dead {
                dead.append((key, id, record.handle))
            }
        }
        let timestamp = now()
        let awake = uptime()
        for entry in dead {
            let first = deadSince[entry.id] ?? awake
            guard awake - first >= deathConfirmation else {
                deadSince[entry.id] = first
                dbg(
                    "prune win\(entry.id): dead handle sighted at \(timestamp), "
                        + "awaiting confirmation")
                continue
            }
            deadSince[entry.id] = nil
            dbg("prune win\(entry.id): dead handle confirmed, releasing slot")
            // Hand the element back to the adapter before the record
            // (the only holder of the handle) goes away.
            gateway.release(entry.handle)
            let outcome = mutateSpace(entry.key) {
                $0.release(window: entry.id, context: placementContext(for: entry.key))
            }
            apply(outcome, on: entry.key)
        }
        // A recovered probe or a vanished record clears the pending
        // death: only windows still reading dead stay marked.
        let deadIDs = Set(dead.map(\.id))
        deadSince = deadSince.filter { deadIDs.contains($0.key) }
    }

    /// Clears the coordinator-side bookkeeping of a window the canvas
    /// released: the handle table, the death clock, and any pending
    /// convergence check. The record itself is already gone.
    private func forgetBookkeeping(_ id: WindowID) {
        cancelVerification(id)
        deadSince[id] = nil
        windowIDs = windowIDs.filter { $0.value != id }
    }

    private func raiseOccupants(on space: TilingSpaceKey) {
        // Raising an off-Space window can pull it to the visible Space;
        // z-order is a nicety, so a hidden canvas waits for its swipe.
        guard isVisible(space) else { return }
        // Expanded windows are non-evicted too: they cover the layout
        // while holding their slots, and the evictee sits below them.
        for (_, id) in spaceState(for: space).occupants
            .sorted(by: { $0.key.rawValue < $1.key.rawValue })
        {
            guard let handle = spaces[space]?.handle(of: id) else { continue }
            gateway.raise(handle)
        }
    }

    // MARK: Bulk operations

    func untileAll() {
        pruneDeadWindows()
        // Untile-all dissolves only the focused canvas: other displays
        // and Spaces keep their arrangements, so the legacy zero-arg
        // form resolves the focused canvas.
        untileAll(in: focusedSpaceKey())
    }

    /// Dissolves one display's currently shown canvas (the screen-based
    /// form menus and tests use). Other canvases, including other Spaces
    /// on the same display, are untouched.
    func untileAll(on screen: ScreenID?) {
        untileAll(in: tilingKey(for: screen))
    }

    /// Dissolves one tiling canvas, leaving every other canvas alone.
    /// The undo chapter tags each window with its canvas so the recovery
    /// retiles per display and per Space.
    private func untileAll(in space: TilingSpaceKey) {
        pruneDeadWindows()
        let outcome = mutateSpace(space) {
            $0.untileAll(context: placementContext(for: space))
        }
        apply(outcome, on: space)
        onChange?()
    }

    /// Snaps all splitters back to defaults and re-tiles everyone. The
    /// displaced fractions are kept as a one-step restore (same pattern
    /// as the shortcuts reset backup), so the app's "destruction is
    /// always reversible" ethic holds for drag positions too. Scoped to
    /// the focused canvas: other displays and Spaces keep their drag
    /// positions.
    func resetDividers() {
        resetDividers(in: focusedSpaceKey())
    }

    /// Snaps one display's currently shown canvas's splitters back to
    /// defaults and re-tiles its occupants (the screen-based form menus
    /// and tests use); every other canvas is untouched.
    func resetDividers(on screen: ScreenID?) {
        resetDividers(in: tilingKey(for: screen))
    }

    private func resetDividers(in space: TilingSpaceKey) {
        mutateSpace(space) { canvas in
            canvas.visibleFrame = visibleFrame(for: space)
            _ = canvas.resetSplitters(context: placementContext(for: space))
        }
        onChange?()
    }

    /// Restores the splitter fractions parked by the last reset, or false
    /// when there is no backup (fresh install, or already restored once).
    /// Scoped to the focused canvas, like `resetDividers`.
    @discardableResult
    func restoreSplitters() -> Bool {
        restoreSplitters(in: focusedSpaceKey())
    }

    /// Restores one display's currently shown canvas's parked splitters
    /// (the screen-based form menus and tests use).
    @discardableResult
    func restoreSplitters(on screen: ScreenID?) -> Bool {
        restoreSplitters(in: tilingKey(for: screen))
    }

    private func restoreSplitters(in space: TilingSpaceKey) -> Bool {
        guard spaces[space]?.hasSplitterBackup == true else { return false }
        mutateSpace(space) {
            $0.restoreSplitters(context: placementContext(for: space))
        }
        onChange?()
        return true
    }

    /// The slot the focused window would return to if it is currently
    /// expanded; nil otherwise. Drives the expand row's stateful title:
    /// the toggle must show its state, not just its combo.
    var expandedFocusedSlot: Slot? {
        guard let handle = gateway.focusedWindow(),
            let id = recordID(for: handle),
            let key = spaceOf(window: id),
            spaces[key]?.isExpanded(id) == true
        else { return nil }
        return spaces[key]?.state.slot(of: id)
    }

    /// Undoes the freshest destructive tiling action: a layout switch, an
    /// ordinary eviction, or a swap. All share one recovery path: the
    /// displaced windows return to their slots, the requester to its
    /// pre-tile frame (a swap's requester entry re-tiles it into its
    /// vacated tile, swapping back). Consumes the entry it restores, so
    /// repeated ⌃⌥⇧⌘Z walks back through history up to `undoDepth`: the
    /// stack, not amnesia, bounds the past.
    func undoLastDisplacement() {
        undoLastDisplacement(in: focusedSpaceKey())
    }

    /// Undoes one display's currently shown canvas's freshest destructive
    /// action (the screen-based form menus and tests use). Other canvases,
    /// including other Spaces on the same display, keep their history.
    func undoLastDisplacement(on screen: ScreenID?) {
        undoLastDisplacement(in: tilingKey(for: screen))
    }

    private func undoLastDisplacement(in space: TilingSpaceKey) {
        guard let entry = mutateSpace(space, { $0.undoStack.popLast() }) else {
            // Expired or empty: the promise needs an answer, not silence
            // (see the undo-expiry feedback below).
            onFeedback?(.nothingToUndo)
            return
        }
        pruneDeadWindows()
        mutateSpace(space) { $0.error = nil; $0.notice = nil }
        // A slot may have been re-tiled, and the canvas may have moved to
        // the other layout, since the chapter was pushed (the undo stack
        // survives new actions by design). Both are honored like any
        // tile: every current occupant the restoration would land on
        // (overlapping cells) or contradict (the other layout) is untiled
        // to its pre-tile frame first. Undo can therefore never
        // double-book a cell or leave two layouts on one canvas. Chapter
        // members are exempt: each has an entry of its own that re-places
        // it (a swap or step-aside chapter's destinations may overlap one
        // another), so untiling one would only churn its identity — its
        // entry restores it in place. A chapter's own requester without
        // an entry still steps aside where it would block a restore,
        // exactly as before.
        let chapterHandles = Set(entry.snapshot.map(\.handle))
        var blockers: Set<WindowID> = []
        for evicted in entry.snapshot {
            let destination = evicted.space ?? space
            for (slot, current) in spaceState(for: destination).occupants
            where slot.overlaps(evicted.slot) || slot.layout != evicted.slot.layout {
                guard let handle = spaces[destination]?.handle(of: current),
                      handle != evicted.handle,
                      !chapterHandles.contains(handle)
                else { continue }
                blockers.insert(current)
            }
        }
        for current in blockers.sorted() {
            untile(window: current, reflowing: false)
        }
        // Group the chapter by destination canvas: each window returns
        // to the canvas it left (legacy untagged entries restore into
        // the undone canvas). The requester restores to its pre-tile
        // frame wherever it sits: frames, not spaces, decide that.
        var bySpace: [TilingSpaceKey: [EvictedWindow]] = [:]
        for evicted in entry.snapshot {
            bySpace[evicted.space ?? space, default: []].append(evicted)
        }
        var restored = 0
        var errors: [String] = []
        // Restore the requester once, in the canvas owning its record.
        // (Its record may already be gone; the restore is a no-op then,
        // but the per-canvas unwinding below still needs its id looked up
        // in the same state.)
        if let requester = entry.requester {
            let requesterSpace = spaceOf(window: requester) ?? space
            mutateSpace(requesterSpace) {
                $0.restore(
                    window: requester, context: placementContext(for: requesterSpace))
            }
            forgetBookkeeping(requester)
        }
        for (destination, group) in bySpace {
            let result = mutateSpace(destination) {
                $0.undo(
                    snapshot: group, requester: nil,
                    context: placementContext(for: destination))
            }
            for window in result.observe {
                observe(window: window)
            }
            if result.notice != nil {
                restored += group.count
            }
            if let error = result.error { errors.append(error) }
        }
        if restored > 0 {
            let total = entry.snapshot.count
            let noun = total == 1 ? "1 window" : "\(total) windows"
            mutateSpace(space) {
                $0.notice = "Undid displacement \u{00B7} \(noun) restored."
            }
        } else if let error = errors.first {
            mutateSpace(space) { $0.error = error }
        } else if entry.snapshot.isEmpty {
            // Untile-all chapter with no surviving windows: the requester
            // restore above already ran; report the standard empty result.
            mutateSpace(space) { $0.error = MenuText.restoreEvictedWindowsFailure }
        } else if errors.isEmpty {
            mutateSpace(space) { $0.error = MenuText.restoreEvictedWindowsFailure }
        }
        // A nil requester with an empty snapshot (untile-all chapter
        // whose windows all died) still consumes the entry: nothing to
        // restore, standard error above.
        onChange?()
    }

    // MARK: Live resize (observe & decide)

    /// The user released the mouse button: the tracker commits every
    /// splitter move an in-progress edge drag made as a resize decision.
    /// Wired from the production mouse-up monitor; tests call it directly.
    func mouseLifted() {
        tracker.mouseLifted()
    }

    /// Routes one drag-end decision to the owning canvas. The tracker
    /// decided; the coordinator performs the one effect the pure core
    /// cannot — reading the dragged window's achieved frame — and hands
    /// it to the canvas's resize reassert. A snapback reasserts the same
    /// canvas under its existing splitters; an untile is the unchanged
    /// drag-out path.
    private func handleDragEnd(_ decision: DragTracker.DragDecision) {
        switch decision {
        case .resize(let id):
            guard let handle = handle(of: id), let achieved = gateway.frame(of: handle) else {
                return
            }
            reassert(id, source: .resize(dragged: id, achieved: achieved))
        case .snapback(let id):
            reassert(id, source: .grid)
        case .untile(let id):
            untileFromDrag(id)
        }
    }

    /// Reasserts the canvas owning `id` for the given source, then applies
    /// the outcome and refreshes the menu. One spelling for the drag's
    /// resize and snapback settles, which differ only in the source.
    private func reassert(_ id: WindowID, source: TilingSpace.ReassertSource) {
        guard let key = spaceOf(window: id) else { return }
        let outcome = mutateSpace(key) {
            $0.reassert(source, context: placementContext(for: key))
        }
        apply(outcome, on: key)
        onChange?()
    }

    /// Production mouse-up registrar: global monitors deliver clicks that
    /// go to other apps — where window-edge drags live — and the local
    /// monitor covers clicks this process receives. Both forward the
    /// event untouched; the handler itself filters (no pending resize is
    /// a no-op). Needs the same accessibility permission as AX.
    static func observeLeftMouseUp(_ fire: @escaping () -> Void) {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in fire() }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            fire()
            return event
        }
    }

    /// Registers the gateway's change handler and feeds callbacks to the
    /// tracker. Element identity and dedupe live behind the seam; echo,
    /// edges, splitters, and coalescing live in the tracker. The
    /// destruction handler releases the slot the moment the OS says the
    /// element is gone, instead of waiting out the prune tick and its
    /// confirmation window.
    private func observe(window id: WindowID) {
        guard let handle = handle(of: id) else { return }
        gateway.observe(
            handle,
            onChange: { [weak self] in
                guard let self else { return }
                guard let currentID = self.recordID(for: handle) else { return }
                guard let frame = self.gateway.frame(of: handle) else { return }
                self.tracker.handleChange(id: currentID, frame: frame)
            },
            onDestroyed: { [weak self] in
                self?.windowDestroyed(handle)
            })
    }

    /// The OS reported this window's element destroyed. That is not a
    /// probe failure — the element is gone — but element identity can
    /// churn while the window lives (display teardowns break it), so the
    /// report accelerates the death check rather than replacing it: a
    /// `.dead` verdict releases the slot on the spot, anything else
    /// leaves the ordinary prune cadence in charge. Called on the main
    /// thread by both adapters.
    private func windowDestroyed(_ handle: WindowHandle) {
        guard let id = recordID(for: handle) else { return }
        guard gateway.liveness(of: handle) == .dead else {
            dbg("destroyed win\(id): still live by the death standard; prune cadence decides")
            return
        }
        let key = spaceOf(window: id) ?? focusedSpaceKey()
        dbg("destroyed win\(id): releasing slot now")
        gateway.release(handle)
        let outcome = mutateSpace(key) {
            $0.release(window: id, context: placementContext(for: key))
        }
        apply(outcome, on: key)
        onChange?()
    }

    // MARK: Presentation

    struct TiledWindowInfo {
        let id: WindowID
        let slot: Slot
        let appName: String?
        /// Display the window tiles on (nil = single-space legacy).
        /// The menu groups rows per monitor when more than one is tiled.
        var screen: ScreenID? = nil
        /// Display name for the menu group header.
        var screenName: String? = nil
    }

    /// The display currently owning focus, resolved from the focused
    /// window's live frame (else its pre-tile frame, else main).
    var focusedScreen: ScreenID? { focusedScreenID() }

    /// The focused tiling canvas (display plus Mission Control Space),
    /// captured once so a UI pass can read the glyph's layout and
    /// occupancy consistently even if focus moves between the reads.
    var focusedTilingSpace: TilingSpaceKey { focusedSpaceKey() }

    var tiledWindowsInfo: [TiledWindowInfo] {
        allTiledWindowsInfo()
    }

    /// The display name to speak for a canvas, or nil when naming it would
    /// distinguish nothing: with a single display attached the glyph's
    /// monitor is unambiguous and the VoiceOver line is left alone. With
    /// more than one display the name tells the user which monitor the
    /// glyph depicts, matching the menu headers.
    func displayName(for space: TilingSpaceKey) -> String? {
        let infos = screens()
        guard infos.count > 1 else { return nil }
        return infos.first(where: { $0.id == space.screen })?.name
    }

    /// Tiled windows on the focused canvas (tile submenu scope).
    var focusedTiledWindowsInfo: [TiledWindowInfo] {
        let key = focusedSpaceKey()
        let screenName = screens().first(where: { $0.id == key.screen })?.name
        return (spaces[key]?.state.occupants ?? [:])
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map {
                TiledWindowInfo(
                    id: $0.value, slot: $0.key, appName: appName(for: $0.value),
                    screen: key.screen, screenName: screenName)
            }
    }

    /// Every tiled window on every currently shown canvas, grouped by
    /// display (manage list scope). Windows parked in Spaces that are
    /// hidden right now stay managed, but are absent from the menu: the
    /// menu describes what a hotkey acts on, and a hotkey acts on the
    /// visible canvas. With no displays (headless tests), falls back to
    /// listing every remembered canvas.
    func allTiledWindowsInfo() -> [TiledWindowInfo] {
        let infos = screens()
        var sources: [(key: TilingSpaceKey, screenName: String?)] =
            if infos.isEmpty {
                spaces.keys.sorted(by: Self.spaceOrder).map { ($0, nil) }
            } else {
                infos.map { (tilingKey(for: $0.id), $0.name) }
            }
        // A canvas whose Space id the server withheld holds windows too,
        // and it is this display's canvas, not a hidden Space: list it so
        // the manage rows and Untile All can still reach them.
        for info in infos {
            let fallback = TilingSpaceKey(screen: info.id, space: nil)
            guard withheldCanvas(on: info.id) != nil,
                  !sources.contains(where: { $0.key == fallback })
            else { continue }
            sources.append((fallback, info.name))
        }
        var rows: [TiledWindowInfo] = []
        for source in sources {
            let occupants = spaces[source.key]?.state.occupants ?? [:]
            for (slot, id) in occupants.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                rows.append(TiledWindowInfo(
                    id: id, slot: slot, appName: appName(for: id),
                    screen: source.key.screen, screenName: source.screenName))
            }
        }
        return rows
    }

    /// Stable menu order for canvases: display first, then Space.
    private static func spaceOrder(_ a: TilingSpaceKey, _ b: TilingSpaceKey) -> Bool {
        let left = a.screen?.rawValue ?? -1
        let right = b.screen?.rawValue ?? -1
        if left != right { return left < right }
        return (a.space?.rawValue ?? 0) < (b.space?.rawValue ?? 0)
    }



    /// Every tiled window on every monitor (prune timer + legacy counts).
    private var allTiledWindows: [WindowID] {
        spaces.values.flatMap(\.state.tiledWindows)
    }

    /// Brings a tiled window to the front without disturbing the layout.
    func focus(window id: WindowID) {
        guard let handle = handle(of: id) else { return }
        gateway.focus(handle)
    }

    /// Evicts the focused window (⌥⇧⌫): restores its pre-tile frame and
    /// releases the slot. Untiled focused windows and failed focuses are
    /// safe no-ops with the standard feedback; like `untile`, eviction
    /// keeps no undo chapter (the restoration IS the frame) — unless the
    /// reflow moved a survivor into the freed cells, which is its own
    /// chapter.
    func handleEvict() {
        pruneDeadWindows()
        guard let handle = gateway.focusedWindow() else {
            dbg("no focused window for evict")
            onFeedback?(.noFocusedWindow)
            return
        }
        let id = windowID(for: handle)
        let key = spaceOf(window: id) ?? focusedSpaceKey()
        let outcome = mutateSpace(key) { canvas in
            canvas.attach(id, handle: handle)
            return canvas.evict(window: id, context: placementContext(for: key))
        }
        if case .nothingToEvict = outcome.result {
            onFeedback?(.nothingToEvict)
            return
        }
        apply(outcome, on: key)
        onChange?()
    }

    /// Untiles one window, restoring its pre-tile frame. The freed cells
    /// reflow to the mergeable survivor; undo's preparatory untiles pass
    /// `reflowing: false` (they make room for a restoration that follows
    /// immediately, and must not churn the layout nor push a chapter).
    func untile(window id: WindowID) {
        untile(window: id, reflowing: true)
    }

    func untile(window id: WindowID, reflowing: Bool) {
        pruneDeadWindows()
        // The window's own canvas clears (not the focused one): menu
        // untile rows act on background displays and Spaces.
        let key = spaceOf(window: id) ?? focusedSpaceKey()
        let outcome = mutateSpace(key) {
            $0.untile(
                window: id, reflowing: reflowing, context: placementContext(for: key))
        }
        apply(outcome, on: key)
        onChange?()
    }

    // MARK: Expand toggle (⌥⇧⏎)

    /// Expands the focused window to fill its screen; pressing again
    /// retiles it to its previous tile (or restores its previous frame
    /// when it wasn't tiled). Layout state is untouched: a tiled window
    /// keeps its slot while expanded, exactly like focusing it.
    func handleExpandToggle() {
        pruneDeadWindows()
        guard let handle = gateway.focusedWindow() else {
            dbg("no focused window for expand toggle")
            onFeedback?(.noFocusedWindow)
            return
        }
        let id = windowID(for: handle)
        let key = spaceOf(window: id) ?? focusedSpaceKey()
        let outcome = mutateSpace(key) { canvas in
            canvas.attach(id, handle: handle)
            return canvas.expandToggle(
                window: id, context: placementContext(for: key))
        }
        announce(outcome.result)
        onChange?()
    }

    /// Slot a window presents to the tracker: expanded windows read as
    /// untiled, so the tracker never diff-resizes them into splitter
    /// moves or drags them out.
    private func trackedSlot(of id: WindowID) -> Slot? {
        guard let key = spaceOf(window: id), spaces[key]?.isExpanded(id) != true else {
            return nil
        }
        return spaces[key]?.state.slot(of: id)
    }

    private var trackedOccupants: [Slot: WindowID] {
        var all: [Slot: WindowID] = [:]
        for space in spaces.values {
            for (slot, id) in space.state.occupants where !space.isExpanded(id) {
                all[slot] = id
            }
        }
        return all
    }

    /// Unexpanded occupants of one canvas.
    private func trackedOccupants(on space: TilingSpaceKey) -> [Slot: WindowID] {
        guard let canvas = self.space(for: space) else { return [:] }
        return canvas.state.occupants.filter { !canvas.isExpanded($0.value) }
    }

    // MARK: Drag-out untile

    /// The user dragged a tiled window past the untile distance and
    /// dropped it: release the slot and leave the window where it was
    /// dropped: no pre-tile restore, the drag IS the placement. (Short
    /// drags snap back inside the tracker and never reach here.)
    func untileFromDrag(_ id: WindowID) {
        guard record(of: id) != nil else { return }
        let key = spaceOf(window: id) ?? focusedSpaceKey()
        let outcome = mutateSpace(key) {
            $0.untileFromDrag(window: id, context: placementContext(for: key))
        }
        apply(outcome, on: key)
        dbg("drag-untile win\(id)")
        onChange?()
    }

    private func appName(for id: WindowID) -> String? {
        record(of: id).flatMap { gateway.appName(of: $0.handle) }
    }

    var isTrusted: Bool { gateway.isTrusted }

    // MARK: Per-canvas spaces

    /// The canvas currently shown on `screen` (nil resolves the main
    /// display). Reads resolve through the same key the next action
    /// would target, withheld-Space fallback included, so a menu or test
    /// can never observe a different canvas than an action touches.
    func canvas(for screen: ScreenID?) -> TilingSpace {
        spaces[actionSpaceKey(for: screen)] ?? TilingSpace()
    }

    /// One canvas by key: the single scoped read surface. A key that has
    /// never been used reads as an empty canvas (never nil), so callers
    /// assert against the same shape an action would have created.
    func canvas(for space: TilingSpaceKey) -> TilingSpace {
        spaces[space] ?? TilingSpace()
    }

    /// One tiling canvas's stored space, if it has been used yet. Keys
    /// carry both the display and the Mission Control Space; a nil Space
    /// id is the per-display fallback when the OS cannot name the Space.
    private func space(for space: TilingSpaceKey) -> TilingSpace? {
        spaces[space]
    }

    @discardableResult
    private func mutateSpace<T>(_ space: TilingSpaceKey, _ body: (inout TilingSpace) -> T) -> T {
        var value = spaces[space] ?? establishedCanvas(for: space)
        let result = body(&value)
        spaces[space] = value
        return result
    }

    private func spaceState(for space: TilingSpaceKey) -> TilingState {
        spaces[space]?.state ?? TilingState()
    }

    /// Owning canvas of a managed window, derived from the canvas that
    /// holds its record (nil when untiled/unknown). A tiled window never
    /// migrates mid-session: its canvas wins over geometry, so dragging
    /// it across displays keeps its slot until untiled.
    private func spaceOf(window id: WindowID) -> TilingSpaceKey? {
        for (key, space) in spaces where space.record(of: id) != nil {
            return key
        }
        return nil
    }

    /// The record of a managed window, wherever it lives.
    private func record(of id: WindowID) -> WindowRecord? {
        spaceOf(window: id).flatMap { spaces[$0]?.record(of: id) }
    }

    /// The handle of a managed window, wherever it lives.
    private func handle(of id: WindowID) -> WindowHandle? {
        spaceOf(window: id).flatMap { spaces[$0]?.handle(of: id) }
    }

    /// Canvas key for a display: the Space shown there right now, resolved
    /// fresh so a swipe is reflected on the next action. A nil or unknown
    /// screen falls back to the main display's canvas, then to the
    /// display-less key.
    private func tilingKey(for screen: ScreenID?) -> TilingSpaceKey {
        let resolved = screen ?? fallbackScreen()
        return TilingSpaceKey(
            screen: resolved, space: activeSpaceID(on: resolved))
    }

    private func activeSpaceID(on screen: ScreenID?) -> SpaceID? {
        guard let screen,
              let info = screens().first(where: { $0.id == screen })
        else { return nil }
        return gateway.activeSpace(on: info.displayID)
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
    /// visible Space either, the write is deferred too: the next
    /// successful lookup re-asserts it.
    private func isVisible(_ space: TilingSpaceKey) -> Bool {
        guard let screen = space.screen else { return true }
        guard screens().contains(where: { $0.id == screen }) else { return false }
        guard let id = space.space else { return true }
        return activeSpaceID(on: screen) == id
    }

    /// The focused canvas: the focused window's display plus the Space
    /// shown there. Focus lands on the active Space of whichever display
    /// owns the focused window, so this is the canvas a hotkey acts on.
    private func focusedSpaceKey() -> TilingSpaceKey {
        actionSpaceKey(for: focusedScreenID())
    }

    /// A display's withheld-Space canvas, when it still holds windows or
    /// chapters. This is not a hidden Space: it is the canvas the window
    /// server would not name when those windows tiled. If the id resolves
    /// later, the canvas must stay reachable or its windows vanish from
    /// the menu, the bulk actions, and undo.
    private func withheldCanvas(on screen: ScreenID?) -> TilingSpaceKey? {
        guard let screen else { return nil }
        let key = TilingSpaceKey(screen: screen, space: nil)
        guard let state = spaces[key],
              !state.state.occupants.isEmpty || !state.undoStack.isEmpty
        else { return nil }
        return key
    }

    /// The canvas an action on `screen` resolves to: the identified
    /// canvas when it holds anything, else the display's withheld-Space
    /// canvas. Without this the first successful Space lookup after a
    /// withheld period would strand every window tiled during it.
    private func actionSpaceKey(for screen: ScreenID?) -> TilingSpaceKey {
        let identified = tilingKey(for: screen)
        if let state = spaces[identified],
           !state.state.occupants.isEmpty || !state.undoStack.isEmpty {
            return identified
        }
        return withheldCanvas(on: identified.screen) ?? identified
    }

    /// The canvas key for every display right now, in screen order. One
    /// entry per display even when the same Space spans displays (the
    /// screen keeps the canvases distinct).
    private func activeSpaceKeys() -> [TilingSpaceKey] {
        var keys: [TilingSpaceKey] = []
        for info in screens() {
            let key = tilingKey(for: info.id)
            if !keys.contains(key) { keys.append(key) }
            // A withheld-Space canvas is reasserted like the identified
            // one: it is the same display, just unnamed.
            if let fallback = withheldCanvas(on: info.id), fallback != key {
                keys.append(fallback)
            }
        }
        if keys.isEmpty { keys = [tilingKey(for: nil)] }
        return keys
    }

    /// Focused display id: owning display of the focused window's live
    /// frame, else its pre-tile frame, else main.
    private func focusedScreenID() -> ScreenID? {
        let infos = screens()
        guard !infos.isEmpty else { return nil }
        if let handle = gateway.focusedWindow() {
            if let frame = gateway.frame(of: handle),
               let info = visibleScreen(for: frame)
            { return info.id }
            if let id = recordID(for: handle),
               let record = record(of: id), record.preTileFrame != .zero,
               let info = visibleScreen(for: record.preTileFrame)
            { return info.id }
        }
        return infos.first?.id
    }

    /// Single-canvas fallback key: the main display when the provider
    /// reports screens, nil for a display-less environment (headless
    /// tests keep the legacy nil-keyed canvas and shared grid).
    private func fallbackScreen() -> ScreenID? {
        screens().first?.id
    }
}
