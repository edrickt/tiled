import AppKit

/// Glues the pure `TilingState` + `GridLayout` to real windows through a
/// `WindowGateway` — never touching AX types directly. All element
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
            occupants: { [weak self] in self?.trackedOccupants ?? [:] }),
        apply: { [weak self] rects, excluding in
            guard let self else { return 0 }
            return self.pushRects(rects, excluding: excluding)
        },
        onUntile: { [weak self] in self?.untileFromDrag($0) },
        scheduleDragEnd: scheduleDragEnd,
        log: { [weak self] in self?.dbg($0) })

    private(set) var state = TilingState()
    /// Current grid. Source of truth lives in the tracker; this mirrors
    /// it for tests and menus that read `controller.grid`.
    var grid: GridLayout { tracker.grid }

    /// Registry of managed windows. `PlanExecutor` reads and mutates
    /// these through `execute`/`undo`; `WindowRecord` is its type so both
    /// modules share one record shape.
    private var records: [WindowID: WindowRecord] = [:]
    private var nextID: WindowID = 1

    /// Snapshot of the last displacement(s), enabling a one-step undo.
    /// Each entry is a full recovery unit: the snapshot plus the requester
    /// to restore alongside it (a switch restores its requester; an
    /// ordinary eviction retiles its own). Newest last. The global undo
    /// consumes from the tail, so the freshest destruction is always the
    /// one that returns — no silent invalidation, ever.
    private var undoStack: [(snapshot: [EvictedWindow], requester: WindowID?)] = []
    /// Depth cap: enough history to survive a tile-tile-realize rhythm
    /// without growing unbounded in a hotkey-heavy session.
    private static let undoDepth = 5
    /// Splitter fractions parked by the last Reset Splitters, enabling a
    /// one-step restore. Memory-only, like the displacement undo: drag
    /// positions are per-session craft.
    private var splitterBackup: GridLayout?

    /// Whether a displacement undo is available (menu item visibility).
    var canUndoDisplacement: Bool { !undoStack.isEmpty }

    /// Count for the undo menu title (0 when unavailable).
    var evictedCount: Int { undoStack.last?.snapshot.count ?? 0 }

    /// Last layout-switch notice (shown in the status menu). A cross-layout
    /// hotkey untiles every other tiled window; the notice always carries
    /// the undo offer, so the first encounter teaches reversibility instead
    /// of just reporting destruction. Cleared on the next tiling attempt.
    /// Never overwrites a real error (refusals, restore failures win).
    private(set) var lastNotice: String?

    /// Last user-visible tiling failure (shown in the status menu).
    /// Cleared on the next tiling attempt.
    private(set) var lastTileError: String?

    /// Windows expanded over the layout by the ⌥⇧⏎ toggle, keyed by id,
    /// holding the frame to restore for windows that had no slot when
    /// expanded (tiled windows retile into their slot instead, so their
    /// entry is unused). Expanded windows keep their slot in `state` —
    /// expanding acts like focusing: it covers the layout without erasing
    /// it — but the tracker reads them as untiled (`trackedSlot`), so
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
        /// to reverse. Say so on every channel — a silent no-op from the
        /// surface whose promise is "never silently disagree" would be
        /// the one lie the app tells.
        case nothingToUndo
        /// A tiling write was refused. The delegate announces it; there
        /// is no on-screen panel — tiling feedback stays out of the way.
        case refused(windowName: String?)
        /// A ⌥⇧⏎ expand write was refused: same shape as `.refused` but
        /// the announcement must not say “tiled”.
        case expandRefused(windowName: String?)
    }

    var onFeedback: ((Feedback) -> Void)?

    private static let debugLogging = ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1"

    private func dbg(_ message: @autoclosure () -> String) {
        if Self.debugLogging {
            NSLog("tiled: %@", message())
        }
    }

    init(
        gateway: WindowGateway = LiveWindowGateway(),
        pruneInterval: TimeInterval? = 5.0,
        scheduleDragEnd: @escaping DragTracker.DragEndScheduler = DragTracker.scheduleDragEndOnMain
    ) {
        self.gateway = gateway
        self.scheduleDragEnd = scheduleDragEnd
        // Windows closed while tiled otherwise linger as ghosts until the
        // next hotkey; release their slots within seconds instead.
        // `pruneInterval == nil` schedules no runloop timer: tests pass nil
        // so no live timer races a test run, and drive `pruneDeadWindows`
        // directly instead.
        if let pruneInterval {
            let prune = Timer.scheduledTimer(withTimeInterval: pruneInterval, repeats: true) {
                [weak self] _ in
                guard let self else { return }
                let before = self.state.tiledWindows.count
                self.pruneDeadWindows()
                if self.state.tiledWindows.count != before {
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
        // An expanded window getting a slot hotkey comes back to earth
        // first: its own slot becomes the strict no-op below; a different
        // slot retiles from the collapsed state.
        if expanded[id] != nil {
            collapseExpanded(id)
        }
        let decision = state.plan(window: id, into: slot)
        guard decision != .noop else {
            // Already in that tile: a strict no-op — no state, error, or
            // menu side effects. Still signal it so the hotkey path can
            // confirm subtly (the Welcome tab teaches this as safety).
            dbg("noop win\(id) already in \(slot.rawValue)")
            onFeedback?(.alreadyTiled(slot: slot))
            return
        }
        resetTransientState()
        // The swap keeps focus on the original tile: capture the slot
        // the requester is about to vacate now — after `execute` the
        // state holds the heirs, not the history.
        let vacated = state.slot(of: id)

        let result = executor.execute(
            decision: decision, requester: id, slot: slot,
            state: state, records: records, nextID: nextID,
            tracker: tracker,
            boundsOf: { [weak self] in self?.visibleBounds(for: $0) ?? $0 },
            observe: { [weak self] in self?.observe(window: $0) })
        state = result.state
        records = result.records
        nextID = result.nextID
        // Evicted windows were restored by the executor: expansion died
        // with the pre-tile frame write that restored them.
        for evicted in decision.windowsToRestore(requester: id) {
            forgetWindow(evicted)
        }
        let outcome = result.outcome
        if case .swap = decision, outcome.error == nil {
            // A swap vacates the requester's old slot: focus stays with
            // the original tile, not the requester. Whoever inherits
            // that slot takes focus, so a chained hotkey acts on the
            // tile's new window with no manual refocus — tiling RH to
            // TL leaves focus on the window that landed in RH, ready to
            // swap onward to BL. This also re-asserts past a settle-late
            // app stealing focus on the final rewrite. When the old slot
            // has no single heir (blockers split it across pieces),
            // focus takes the first overlapping piece in slot order —
            // rawValue order, the same order the menus use, so the perch
            // is deterministic.
            focusSwapHeir(vacated: vacated)
        }
        if let feedback = outcome.feedback {
            onFeedback?(feedback)
        }
        lastNotice = outcome.notice
        if let error = outcome.error {
            lastTileError = error
        }
        pushUndo(snapshot: outcome.snapshot, requester: outcome.requester)
        onChange?()
    }

    /// Records a destructive outcome on the undo stack: keeps the
    /// freshest `undoDepth` recoveries, dropping the oldest. A new tiling
    /// action pushes; it never silently invalidates — depth, not
    /// amnesia, bounds the history.
    private func pushUndo(snapshot: [EvictedWindow]?, requester: WindowID?) {
        guard let snapshot, !snapshot.isEmpty else { return }
        undoStack.append((snapshot: snapshot, requester: requester))
        if undoStack.count > Self.undoDepth {
            undoStack.removeFirst(undoStack.count - Self.undoDepth)
        }
    }

    // MARK: Placement (delegated)

    /// Single-window restore shared by `untile` and `untileAll`: restores
    /// the pre-tile frame, releases the slot, and reports refusal so the
    /// caller can name the window instead of leaving a stray behind.
    /// Returns the pre-tile frame it restored to (nil when there was
    /// nothing to restore), so bulk callers can snapshot it for undo —
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
    /// The tracker computes rects under its grid; this module performs the
    /// writes and reports refusals — the push half of the tracker's
    /// decide/push split.
    private func applyAll(excluding excluded: Set<WindowID> = []) {
        var rects: [WindowID: CGRect] = [:]
        for (_, occupant) in state.occupants {
            guard !excluded.contains(occupant), records[occupant] != nil,
                expanded[occupant] == nil
            else { continue }
            if let target = tracker.rect(for: occupant) {
                rects[occupant] = target
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
    /// is the drag's source of truth; it is informational — snapback rects
    /// DO name the (formerly) dragged window, with `excluding` nil.
    private func pushRects(_ rects: [WindowID: CGRect], excluding: WindowID?) -> Int {
        var failed = 0
        for (id, target) in rects {
            guard let record = records[id] else { continue }
            tracker.markExpected(id, target)
            if !gateway.setFrame(record.handle, to: target) { failed += 1 }
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
    /// tick late) can never read as a user drag — echo suppression
    /// compares against this, and it must be our intent, not the echo.
    private func frameForTracker(_ id: WindowID) -> CGRect? {
        guard let record = records[id] else { return nil }
        if let pushed = tracker.lastPushedTarget(for: id) { return pushed }
        return gateway.frame(of: record.handle) ?? record.preTileFrame
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
    /// midpoint screen, then main — so off-screen or inter-Space windows
    /// still tile somewhere sane instead of using raw frame coordinates.
    private func visibleBounds(for frame: CGRect) -> CGRect {
        screen(for: frame)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
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
        for (id, record) in records where record.handle == handle {
            return id
        }
        let id = nextID
        nextID += 1
        records[id] = WindowRecord(handle: handle, preTileFrame: .zero)
        return id
    }

    /// Drops records whose handle is gone (window closed, app quit).
    /// Called lazily before each hotkey and by the prune timer; internal so
    /// tests can drive ghost cleanup without waiting on the runloop.
    func pruneDeadWindows() {
        for (id, record) in records where !gateway.isAlive(record.handle) {
            forgetWindow(id)
        }
    }

    /// Clears error/notice state: every user-initiated tiling action
    /// starts from a clean slate. The undo stack is NOT cleared here —
    /// history survives new actions up to `undoDepth`. Only a successful
    /// undo consumes its entry, and bulk destructive ops (untile all)
    /// start a new chapter.
    private func resetTransientState() {
        lastTileError = nil
        lastNotice = nil
    }

    // MARK: Bulk operations

    func untileAll() {
        pruneDeadWindows()
        resetTransientState()
        // Untile-all starts its own undo chapter: the chapter lists each
        // dissolved (slot, pre-tile frame) pair, and undo re-applies the
        // slot rect on top of the restored frame — the window visibly
        // returns to the arrangement, not just to its pre-tile frame.
        // No modal: the sticky notice + ⌃⌥⇧⌘Z are the safety.
        let chapter = state.occupants
        if !chapter.isEmpty {
            undoStack.append((snapshot: [], requester: nil))
            if undoStack.count > Self.undoDepth {
                undoStack.removeFirst(undoStack.count - Self.undoDepth)
            }
            let noun = chapter.count == 1 ? "1 window" : "\(chapter.count) windows"
            lastNotice = "Untiled \(noun). Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."
            // Prime the tracker's intent for the slot rects the undo will
            // write: the live frames are pre-tile settle frames, and the
            // diff must measure against where we're going, not where the
            // restore just put us. Without this the undo's own writes
            // read as a user drag and the grid moves under them.
            for (slot, id) in chapter {
                if let record = records[id] {
                    let target = tracker.grid.rect(
                        for: slot, in: visibleBounds(for: record.preTileFrame))
                    tracker.markExpected(id, target)
                }
            }
        }
        // Handles first: restoreOne clears each record, so resolve every
        // handle while the registry still knows them.
        var handles: [WindowID: WindowHandle] = [:]
        for id in state.tiledWindows {
            if let record = records[id] { handles[id] = record.handle }
        }
        let failures = state.tiledWindows.compactMap { restoreOne($0).failure }
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
                observe(window: fresh)
                snapshot.append(EvictedWindow(handle: handle, slot: slot, preTileFrame: frame))
            }
            undoStack[undoStack.count - 1] = (snapshot: snapshot, requester: nil)
        }
        onChange?()
    }

    /// Reports restore failures unless a more relevant error already took
    /// the slot. Shared by `untile`/`untileAll`; plan execution reports
    /// its own through `Outcome.error` with the same precedence rule.
    private func reportRestoreFailures(_ failures: [String]) {
        guard !failures.isEmpty, lastTileError == nil else { return }
        if failures.count == 1 {
            lastTileError =
                "Couldn't restore “\(failures[0])” — it may still be sitting in its old tile."
        } else {
            lastTileError =
                "Couldn't restore \(failures.count) windows — they may still be sitting in their old tiles."
        }
    }

    /// Snaps all splitters back to defaults and re-tiles everyone. The
    /// displaced fractions are kept as a one-step restore — same pattern
    /// as the shortcuts reset backup — so the app's "destruction is
    /// always reversible" ethic holds for drag positions too.
    func resetDividers() {
        splitterBackup = tracker.resetDividers()
        resetTransientState()
        applyAll()
        onChange?()
    }

    /// Restores the splitter fractions parked by the last reset, or false
    /// when there is no backup (fresh install, or already restored once).
    @discardableResult
    func restoreSplitters() -> Bool {
        guard let backup = splitterBackup else { return false }
        tracker.restoreDividers(backup)
        splitterBackup = nil
        resetTransientState()
        lastNotice = "Splitters restored to their pre-reset positions."
        applyAll()
        onChange?()
        return true
    }

    /// Whether a splitter backup is parked: drives the menu row title
    /// ("Reset Splitters" vs "Restore Previous Splitters").
    var hasSplitterBackup: Bool { splitterBackup != nil }

    /// The slot the focused window would return to if it is currently
    /// expanded — nil otherwise. Drives the expand row's stateful title:
    /// the toggle must show its state, not just its combo.
    var expandedFocusedSlot: Slot? {
        guard let handle = gateway.focusedWindow() else { return nil }
        let id = windowID(for: handle)
        guard expanded[id] != nil else { return nil }
        return state.slot(of: id)
    }

    /// Undoes the freshest destructive tiling action — a layout switch or
    /// an ordinary eviction. Both share one recovery path: the displaced
    /// windows return to their slots, the requester to its pre-tile frame.
    /// Consumes the entry it restores, so repeated ⌃⌥⇧⌘Z walks back
    /// through history up to `undoDepth` — the stack, not amnesia, bounds
    /// the past.
    func undoLastDisplacement() {
        guard let entry = undoStack.popLast() else {
            // Expired or empty: the promise needs an answer, not silence
            // (see the undo-expiry feedback below).
            onFeedback?(.nothingToUndo)
            return
        }
        pruneDeadWindows()
        lastTileError = nil
        lastNotice = nil
        let result = executor.undo(
            snapshot: entry.snapshot, requester: entry.requester,
            state: state, records: records, nextID: nextID, tracker: tracker,
            boundsOf: { [weak self] in self?.visibleBounds(for: $0) ?? $0 },
            observe: { [weak self] in self?.observe(window: $0) })
        state = result.state
        records = result.records
        nextID = result.nextID
        lastNotice = result.notice
        if let error = result.error {
            lastTileError = error
        }
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
    }

    var activeLayout: LayoutKind { state.activeLayout }

    var tiledWindowsInfo: [TiledWindowInfo] {
        state.occupants
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { slot, id in TiledWindowInfo(id: id, slot: slot, appName: appName(for: id)) }
    }

    /// Brings a tiled window to the front without disturbing the layout.
    func focus(window id: WindowID) {
        guard let record = records[id] else { return }
        gateway.focus(record.handle)
    }

    /// Focus after a successful swap stays on the original tile: the heir
    /// now sitting in the requester's vacated slot takes focus, so chained
    /// hotkeys keep acting on that tile with no manual refocus. When the
    /// vacated slot has no single heir (blockers split it across pieces),
    /// focus takes the first overlapping piece in reading order —
    /// `Slot.readingOrderedCases`, the same spatial order the solver deals
    /// blockers in, so the perch matches the shuffle instead of
    /// dictionary order. Refused swaps never reach here (the caller
    /// guards on `outcome.error == nil`): a window that refused its
    /// write holds no slot, and activating it would be a surprise.
    private func focusSwapHeir(vacated: Slot?) {
        guard let vacated else { return }
        if let heir = state.occupant(of: vacated), let record = records[heir] {
            gateway.focus(record.handle)
            return
        }
        // Split tile: no single heir. First overlapping piece in reading
        // order wins — the same spatial order the solver dealt the pieces in.
        let piece = state.occupants
            .filter { $0.key.overlaps(vacated) }
            .sorted {
                let order = Slot.readingOrderedCases
                return order.firstIndex(of: $0.key)! < order.firstIndex(of: $1.key)!
            }
            .first
        if let heir = piece?.value, let record = records[heir] {
            gateway.focus(record.handle)
        }
    }

    /// Untiles one window, restoring its pre-tile frame.
    func untile(window id: WindowID) {
        pruneDeadWindows()
        resetTransientState()
        if let failure = restoreOne(id).failure {
            reportRestoreFailures([failure])
        }
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
        resetTransientState()
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
        resetTransientState()
        if state.slot(of: id) != nil {
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
        guard let record = records[id], let slot = state.slot(of: id) else { return }
        let current = gateway.frame(of: record.handle) ?? record.preTileFrame
        let bounds = visibleBounds(for: current)
        let target = tracker.grid.rect(for: slot, in: bounds)
        if !writeExpandedFrame(id, to: target) {
            onFeedback?(.expandRefused(windowName: appName(for: id)))
        }
        dbg("retile expanded win\(id) -> \(slot.rawValue) target=\(target)")
    }

    /// One expected frame write via the gateway — the shared shape of the
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
        expanded[id] == nil ? state.slot(of: id) : nil
    }

    private var trackedOccupants: [Slot: WindowID] {
        state.occupants.filter { expanded[$0.value] == nil }
    }

    // MARK: Drag-out untile

    /// The user dragged a tiled window past the untile distance and
    /// dropped it: release the slot and leave the window where it was
    /// dropped — no pre-tile restore, the drag IS the placement. (Short
    /// drags snap back inside the tracker and never reach here.)
    func untileFromDrag(_ id: WindowID) {
        guard records[id] != nil else { return }
        resetTransientState()
        forgetWindow(id)
        dbg("drag-untile win\(id)")
        onChange?()
    }

    private func appName(for id: WindowID) -> String? {
        records[id].flatMap { gateway.appName(of: $0.handle) }
    }

    /// Releases a window's records, tracker entries, occupancy, and any
    /// expansion. Callers handle any frame writes first — this only
    /// forgets. Shared by untile, drag-out untile, prune, and eviction.
    private func forgetWindow(_ id: WindowID) {
        records[id] = nil
        tracker.forget(id)
        state.remove(window: id)
        expanded[id] = nil
    }

    private static func refusalMessage(count: Int) -> String {
        count == 1
            ? "Couldn't move that window — the app refused to resize it."
            : "Couldn't move \(count) windows — an app refused to resize."
    }

    var isTrusted: Bool { gateway.isTrusted }
}
