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
    private lazy var executor = PlanExecutor(
        gateway: gateway, log: { [weak self] in self?.dbg($0) })

    /// The drag-resize loop. Lazy so its context closures can capture
    /// self: the tracker decides (echo, edges, splitters), this module
    /// performs writes via `pushRects` and serves record reads.
    private lazy var tracker: DragTracker = DragTracker(
        context: DragTracker.Context(
            slotOf: { [weak self] in self?.state.slot(of: $0) },
            frameOf: { [weak self] in self?.frameForTracker($0) },
            boundsOf: { [weak self] in self?.visibleBounds(for: $0) ?? $0 },
            occupants: { [weak self] in self?.state.occupants ?? [:] }),
        apply: { [weak self] rects, excluding in
            guard let self else { return 0 }
            return self.pushRects(rects, excluding: excluding)
        },
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

    /// Snapshot of windows evicted by the last layout switch, enabling a
    /// one-step undo ("Restore Evicted Windows"). `EvictedWindow` lives
    /// in PlanExecutor.swift; the snapshot is filled from `Outcome`.
    /// Cleared by any new tiling action, bulk op, or use — exactly one
    /// undo step exists.
    private var evictedSnapshot: [EvictedWindow]?
    private var switchRequester: WindowID?

    /// Whether a layout-switch undo is available (menu item visibility).
    var canUndoSwitch: Bool { evictedSnapshot?.isEmpty == false }

    /// Count for the undo menu title (0 when unavailable).
    var evictedCount: Int { evictedSnapshot?.count ?? 0 }

    /// Last layout-switch notice (shown in the status menu). A cross-layout
    /// hotkey untiles every other tiled window; the notice always carries
    /// the undo offer, so the first encounter teaches reversibility instead
    /// of just reporting destruction. Cleared on the next tiling attempt.
    /// Never overwrites a real error (refusals, restore failures win).
    private(set) var lastNotice: String?

    /// Last user-visible tiling failure (shown in the status menu).
    /// Cleared on the next tiling attempt.
    private(set) var lastTileError: String?

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
        case refused(windowName: String?)
    }

    var onFeedback: ((Feedback) -> Void)?

    private static let debugLogging = ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1"

    private func dbg(_ message: @autoclosure () -> String) {
        if Self.debugLogging {
            NSLog("tiled: %@", message())
        }
    }

    init(gateway: WindowGateway = LiveWindowGateway(), pruneInterval: TimeInterval? = 5.0) {
        self.gateway = gateway
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
        let decision = state.plan(window: id, into: slot)
        guard decision != .noop else {
            // Already in that tile: a strict no-op — no state, error, or
            // menu side effects. Still signal it so the hotkey path can
            // confirm subtly (the Welcome tab teaches this as safety).
            dbg("noop win\(id) already in \(slot.rawValue)")
            onFeedback?(.alreadyTiled(slot: slot))
            return
        }
        lastTileError = nil
        lastNotice = nil
        evictedSnapshot = nil
        switchRequester = nil

        let result = executor.execute(
            decision: decision, requester: id, slot: slot,
            state: state, records: records, nextID: nextID,
            tracker: tracker,
            boundsOf: { [weak self] in self?.visibleBounds(for: $0) ?? $0 },
            observe: { [weak self] in self?.observe(window: $0) })
        state = result.state
        records = result.records
        nextID = result.nextID
        let outcome = result.outcome
        if let feedback = outcome.feedback {
            onFeedback?(feedback)
        }
        lastNotice = outcome.notice
        if let error = outcome.error {
            lastTileError = error
        }
        evictedSnapshot = outcome.snapshot
        switchRequester = outcome.requester
        onChange?()
    }

    // MARK: Placement (delegated)

    /// Single-window restore shared by `untile` and `untileAll`: restores
    /// the pre-tile frame, releases the slot, and reports refusal so the
    /// caller can name the window instead of leaving a stray behind.
    private func restoreOne(_ id: WindowID) -> String? {
        var restored = true
        if let record = records[id], record.preTileFrame != .zero {
            restored = gateway.setFrame(record.handle, to: record.preTileFrame)
        }
        records[id] = nil
        tracker.forget(id)
        state.remove(window: id)
        if restored { return nil }
        return appName(for: id) ?? "A window"
    }

    /// Recomputes and pushes rects for all occupants (resize propagation).
    /// The tracker computes rects under its grid; this module performs the
    /// writes and reports refusals — the push half of the tracker's
    /// decide/push split.
    private func applyAll(excluding excluded: Set<WindowID> = []) {
        var rects: [WindowID: CGRect] = [:]
        for (_, occupant) in state.occupants {
            guard !excluded.contains(occupant), records[occupant] != nil else { continue }
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
    /// Returns the refusal count. `excluding` is informational — rects
    /// never name the dragged window.
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
    /// else the live frame, else the pre-tile frame.
    private func frameForTracker(_ id: WindowID) -> CGRect? {
        guard let record = records[id] else { return nil }
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
        let screens = NSScreen.screens
        if let index = Self.owningScreenIndex(frames: screens.map(\.frame), for: frame) {
            return screens[index].visibleFrame
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        if let containing = screens.first(where: { $0.frame.contains(point) }) {
            return containing.visibleFrame
        }
        dbg("no screen overlaps \(frame); falling back to main")
        return NSScreen.main?.visibleFrame ?? frame
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
            records[id] = nil
            tracker.forget(id)
            state.remove(window: id)
        }
    }

    // MARK: Bulk operations

    func untileAll() {
        pruneDeadWindows()
        lastTileError = nil
        lastNotice = nil
        evictedSnapshot = nil
        switchRequester = nil
        let failures = state.tiledWindows.compactMap { restoreOne($0) }
        reportRestoreFailures(failures)
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

    /// Snaps all splitters back to defaults and re-tiles everyone.
    func resetDividers() {
        tracker.resetDividers()
        lastTileError = nil
        lastNotice = nil
        evictedSnapshot = nil
        switchRequester = nil
        applyAll()
        onChange?()
    }

    /// Undoes the last layout switch via the executor: the requester is
    /// restored and every surviving evicted window returns to its slot.
    /// One step only — using it (or any new action) clears it.
    func undoLayoutSwitch() {
        guard let snapshot = evictedSnapshot, !snapshot.isEmpty else { return }
        pruneDeadWindows()
        lastTileError = nil
        lastNotice = nil
        evictedSnapshot = nil
        let requester = switchRequester
        switchRequester = nil
        let result = executor.undo(
            snapshot: snapshot, requester: requester,
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

    /// Untiles one window, restoring its pre-tile frame.
    func untile(window id: WindowID) {
        pruneDeadWindows()
        lastTileError = nil
        lastNotice = nil
        evictedSnapshot = nil
        switchRequester = nil
        if let failure = restoreOne(id) {
            reportRestoreFailures([failure])
        }
        onChange?()
    }

    private func appName(for id: WindowID) -> String? {
        records[id].flatMap { gateway.appName(of: $0.handle) }
    }

    private static func refusalMessage(count: Int) -> String {
        count == 1
            ? "Couldn't move that window — the app refused to resize it."
            : "Couldn't move \(count) windows — an app refused to resize."
    }

    var isTrusted: Bool { gateway.isTrusted }
}
