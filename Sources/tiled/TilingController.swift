import AppKit

/// Glues the pure `TilingState` + `GridLayout` to real windows through a
/// `WindowGateway`, never touching AX types directly. All element
/// identity, coordinate conversion, observation, and activation live
/// behind the seam; this module owns only tiling decisions and records.
///
/// The live drag-resize loop lives in `DragTracker` (echo suppression,
/// edge detection, splitter moves, apply coalescing); this module feeds
/// it gateway callbacks and performs the writes it schedules.
final class TilingController {
    private let gateway: WindowGateway
    /// Drag-end debounce scheduler for the tracker's drag-out loop.
    /// Injectable so tests fire drag ends without waiting on the runloop.
    private let scheduleDragEnd: DragTracker.DragEndScheduler
    /// Convergence-check scheduler for the late silent-ignore verification.
    /// Injectable so tests fire verifications without waiting 3.5s.
    private let scheduleVerify: DragTracker.DragEndScheduler
    private lazy var executor = PlanExecutor(
        gateway: gateway, log: { [weak self] in self?.dbg($0) })

    /// The drag-resize loop. Lazy so its context closures can capture
    /// self: the tracker decides (echo, edges, splitters), this module
    /// performs writes via `pushRects` and serves record reads.
    private lazy var tracker: DragTracker = DragTracker(
        context: DragTracker.Context(
            slotOf: { [weak self] in self?.trackedSlot(of: $0) },
            frameOf: { [weak self] in self?.frameForTracker($0) },
            boundsOf: { [weak self] in self?.visibleBounds(for: $0) ?? $0 },
            occupants: { [weak self] in self?.trackedOccupants ?? [:] },
            spaceOf: { [weak self] in self?.spaceOf(window: $0) },
            occupantsOf: { [weak self] space in self?.trackedOccupants(on: space) ?? [:] },
            liveFrameOf: { [weak self] id in self?.liveFrameForTracker(id) }),
        apply: { [weak self] rects, excluding in
            guard let self else { return 0 }
            return self.pushRects(rects, excluding: excluding)
        },
        onUntile: { [weak self] in self?.untileFromDrag($0) },
        scheduleDragEnd: scheduleDragEnd,
        log: { [weak self] in self?.dbg($0) })

    /// Display set provider. Production returns one entry per NSScreen;
    /// tests inject synthetic multi-monitor setups. Called on every tiling
    /// action (never cached between them), so replugs and rearranges take
    /// effect without an observer.
    private let screens: ScreenProvider
    /// Per-canvas tiling spaces: each display's each Mission Control
    /// Space runs its own occupancy, splitters (owned by the tracker),
    /// undo chapters, and transient notices. The `state` / `grid` surface
    /// below is derived from one canvas at a time, so menus and existing
    /// tests keep working without a second copy of anything.
    private var spaces: [TilingSpaceKey: CanvasState] = [:]
    /// The canvas the derived `state` surface reports: the one the last
    /// action touched, else the focused canvas. Only the *key* is stored;
    /// the occupancy is read from the canvas on demand, so the surface
    /// cannot go stale or become a second owner of state `CanvasState`
    /// already holds.
    private var surfaceSpace: TilingSpaceKey?
    var state: TilingState {
        spaceState(for: surfaceSpace ?? focusedSpaceKey())
    }
    /// Current grid. Source of truth lives in the tracker; this mirrors
    /// it for tests and menus that read `controller.grid`.
    var grid: GridLayout { tracker.grid(for: focusedSpaceKey()) }

    /// Registry of managed windows. `PlanExecutor` reads and mutates
    /// these through `execute`/`undo`; `WindowRecord` is its type so both
    /// modules share one record shape.
    private var records: [WindowID: WindowRecord] = [:]
    private var nextID: WindowID = 1
    /// Window -> owning tiling canvas. Set when a window tiles (and when
    /// undo reissues ids); cleared on forget. A tiled window never
    /// migrates mid-session: its canvas wins over geometry, so dragging
    /// it across displays keeps its slot until untiled.
    private var spaceOwnership: [WindowID: TilingSpaceKey] = [:]

    /// Depth cap for the per-canvas displacement undo: enough history to
    /// survive a tile-tile-realize rhythm without growing unbounded in a
    /// hotkey-heavy session. The chapters themselves live in `CanvasState`,
    /// beside the occupancy they describe.
    fileprivate static let undoDepth = 5

    /// Whether a displacement undo is available (menu item visibility).
    var canUndoDisplacement: Bool { focusedCanvas().undoStack.isEmpty == false }

    /// Count for the undo menu title (0 when unavailable).
    var evictedCount: Int { focusedCanvas().undoStack.last?.snapshot.count ?? 0 }

    /// Last layout-switch notice (shown in the status menu). A cross-layout
    /// hotkey untiles every other tiled window; the notice always carries
    /// the undo offer, so the first encounter teaches reversibility instead
    /// of just reporting destruction. Cleared on the next tiling attempt.
    /// Never overwrites a real error (refusals, restore failures win).
    /// Per-canvas: the shared surface reads the focused canvas's space.
    private(set) var lastNotice: String? {
        get { focusedCanvas().notice }
        set { mutateSpace(focusedSpaceKey()) { $0.notice = newValue } }
    }

    /// Last user-visible tiling failure (shown in the status menu).
    /// Cleared on the next tiling attempt. Per-canvas, like `lastNotice`.
    private(set) var lastTileError: String? {
        get { focusedCanvas().error }
        set { mutateSpace(focusedSpaceKey()) { $0.error = newValue } }
    }

    /// Windows expanded over the layout by the ⌥⇧⏎ toggle, keyed by id,
    /// holding the frame to restore for windows that had no slot when
    /// expanded (tiled windows retile into their slot instead, so their
    /// entry is unused). Expanded windows keep their slot in `state`:
    /// expanding acts like focusing, covering the layout without erasing
    /// it, but the tracker reads them as untiled (`trackedSlot`), so
    /// echoes of the expand write and hand drags of the covering window
    /// never mutate splitters or trigger drag-out untile.
    private var expanded: [WindowID: CGRect] = [:]
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
    /// Clock for the confirmation window. Injectable so tests advance
    /// time instead of waiting on real seconds.
    private let now: () -> Date
    /// First dead-probe sighting per window. Cleared when the probe
    /// recovers or the record goes away.
    private var deadSince: [WindowID: Date] = [:]
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
        observeMouseUp: (@escaping () -> Void) -> Void = { _ in }
    ) {
        self.gateway = gateway
        self.scheduleDragEnd = scheduleDragEnd
        self.scheduleVerify = scheduleVerify
        self.deathConfirmation = deathConfirmation
        self.now = now
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
        noteSurfaceCanvas(key)
        onFocusedSpaceChange?()
    }

    /// One workspace notification: a swipe changed the Space shown on
    /// some display. The newly visible canvas may have missed a display
    /// reassertion while hidden, and the menu aggregates visible
    /// canvases, so both the stale reassert and the menu refresh are
    /// unconditional; only the glyph is scoped to the focused canvas.
    private func activeSpaceMayHaveChanged() {
        reassertStaleActiveSpaces()
        let key = focusedSpaceKey()
        if !hasResolvedFocusedSpace || key != lastFocusedSpace {
            hasResolvedFocusedSpace = true
            lastFocusedSpace = key
            noteSurfaceCanvas(key)
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
    private func requesterAndCanvas(for slot: Slot) -> (id: WindowID, key: TilingSpaceKey)? {
        pruneDeadWindows()
        guard let handle = gateway.focusedWindow() else {
            dbg("no focused window for \(slot.rawValue)")
            onFeedback?(.noFocusedWindow)
            return nil
        }
        let id = windowID(for: handle)
        return (id, spaceKeyForRequester(id, handle: handle))
    }

    func handle(slot: Slot) {
        guard let (id, key) = requesterAndCanvas(for: slot) else { return }
        // An expanded window getting a slot hotkey comes back to earth
        // first: its own slot becomes the strict no-op below; a different
        // slot retiles from the collapsed state.
        if expanded[id] != nil {
            collapseExpanded(id)
        }
        let current = spaceState(for: key)
        let decision = current.plan(window: id, into: slot)
        guard decision != .noop else {
            // Already in that tile: a strict no-op; no state, error, or
            // menu side effects. Still signal it so the hotkey path can
            // confirm subtly (the Welcome tab teaches this as safety).
            dbg("noop win\(id) already in \(slot.rawValue)")
            onFeedback?(.alreadyTiled(slot: slot))
            return
        }
        // Clear this canvas's slate (not the focused one: the requester
        // may tile onto a background display or Space while focus sits
        // elsewhere).
        mutateSpace(key) { $0.error = nil; $0.notice = nil }
        // A swap moves the displaced window too: an expanded window
        // coming out of a swap returns to earth in its new tile, exactly
        // like the requester above.
        if case .swap(let displaced) = decision {
            collapseExpanded(displaced)
        }

        let result = executor.execute(
            decision: decision, requester: id, slot: slot,
            state: current, records: records, nextID: nextID,
            tracker: tracker,
            boundsOf: { [weak self] in self?.visibleBounds(for: $0) ?? $0 },
            observe: { [weak self] in self?.observe(window: $0) },
            spaceOf: { [weak self] in self?.spaceOf(window: $0) },
            isExpanded: { [weak self] in self?.expanded[$0] != nil },
            space: key)
        setSpaceState(result.state, for: key)
        records = result.records
        nextID = result.nextID
        // Successful placements own the requester's canvas: the window
        // tiles where it sits, and never migrates mid-session. Refused
        // writes roll back occupancy, so ownership follows the commit.
        if result.outcome.error == nil, result.state.slot(of: id) != nil {
            setSpaceOwnership(id, key)
        }
        settle(decision, outcome: result.outcome, requester: id, on: key)
    }

    /// Everything after a committed plan: untiled windows give up their
    /// records, the cells the event freed reflow into one survivor,
    /// restored windows sit below the arrangement, a swap's displaced
    /// window takes focus, and the event is narrated, verified, noted on
    /// the surface, and made undoable. One chapter per event, so a single
    /// ⌃⌥⇧⌘Z puts back everything this function settled.
    private func settle(
        _ decision: TilePlan, outcome: PlanExecutor.Outcome,
        requester id: WindowID, on key: TilingSpaceKey
    ) {
        // Restored-not-re-housed windows: untiled for good. A re-housed
        // window is the exception: it stayed tiled in the slot the
        // request left free, so its record and observation survive.
        let restored = decision.windowsToRestore(requester: id)
            .filter { $0 != outcome.rehoused }
        for evicted in restored {
            forgetWindow(evicted)
        }
        // Reflow: the cells the event freed (eviction remainders, the
        // requester's vacated tile) flow into the one survivor that
        // merges with them into a whole slot. Skipped when the placement
        // or a restore failed: the screen must agree with state before
        // anyone grows into it. The requester, the evicted, and expanded
        // windows never grow.
        var reflowSnapshot: [EvictedWindow] = []
        if outcome.error == nil, let freed = outcome.reflowFreed, !freed.isEmpty {
            let skip = Set([id] + decision.windowsToRestore(requester: id))
            reflowSnapshot = reflow(freed, excluding: skip, on: key)
        }
        // Restored windows sit BELOW the arrangement they left: an
        // evictee returns to its pre-tile frame and must never cover the
        // occupants that stayed (or the requester). No focus change.
        if !restored.isEmpty {
            raiseOccupants(on: key)
        }
        // A swap leaves the user's attention on the window that took the
        // requester's old tile: focus follows the displaced window. The
        // degenerate fallback (a plain eviction) deletes its record, so
        // the guard keeps focus untouched there and after refusals.
        if case .swap(let displaced) = decision, outcome.error == nil,
            let record = records[displaced]
        {
            gateway.focus(record.handle)
        }
        if let feedback = outcome.feedback {
            onFeedback?(feedback)
        }
        mutateSpace(key) {
            $0.notice = outcome.notice
            if let error = outcome.error { $0.error = error }
        }
        if outcome.error == nil {
            // Late convergence check: a silent ignore (gateway success,
            // app never moved) is invisible at write time, so verify one
            // verify-delay later via the echo trail; no extra AX traffic
            // on the hot path. Windows that converged, produced any frames,
            // or were re-written since are skipped; only total silence
            // rolls back. Cancelled by the next placement's scheduling
            // (a newer write supersedes) and by forget paths.
            scheduleVerification(of: decision, requester: id, on: key)
            if let rehoused = outcome.rehoused {
                scheduleVerification(of: [rehoused], on: key)
            }
        }
        noteSurfaceCanvas(key)
        // The reflow's survivors share the event's undo chapter: undo
        // restores the pre-event world in one ⌃⇧⌘Z (a move with no
        // eviction has no chapter of its own, so the reflow starts one).
        let chapter = (outcome.snapshot ?? []) + reflowSnapshot
        pushUndo(
            snapshot: chapter.isEmpty ? nil : chapter,
            requester: outcome.requester, on: key)
        onChange?()
    }

    /// Pending convergence checks by window: a newer placement for the
    /// same window supersedes (cancels) the older check, and forget paths
    /// cancel outright: a verification must never roll back a window
    /// that already moved on.
    private var pendingVerifications: [WindowID: () -> Void] = [:]

    private func scheduleVerification(of decision: TilePlan, requester id: WindowID, on space: TilingSpaceKey) {
        let placed: [WindowID]
        switch decision {
        case .tile, .switchLayout: placed = [id]
        case .swap(let displaced): placed = [id, displaced]
        case .noop: return
        }
        scheduleVerification(of: placed, on: space)
    }

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
        guard records[id] != nil, slotOfWindow(id) != nil else { return }
        guard tracker.convergence(for: id) == .ignored else { return }
        let errorSpace = spaceOf(window: id) ?? space
        tracker.forget(id)
        var s = spaceState(for: errorSpace)
        s.remove(window: id)
        setSpaceState(s, for: errorSpace)
        spaceOwnership[id] = nil
        expanded[id] = nil
        let name = appName(for: id) ?? "That window"
        // A later error (e.g. a newer refusal) wins over this late one.
        // Scoped to the window's own canvas: the placement may tile onto
        // a background display or Space while focus sits elsewhere.
        if self.space(for: errorSpace)?.error == nil {
            mutateSpace(errorSpace) {
                $0.error = "\(name) couldn't be tiled: the app refused to resize it."
            }
        }
        onFeedback?(.refused(windowName: name))
        noteSurfaceCanvas(errorSpace)
        onChange?()
        dbg("verify FAILED win\(id): silent ignore, rolled back")
    }

    /// Records a destructive outcome on the undo stack: keeps the
    /// freshest `undoDepth` recoveries, dropping the oldest. A new tiling
    /// action pushes; it never silently invalidates: depth, not
    /// amnesia, bounds the history.
    private func pushUndo(
        snapshot: [EvictedWindow]?, requester: WindowID?, on space: TilingSpaceKey? = nil
    ) {
        guard let snapshot, !snapshot.isEmpty else { return }
        mutateSpace(space ?? focusedSpaceKey()) {
            $0.undoStack.append((snapshot: snapshot, requester: requester))
            if $0.undoStack.count > Self.undoDepth {
                $0.undoStack.removeFirst($0.undoStack.count - Self.undoDepth)
            }
        }
    }

    // MARK: Placement (delegated)

    /// Single-window restore shared by `untile` and `untileAll`: restores
    /// the pre-tile frame, releases the slot, and reports refusal so the
    /// caller can name the window instead of leaving a stray behind.
    /// Returns the pre-tile frame it restored to (nil when there was
    /// nothing to restore), so bulk callers can snapshot it for undo;
    /// the record is cleared here and unreadable afterwards.
    private func restoreOne(_ id: WindowID) -> (failure: String?, restoredFrame: CGRect?) {
        // Capture the display name before the record is cleared, so a
        // refused restore can name the window instead of saying "A window".
        let name = appName(for: id) ?? "A window"
        var restored = true
        var restoredFrame: CGRect?
        if let record = records[id], record.preTileFrame != .zero {
            restoredFrame = record.preTileFrame
            restored = gateway.setFrame(record.handle, to: record.preTileFrame)
        }
        forgetWindow(id)
        if restored { return (nil, restoredFrame) }
        return (name, nil)
    }

    /// Recomputes and pushes rects for all occupants (resize propagation).
    /// The tracker computes rects under each canvas's grid; this module
    /// performs the writes and reports refusals: the push half of the
    /// tracker's decide/push split. Nil reasserts every currently visible
    /// canvas (display changes); a key scopes to one canvas (reset,
    /// restore, stale reassert).
    private func applyAll(excluding excluded: Set<WindowID> = [], on space: TilingSpaceKey? = nil) {
        var rects: [WindowID: CGRect] = [:]
        let keys: [TilingSpaceKey] =
            if let space { [space] } else { activeSpaceKeys() }
        staleSpaces.subtract(keys)
        for key in keys {
            for (_, occupant) in spaceState(for: key).occupants {
                guard !excluded.contains(occupant), records[occupant] != nil,
                    expanded[occupant] == nil
                else { continue }
                if let target = tracker.rect(for: occupant) {
                    rects[occupant] = target
                }
            }
        }
        let failed = pushRects(rects, excluding: nil)
        if failed > 0 {
            lastTileError = Self.refusalMessage(count: failed)
        }
    }

    /// Performs tracker-scheduled pushes: marks each write expected (echo
    /// bookkeeping lives in the tracker) and writes via the gateway.
    /// Returns the refusal count. `excluding` names the window whose frame
    /// is the drag's source of truth; it is informational, since snapback rects
    /// DO name the (formerly) dragged window, with `excluding` nil.
    /// Successful pushes schedule the same late convergence check as
    /// placements: a re-push the app silently ignores rolls back the same
    /// way. Per-window supersede keeps drag streams to one pending check.
    private func pushRects(_ rects: [WindowID: CGRect], excluding: WindowID?) -> Int {
        var failed = 0
        for (id, target) in rects {
            guard let record = records[id] else { continue }
            // A push for a window on a canvas the user cannot see waits
            // for the swipe back: resizing an off-Space window can pull
            // it onto the visible Space. The mark re-asserts it later.
            if let windowSpace = spaceOf(window: id), !isVisible(windowSpace) {
                staleSpaces.insert(windowSpace)
                dbg("push win\(id) deferred off-Space")
                continue
            }
            // No-op writes are skipped, not pushed: the app changes
            // nothing and emits no echo, so a marked expectation here
            // would never converge and the late check would evict an
            // already-correct window.
            if let current = gateway.frame(of: record.handle),
                DragTracker.close(current, target, tolerance: DragTracker.noOpWriteTolerance)
            {
                dbg("push win\(id) no-op skip target=\(target)")
                continue
            }
            tracker.markExpected(id, target)
            if !gateway.setFrame(record.handle, to: target) { failed += 1 }
            else { scheduleVerification(of: [id], on: spaceOf(window: id) ?? focusedSpaceKey()) }
            dbg("push win\(id) target=\(target)")
        }
        if failed > 0 {
            lastTileError = Self.refusalMessage(count: failed)
        }
        onChange?()
        return failed
    }

    /// Frame the tracker diffs against: the last pushed target when known,
    /// else the live frame, else the pre-tile frame. Prefers the pushed
    /// target so a settle frame (the gateway applying our own write a
    /// tick late) can never read as a user drag: echo suppression
    /// compares against this, and it must be our intent, not the echo.
    private func frameForTracker(_ id: WindowID) -> CGRect? {
        guard let record = records[id] else { return nil }
        if let pushed = tracker.lastPushedTarget(for: id) { return pushed }
        return gateway.frame(of: record.handle) ?? record.preTileFrame
    }

    /// The window's frame as the app reports it: the no-op-write check
    /// must never consult intent (`frameForTracker`), which equals the
    /// push target by definition and would skip every push.
    private func liveFrameForTracker(_ id: WindowID) -> CGRect? {
        guard let record = records[id] else { return nil }
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

    /// Screen owning `frame`: the display showing the largest share of
    /// the window (straddles resolve to the mostly-visible side, never
    /// jittering on the midpoint). Ties and zero-overlap fall back to the
    /// midpoint screen, then main, so off-screen or inter-Space windows
    /// still tile somewhere sane instead of using raw frame coordinates.
    private func visibleBounds(for frame: CGRect) -> CGRect {
        visibleScreen(for: frame)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
    }

    /// Provider-backed screen info owning `frame` (same fallback chain
    /// as `visibleBounds`): largest overlap, then midpoint, then main.
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
        if let record = records[id], record.preTileFrame != .zero,
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
        if let existing = recordID(for: handle) { return existing }
        let id = nextID
        nextID += 1
        records[id] = WindowRecord(handle: handle, preTileFrame: .zero)
        return id
    }

    /// Existing id for a live handle, without creating a record.
    private func recordID(for handle: WindowHandle) -> WindowID? {
        records.first(where: { $0.value.handle == handle })?.key
    }

    /// Drops records whose handle is gone (window closed, app quit).
    /// Called lazily before each hotkey and by the prune timer; internal so
    /// tests can drive ghost cleanup without waiting on the runloop. Only
    /// confirmed deaths prune: a busy app's unanswerable probe is unknown,
    /// and pruning on a maybe would untile a live window.
    func pruneDeadWindows() {
        let dead = records.filter { gateway.liveness(of: $0.value.handle) == .dead }
        let timestamp = now()
        for (id, _) in dead {
            let first = deadSince[id] ?? timestamp
            guard timestamp.timeIntervalSince(first) >= deathConfirmation else {
                deadSince[id] = first
                dbg("prune win\(id): dead handle, awaiting confirmation")
                continue
            }
            deadSince[id] = nil
            dbg("prune win\(id): dead handle confirmed, releasing slot")
            let slot = slotOfWindow(id)
            let space = spaceOf(window: id)
            forgetWindow(id)
            // A window closed while tiled is a leave like any other:
            // its cells flow to the mergeable survivor.
            pushLeaveUndo(slot: slot, on: space)
        }
        // A recovered probe or a vanished record clears the pending
        // death: only windows still reading dead stay marked.
        let deadIDs = Set(dead.map(\.key))
        deadSince = deadSince.filter { deadIDs.contains($0.key) }
    }

    /// Clears error/notice state: every user-initiated tiling action
    /// starts from a clean slate. The undo stack is NOT cleared here:
    /// history survives new actions up to `undoDepth`. Only a successful
    /// undo consumes its entry, and bulk destructive ops (untile all)
    /// start a new chapter. Scoped to the affected canvas: other
    /// displays and Spaces keep their notices until acted on there.


    private func raiseOccupants(on space: TilingSpaceKey) {
        // Raising an off-Space window can pull it to the visible Space;
        // z-order is a nicety, so a hidden canvas waits for its swipe.
        guard isVisible(space) else { return }
        // Expanded windows are non-evicted too: they cover the layout
        // while holding their slots, and the evictee sits below them.
        for (_, id) in spaceState(for: space).occupants
            .sorted(by: { $0.key.rawValue < $1.key.rawValue })
        {
            guard let record = records[id] else { continue }
            gateway.raise(record.handle)
        }
    }

    /// The shared tail of every leave-with-reflow path: the freed cells
    /// flow to the mergeable survivor, and the survivor is raised above
    /// the window that just left — one helper so the invariant lives in
    /// one place and no leave path forgets the raise.
    private func pushLeaveUndo(slot: Slot?, on space: TilingSpaceKey?) {
        let key = space ?? focusedSpaceKey()
        pushUndo(snapshot: reflow(slot?.cells ?? [], excluding: [], on: key), requester: nil, on: key)
        raiseOccupants(on: key)
    }

    // MARK: Bulk operations

    func untileAll() {
        pruneDeadWindows()
        // Untile-all dissolves only the focused canvas: other displays
        // and Spaces keep their arrangements. The shared surface reads
        // the focused canvas, so the legacy zero-arg form resolves it.
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
        mutateSpace(space) { $0.error = nil; $0.notice = nil }
        // Untile-all starts its own undo chapter: the chapter lists each
        // dissolved (slot, pre-tile frame) pair, and undo re-applies the
        // slot rect on top of the restored frame: the window visibly
        // returns to the arrangement, not just to its pre-tile frame.
        // No modal: the sticky notice + ⌃⌥⇧⌘Z are the safety.
        let chapter = spaceState(for: space).occupants
        if !chapter.isEmpty {
            mutateSpace(space) {
                $0.undoStack.append((snapshot: [], requester: nil))
                if $0.undoStack.count > Self.undoDepth {
                    $0.undoStack.removeFirst($0.undoStack.count - Self.undoDepth)
                }
            }
            let noun = chapter.count == 1 ? "1 window" : "\(chapter.count) windows"
            mutateSpace(space) {
                $0.notice = "Untiled \(noun). Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."
            }
            // Prime the tracker's intent for the slot rects the undo will
            // write: the live frames are pre-tile settle frames, and the
            // diff must measure against where we're going, not where the
            // restore just put us. Without this the undo's own writes
            // read as a user drag and the grid moves under them.
            for (slot, id) in chapter {
                if let record = records[id] {
                    let target = tracker.grid(for: space).rect(
                        for: slot, in: visibleBounds(for: record.preTileFrame))
                    tracker.markExpected(id, target)
                }
            }
        }
        // Handles first: restoreOne clears each record, so resolve every
        // handle while the registry still knows them.
        var handles: [WindowID: WindowHandle] = [:]
        for id in spaceState(for: space).tiledWindows {
            if let record = records[id] { handles[id] = record.handle }
        }
        let failures = spaceState(for: space).tiledWindows.compactMap { restoreOne($0).failure }
        reportRestoreFailures(failures)
        // Rebuild the chapter from the frames untile-all just restored:
        // each window now sits at its pre-tile frame with no record, so
        // re-observe it there and pair it with its dissolved slot. The
        // undo then retiles the live window back into place.
        if !chapter.isEmpty {
            var snapshot: [EvictedWindow] = []
            for (slot, id) in chapter {
                guard let handle = handles[id],
                      let frame = gateway.frame(of: handle)
                else { continue }
                let fresh: WindowID = nextID
                nextID += 1
                records[fresh] = WindowRecord(handle: handle, preTileFrame: frame)
                setSpaceOwnership(fresh, space)
                observe(window: fresh)
                snapshot.append(EvictedWindow(
                    handle: handle, slot: slot, preTileFrame: frame, space: space))
            }
            mutateSpace(space) {
                $0.undoStack[$0.undoStack.count - 1] = (snapshot: snapshot, requester: nil)
            }
        }
        noteSurfaceCanvas(space)
        onChange?()
    }

    /// Reports restore failures unless a more relevant error already took
    /// the slot. Shared by `untile`/`untileAll`; plan execution reports
    /// its own through `Outcome.error` with the same precedence rule.
    private func reportRestoreFailures(_ failures: [String]) {
        guard !failures.isEmpty, lastTileError == nil else { return }
        lastTileError = MenuText.restoreFailureMessage(failures)
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
        mutateSpace(space) { $0.splitterBackup = self.tracker.resetDividers(for: space) }
        mutateSpace(space) { $0.error = nil; $0.notice = nil }
        applyAll(on: space)
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
        guard let backup = self.space(for: space)?.splitterBackup else { return false }
        tracker.restoreDividers(backup, for: space)
        mutateSpace(space) { $0.splitterBackup = nil }
        mutateSpace(space) { $0.error = nil; $0.notice = "Splitters restored to their pre-reset positions." }
        applyAll(on: space)
        onChange?()
        return true
    }

    /// Whether a splitter backup is parked: drives the menu row title
    /// ("Reset Splitters" vs "Restore Previous Splitters"). Reads the
    /// focused canvas.
    var hasSplitterBackup: Bool { focusedCanvas().splitterBackup != nil }

    /// The slot the focused window would return to if it is currently
    /// expanded; nil otherwise. Drives the expand row's stateful title:
    /// the toggle must show its state, not just its combo.
    var expandedFocusedSlot: Slot? {
        guard let handle = gateway.focusedWindow() else { return nil }
        let id = recordID(for: handle) ?? windowID(for: handle)
        guard expanded[id] != nil else { return nil }
        guard let space = spaceOf(window: id) else { return nil }
        return spaceState(for: space).slot(of: id)
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
        // A slot may have been re-tiled since its window was evicted (the
        // undo stack survives new actions by design). The restoration is
        // honored like any tile: the current occupant is untiled to its
        // pre-tile frame first, so undo never silently clobbers a window
        // into a ghost that overlaps the restored one on screen. The
        // window being restored itself (same handle, e.g. reissued by an
        // earlier undo) is not displaced.
        for evicted in entry.snapshot {
            let destination = evicted.space ?? space
            if let current = spaceState(for: destination).occupant(of: evicted.slot),
               let record = records[current], record.handle != evicted.handle
            {
                untile(window: current, reflowing: false)
            }
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
        // Restore the requester once, against the undone canvas's state.
        // (Its record may already be gone; `restoreWindow` is a no-op
        // then, but the per-canvas unwinding below still needs its id
        // looked up in the same state.)
        if let requester = entry.requester {
            var undoneState = spaceState(for: space)
            undoRestoreWindow(requester, state: &undoneState)
            setSpaceState(undoneState, for: space)
        }
        for (destination, group) in bySpace {
            let groupState = spaceState(for: destination)
            let result = executor.undo(
                snapshot: group, requester: nil,
                state: groupState, records: records, nextID: nextID, tracker: tracker,
                boundsOf: { [weak self] in self?.visibleBounds(for: $0) ?? $0 },
                observe: { [weak self] in self?.observe(window: $0) })
            setSpaceState(result.state, for: destination)
            records = result.records
            nextID = result.nextID
            // Tag reissued ids with their destination canvas: undo creates
            // fresh records for pruned handles, and the window belongs to
            // the canvas it just returned to.
            for evicted in group {
                if let id = records.first(where: { $0.value.handle == evicted.handle })?.key {
                    setSpaceOwnership(id, destination)
                }
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
        noteSurfaceCanvas(space)
        onChange?()
    }

    // MARK: Live resize (observe & compensate)

    /// The user released the mouse button: commit every splitter move an
    /// in-progress edge drag made, re-pushing the neighbor tiles the new
    /// grid implies. Wired from the production mouse-up monitor; tests
    /// call it directly.
    func mouseLifted() {
        tracker.mouseLifted()
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
    /// edges, splitters, and coalescing live in the tracker.
    private func observe(window id: WindowID) {
        guard let record = records[id] else { return }
        let handle = record.handle
        gateway.observe(handle) { [weak self] in
            guard let self else { return }
            guard let currentID = self.currentID(for: handle) else { return }
            guard let frame = self.gateway.frame(of: handle) else { return }
            self.tracker.handleChange(id: currentID, frame: frame)
        }
    }

    private func currentID(for handle: WindowHandle) -> WindowID? {
        for (id, record) in records where record.handle == handle {
            return id
        }
        return nil
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

    var activeLayout: LayoutKind { activeLayout(in: focusedSpaceKey()) }

    /// One canvas's layout.
    func activeLayout(in space: TilingSpaceKey) -> LayoutKind {
        spaces[space]?.state.activeLayout ?? .sixths
    }

    /// One display's currently shown canvas layout (the screen-based form
    /// menus and tests use).
    func activeLayout(on screen: ScreenID?) -> LayoutKind {
        activeLayout(in: tilingKey(for: screen))
    }

    /// One canvas's occupancy.
    func occupant(of slot: Slot, in space: TilingSpaceKey) -> WindowID? {
        spaces[space]?.state.occupant(of: slot)
    }

    /// One display's currently shown canvas occupancy (the screen-based
    /// form menus and tests use).
    func occupant(of slot: Slot, on screen: ScreenID?) -> WindowID? {
        occupant(of: slot, in: tilingKey(for: screen))
    }

    /// One canvas's pure state. Tests assert per-canvas occupancy through
    /// this.
    func state(in space: TilingSpaceKey) -> TilingState {
        spaces[space]?.state ?? TilingState()
    }

    /// One display's currently shown canvas state (the screen-based form
    /// menus and tests use).
    func state(on screen: ScreenID?) -> TilingState {
        state(in: tilingKey(for: screen))
    }

    /// One canvas's grid.
    func grid(in space: TilingSpaceKey) -> GridLayout {
        tracker.grid(for: space)
    }

    /// One display's currently shown canvas grid (the screen-based form
    /// menus and tests use).
    func grid(on screen: ScreenID?) -> GridLayout {
        tracker.grid(for: tilingKey(for: screen))
    }

    var tiledWindowsInfo: [TiledWindowInfo] {
        allTiledWindowsInfo()
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
        let sources: [(key: TilingSpaceKey, screenName: String?)] =
            if infos.isEmpty {
                spaces.keys.sorted(by: Self.spaceOrder).map { ($0, nil) }
            } else {
                infos.map { (tilingKey(for: $0.id), $0.name) }
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
        guard let record = records[id] else { return }
        gateway.focus(record.handle)
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
        let id = recordID(for: handle) ?? windowID(for: handle)
        let space = spaceOf(window: id) ?? focusedSpaceKey()
        let slot = slotOfWindow(id)
        guard slot != nil else {
            onFeedback?(.nothingToEvict)
            return
        }
        mutateSpace(space) { $0.error = nil; $0.notice = nil }
        if let failure = restoreOne(id).failure {
            reportRestoreFailures([failure])
        }
        pushLeaveUndo(slot: slot, on: space)
        noteSurfaceCanvas(space)
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
        let space = spaceOf(window: id) ?? focusedSpaceKey()
        mutateSpace(space) { $0.error = nil; $0.notice = nil }
        let slot = slotOfWindow(id)
        if let failure = restoreOne(id).failure {
            reportRestoreFailures([failure])
        }
        if reflowing {
            pushLeaveUndo(slot: slot, on: space)
        }
        onChange?()
    }

    // MARK: Reflow

    /// Applies reflow on one canvas after a tiled window left it or
    /// freed cells by moving: the one survivor whose cells merge with
    /// the freed cells into a whole slot moves into it, the rightmost
    /// candidate winning ties (see `TilingState.reflow`). Callers have
    /// already removed the leaving window; the requester, evicted, and
    /// expanded windows never grow. A hole no survivor merges into
    /// exactly stays empty. Refused writes roll every survivor back and
    /// the generic refusal message lands in the menu, so state and
    /// screen never disagree about who holds the freed cells.
    ///
    /// Returns the undo entries for the survivors that moved: callers
    /// fold them into the triggering event's undo chapter, or start one
    /// when the reflow stands alone.
    private func reflow(
        _ freed: Set<TileCell>, excluding: Set<WindowID>, on space: TilingSpaceKey
    ) -> [EvictedWindow] {
        guard !freed.isEmpty else { return [] }
        var current = spaceState(for: space)
        // Expanded windows keep covering the layout; they never grow.
        let skip = excluding.union(
            Set(current.occupants.filter { expanded[$0.value] != nil }.map(\.value)))
        let placements = current.reflow(freed: freed, excluding: skip)
        guard !placements.isEmpty else { return [] }
        var moves: [(window: WindowID, from: Slot, to: Slot)] = []
        for (wid, target) in placements.sorted(by: { $0.key < $1.key }) {
            guard let from = current.slot(of: wid) else { continue }
            current.commit(window: wid, into: target)
            moves.append((wid, from, target))
        }
        setSpaceState(current, for: space)
        // A hidden canvas's survivors grow in state now but are written
        // when the user swipes back: sizing an off-Space window can move
        // it onto the visible Space, which would break the independence
        // the layout exists to provide.
        guard isVisible(space) else {
            staleSpaces.insert(space)
            dbg("reflow deferred on hidden canvas")
            return moves.compactMap { move in
                records[move.window].map {
                    EvictedWindow(
                        handle: $0.handle, slot: move.from,
                        preTileFrame: $0.preTileFrame, space: space)
                }
            }
        }
        var rects: [WindowID: CGRect] = [:]
        for move in moves {
            if let target = tracker.rect(for: move.window) { rects[move.window] = target }
        }
        if pushRects(rects, excluding: nil) > 0 {
            var rolled = spaceState(for: space)
            for move in moves { rolled.commit(window: move.window, into: move.from) }
            setSpaceState(rolled, for: space)
            var oldRects: [WindowID: CGRect] = [:]
            for move in moves {
                if let old = tracker.rect(for: move.window) { oldRects[move.window] = old }
            }
            _ = pushRects(oldRects, excluding: nil)
            return []
        }
        dbg("reflow \(moves.map { "win\($0.window)->\($0.to.rawValue)" }.joined(separator: ", "))")
        return moves.compactMap { move in
            records[move.window].map {
                EvictedWindow(
                    handle: $0.handle, slot: move.from,
                    preTileFrame: $0.preTileFrame, space: space)
            }
        }
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
        if expanded[id] != nil {
            collapseExpanded(id)
        } else {
            expand(id)
        }
    }

    private func expand(_ id: WindowID) {
        guard let record = records[id] else { return }
        let current = gateway.frame(of: record.handle) ?? record.preTileFrame
        // No readable frame anywhere: there is no sane screen to expand
        // onto, so refuse to guess (visibleBounds would fall back to main).
        guard current != .zero else { return }
        let target = visibleBounds(for: current)
        mutateSpace(spaceOf(window: id) ?? focusedSpaceKey()) { $0.error = nil; $0.notice = nil }
        if writeExpandedFrame(id, to: target) {
            expanded[id] = current
            dbg("expand win\(id) -> \(target)")
        } else {
            onFeedback?(.expandRefused(windowName: appName(for: id)))
        }
        onChange?()
    }

    private func collapseExpanded(_ id: WindowID) {
        guard let saved = expanded[id] else { return }
        expanded[id] = nil
        mutateSpace(spaceOf(window: id) ?? focusedSpaceKey()) { $0.error = nil; $0.notice = nil }
        if slotOfWindow(id) != nil {
            retileExpanded(id)
        } else if records[id] != nil {
            if !writeExpandedFrame(id, to: saved) {
                onFeedback?(.expandRefused(windowName: appName(for: id)))
            }
            dbg("collapse win\(id) -> saved \(saved)")
        }
        onChange?()
    }

    /// Re-applies an expanded window's slot rect after collapse. Uses the
    /// tracker grid directly, not plan execution: the window never left
    /// its slot, so there is nothing to restore or evict.
    private func retileExpanded(_ id: WindowID) {
        guard let record = records[id], let slot = slotOfWindow(id) else { return }
        let current = gateway.frame(of: record.handle) ?? record.preTileFrame
        let bounds = visibleBounds(for: current)
        let target = tracker.grid(for: spaceOf(window: id) ?? focusedSpaceKey())
            .rect(for: slot, in: bounds)
        if !writeExpandedFrame(id, to: target) {
            onFeedback?(.expandRefused(windowName: appName(for: id)))
        }
        dbg("retile expanded win\(id) -> \(slot.rawValue) target=\(target)")
    }

    /// One expected frame write via the gateway: the shared shape of the
    /// expand, collapse, and retile writes. On refusal, records the
    /// standard error line and returns false so the caller can add the
    /// feedback of its own.
    private func writeExpandedFrame(_ id: WindowID, to target: CGRect) -> Bool {
        guard let record = records[id] else { return false }
        tracker.markExpected(id, target)
        if gateway.setFrame(record.handle, to: target) { return true }
        lastTileError = Self.refusalMessage(count: 1)
        return false
    }

    /// Slot a window presents to the tracker: expanded windows read as
    /// untiled, so the tracker never diff-resizes them into splitter
    /// moves or drags them out.
    private func trackedSlot(of id: WindowID) -> Slot? {
        expanded[id] == nil ? slotOfWindow(id) : nil
    }

    private var trackedOccupants: [Slot: WindowID] {
        var all: [Slot: WindowID] = [:]
        for space in spaces.values {
            for (slot, id) in space.state.occupants where expanded[id] == nil {
                all[slot] = id
            }
        }
        return all
    }

    /// Unexpanded occupants of one canvas.
    private func trackedOccupants(on space: TilingSpaceKey) -> [Slot: WindowID] {
        self.space(for: space)?.state.occupants.filter { expanded[$0.value] == nil } ?? [:]
    }

    // MARK: Drag-out untile

    /// The user dragged a tiled window past the untile distance and
    /// dropped it: release the slot and leave the window where it was
    /// dropped: no pre-tile restore, the drag IS the placement. (Short
    /// drags snap back inside the tracker and never reach here.)
    func untileFromDrag(_ id: WindowID) {
        guard records[id] != nil else { return }
        let space = spaceOf(window: id) ?? focusedSpaceKey()
        mutateSpace(space) { $0.error = nil; $0.notice = nil }
        let slot = slotOfWindow(id)
        forgetWindow(id)
        pushLeaveUndo(slot: slot, on: space)
        dbg("drag-untile win\(id)")
        onChange?()
    }

    private func appName(for id: WindowID) -> String? {
        records[id].flatMap { gateway.appName(of: $0.handle) }
    }

    /// Releases a window's records, tracker entries, occupancy, and any
    /// expansion. Callers handle any frame writes first; this only
    /// forgets. Shared by untile, drag-out untile, prune, and eviction.
    private func forgetWindow(_ id: WindowID) {
        cancelVerification(id)
        records[id] = nil
        deadSince[id] = nil
        tracker.forget(id)
        if let space = spaceOf(window: id) {
            var s = spaceState(for: space)
            s.remove(window: id)
            setSpaceState(s, for: space)
        } else {
            for key in spaces.keys {
                var s = spaceState(for: key)
                s.remove(window: id)
                setSpaceState(s, for: key)
            }
        }
        spaceOwnership[id] = nil
        expanded[id] = nil
        noteSurfaceCanvas(nil)
    }

    private static func refusalMessage(count: Int) -> String {
        count == 1
            ? "Couldn't move that window: the app refused to resize it."
            : "Couldn't move \(count) windows: an app refused to resize."
    }

    var isTrusted: Bool { gateway.isTrusted }

    // MARK: Per-canvas spaces

    /// One tiling canvas's stored space, if it has been used yet. Keys
    /// carry both the display and the Mission Control Space; a nil Space
    /// id is the per-display fallback when the OS cannot name the Space.
    private func space(for space: TilingSpaceKey) -> CanvasState? {
        spaces[space]
    }

    private func mutateSpace<T>(_ space: TilingSpaceKey, _ body: (inout CanvasState) -> T) -> T {
        var value = spaces[space] ?? CanvasState()
        let result = body(&value)
        spaces[space] = value
        return result
    }

    private func spaceState(for space: TilingSpaceKey) -> TilingState {
        spaces[space]?.state ?? TilingState()
    }

    private func setSpaceState(_ state: TilingState, for space: TilingSpaceKey) {
        mutateSpace(space) { $0.state = state }
    }

    /// Owning canvas of a tiled window (nil when untiled/unknown).
    private func spaceOf(window id: WindowID) -> TilingSpaceKey? {
        spaceOwnership[id]
    }

    private func setSpaceOwnership(_ id: WindowID, _ space: TilingSpaceKey) {
        spaceOwnership[id] = space
    }

    /// Slot of a window in its own canvas (nil when untiled/unknown).
    private func slotOfWindow(_ id: WindowID) -> Slot? {
        guard let space = spaceOf(window: id) else {
            // No ownership yet: scan canvases (fresh records pre-tiling).
            for space in spaces.values {
                if let slot = space.state.slot(of: id) { return slot }
            }
            return nil
        }
        return spaceState(for: space).slot(of: id)
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

    /// Whether `space` is the canvas the user can see right now. A nil
    /// Space id (fallback mode) or nil display (headless tests) is
    /// treated as visible: there is no hidden canvas to protect. When
    /// the window server cannot name the visible Space either, the write
    /// is deferred too: the next successful lookup re-asserts it.
    private func isVisible(_ space: TilingSpaceKey) -> Bool {
        guard let screen = space.screen, let id = space.space else { return true }
        return activeSpaceID(on: screen) == id
    }

    /// The focused canvas: the focused window's display plus the Space
    /// shown there. Focus lands on the active Space of whichever display
    /// owns the focused window, so this is the canvas a hotkey acts on.
    private func focusedSpaceKey() -> TilingSpaceKey {
        tilingKey(for: focusedScreenID())
    }

    /// The canvas key for every display right now, in screen order. One
    /// entry per display even when the same Space spans displays (the
    /// screen keeps the canvases distinct).
    private func activeSpaceKeys() -> [TilingSpaceKey] {
        var keys: [TilingSpaceKey] = []
        for info in screens() {
            let key = tilingKey(for: info.id)
            if !keys.contains(key) { keys.append(key) }
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
               let record = records[id], record.preTileFrame != .zero,
               let info = visibleScreen(for: record.preTileFrame)
            { return info.id }
        }
        return infos.first?.id
    }

    private func focusedCanvas() -> CanvasState {
        space(for: focusedSpaceKey()) ?? CanvasState()
    }

    /// Single-canvas fallback key: the main display when the provider
    /// reports screens, nil for a display-less environment (headless
    /// tests keep the legacy nil-keyed canvas and shared grid).
    private func fallbackScreen() -> ScreenID? {
        screens().first?.id
    }

    /// Restores one window's pre-tile frame and releases its slot in its
    /// own canvas. Shared with the per-canvas undo unwinding (the
    /// executor's restore targets a single state value).
    private func undoRestoreWindow(_ id: WindowID, state: inout TilingState) {
        if let record = records[id], record.preTileFrame != .zero {
            _ = gateway.setFrame(record.handle, to: record.preTileFrame)
        }
        records[id] = nil
        tracker.forget(id)
        state.remove(window: id)
        spaceOwnership[id] = nil
        expanded[id] = nil
    }

    /// Reports which canvas the derived `state` surface describes: the
    /// one that just changed. `space` nil re-resolves to the focused
    /// canvas, which is what a focus change should show. Nothing is
    /// copied: the occupancy is read from the canvas when asked, so a
    /// mutation path that forgets this call leaves the surface pointing
    /// at a canvas, never at a stale snapshot of one.
    private func noteSurfaceCanvas(_ space: TilingSpaceKey?) {
        surfaceSpace = space ?? focusedSpaceKey()
    }
}
