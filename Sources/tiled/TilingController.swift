import AppKit

/// Glues the pure `TilingState` + `GridLayout` to real windows through a
/// `WindowGateway`, never touching AX types directly. All element
/// identity, coordinate conversion, observation, and activation live
/// behind the seam; the coordinator keeps focus and action routing,
/// `WindowRegister` keeps handle identity, the death clock, and pending
/// convergence checks, and `CanvasDirectory` keeps display + Space
/// resolution, the canvas table, visibility, and stale marks.
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
        isVisible: { [weak self] in self?.directory.isVisible($0) ?? false },
        markStale: { [weak self] space in
            self?.directory.markStale(space)
        },
        markExpected: { [weak self] id, target in
            self?.tracker.markExpected(id, target)
        },
        cancelExpected: { [weak self] id in
            self?.tracker.cancelExpected(id)
        },
        seedBaseline: { [weak self] id, target in
            self?.tracker.seedBaseline(id, target)
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
            spaceOf: { [weak self] in self?.directory.owner(of: $0) },
            occupantsOf: { [weak self] space in self?.trackedOccupants(on: space) ?? [:] },
            liveFrameOf: { [weak self] id in self?.liveFrameForTracker(id) }),
        gridProvider: DragTracker.GridProvider(
            grid: { [weak self] space in
                guard let self else { return GridLayout() }
                return self.directory.storedCanvas(for: space ?? .displayless)?.grid
                    ?? GridLayout()
            },
            setGrid: { [weak self] updated, space in
                guard let self else { return }
                self.directory.withCanvas(space ?? .displayless) { $0.grid = updated }
            },
            visibleFrame: { [weak self] space in
                guard let self else { return .zero }
                return self.directory.storedCanvas(for: space ?? .displayless)?.visibleFrame
                    ?? .zero
            }),
        onDragEnd: { [weak self] decision in self?.handleDragEnd(decision) },
        scheduleDragEnd: scheduleDragEnd,
        log: { [weak self] in self?.dbg($0) })

    /// Display set provider. Production returns one entry per NSScreen;
    /// tests inject synthetic multi-monitor setups. Called on every tiling
    /// action (never cached between them), so replugs and rearranges take
    /// effect without an observer.
    private let screens: ScreenProvider
    /// The one owner of display + Space identity: the canvas table, stale
    /// marks, last focus, visibility, and the withheld-Space fallback.
    private lazy var directory = CanvasDirectory(
        screens: screens,
        activeSpace: { [weak self] in self?.gateway.activeSpace(on: $0) },
        focusedWindow: { [weak self] in self?.gateway.focusedWindow() },
        frameOf: { [weak self] in self?.gateway.frame(of: $0) },
        preTileFrameOf: { [weak self] in self?.preTileFrame(of: $0) })
    /// The controller-owned identity register: the id each handle wears,
    /// the allocator, the death clock, and pending convergence checks.
    /// Ownership is read through the directory, so the canvas records
    /// remain the only owner of which canvas a window lives on.
    private lazy var register = WindowRegister(
        owner: { [weak self] in self?.directory.owner(of: $0) },
        releaseForeignClaim: { [weak self] id, owner in
            self?.releaseRecordClaimedByAnotherCanvas(id, on: owner)
        },
        schedule: scheduleVerify)

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
        observeMouseUp: (@escaping () -> Void) -> Void = { _ in },
        observeMouseDown: (@escaping (CGPoint) -> Void) -> Void = { _ in },
        observeMouseDragged: (@escaping () -> Void) -> Void = { _ in }
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
            self.directory.refreshAllFrames()
            self.directory.markAllStale()
            self.applyAll()
            self.onChange?()
        }
        // Mouse presses/drags supply the hand evidence a move tick cannot
        // carry (see DragTracker.mousePressed/mouseDragged), and mouse-up
        // commits the deferred neighbor re-pushes of an edge drag (see
        // DragTracker.mouseLifted). AppDelegate wires the production
        // monitors; the no-op defaults keep tests from installing real
        // event monitors.
        observeMouseDown { [weak self] point in self?.mousePressed(at: point) }
        observeMouseDragged { [weak self] in self?.mouseDragged() }
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
        guard directory.noteFocusedKey(directory.focusedKey()) else { return }
        onFocusedSpaceChange?()
    }

    /// One workspace notification: a swipe changed the Space shown on
    /// some display. The newly visible canvas may have missed a display
    /// reassertion while hidden, and the menu aggregates visible
    /// canvases, so both the stale reassert and the menu refresh are
    /// unconditional; only the glyph is scoped to the focused canvas.
    private func activeSpaceMayHaveChanged() {
        directory.refreshFrames(directory.visibleKeys())
        reassertStaleActiveSpaces()
        if directory.noteFocusedKey(directory.focusedKey()) {
            onFocusedSpaceChange?()
        }
        onChange?()
    }

    /// Re-applies every currently visible canvas that a display change
    /// marked stale, and clears the marks. One pass per screen; the
    /// active Space lookup is fresh, so a swipe is enough to know which
    /// canvas just appeared.
    private func reassertStaleActiveSpaces() {
        let stale = directory.visibleKeys().filter { directory.isMarkedStale($0) }
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
        let liveID = register.liveID(for: handle)
        let key = directory.keyForRequester(
            owned: liveID.flatMap { directory.owner(of: $0) },
            frame: gateway.frame(of: handle),
            preTileFrame: liveID.flatMap { record(of: $0)?.preTileFrame })
        let id = liveID ?? register.claim(handle, on: key)
        return (id, handle, key)
    }

    func handle(slot: Slot) {
        guard let (id, handle, key) = requesterAndCanvas(for: slot) else { return }
        let hadSlot = directory.storedCanvas(for: key)?.state.slot(of: id) != nil
        let context = placementContext(for: key)
        // An expanded window getting a slot hotkey comes back to earth
        // first: its own slot becomes the strict no-op below; a different
        // slot retiles from the collapsed state.
        let (collapse, outcome) = directory.withCanvas(key) { canvas in
            canvas.attach(id, handle: handle)
            let collapse = canvas.isExpanded(id)
                ? canvas.collapseExpanded(id, context: context)
                : nil
            return (collapse, canvas.apply(slot: slot, requester: id, context: context))
        }
        // A slot request clears an older deferred restore only when it
        // actually claims the window. A refused first tiling leaves no
        // record and no slot, so a restore still pending on the canvas the
        // window came from remains live; only a tiled requester's refusal
        // (its old slot survives) is still a claim.
        let claimed: Bool
        switch outcome.result {
        case .placed, .alreadyTiled, .deferred: claimed = true
        case .refused: claimed = hadSlot
        case .nothingToEvict, .expandRefused: claimed = false
        }
        if claimed { discardDeferredRestores(for: handle) }
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
            register.forget(evicted)
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
    /// reflected; the id allocator writes through to the register.
    private func placementContext(for key: TilingSpaceKey) -> TilingSpace.Context {
        TilingSpace.Context(
            gateway: gateway,
            frameWriter: frameWriter,
            tracker: tracker,
            space: key,
            allocateID: { [weak self] handle in
                guard let self else { return 0 }
                return self.register.claim(handle, on: key)
            },
            discardDeferredRestores: { [weak self] handle in
                self?.discardDeferredRestores(for: handle)
            },
            log: { [weak self] message in self?.dbg(message) })
    }

    /// Schedules one convergence check per window, superseding any pending
    /// check for the same window: only the latest write is ever judged.
    private func scheduleVerification(of placed: [WindowID], on space: TilingSpaceKey) {
        for window in placed {
            register.scheduleVerification(of: window) { [weak self] in
                self?.verifyConvergence(window, on: space)
            }
        }
    }

    /// Late silent-ignore check: `scheduleVerification` fires this one
    /// verify-delay after the placement. Converged / inconclusive /
    /// re-placed windows are left alone; a window whose write drew total
    /// AX silence is rolled back exactly like a refused write (slot
    /// released, tracker entry cleared, standard refusal surfaced), so
    /// state and screen agree instead of disagreeing silently.
    private func verifyConvergence(_ id: WindowID, on space: TilingSpaceKey) {
        guard let errorSpace = directory.owner(of: id),
            directory.storedCanvas(for: errorSpace)?.state.slot(of: id) != nil
        else { return }
        guard tracker.convergence(for: id) == .ignored else { return }
        // Name the window before its record goes; the rollback itself
        // writes nothing (the write never took effect).
        let name = appName(for: id) ?? "That window"
        let hasError = directory.withCanvas(errorSpace) { canvas in
            canvas.discard(window: id, context: placementContext(for: errorSpace))
            return canvas.error != nil
        }
        register.forget(id)
        // A later error (e.g. a newer refusal) wins over this late one.
        // Scoped to the window's own canvas: the placement may tile onto
        // a background display or Space while focus sits elsewhere.
        if !hasError {
            directory.withCanvas(errorSpace) {
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
            if let space { [space] } else { directory.visibleKeys() }
        for key in keys {
            // The mark means "this canvas still owes a reassert", so it may
            // only be cleared by a reassert with real geometry to write
            // against: `reassert` early-returns on a degenerate visible
            // frame (and an absent display cannot be written), and clearing
            // the mark then would drop the deferred reassert for good.
            let hasGeometry = directory.isDisplayAttached(key.screen)
                && (directory.storedCanvas(for: key)?.visibleFrame)
                    .map { $0.width > 0 && $0.height > 0 } == true
            directory.withCanvas(key) {
                $0.reassert(.grid, context: placementContext(for: key))
            }
            if hasGeometry {
                directory.clearStale(key)
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

    // MARK: Registry

    /// Drops `handle`'s deferred pre-tile restore on every canvas. Call
    /// this at a claim (a slot request, an undo re-place, or an expand):
    /// the window's frame now belongs to the new action, so the canvas
    /// it left must never write the old frame over it on the swipe back.
    private func discardDeferredRestores(for handle: WindowHandle) {
        for key in directory.allKeys {
            directory.modifyCanvas(key) { $0.discardDeferredRestore(for: handle) }
        }
    }

    /// Test seam for the ownership invariant (audit M1/L2): the id the
    /// register currently names for `handle` while its record lives. A
    /// forgotten window must leave no entry behind; a live tiled window
    /// names its canvas's id.
    func registeredID(for handle: WindowHandle) -> WindowID? { register.liveID(for: handle) }

    /// Test seam for ticket 09's visibility guard: whether the canvas is
    /// currently marked stale, i.e. still owes a reassert for when its
    /// display or Space becomes visible. A deferred write marks the
    /// canvas; a reassert with real geometry clears it.
    func isMarkedStale(_ space: TilingSpaceKey) -> Bool {
        directory.isMarkedStale(space)
    }

    /// Test seam for the death-bookkeeping half of ticket 02: whether `id`
    /// has an unconfirmed death pending. Forgetting a window must clear
    /// this clock along with the handle entry.
    func hasPendingDeath(_ id: WindowID) -> Bool { register.hasPendingDeath(id) }

    /// Releases the record `id` holds on `owner` because another canvas is
    /// claiming its handle: the freed cells reflow and the coordinator's
    /// bookkeeping drops the id, but no frame is written — the claiming
    /// canvas owns the window's next write.
    private func releaseRecordClaimedByAnotherCanvas(_ id: WindowID, on owner: TilingSpaceKey) {
        let outcome = directory.withCanvas(owner) {
            $0.release(window: id, context: placementContext(for: owner))
        }
        apply(outcome, on: owner)
    }

    /// Drops records whose handle is gone (window closed, app quit).
    /// Called lazily before each hotkey and by the prune timer; internal so
    /// tests can drive ghost cleanup without waiting on the runloop. Only
    /// confirmed deaths prune: a busy app's unanswerable probe is unknown,
    /// and pruning on a maybe would untile a live window.
    func pruneDeadWindows() {
        var dead: [(key: TilingSpaceKey, id: WindowID, handle: WindowHandle)] = []
        for (key, canvas) in directory.allCanvases {
            for (id, record) in canvas.records
            where gateway.liveness(of: record.handle) == .dead {
                dead.append((key, id, record.handle))
            }
        }
        let timestamp = now()
        let awake = uptime()
        for entry in dead {
            let first = register.deathClock(entry.id, seenAt: awake)
            guard awake - first >= deathConfirmation else {
                dbg(
                    "prune win\(entry.id): dead handle sighted at \(timestamp), "
                        + "awaiting confirmation")
                continue
            }
            register.clearDeath(entry.id)
            dbg("prune win\(entry.id): dead handle confirmed, releasing slot")
            // Hand the element back to the adapter before the record
            // (the only holder of the handle) goes away.
            gateway.release(entry.handle)
            let outcome = directory.withCanvas(entry.key) {
                $0.release(window: entry.id, context: placementContext(for: entry.key))
            }
            apply(outcome, on: entry.key)
        }
        // A recovered probe or a vanished record clears the pending
        // death: only windows still reading dead stay marked.
        register.retainDeaths(only: Set(dead.map(\.id)))
    }

    private func raiseOccupants(on space: TilingSpaceKey) {
        // Raising an off-Space window can pull it to the visible Space;
        // z-order is a nicety, so a hidden canvas waits for its swipe.
        guard directory.isVisible(space) else { return }
        // Expanded windows are non-evicted too: they cover the layout
        // while holding their slots, and the evictee sits below them.
        for (_, id) in spaceState(for: space).occupants
            .sorted(by: { $0.key.rawValue < $1.key.rawValue })
        {
            guard let handle = directory.storedCanvas(for: space)?.handle(of: id) else {
                continue
            }
            gateway.raise(handle)
        }
    }

    // MARK: Bulk operations

    /// Dissolves the focused canvas's arrangement. Returns the one receipt
    /// the menu and hotkey paths present: performed only when windows were
    /// actually restored without a refusal.
    @discardableResult
    func untileAll() -> ActionReceipt {
        pruneDeadWindows()
        // Untile-all dissolves only the focused canvas: other displays
        // and Spaces keep their arrangements.
        return untileAll(in: directory.focusedKey())
    }

    /// Dissolves one tiling canvas, leaving every other canvas alone.
    /// The undo chapter tags each window with its canvas so the recovery
    /// retiles per display and per Space.
    @discardableResult
    private func untileAll(in space: TilingSpaceKey) -> ActionReceipt {
        pruneDeadWindows()
        let hadWindows =
            directory.storedCanvas(for: space)?.state.tiledWindows.isEmpty == false
        let outcome = directory.withCanvas(space) {
            $0.untileAll(context: placementContext(for: space))
        }
        apply(outcome, on: space)
        onChange?()
        let error = directory.storedCanvas(for: space)?.error
        let performed = hadWindows && error == nil
        return receipt(
            canvas: space, performed: performed,
            failure: error, success: MenuText.untileAllAnnouncement(),
            noOp: MenuText.nothingToUntileAnnouncement())
    }

    /// Resets the focused canvas's splitters, or restores the parked
    /// backup when one exists. One action for both surfaces: the menu row
    /// and the reset hotkey must agree, and a reset must never overwrite
    /// a parked restore (the menu already branches this way; the hotkey
    /// did not). The receipt names which outcome happened.
    @discardableResult
    func resetOrRestoreSplitters() -> ActionReceipt {
        let space = directory.focusedKey()
        let restored = directory.storedCanvas(for: space)?.hasSplitterBackup == true
        directory.withCanvas(space) { canvas in
            if restored {
                _ = canvas.restoreSplitters(context: placementContext(for: space))
            } else {
                canvas.visibleFrame = directory.visibleFrame(for: space)
                _ = canvas.resetSplitters(context: placementContext(for: space))
            }
        }
        onChange?()
        let error = directory.storedCanvas(for: space)?.error
        return receipt(
            canvas: space, performed: error == nil, failure: error,
            success: restored
                ? MenuText.splittersRestoredAnnouncement()
                : MenuText.splittersResetAnnouncement(),
            noOp: MenuText.splittersNothingToDoAnnouncement())
    }

    /// Snaps all splitters back to defaults and re-tiles everyone. The
    /// displaced fractions are kept as a one-step restore (same pattern
    /// as the shortcuts reset backup), so the app's "destruction is
    /// always reversible" ethic holds for drag positions too. Scoped to
    /// the focused canvas: other displays and Spaces keep their drag
    /// positions.
    func resetDividers() {
        resetDividers(in: directory.focusedKey())
    }

    private func resetDividers(in space: TilingSpaceKey) {
        directory.withCanvas(space) { canvas in
            canvas.visibleFrame = directory.visibleFrame(for: space)
            _ = canvas.resetSplitters(context: placementContext(for: space))
        }
        onChange?()
    }

    /// Restores the splitter fractions parked by the last reset, or false
    /// when there is no backup (fresh install, or already restored once).
    /// Scoped to the focused canvas, like `resetDividers`.
    @discardableResult
    func restoreSplitters() -> Bool {
        restoreSplitters(in: directory.focusedKey())
    }

    private func restoreSplitters(in space: TilingSpaceKey) -> Bool {
        guard directory.storedCanvas(for: space)?.hasSplitterBackup == true else {
            return false
        }
        directory.withCanvas(space) {
            $0.restoreSplitters(context: placementContext(for: space))
        }
        onChange?()
        return true
    }

    /// What the focused window's expand toggle does right now: drives the
    /// menu row's stateful title.
    var focusedExpandState: ExpandToggleState {
        guard let handle = gateway.focusedWindow(),
            let id = register.liveID(for: handle),
            let key = directory.owner(of: id)
        else { return .expands }
        return directory.storedCanvas(for: key)?.expandToggleState(of: id) ?? .expands
    }

    /// Undoes the freshest destructive tiling action: a layout switch, an
    /// ordinary eviction, or a swap. All share one recovery path: the
    /// displaced windows return to their slots, the requester to its
    /// pre-tile frame (a swap's requester entry re-tiles it into its
    /// vacated tile, swapping back). Consumes the entry it restores, so
    /// repeated ⌃⌥⇧⌘Z walks back through history up to `undoDepth`: the
    /// stack, not amnesia, bounds the past.
    ///
    /// This Bool seam exists for tests and callers that only need the
    /// verdict; the menu and hotkey paths present `undoAction()`'s receipt.
    @discardableResult
    func undoLastDisplacement() -> Bool {
        undoReceipt(in: directory.focusedKey()).performed
    }

    /// The menu and hotkey Undo path: one receipt carrying whether the
    /// chapter restored, its canvas and notice, and exactly one sentence.
    @discardableResult
    func undoAction() -> ActionReceipt {
        undoReceipt(in: directory.focusedKey())
    }

    @discardableResult
    private func undoReceipt(in space: TilingSpaceKey) -> ActionReceipt {
        guard let chapter = directory.withCanvas(space, { $0.undoStack.popLast() }) else {
            // Expired or empty: the one announcement is the answer.
            return receipt(
                canvas: space, performed: false,
                failure: nil, success: MenuText.undoAnnouncement(),
                noOp: MenuText.nothingToUndoAnnouncement())
        }
        let performed = restoreChapter(chapter, on: space)
        let error = directory.storedCanvas(for: space)?.error
        return receipt(
            canvas: space, performed: performed,
            failure: error, success: MenuText.undoAnnouncement(),
            noOp: MenuText.nothingToUndoAnnouncement())
    }

    /// Chapter restoration, owned here because the controller routes the
    /// cross-canvas effects. The directory holds the canvas table; the
    /// canvas supplies the primitive: `TilingSpace.restoreEvictees`
    /// re-places a group's evictees and `TilingSpace.restore` returns the
    /// requester, while this one named behaviour owns the cross-canvas
    /// rules — step-aside admission, per-canvas grouping, and the
    /// notice/error precedence that lets a partial failure surface ahead
    /// of the success sentence. Returns whether the chapter restored
    /// everything it owed.
    @discardableResult
    private func restoreChapter(
        _ chapter: TilingSpace.UndoChapter, on space: TilingSpaceKey
    ) -> Bool {
        pruneDeadWindows()
        directory.withCanvas(space) { $0.error = nil; $0.notice = nil }
        var failures: [String] = []
        var failedWindows: Set<WindowHandle> = []
        // One window can be refused on both its pre-tile restore and its
        // chapter entry; the handle is stable across the id reissue, so
        // the undo story names that window once, not twice.
        func recordFailure(_ handle: WindowHandle, name: String) {
            guard failedWindows.insert(handle).inserted else { return }
            failures.append(name)
        }
        var restored = 0
        // Restore the requester first, in the canvas owning its record:
        // its pre-tile frame wherever it sits — frames, not spaces,
        // decide that. (Its record may already be gone; the restore is a
        // no-op then.) Doing this before step-aside admission means a
        // fresh requester is restored by the requester path, not untiled
        // as a blocker, so its refusal is narrated rather than absorbed.
        var retainedRequester: (space: TilingSpaceKey, slot: Slot)?
        let requesterHandle = chapter.requester.flatMap { handle(of: $0) }
        if let requester = chapter.requester {
            let requesterSpace = directory.owner(of: requester) ?? space
            let handle = requesterHandle
            let name = appName(for: requester) ?? "A window"
            let hasChapterEntry = handle.map { handle in
                chapter.snapshot.contains { $0.handle == handle }
            } ?? false
            // A live requester that refuses to leave keeps the slot it
            // visibly holds (mirroring a refused move). A confirmed-dead
            // one is forgotten: it has no state left to own.
            let isDead = handle.map { gateway.liveness(of: $0) == .dead } ?? false
            let refused = directory.withCanvas(requesterSpace) { canvas -> Bool in
                !canvas.restore(
                    window: requester, context: placementContext(for: requesterSpace),
                    keepingOccupancyOnRefusal: !isDead)
            }
            if refused, let handle { recordFailure(handle, name: name) }
            // A retained requester owns its slot again; every other
            // outcome released the record. Without a chapter entry this
            // slot is a final barrier for the evictees below. With one,
            // the entry is re-placed first and decides the barrier.
            if directory.owner(of: requester) == nil {
                register.forget(requester)
            } else if !hasChapterEntry {
                retainedRequester = directory.owner(of: requester).flatMap { key in
                    spaceState(for: key).slot(of: requester).map { (space: key, slot: $0) }
                }
            }
        }
        // Step-aside admission: every remaining occupant the restoration
        // would land on (overlapping cells) or contradict (the other
        // layout) is untiled to its pre-tile frame first, so undo can
        // never double-book a cell or leave two layouts on one canvas.
        // The requester is already handled above and stays exempt.
        let handled: Set<WindowID> = chapter.requester.map { [$0] } ?? []
        for blocker in blockers(of: chapter, on: space, excluding: handled).sorted() {
            let handle = handle(of: blocker)
            let name = appName(for: blocker) ?? "A window"
            if untile(window: blocker, reflowing: false), let handle {
                recordFailure(handle, name: name)
            }
        }
        // Group the chapter by destination canvas: each window returns
        // to the canvas it left (legacy untagged entries restore into
        // the undone canvas). The requester's entry goes first, so a
        // refused move back becomes the barrier the rest respect.
        var orderedSnapshot = chapter.snapshot
        if let requesterHandle,
            let index = orderedSnapshot.firstIndex(where: { $0.handle == requesterHandle })
        {
            orderedSnapshot.insert(orderedSnapshot.remove(at: index), at: 0)
        }
        var bySpace: [TilingSpaceKey: [EvictedWindow]] = [:]
        for evicted in orderedSnapshot {
            bySpace[evicted.space ?? space, default: []].append(evicted)
        }
        for (destination, group) in bySpace {
            let retainedSlots: [Slot]
            if let retainedRequester, retainedRequester.space == destination {
                retainedSlots = [retainedRequester.slot]
            } else {
                retainedSlots = []
            }
            let result = directory.withCanvas(destination) {
                $0.restoreEvictees(
                    group, retained: retainedSlots,
                    context: placementContext(for: destination))
            }
            for window in result.restored {
                observe(window: window)
            }
            restored += result.restored.count
            for failure in result.failures {
                recordFailure(failure.handle, name: failure.name)
            }
            // A restore the canvas refused left no record: forget the
            // id (and death clock) for every window it released, not
            // just the requester's.
            for window in result.forget {
                register.forget(window)
            }
        }
        // The chapter's story, told once here: any refused frame surfaces
        // ahead of the success sentence, so a partial failure can never
        // hide behind "N windows restored".
        if !failures.isEmpty {
            directory.withCanvas(space) {
                $0.error = MenuText.restoreFailureMessage(failures)
            }
        } else if restored > 0 {
            let noun = restored == 1 ? "1 window" : "\(restored) windows"
            directory.withCanvas(space) {
                $0.notice = "Undid displacement \u{00B7} \(noun) restored."
            }
        } else {
            // Nothing restored and nothing refused (a chapter whose
            // windows all died): report the standard failure. The entry
            // is consumed either way.
            directory.withCanvas(space) { $0.error = MenuText.restoreDisplacedWindowsFailure }
        }
        onChange?()
        // A refused frame means the chapter did not fully restore: report
        // not-performed so a caller cannot speak a success sentence over
        // the canvas's refusal.
        return restored > 0 && failures.isEmpty
    }

    /// The current occupants that must step aside before `chapter`
    /// returns: those whose cells a restored window would land on, or
    /// whose layout the chapter contradicts. Chapter members are exempt —
    /// each has an entry of its own that re-places it (a swap or
    /// step-aside chapter's destinations may overlap one another) — and
    /// so is the window being restored.
    private func blockers(
        of chapter: TilingSpace.UndoChapter, on space: TilingSpaceKey,
        excluding handled: Set<WindowID>
    ) -> Set<WindowID> {
        let chapterHandles = Set(chapter.snapshot.map(\.handle))
        var blockers: Set<WindowID> = []
        for evicted in chapter.snapshot {
            let destination = evicted.space ?? space
            for (slot, current) in spaceState(for: destination).occupants
            where slot.overlaps(evicted.slot) || slot.layout != evicted.slot.layout {
                guard let handle = directory.storedCanvas(for: destination)?.handle(of: current),
                      handle != evicted.handle,
                      !chapterHandles.contains(handle),
                      !handled.contains(current)
                else { continue }
                blockers.insert(current)
            }
        }
        return blockers
    }

    // MARK: Live resize (observe & decide)

    /// The user pressed the mouse button at `point` (AppKit global
    /// coordinates, like every frame the tracker compares against):
    /// records the hand evidence a single far drag needs, so it can
    /// untile at mouse-up while a programmatic jump cannot. Wired from
    /// the production mouse-down monitor, which converts the event's
    /// Quartz location first; tests call it directly.
    func mousePressed(at point: CGPoint) {
        tracker.mousePressed(at: point)
    }

    /// The user moved the mouse with the button down. Refreshes the
    /// freshness of the press evidence so a slow-starting drag stays
    /// eligible; the press point itself remains the containment witness.
    /// Wired from the production drag monitor; tests call it directly.
    func mouseDragged() {
        tracker.mouseDragged()
    }

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
            guard let handle = handle(of: id) else { return }
            // An unreadable achieved frame (the lid-close transient) is
            // not a reason to drop the release: keep the stored splitters
            // and still map every rect, so neighbours never go stale.
            reassert(
                id,
                source: .resize(dragged: id, achieved: gateway.frame(of: handle)))
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
        guard let key = directory.owner(of: id) else { return }
        let outcome = directory.withCanvas(key) {
            $0.reassert(source, context: placementContext(for: key))
        }
        apply(outcome, on: key)
        onChange?()
    }

    /// Production mouse-down registrar: global monitors deliver clicks
    /// that go to other apps — where window-edge drags live — and the
    /// local monitor covers clicks this process receives. The tracker
    /// uses the press point only to tell a hand drag from a programmatic
    /// move, and it compares that point against AppKit frames: convert
    /// the event's Quartz top-left location before handing it over.
    static func observeLeftMouseDown(_ fire: @escaping (CGPoint) -> Void) {
        observeLeftMouse(
            .leftMouseDown,
            mouseDownHandler(
                primaryTop: { NSScreen.screens.first?.frame.maxY }, fire))
    }

    /// The press monitor's handler, split out so the conversion is
    /// pinned without installing a real event monitor.
    static func mouseDownHandler(
        primaryTop: @escaping () -> CGFloat?,
        _ fire: @escaping (CGPoint) -> Void
    ) -> (CGPoint?) -> Void {
        { point in
            guard let point, let primaryTop = primaryTop() else { return }
            fire(appKitPoint(fromQuartz: point, primaryTop: primaryTop))
        }
    }

    /// Quartz global event coordinates count y down from the main
    /// display's top; the tracker's frames are AppKit global coordinates,
    /// which count y up from its bottom. Pure, so the conversion is
    /// pinned without installing an event monitor.
    static func appKitPoint(fromQuartz point: CGPoint, primaryTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryTop - point.y)
    }

    /// Production mouse-drag registrar. A drag event refreshes the hand
    /// evidence while the button moves, so a press held still before the
    /// drag does not go stale.
    static func observeLeftMouseDragged(_ fire: @escaping () -> Void) {
        observeLeftMouse(.leftMouseDragged) { _ in fire() }
    }

    /// Production mouse-up registrar: the same two monitors as the press,
    /// because a release outside this process is exactly where a window
    /// drag ends. Both forward the event untouched; the handler itself
    /// filters (no pending resize is a no-op). Needs the same
    /// accessibility permission as AX.
    static func observeLeftMouseUp(_ fire: @escaping () -> Void) {
        observeLeftMouse(.leftMouseUp) { _ in fire() }
    }

    /// One registration shape for every left-mouse edge: the global
    /// monitor sees events delivered to other apps, the local one sees
    /// events this process receives. The point is the raw CG event
    /// location in Quartz top-left global coordinates; nil when the
    /// event has no CGEvent, which simply withholds hand evidence rather
    /// than guessing a point. Only the press registrar consumes it, and
    /// it converts into the AppKit space the tracker compares against.
    private static func observeLeftMouse(
        _ mask: NSEvent.EventTypeMask, _ fire: @escaping (CGPoint?) -> Void
    ) {
        NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            fire(event.cgEvent?.location)
        }
        NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            fire(event.cgEvent?.location)
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
                guard let currentID = self.register.liveID(for: handle) else { return }
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
        guard let id = register.liveID(for: handle) else { return }
        guard gateway.liveness(of: handle) == .dead else {
            dbg("destroyed win\(id): still live by the death standard; prune cadence decides")
            return
        }
        let key = directory.owner(of: id) ?? directory.focusedKey()
        dbg("destroyed win\(id): releasing slot now")
        gateway.release(handle)
        let outcome = directory.withCanvas(key) {
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
    var focusedScreen: ScreenID? { directory.focusedScreenID() }

    /// The focused tiling canvas (display plus Mission Control Space),
    /// captured once so a UI pass can read the glyph's layout and
    /// occupancy consistently even if focus moves between the reads.
    var focusedTilingSpace: TilingSpaceKey { directory.focusedKey() }

    var tiledWindowsInfo: [TiledWindowInfo] {
        allTiledWindowsInfo()
    }

    /// The provider's display name for a canvas's display, or nil when the
    /// provider does not know that display (headless) or the key is
    /// display-less. The raw lookup shared by the menu header and the
    /// spoken display-name gate; `displayName(for:)` adds the
    /// single-vs-multi-display rule on top.
    private func screenName(for space: TilingSpaceKey) -> String? {
        screens().first(where: { $0.id == space.screen })?.name
    }

    /// The display name to speak for a canvas, or nil when naming it would
    /// distinguish nothing: with a single display attached the glyph's
    /// monitor is unambiguous and the VoiceOver line is left alone. With
    /// more than one display the name tells the user which monitor the
    /// glyph depicts, matching the menu headers.
    func displayName(for space: TilingSpaceKey) -> String? {
        guard screens().count > 1 else { return nil }
        return screenName(for: space)
    }

    /// Every tiled window on every currently shown canvas, grouped by
    /// display (manage list scope). Windows parked in Spaces that are
    /// hidden right now stay managed, but are absent from the menu: the
    /// menu describes what a hotkey acts on, and a hotkey acts on the
    /// visible canvas. A canvas whose Space id the server withheld is not
    /// a hidden Space, so it is listed even when a display action resolves
    /// its identified sibling; the menu dedupes the rows by window. With
    /// no displays (headless tests), falls back to every remembered canvas.
    func allTiledWindowsInfo() -> [TiledWindowInfo] {
        var rows: [TiledWindowInfo] = []
        for key in directory.visibleKeys() {
            let occupants = directory.storedCanvas(for: key)?.state.occupants ?? [:]
            for (slot, id) in occupants.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                rows.append(TiledWindowInfo(
                    id: id, slot: slot, appName: appName(for: id),
                    screen: key.screen, screenName: screenName(for: key)))
            }
        }
        return rows
    }

    /// Every tiled window on every monitor (prune timer + legacy counts).
    private var allTiledWindows: [WindowID] {
        directory.allCanvases.values.flatMap(\.state.tiledWindows)
    }

    /// Brings a tiled window to the front without disturbing the layout.
    func focus(window id: WindowID) {
        guard let handle = handle(of: id) else { return }
        gateway.focus(handle)
    }

    /// Evicts the focused window (⌥⇧⌫): restores its pre-tile frame and
    /// releases the slot. Untiled focused windows and failed focuses are
    /// safe no-ops whose receipt answers once, instead of emitting
    /// feedback the delegate could duplicate; like `untile`, eviction
    /// keeps no undo chapter (the restoration IS the frame) — unless the
    /// reflow moved a survivor into the freed cells, which is its own
    /// chapter.
    @discardableResult
    func handleEvict() -> ActionReceipt {
        pruneDeadWindows()
        guard let handle = gateway.focusedWindow() else {
            dbg("no focused window for evict")
            return receipt(
                canvas: directory.focusedKey(), performed: false,
                failure: nil, success: MenuText.evictedAnnouncement(),
                noOp: MenuText.noFocusedWindowAnnouncement())
        }
        let liveID = register.liveID(for: handle)
        let key = liveID.flatMap { directory.owner(of: $0) } ?? directory.focusedKey()
        let id = liveID ?? register.claim(handle, on: key)
        // No pre-attach: a window with no slot is not tiled, and handing
        // it a record only for the eviction to find no slot would leave
        // stale ownership behind. The eviction forgets any record it
        // finds, and this applies that release so the register entry goes
        // with it.
        let outcome = directory.withCanvas(key) {
            $0.evict(window: id, context: placementContext(for: key))
        }
        apply(outcome, on: key)
        if case .nothingToEvict = outcome.result {
            return receipt(
                canvas: key, performed: false,
                failure: nil, success: MenuText.evictedAnnouncement(),
                noOp: MenuText.nothingToEvictAnnouncement())
        }
        onChange?()
        let error = directory.storedCanvas(for: key)?.error
        return receipt(
            canvas: key, performed: error == nil,
            failure: error, success: MenuText.evictedAnnouncement(),
            noOp: MenuText.nothingToEvictAnnouncement())
    }

    /// Untiles one window, restoring its pre-tile frame. The freed cells
    /// reflow to the mergeable survivor; undo's preparatory untiles pass
    /// `reflowing: false` (they make room for a restoration that follows
    /// immediately, and must not churn the layout nor push a chapter).
    ///
    /// Returns the menu's receipt: the window's own canvas (a background
    /// display or Space, not necessarily the focused one), whether a slot
    /// was actually released without a refusal, and one sentence. A
    /// refusal on another display names that display, so the spoken answer
    /// identifies the canvas the menu row acted on.
    @discardableResult
    func untile(window id: WindowID) -> ActionReceipt {
        // Prune before resolving the window and focus: a confirmed dead
        // handle is already untiled by the prune, so the receipt must not
        // call that release a fresh success.
        pruneDeadWindows()
        // Resolve focus before the action: an untile on another display or
        // Space must still know whether the canvas it touched was the
        // focused one when its refusal is spoken.
        let focusedBefore = directory.focusedKey()
        let key = directory.owner(of: id) ?? focusedBefore
        let name = appName(for: id)
        guard directory.storedCanvas(for: key)?.state.slot(of: id) != nil else {
            // A true no-op leaves the canvas's notice and error alone: the
            // menu must not lose a live receipt just because a stale row
            // was clicked after its window left.
            return receipt(
                canvas: key, performed: false,
                failure: nil, success: MenuText.untileWindowAnnouncement(windowName: name),
                noOp: MenuText.nothingToUntileWindowAnnouncement())
        }
        let refused = untile(window: id, reflowing: true)
        let error = directory.storedCanvas(for: key)?.error
        let display = key.screen == focusedBefore.screen ? nil : displayName(for: key)
        let failure = error.map {
            MenuText.untileWindowRefusalAnnouncement(displayName: display, error: $0)
        }
        return receipt(
            canvas: key, performed: !refused,
            failure: failure, success: MenuText.untileWindowAnnouncement(windowName: name),
            noOp: MenuText.nothingToUntileWindowAnnouncement(),
            noticeOverride: failure)
    }

    /// Returns whether the pre-tile restore was refused. Undo's
    /// preparatory untiles use this to fold a blocker's refusal into the
    /// chapter's story instead of letting a later success notice cover it.
    @discardableResult
    func untile(window id: WindowID, reflowing: Bool) -> Bool {
        pruneDeadWindows()
        // The window's own canvas clears (not the focused one): menu
        // untile rows act on background displays and Spaces.
        let key = directory.owner(of: id) ?? directory.focusedKey()
        let (outcome, refused) = directory.withCanvas(key) {
            canvas -> (TilingSpace.Outcome, Bool) in
            let outcome = canvas.untile(
                window: id, reflowing: reflowing, context: placementContext(for: key))
            return (outcome, canvas.error != nil)
        }
        apply(outcome, on: key)
        onChange?()
        return refused
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
        let liveID = register.liveID(for: handle)
        let key = liveID.flatMap { directory.owner(of: $0) } ?? directory.focusedKey()
        let id = liveID ?? register.claim(handle, on: key)
        let wasExpanded = directory.storedCanvas(for: key)?.isExpanded(id) == true
        let outcome = directory.withCanvas(key) { canvas in
            canvas.attach(id, handle: handle)
            return canvas.expandToggle(
                window: id, context: placementContext(for: key))
        }
        // Only a landed toggle (or a deferred one whose state stands)
        // claims the handle for this canvas. A refused expand, or the
        // no-readable-frame no-op, leaves the window exactly where it
        // was, so a deferred pre-tile restore on another canvas is still
        // live and must not be discarded.
        let expandedNow = directory.storedCanvas(for: key)?.isExpanded(id) == true
        switch outcome.result {
        case .placed:
            if expandedNow != wasExpanded { discardDeferredRestores(for: handle) }
        case .deferred:
            discardDeferredRestores(for: handle)
        case .refused, .alreadyTiled, .nothingToEvict, .expandRefused:
            break
        }
        announce(outcome.result)
        onChange?()
    }

    /// Slot a window presents to the tracker: expanded windows read as
    /// untiled, so the tracker never diff-resizes them into splitter
    /// moves or drags them out.
    private func trackedSlot(of id: WindowID) -> Slot? {
        guard let key = directory.owner(of: id),
            directory.storedCanvas(for: key)?.isExpanded(id) != true
        else {
            return nil
        }
        return directory.storedCanvas(for: key)?.state.slot(of: id)
    }

    private var trackedOccupants: [Slot: WindowID] {
        var all: [Slot: WindowID] = [:]
        for space in directory.allCanvases.values {
            for (slot, id) in space.state.occupants where !space.isExpanded(id) {
                all[slot] = id
            }
        }
        return all
    }

    /// Unexpanded occupants of one canvas.
    private func trackedOccupants(on space: TilingSpaceKey) -> [Slot: WindowID] {
        guard let canvas = directory.storedCanvas(for: space) else { return [:] }
        return canvas.state.occupants.filter { !canvas.isExpanded($0.value) }
    }

    // MARK: Drag-out untile

    /// The user dragged a tiled window past the untile distance and
    /// dropped it: release the slot and leave the window where it was
    /// dropped: no pre-tile restore, the drag IS the placement. (Short
    /// drags snap back inside the tracker and never reach here.)
    func untileFromDrag(_ id: WindowID) {
        guard record(of: id) != nil else { return }
        let key = directory.owner(of: id) ?? directory.focusedKey()
        let outcome = directory.withCanvas(key) {
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

    /// Whether a window has keyboard focus right now. The menu's collapsed
    /// switch rows read this from the controller instead of having the
    /// presenter post its own AX query, so one refresh pass stays one read.
    var hasFocusedWindow: Bool {
        gateway.isTrusted && gateway.focusedWindow() != nil
    }

    // MARK: Per-canvas spaces

    /// The canvas currently shown on `screen` (nil resolves the main
    /// display). Reads resolve through the same key the next action
    /// would target, withheld-Space fallback included, so a menu or test
    /// can never observe a different canvas than an action touches.
    func canvas(for screen: ScreenID?) -> TilingSpace {
        directory.canvas(for: directory.actionKey(for: screen))
    }

    /// One canvas by key: the single scoped read surface. A key that has
    /// never been used reads as an empty canvas (never nil), so callers
    /// assert against the same shape an action would have created.
    func canvas(for space: TilingSpaceKey) -> TilingSpace {
        directory.canvas(for: space)
    }

    /// One action receipt, built after the action so the canvas's notice or
    /// error and the restore verdict are final. The controller chooses the
    /// one announcement: a failure names the error, a performed action the
    /// success sentence, a no-op the no-op sentence. The notice prefers the
    /// error over a stale success notice, so the menu and the spoken answer
    /// cannot tell different stories. `noticeOverride` lets a background
    /// refusal put its display-qualified sentence in the menu too.
    private func receipt(
        canvas space: TilingSpaceKey,
        performed: Bool, failure: String?, success: String, noOp: String,
        noticeOverride: String? = nil
    ) -> ActionReceipt {
        let canvas = directory.storedCanvas(for: space)
        return ActionReceipt(
            canvas: space, performed: performed,
            notice: noticeOverride ?? canvas?.error ?? canvas?.notice,
            announcement: failure ?? (performed ? success : noOp))
    }

    private func spaceState(for space: TilingSpaceKey) -> TilingState {
        directory.canvas(for: space).state
    }

    /// The record of a managed window, wherever it lives.
    private func record(of id: WindowID) -> WindowRecord? {
        directory.owner(of: id).flatMap { directory.canvas(for: $0).record(of: id) }
    }

    /// The pre-tile frame of a handle whose record still lives. Focus
    /// resolution falls back to it when the live frame will not read.
    private func preTileFrame(of handle: WindowHandle) -> CGRect? {
        guard let id = register.liveID(for: handle) else { return nil }
        return record(of: id)?.preTileFrame
    }

    /// The handle of a managed window, wherever it lives.
    private func handle(of id: WindowID) -> WindowHandle? {
        directory.owner(of: id).flatMap { directory.canvas(for: $0).handle(of: id) }
    }
}
