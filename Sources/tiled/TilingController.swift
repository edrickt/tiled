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
            screenOf: { [weak self] in self?.spaceOf(window: $0) },
            occupantsOf: { [weak self] screen in self?.trackedOccupants(on: screen) ?? [:] },
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
    /// Per-monitor tiling spaces: each display runs its own occupancy,
    /// splitters (owned by the tracker), undo chapters, and transient
    /// notices. Single-monitor setups use one space; the legacy `state`
    /// / `grid` / undo surface below aggregates the focused monitor's
    /// space so menus and existing callers keep working.
    private var spaces: [ScreenID?: MonitorSpace] = [:]
    private(set) var state = TilingState()
    /// Current grid. Source of truth lives in the tracker; this mirrors
    /// it for tests and menus that read `controller.grid`.
    var grid: GridLayout { tracker.grid(for: focusedScreenID()) }

    /// Registry of managed windows. `PlanExecutor` reads and mutates
    /// these through `execute`/`undo`; `WindowRecord` is its type so both
    /// modules share one record shape.
    private var records: [WindowID: WindowRecord] = [:]
    private var nextID: WindowID = 1
    /// Window -> owning tiling space. Set when a window tiles (and when
    /// undo reissues ids); cleared on forget. A tiled window never
    /// migrates mid-session: its space wins over geometry, so dragging
    /// it across displays keeps its slot until untiled.
    private var spaceOwnership: [WindowID: ScreenID?] = [:]

    /// Snapshot of the last displacement(s), enabling a one-step undo.
    /// Each entry is a full recovery unit: the snapshot plus the requester
    /// to restore alongside it (a switch restores its requester; an
    /// ordinary eviction retiles its own). Newest last. The global undo
    /// consumes from the tail, so the freshest destruction is always the
    /// one that returns: no silent invalidation, ever.
    private var undoStack: [(snapshot: [EvictedWindow], requester: WindowID?)] = []
    /// Depth cap: enough history to survive a tile-tile-realize rhythm
    /// without growing unbounded in a hotkey-heavy session.
    fileprivate static let undoDepth = 5
    /// Splitter fractions parked by the last Reset Splitters, enabling a
    /// one-step restore. Memory-only, like the displacement undo: drag
    /// positions are per-session craft.
    private var splitterBackup: GridLayout?

    /// Whether a displacement undo is available (menu item visibility).
    var canUndoDisplacement: Bool { focusedSpace().undoStack.isEmpty == false }

    /// Count for the undo menu title (0 when unavailable).
    var evictedCount: Int { focusedSpace().undoStack.last?.snapshot.count ?? 0 }

    /// Last layout-switch notice (shown in the status menu). A cross-layout
    /// hotkey untiles every other tiled window; the notice always carries
    /// the undo offer, so the first encounter teaches reversibility instead
    /// of just reporting destruction. Cleared on the next tiling attempt.
    /// Never overwrites a real error (refusals, restore failures win).
    /// Per-monitor: the shared surface reads the focused monitor's space.
    private(set) var lastNotice: String? {
        get { focusedSpace().notice }
        set { mutateSpace(focusedScreenID()) { $0.notice = newValue } }
    }

    /// Last user-visible tiling failure (shown in the status menu).
    /// Cleared on the next tiling attempt. Per-monitor, like `lastNotice`.
    private(set) var lastTileError: String? {
        get { focusedSpace().error }
        set { mutateSpace(focusedScreenID()) { $0.error = newValue } }
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

    /// Called after any state change (for menu refresh).
    var onChange: (() -> Void)?

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
        screens: ScreenProvider? = nil
    ) {
        self.gateway = gateway
        self.scheduleDragEnd = scheduleDragEnd
        self.scheduleVerify = scheduleVerify
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
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.dbg("screens changed; reasserting layout")
            self.applyAll()
            self.onChange?()
        }
    }

    deinit {
        pruneTimer?.invalidate()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: Hotkey entry point

    func handle(slot: Slot) {
        pruneDeadWindows()
        guard let handle = gateway.focusedWindow() else {
            dbg("no focused window for \(slot.rawValue)")
            onFeedback?(.noFocusedWindow)
            return
        }
        let id = windowID(for: handle)
        let screen = screenForRequester(id, handle: handle)
        // An expanded window getting a slot hotkey comes back to earth
        // first: its own slot becomes the strict no-op below; a different
        // slot retiles from the collapsed state.
        if expanded[id] != nil {
            collapseExpanded(id)
        }
        let current = spaceState(for: screen)
        let decision = current.plan(window: id, into: slot)
        guard decision != .noop else {
            // Already in that tile: a strict no-op; no state, error, or
            // menu side effects. Still signal it so the hotkey path can
            // confirm subtly (the Welcome tab teaches this as safety).
            dbg("noop win\(id) already in \(slot.rawValue)")
            onFeedback?(.alreadyTiled(slot: slot))
            return
        }
        // Clear this monitor's slate (not the focused one: the requester
        // may tile onto a background display while focus sits elsewhere).
        mutateSpace(screen) { $0.error = nil; $0.notice = nil }
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
            screenOf: { [weak self] in self?.spaceOf(window: $0) },
            isExpanded: { [weak self] in self?.expanded[$0] != nil },
            screen: screen)
        setSpaceState(result.state, for: screen)
        records = result.records
        nextID = result.nextID
        // Successful placements own the requester's space: the window
        // tiles where it sits, and never migrates mid-session. Refused
        // writes roll back occupancy, so ownership follows the commit.
        if result.outcome.error == nil, result.state.slot(of: id) != nil {
            setSpaceOwnership(id, screen)
        }
        let outcome = result.outcome
        // Evicted windows were restored by the executor: expansion died
        // with the pre-tile frame write that restored them. A re-housed
        // window is the exception: it stayed tiled in the slot the
        // request left free, so its record and observation survive.
        for evicted in decision.windowsToRestore(requester: id)
        where evicted != outcome.rehoused {
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
            reflowSnapshot = reflow(freed, excluding: skip, on: screen)
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
        mutateSpace(screen) {
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
            scheduleVerification(of: decision, requester: id, on: screen)
            if let rehoused = outcome.rehoused {
                scheduleVerification(of: [rehoused], on: screen)
            }
        }
        syncLegacySurface(focus: screen)
        // The reflow's survivors share the event's undo chapter: undo
        // restores the pre-event world in one ⌃⇧⌘Z (a move with no
        // eviction has no chapter of its own, so the reflow starts one).
        let chapter = (outcome.snapshot ?? []) + reflowSnapshot
        pushUndo(
            snapshot: chapter.isEmpty ? nil : chapter,
            requester: outcome.requester, on: screen)
        onChange?()
    }

    /// Pending convergence checks by window: a newer placement for the
    /// same window supersedes (cancels) the older check, and forget paths
    /// cancel outright: a verification must never roll back a window
    /// that already moved on.
    private var pendingVerifications: [WindowID: () -> Void] = [:]

    private func scheduleVerification(of decision: TilePlan, requester id: WindowID, on screen: ScreenID?) {
        let placed: [WindowID]
        switch decision {
        case .tile, .switchLayout: placed = [id]
        case .swap(let displaced): placed = [id, displaced]
        case .noop: return
        }
        scheduleVerification(of: placed, on: screen)
    }

    /// Schedules one convergence check per window, superseding any pending
    /// check for the same window: only the latest write is ever judged.
    private func scheduleVerification(of placed: [WindowID], on screen: ScreenID?) {
        for window in placed {
            pendingVerifications[window]?()
            let checkScreen = screen
            pendingVerifications[window] = scheduleVerify { [weak self] in
                self?.pendingVerifications[window] = nil
                self?.verifyConvergence(window, on: checkScreen)
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
    private func verifyConvergence(_ id: WindowID, on screen: ScreenID?) {
        guard records[id] != nil, slotOfWindow(id) != nil else { return }
        guard tracker.convergence(for: id) == .ignored else { return }
        let errorScreen = spaceOf(window: id) ?? screen
        tracker.forget(id)
        if let errorScreen {
            var s = spaceState(for: errorScreen)
            s.remove(window: id)
            setSpaceState(s, for: errorScreen)
        }
        spaceOwnership[id] = nil
        expanded[id] = nil
        let name = appName(for: id) ?? "That window"
        // A later error (e.g. a newer refusal) wins over this late one.
        // Scoped to the window's own screen: the placement may tile onto
        // a background display while focus sits elsewhere.
        if space(for: errorScreen)?.error == nil {
            mutateSpace(errorScreen) {
                $0.error = "\(name) couldn't be tiled: the app refused to resize it."
            }
        }
        onFeedback?(.refused(windowName: name))
        syncLegacySurface(focus: errorScreen)
        onChange?()
        dbg("verify FAILED win\(id): silent ignore, rolled back")
    }

    /// Records a destructive outcome on the undo stack: keeps the
    /// freshest `undoDepth` recoveries, dropping the oldest. A new tiling
    /// action pushes; it never silently invalidates: depth, not
    /// amnesia, bounds the history.
    private func pushUndo(
        snapshot: [EvictedWindow]?, requester: WindowID?, on screen: ScreenID? = nil
    ) {
        guard let snapshot, !snapshot.isEmpty else { return }
        mutateSpace(screen) {
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
    /// The tracker computes rects under each screen's grid; this module
    /// performs the writes and reports refusals: the push half of the
    /// tracker's decide/push split. Nil reasserts every space (display
    /// changes); a screen scopes to one monitor (reset/restore).
    private func applyAll(excluding excluded: Set<WindowID> = [], on screen: ScreenID? = nil) {
        var rects: [WindowID: CGRect] = [:]
        let keys: [ScreenID?] =
            if let screen { [screen] } else { Array(spaces.keys) }
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
            else { scheduleVerification(of: [id], on: spaceOf(window: id)) }
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

    /// Screen for a tiling request: a tiled window's own space wins (it
    /// never migrates mid-session), else the owning display of its live
    /// frame, else its pre-tile frame, else the focused display. Untiled
    /// windows with no readable frame land on the focused display,
    /// never guessed from another monitor's geometry.
    private func screenForRequester(_ id: WindowID, handle: WindowHandle) -> ScreenID? {
        if let owned = spaceOf(window: id) { return owned }
        if let frame = gateway.frame(of: handle),
           let info = screenInfo(for: frame)
        { return info.id }
        if let record = records[id], record.preTileFrame != .zero,
           let info = screenInfo(for: record.preTileFrame)
        { return info.id }
        return focusedScreenID()
    }

    /// Screen info owning `frame`, or the main screen when nothing
    /// overlaps (off-screen or inter-Space windows still tile somewhere
    /// sane). Nil only when the provider reports no displays at all.
    private func screenInfo(for frame: CGRect) -> ScreenInfo? {
        visibleScreen(for: frame)
    }

    /// The screen that owns `frame` (same fallback chain as
    /// `visibleBounds`): largest overlap, then midpoint, then main.
    func screen(for frame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        if let index = Self.owningScreenIndex(frames: screens.map(\.frame), for: frame) {
            return screens[index]
        }
        if let index = Self.midpointScreenIndex(frames: screens.map(\.frame), for: frame) {
            return screens[index]
        }
        dbg("no screen overlaps \(frame); falling back to main")
        return NSScreen.main
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
        for (id, record) in records where gateway.liveness(of: record.handle) == .dead {
            dbg("prune win\(id): dead handle, releasing slot")
            let slot = slotOfWindow(id)
            let screen = spaceOf(window: id)
            forgetWindow(id)
            // A window closed while tiled is a leave like any other:
            // its cells flow to the mergeable survivor.
            pushUndo(snapshot: reflow(slot?.cells ?? [], excluding: [], on: screen), requester: nil, on: screen)
        }
    }

    /// Clears error/notice state: every user-initiated tiling action
    /// starts from a clean slate. The undo stack is NOT cleared here:
    /// history survives new actions up to `undoDepth`. Only a successful
    /// undo consumes its entry, and bulk destructive ops (untile all)
    /// start a new chapter. Scoped to the focused monitor: other
    /// displays keep their notices until acted on there.


    // MARK: Bulk operations

    func untileAll() {
        pruneDeadWindows()
        // Untile-all dissolves only the focused monitor's space: the
        // other display keeps its arrangement. The shared surface reads
        // the focused space, so the legacy zero-arg form resolves it.
        untileAll(on: focusedScreenID())
    }

    /// Dissolves one monitor's space, leaving the others untouched. The
    /// undo chapter tags each window with its screen so the recovery
    /// retiles per-monitor.
    func untileAll(on screen: ScreenID?) {
        pruneDeadWindows()
        mutateSpace(screen) { $0.error = nil; $0.notice = nil }
        // Untile-all starts its own undo chapter: the chapter lists each
        // dissolved (slot, pre-tile frame) pair, and undo re-applies the
        // slot rect on top of the restored frame: the window visibly
        // returns to the arrangement, not just to its pre-tile frame.
        // No modal: the sticky notice + ⌃⌥⇧⌘Z are the safety.
        let chapter = spaceState(for: screen).occupants
        if !chapter.isEmpty {
            mutateSpace(screen) {
                $0.undoStack.append((snapshot: [], requester: nil))
                if $0.undoStack.count > Self.undoDepth {
                    $0.undoStack.removeFirst($0.undoStack.count - Self.undoDepth)
                }
            }
            let noun = chapter.count == 1 ? "1 window" : "\(chapter.count) windows"
            mutateSpace(screen) {
                $0.notice = "Untiled \(noun). Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."
            }
            // Prime the tracker's intent for the slot rects the undo will
            // write: the live frames are pre-tile settle frames, and the
            // diff must measure against where we're going, not where the
            // restore just put us. Without this the undo's own writes
            // read as a user drag and the grid moves under them.
            for (slot, id) in chapter {
                if let record = records[id] {
                    let target = tracker.grid(for: screen).rect(
                        for: slot, in: visibleBounds(for: record.preTileFrame))
                    tracker.markExpected(id, target)
                }
            }
        }
        // Handles first: restoreOne clears each record, so resolve every
        // handle while the registry still knows them.
        var handles: [WindowID: WindowHandle] = [:]
        for id in spaceState(for: screen).tiledWindows {
            if let record = records[id] { handles[id] = record.handle }
        }
        let failures = spaceState(for: screen).tiledWindows.compactMap { restoreOne($0).failure }
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
                setSpaceOwnership(fresh, screen)
                observe(window: fresh)
                snapshot.append(EvictedWindow(
                    handle: handle, slot: slot, preTileFrame: frame, screen: screen))
            }
            mutateSpace(screen) {
                $0.undoStack[$0.undoStack.count - 1] = (snapshot: snapshot, requester: nil)
            }
        }
        syncLegacySurface(focus: screen)
        onChange?()
    }

    /// Reports restore failures unless a more relevant error already took
    /// the slot. Shared by `untile`/`untileAll`; plan execution reports
    /// its own through `Outcome.error` with the same precedence rule.
    private func reportRestoreFailures(_ failures: [String]) {
        guard !failures.isEmpty, lastTileError == nil else { return }
        if failures.count == 1 {
            lastTileError =
                "Couldn't restore “\(failures[0])”: it may still be sitting in its old tile."
        } else {
            lastTileError =
                "Couldn't restore \(failures.count) windows: they may still be sitting in their old tiles."
        }
    }

    /// Snaps all splitters back to defaults and re-tiles everyone. The
    /// displaced fractions are kept as a one-step restore (same pattern
    /// as the shortcuts reset backup), so the app's "destruction is
    /// always reversible" ethic holds for drag positions too. Scoped to
    /// the focused monitor: other displays keep their drag positions.
    func resetDividers() {
        resetDividers(on: focusedScreenID())
    }

    /// Snaps one monitor's splitters back to defaults and re-tiles its
    /// occupants; neighbors on other displays are untouched.
    func resetDividers(on screen: ScreenID?) {
        let key = screen ?? self.fallbackScreen() ?? ScreenID(rawValue: 0)
        mutateSpace(screen) { $0.splitterBackup = self.tracker.resetDividers(for: key) }
        mutateSpace(screen) { $0.error = nil; $0.notice = nil }
        applyAll(on: screen)
        onChange?()
    }

    /// Restores the splitter fractions parked by the last reset, or false
    /// when there is no backup (fresh install, or already restored once).
    /// Scoped to the focused monitor, like `resetDividers`.
    @discardableResult
    func restoreSplitters() -> Bool {
        restoreSplitters(on: focusedScreenID())
    }

    /// Restores one monitor's parked splitter fractions.
    @discardableResult
    func restoreSplitters(on screen: ScreenID?) -> Bool {
        guard let backup = space(for: screen)?.splitterBackup else { return false }
        let key = screen ?? fallbackScreen() ?? ScreenID(rawValue: 0)
        tracker.restoreDividers(backup, for: key)
        mutateSpace(screen) { $0.splitterBackup = nil }
        mutateSpace(screen) { $0.error = nil; $0.notice = "Splitters restored to their pre-reset positions." }
        applyAll(on: screen)
        onChange?()
        return true
    }

    /// Whether a splitter backup is parked: drives the menu row title
    /// ("Reset Splitters" vs "Restore Previous Splitters"). Reads the
    /// focused monitor's space.
    var hasSplitterBackup: Bool { focusedSpace().splitterBackup != nil }

    /// The slot the focused window would return to if it is currently
    /// expanded; nil otherwise. Drives the expand row's stateful title:
    /// the toggle must show its state, not just its combo.
    var expandedFocusedSlot: Slot? {
        guard let handle = gateway.focusedWindow() else { return nil }
        let id = recordID(for: handle) ?? windowID(for: handle)
        guard expanded[id] != nil else { return nil }
        guard let screen = spaceOf(window: id) else { return nil }
        return spaceState(for: screen).slot(of: id)
    }

    /// Undoes the freshest destructive tiling action: a layout switch, an
    /// ordinary eviction, or a swap. All share one recovery path: the
    /// displaced windows return to their slots, the requester to its
    /// pre-tile frame (a swap's requester entry re-tiles it into its
    /// vacated tile, swapping back). Consumes the entry it restores, so
    /// repeated ⌃⌥⇧⌘Z walks back through history up to `undoDepth`: the
    /// stack, not amnesia, bounds
    /// the past.
    func undoLastDisplacement() {
        undoLastDisplacement(on: focusedScreenID())
    }

    /// Undoes one monitor's freshest destructive action. Untagged legacy
    /// snapshots restore into that monitor's space; tagged snapshots
    /// retile each window on the display it left.
    func undoLastDisplacement(on screen: ScreenID?) {
        guard let entry = mutateSpace(screen, { $0.undoStack.popLast() }) else {
            // Expired or empty: the promise needs an answer, not silence
            // (see the undo-expiry feedback below).
            onFeedback?(.nothingToUndo)
            return
        }
        pruneDeadWindows()
        mutateSpace(screen) { $0.error = nil; $0.notice = nil }
        // A slot may have been re-tiled since its window was evicted (the
        // undo stack survives new actions by design). The restoration is
        // honored like any tile: the current occupant is untiled to its
        // pre-tile frame first, so undo never silently clobbers a window
        // into a ghost that overlaps the restored one on screen. The
        // window being restored itself (same handle, e.g. reissued by an
        // earlier undo) is not displaced.
        for evicted in entry.snapshot {
            let destination = evicted.screen ?? screen
            if let current = spaceState(for: destination).occupant(of: evicted.slot),
               let record = records[current], record.handle != evicted.handle
            {
                untile(window: current, reflowing: false)
            }
        }
        // Group the chapter by destination screen: each window returns
        // to the display it left (legacy untagged entries restore into
        // the undone space). The requester restores to its pre-tile
        // frame wherever it sits: frames, not spaces, decide that.
        var byScreen: [ScreenID?: [EvictedWindow]] = [:]
        for evicted in entry.snapshot {
            byScreen[evicted.screen ?? screen, default: []].append(evicted)
        }
        var restored = 0
        var errors: [String] = []
        // Restore the requester once, against the undone space's state.
        // (Its record may already be gone; `restoreWindow` is a no-op
        // then, but the per-screen unwinding below still needs its id
        // looked up in the same state.)
        if let requester = entry.requester {
            var undoneState = spaceState(for: screen)
            undoRestoreWindow(requester, state: &undoneState)
            setSpaceState(undoneState, for: screen)
        }
        for (destination, group) in byScreen {
            let groupState = spaceState(for: destination)
            let result = executor.undo(
                snapshot: group, requester: nil,
                state: groupState, records: records, nextID: nextID, tracker: tracker,
                boundsOf: { [weak self] in self?.visibleBounds(for: $0) ?? $0 },
                observe: { [weak self] in self?.observe(window: $0) })
            setSpaceState(result.state, for: destination)
            records = result.records
            nextID = result.nextID
            // Tag reissued ids with their destination space: undo creates
            // fresh records for pruned handles, and the window belongs to
            // the display it just returned to.
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
            mutateSpace(screen) {
                $0.notice = "Undid displacement \u{00B7} \(noun) restored."
            }
        } else if let error = errors.first {
            mutateSpace(screen) { $0.error = error }
        } else if entry.snapshot.isEmpty {
            // Untile-all chapter with no surviving windows: the requester
            // restore above already ran; report the standard empty result.
            mutateSpace(screen) { $0.error = "Couldn't restore the evicted windows." }
        } else if errors.isEmpty {
            mutateSpace(screen) { $0.error = "Couldn't restore the evicted windows." }
        }
        // A nil requester with an empty snapshot (untile-all chapter
        // whose windows all died) still consumes the entry: nothing to
        // restore, standard error above.
        syncLegacySurface(focus: screen)
        onChange?()
    }

    // MARK: Live resize (observe & compensate)

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

    var activeLayout: LayoutKind { focusedSpace().state.activeLayout }

    /// One monitor's layout (nil = focused monitor's space).
    func activeLayout(on screen: ScreenID?) -> LayoutKind {
        space(for: screen)?.state.activeLayout ?? .quarters
    }

    /// One monitor's occupancy (nil = focused monitor's space).
    func occupant(of slot: Slot, on screen: ScreenID?) -> WindowID? {
        space(for: screen)?.state.occupant(of: slot)
    }

    /// One monitor's pure state (nil = focused monitor's space). Tests
    /// assert per-screen occupancy through this.
    func state(on screen: ScreenID?) -> TilingState {
        space(for: screen)?.state ?? TilingState()
    }

    /// One monitor's grid (nil = focused monitor's space).
    func grid(on screen: ScreenID?) -> GridLayout {
        tracker.grid(for: screen ?? fallbackScreen())
    }

    var tiledWindowsInfo: [TiledWindowInfo] {
        allTiledWindowsInfo()
    }

    /// Tiled windows on the focused monitor (tile submenu scope).
    var focusedTiledWindowsInfo: [TiledWindowInfo] {
        let key = focusedScreenID()
        let screenName = screens().first(where: { $0.id == key })?.name
        return (space(for: key)?.state.occupants ?? [:])
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map {
                TiledWindowInfo(
                    id: $0.value, slot: $0.key, appName: appName(for: $0.value),
                    screen: key, screenName: screenName)
            }
    }

    /// Every tiled window on every monitor, grouped by display (manage
    /// list scope). Single-monitor setups return the flat list.
    func allTiledWindowsInfo() -> [TiledWindowInfo] {
        let infos = screens()
        let keys = spaces.keys.sorted(by: { ($0?.rawValue ?? -1) < ($1?.rawValue ?? -1) })
        var rows: [TiledWindowInfo] = []
        for key in keys {
            let screenName = infos.first(where: { $0.id == key })?.name
            let occupants = spaces[key]?.state.occupants ?? [:]
            for (slot, id) in occupants.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                rows.append(TiledWindowInfo(
                    id: id, slot: slot, appName: appName(for: id),
                    screen: key, screenName: screenName))
            }
        }
        return rows
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
        let screen = spaceOf(window: id) ?? focusedScreenID()
        let slot = slotOfWindow(id)
        guard slot != nil else {
            onFeedback?(.nothingToEvict)
            return
        }
        mutateSpace(screen) { $0.error = nil; $0.notice = nil }
        if let failure = restoreOne(id).failure {
            reportRestoreFailures([failure])
        }
        pushUndo(snapshot: reflow(slot?.cells ?? [], excluding: [], on: screen), requester: nil, on: screen)
        syncLegacySurface(focus: screen)
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
        // The window's own space clears (not the focused one): menu
        // untile rows act on background displays.
        let screen = spaceOf(window: id) ?? focusedScreenID()
        mutateSpace(screen) { $0.error = nil; $0.notice = nil }
        let slot = slotOfWindow(id)
        if let failure = restoreOne(id).failure {
            reportRestoreFailures([failure])
        }
        if reflowing {
            pushUndo(snapshot: reflow(slot?.cells ?? [], excluding: [], on: screen), requester: nil, on: screen)
        }
        onChange?()
    }

    // MARK: Reflow

    /// Applies reflow on one monitor after a tiled window left it or
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
        _ freed: Set<TileCell>, excluding: Set<WindowID>, on screen: ScreenID?
    ) -> [EvictedWindow] {
        guard !freed.isEmpty else { return [] }
        var current = spaceState(for: screen)
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
        setSpaceState(current, for: screen)
        var rects: [WindowID: CGRect] = [:]
        for move in moves {
            if let target = tracker.rect(for: move.window) { rects[move.window] = target }
        }
        if pushRects(rects, excluding: nil) > 0 {
            var rolled = spaceState(for: screen)
            for move in moves { rolled.commit(window: move.window, into: move.from) }
            setSpaceState(rolled, for: screen)
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
                    preTileFrame: $0.preTileFrame, screen: screen)
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
        mutateSpace(spaceOf(window: id) ?? focusedScreenID()) { $0.error = nil; $0.notice = nil }
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
        mutateSpace(spaceOf(window: id) ?? focusedScreenID()) { $0.error = nil; $0.notice = nil }
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
        let target = tracker.grid(for: spaceOf(window: id)).rect(for: slot, in: bounds)
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

    /// Unexpanded occupants of one screen's space (nil = focused space).
    private func trackedOccupants(on screen: ScreenID?) -> [Slot: WindowID] {
        space(for: screen)?.state.occupants.filter { expanded[$0.value] == nil } ?? [:]
    }

    // MARK: Drag-out untile

    /// The user dragged a tiled window past the untile distance and
    /// dropped it: release the slot and leave the window where it was
    /// dropped: no pre-tile restore, the drag IS the placement. (Short
    /// drags snap back inside the tracker and never reach here.)
    func untileFromDrag(_ id: WindowID) {
        guard records[id] != nil else { return }
        let screen = spaceOf(window: id) ?? focusedScreenID()
        mutateSpace(screen) { $0.error = nil; $0.notice = nil }
        let slot = slotOfWindow(id)
        forgetWindow(id)
        pushUndo(snapshot: reflow(slot?.cells ?? [], excluding: [], on: screen), requester: nil, on: screen)
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
        tracker.forget(id)
        if let screen = spaceOf(window: id) {
            var s = spaceState(for: screen)
            s.remove(window: id)
            setSpaceState(s, for: screen)
        } else {
            for key in spaces.keys {
                var s = spaceState(for: key)
                s.remove(window: id)
                setSpaceState(s, for: key)
            }
        }
        spaceOwnership[id] = nil
        expanded[id] = nil
        syncLegacySurface(focus: nil)
    }

    private static func refusalMessage(count: Int) -> String {
        count == 1
            ? "Couldn't move that window: the app refused to resize it."
            : "Couldn't move \(count) windows: an app refused to resize."
    }

    var isTrusted: Bool { gateway.isTrusted }

    // MARK: Per-monitor spaces

    /// One monitor's space, creating it on first use. Single-monitor
    /// setups converge on one key (see `fallbackScreen`), so the old
    /// single-space behavior is the one-space case of this model.
    private func space(for screen: ScreenID?) -> MonitorSpace? {
        guard let key = screen ?? fallbackScreen() else { return spaces[nil] }
        return spaces[key]
    }

    private func mutateSpace<T>(_ screen: ScreenID?, _ body: (inout MonitorSpace) -> T) -> T {
        let key = screen ?? fallbackScreen()
        var space = spaces[key] ?? MonitorSpace()
        let result = body(&space)
        spaces[key] = space
        return result
    }

    private func spaceState(for screen: ScreenID?) -> TilingState {
        space(for: screen)?.state ?? TilingState()
    }

    private func setSpaceState(_ state: TilingState, for screen: ScreenID?) {
        mutateSpace(screen) { $0.state = state }
        if screen == nil || screen == focusedScreenID() {
            self.state = state
        }
    }

    /// Owning space of a tiled window (nil when untiled/unknown).
    private func spaceOf(window id: WindowID) -> ScreenID? {
        spaceOwnership[id] ?? nil
    }

    private func setSpaceOwnership(_ id: WindowID, _ screen: ScreenID?) {
        spaceOwnership[id] = screen
    }

    /// Slot of a window in its own space (nil when untiled/unknown).
    private func slotOfWindow(_ id: WindowID) -> Slot? {
        guard let screen = spaceOf(window: id) else {
            // No ownership yet: scan spaces (fresh records pre-tiling).
            for space in spaces.values {
                if let slot = space.state.slot(of: id) { return slot }
            }
            return nil
        }
        return spaceState(for: screen).slot(of: id)
    }

    /// Focused monitor's space key: owning display of the focused
    /// window's live frame, else its pre-tile frame, else main.
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

    private func focusedSpace() -> MonitorSpace {
        space(for: focusedScreenID()) ?? MonitorSpace()
    }

    /// Single-space fallback key: the main display when the provider
    /// reports screens, nil for a display-less environment (headless
    /// tests keep the legacy nil-keyed space and shared grid).
    private func fallbackScreen() -> ScreenID? {
        screens().first?.id
    }

    /// Restores one window's pre-tile frame and releases its slot in its
    /// own space. Shared with the per-screen undo unwinding (the
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

    /// Mirrors the focused space onto the legacy surface (`state`,
    /// `undoStack`, `splitterBackup`, `lastNotice`, `lastTileError`)
    /// that menus and existing tests read. `focus` names the space that
    /// just changed; nil re-resolves from the focused window.
    private func syncLegacySurface(focus screen: ScreenID?) {
        let key = screen ?? focusedScreenID()
        let current = space(for: key) ?? MonitorSpace()
        state = current.state
        undoStack = current.undoStack
        splitterBackup = current.splitterBackup
    }
}
