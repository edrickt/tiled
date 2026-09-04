import AppKit
import ApplicationServices

/// Glues the pure `TilingState` + `GridLayout` to real windows via AX.
///
/// Responsibilities:
/// - Tiling/eviction per the decided rules (see TilingState).
/// - Live drag resize (observe & compensate): AXObserver notifications on
///   tiled windows -> detect which edge the user dragged -> move the
///   corresponding grid splitter -> push new rects to the neighbor windows.
///   Writes are bookkept in `expectedFrames` so our own echoes don't recurse.
final class TilingController {
    /// The single controller instance (AXObserver callbacks have no user data).
    static weak var active: TilingController?

    private(set) var state = TilingState()
    private(set) var grid = GridLayout()

    private struct Record {
        let element: AXUIElement
        let pid: pid_t
        var preTileFrame: CGRect
    }

    private var records: [WindowID: Record] = [:]
    private var nextID: WindowID = 1

    /// Last frame we observed per tiled window (for edge-change detection).
    private var lastKnownFrames: [WindowID: CGRect] = [:]
    /// Frames we recently asked AX to set (echo suppression). Apps animate
    /// AX frame writes, emitting notification streams that converge on the
    /// requested frame; we swallow while converging and escape as soon as a
    /// tick moves away from it (a real user grab).
    private var expectedFrames: [WindowID: ExpectedWrite] = [:]
    /// Elements with resize/move observers registered (CFHash keyed; we can
    /// never unregister, so dedupe to avoid duplicate callbacks on re-tile).
    private var observedElements: Set<UInt> = []
    private var observers: [pid_t: AXObserver] = [:]

    private var applyScheduled = false
    private var applyExclusions: Set<WindowID> = []

    private static let echoTolerance: CGFloat = 32
    private static let staleWrite: TimeInterval = 3
    private static let edgeMoveThreshold: CGFloat = 1

    private struct ExpectedWrite {
        let frame: CGRect
        /// Last observed sum-of-edge-deltas from `frame`. Starts at infinity;
        /// only a strictly increasing distance means a user took over.
        var lastDistance: CGFloat
        let date: Date
    }

    /// Last user-visible tiling failure (shown in the status menu).
    /// Cleared on the next tiling attempt.
    private(set) var lastTileError: String?

    private var pruneTimer: Timer?
    private var screenObserver: NSObjectProtocol?

    /// Called after any state change (for menu refresh).
    var onChange: (() -> Void)?

    private static let debugLogging = ProcessInfo.processInfo.environment["TILED_DEBUG"] == "1"

    private func dbg(_ message: @autoclosure () -> String) {
        if Self.debugLogging {
            NSLog("tiled: %@", message())
        }
    }

    init() {
        TilingController.active = self
        // Windows closed while tiled otherwise linger as ghosts until the
        // next hotkey; release their slots within seconds instead.
        let prune = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) {
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
        guard let focused = AXKit.focusedWindow() else { return }
        let id = windowID(for: focused.element, pid: focused.pid)
        let decision = state.plan(window: id, into: slot)
        guard decision != .noop else {
            // Already in that tile: a strict no-op — no state, error, or
            // menu side effects.
            dbg("noop win\(id) already in \(slot.rawValue)")
            return
        }
        lastTileError = nil

        switch decision {
        case .noop:
            break // unreachable (guarded above)
        case .swap(let placements):
            state.commitSwaps(placements)
            var failed = 0
            for occupant in placements.keys {
                if !applyLayout(for: occupant) { failed += 1 }
            }
            if failed > 0 {
                lastTileError = Self.refusalMessage(count: failed)
            }
            dbg("swap win\(id) -> \(slot.rawValue) placements=\(placements)")
        case .switchLayout:
            // The requester moves rather than evicts: restore everyone
            // else first (restoring it would delete its record, so `place`
            // would bail and the window would merely untile). Its old tile
            // is vacated by the commit inside `place`.
            let restoreFailures = restore(decision.windowsToRestore(requester: id))
            place(window: id, into: slot)
            reportRestoreFailures(restoreFailures)
            dbg("switchLayout win\(id) -> \(slot.rawValue) decision=\(decision)")
        case .tile:
            let restoreFailures = restore(decision.windowsToRestore(requester: id))
            place(window: id, into: slot)
            reportRestoreFailures(restoreFailures)
        }
        onChange?()
    }

    // MARK: Placement

    private func place(window id: WindowID, into slot: Slot) {
        guard var record = records[id] else { return }
        if state.slot(of: id) == nil {
            // First tiling: remember where to restore when untiled.
            // A window moving between overlapping slots (e.g. Left -> BottomLeft)
            // keeps its original pre-tile frame.
            record.preTileFrame = AXKit.frame(of: record.element) ?? record.preTileFrame
            records[id] = record
        }
        state.commit(window: id, into: slot)
        observe(window: id, record: record)
        if !applyLayout(for: id) {
            // The window refused the frame (some apps ignore AX resizes):
            // roll back occupancy so state and screen agree, and say so.
            state.remove(window: id)
            lastKnownFrames[id] = nil
            expectedFrames[id] = nil
            let name = appName(for: id) ?? "That window"
            lastTileError = "\(name) couldn't be tiled — the app refused to resize it."
            dbg("place FAILED win\(id) -> \(slot.rawValue)")
            return
        }
        dbg("place win\(id) -> \(slot.rawValue)")
    }

    /// Restores the window's pre-tile frame and releases its slot.
    /// Returns false when the restore was attempted and refused, so the
    /// caller can say so instead of silently leaving a stray window behind.
    @discardableResult
    private func untile(window id: WindowID) -> Bool {
        var restored = true
        if let record = records[id], record.preTileFrame != .zero {
            restored = AXKit.setFrame(record.element, to: record.preTileFrame)
        }
        records[id] = nil
        lastKnownFrames[id] = nil
        expectedFrames[id] = nil
        state.remove(window: id)
        return restored
    }

    /// Untiles every window in `ids`, returning the display names of those
    /// whose pre-tile frame refused to restore.
    private func restore(_ ids: [WindowID]) -> [String] {
        var failures: [String] = []
        for evicted in ids {
            let name = appName(for: evicted) ?? "A window"
            if !untile(window: evicted) {
                failures.append(name)
            }
        }
        return failures
    }

    /// Reports restore failures unless a more relevant error (e.g. the
    /// requested tiling itself failing) already took the slot.
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

    /// Applies `id`'s slot rect on the screen the window currently lives on.
    /// Returns whether the AX write succeeded (some windows refuse resizes).
    @discardableResult
    private func applyLayout(for id: WindowID) -> Bool {
        guard let record = records[id], let slot = state.slot(of: id) else { return false }
        let current = AXKit.frame(of: record.element) ?? record.preTileFrame
        let bounds = visibleBounds(for: current)
        let target = grid.rect(for: slot, in: bounds)
        markExpected(id, target)
        lastKnownFrames[id] = target
        let ok = AXKit.setFrame(record.element, to: target)
        dbg("applyLayout win\(id) slot=\(slot.rawValue) bounds=\(bounds) target=\(target) ok=\(ok)")
        return ok
    }

    /// Recomputes and pushes rects for all occupants (resize propagation).
    private func applyAll(excluding excluded: Set<WindowID> = []) {
        var failed = 0
        for (slot, occupant) in state.occupants {
            guard !excluded.contains(occupant), let record = records[occupant] else { continue }
            let frame =
                lastKnownFrames[occupant] ?? AXKit.frame(of: record.element)
                ?? record.preTileFrame
            let bounds = visibleBounds(for: frame)
            let target = grid.rect(for: slot, in: bounds)
            markExpected(occupant, target)
            if !AXKit.setFrame(record.element, to: target) { failed += 1 }
            dbg("applyAll win\(occupant) slot=\(slot.rawValue) target=\(target)")
        }
        if failed > 0 {
            lastTileError = Self.refusalMessage(count: failed)
        }
    }

    /// Coalesces rapid resize notifications into one apply per runloop tick.
    private func scheduleApply(excluding id: WindowID) {
        applyExclusions.insert(id)
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyScheduled = false
            let excluded = self.applyExclusions
            self.applyExclusions = []
            self.applyAll(excluding: excluded)
            self.onChange?()
        }
    }

    private func visibleBounds(for frame: CGRect) -> CGRect {
        NSScreen.screens.first {
            $0.visibleFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
    }

    // MARK: Registry

    private func windowID(for element: AXUIElement, pid: pid_t) -> WindowID {
        for (id, record) in records where CFEqual(record.element, element) {
            return id
        }
        let id = nextID
        nextID += 1
        records[id] = Record(element: element, pid: pid, preTileFrame: .zero)
        return id
    }

    /// Drops records whose AX element is gone (window closed, app quit).
    /// Called lazily before each hotkey; proper AXObserver-driven cleanup is
    /// a later milestone.
    private func pruneDeadWindows() {
        for (id, record) in records where !AXKit.isAlive(record.element) {
            records[id] = nil
            lastKnownFrames[id] = nil
            expectedFrames[id] = nil
            state.remove(window: id)
        }
    }

    // MARK: Bulk operations

    func untileAll() {
        pruneDeadWindows()
        lastTileError = nil
        reportRestoreFailures(restore(state.tiledWindows))
        onChange?()
    }

    /// Snaps all splitters back to defaults and re-tiles everyone.
    func resetGrid() {
        grid = GridLayout()
        lastTileError = nil
        applyAll()
        onChange?()
    }

    // MARK: Live resize (observe & compensate)

    private func observe(window id: WindowID, record: Record) {
        let key = UInt(CFHash(record.element))
        guard !observedElements.contains(key) else { return }
        observedElements.insert(key)

        let observer: AXObserver
        if let existing = observers[record.pid] {
            observer = existing
        } else {
            var created: AXObserver?
            let result = AXObserverCreate(record.pid, Self.observerCallback, &created)
            guard result == .success, let newObserver = created else {
                observedElements.remove(key)
                NSLog("tiled: AXObserverCreate failed for pid %d (%d)", record.pid, result.rawValue)
                return
            }
            observer = newObserver
            observers[record.pid] = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.commonModes)
        }

        for name in [kAXWindowResizedNotification, kAXWindowMovedNotification] {
            let status = AXObserverAddNotification(
                observer, record.element, name as CFString,
                UnsafeMutableRawPointer(bitPattern: id))
            if status != .success {
                NSLog(
                    "tiled: could not observe %@ on pid %d (%d)", name as String, record.pid,
                    status.rawValue)
            }
        }
    }

    func handleAXNotification(notification: String, element: AXUIElement) {
        // The observer refcon ids go stale (registrations outlive untiled
        // records and can never be removed), so resolve the window by element
        // identity. Windows that are currently untiled are ignored.
        guard let id = currentID(for: element) else { return }
        guard let frame = AXKit.frame(of: element) else { return }
        dbg("notif win\(id) \(notification as String) frame=\(frame)")

        // Echo suppression: our writes apply (often animated) as a stream of
        // notifications converging on the requested frame. Swallow them; a
        // tick that moves AWAY from the target means a real user drag took
        // over, so we clear the entry and process it.
        if var entry = expectedFrames[id] {
            if framesClose(entry.frame, frame, tolerance: Self.echoTolerance) {
                expectedFrames[id] = nil // write fully applied
                lastKnownFrames[id] = frame
                dbg("echo win\(id) consumed")
                return
            }
            let distance = frameDistance(entry.frame, frame)
            if distance > entry.lastDistance + 1 {
                expectedFrames[id] = nil // user took over
                dbg("echo win\(id) ESCAPE dist=\(distance) last=\(entry.lastDistance)")
            } else if Date().timeIntervalSince(entry.date) > Self.staleWrite {
                expectedFrames[id] = nil // write never applied; stop waiting
                dbg("echo win\(id) stale")
            } else {
                entry.lastDistance = distance
                expectedFrames[id] = entry
                lastKnownFrames[id] = frame
                dbg("echo win\(id) converging dist=\(distance)")
                return
            }
        }

        // Diff against the previous frame of ANY kind. Drags that change a
        // window's origin arrive as Moved+Resized pairs with identical
        // frames; comparing Resized against the paired Moved would silently
        // drop every left/top/corner drag. Origin-only changes are title-bar
        // moves: v1 leaves them off-grid until the next layout assertion.
        let previous = lastKnownFrames[id]
        lastKnownFrames[id] = frame
        guard let previous, previous != frame else { return }
        guard previous.size == frame.size else {
            processResize(windowID: id, from: previous, to: frame)
            return
        }
        dbg("move win\(id) ignored (origin-only change)")
    }

    /// Detects which edges moved, maps them to grid boundaries, updates the
    /// splitters from the dragged window's *actual* frame, then pushes new
    /// rects to the neighbors.
    private func processResize(windowID id: WindowID, from old: CGRect, to new: CGRect) {
        guard let slot = state.slot(of: id) else { return }
        let bounds = visibleBounds(for: new)
        let threshold = Self.edgeMoveThreshold

        func moved(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > threshold }

        var changed = false
        for edge in TileEdge.allCases {
            let edgeMoved: Bool
            let position: CGFloat
            switch edge {
            case .left:
                edgeMoved = moved(new.minX, old.minX); position = new.minX
            case .right:
                edgeMoved = moved(new.maxX, old.maxX); position = new.maxX
            case .top:
                edgeMoved = moved(new.maxY, old.maxY); position = new.maxY
            case .bottom:
                edgeMoved = moved(new.minY, old.minY); position = new.minY
            }
            guard edgeMoved else { continue }
            // The dragged window's own edge is the source of truth; skip it
            // below so we never fight an in-progress native drag.
            guard let boundary = GridLayout.boundary(edge: edge, slot: slot) else { continue }
            if grid.update(boundary: boundary, toPosition: position, in: bounds) {
                changed = true
                dbg("resize win\(id) edge=\(edge) position=\(position) -> \(boundary) grid=\(grid)")
            }
        }
        if changed {
            scheduleApply(excluding: id)
        }
    }

    private func framesClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.maxX - b.maxX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    /// Sum of per-edge deltas between two frames.
    private func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.maxX - b.maxX)
            + abs(a.minY - b.minY) + abs(a.maxY - b.maxY)
    }

    private func markExpected(_ id: WindowID, _ frame: CGRect) {
        expectedFrames[id] = ExpectedWrite(frame: frame, lastDistance: .infinity, date: Date())
    }

    private func currentID(for element: AXUIElement) -> WindowID? {
        for (id, record) in records where CFEqual(record.element, element) {
            return id
        }
        return nil
    }

    private static let observerCallback: AXObserverCallback = {
        _, element, notification, _ in
        guard let controller = TilingController.active else { return }
        controller.handleAXNotification(
            notification: notification as String, element: element)
    }

    // MARK: Presentation

    struct TiledWindowInfo {
        let slot: Slot
        let appName: String?
    }

    var activeLayout: LayoutKind { state.activeLayout }

    var tiledWindowsInfo: [TiledWindowInfo] {
        state.occupants
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { slot, id in TiledWindowInfo(slot: slot, appName: appName(for: id)) }
    }

    private func appName(for id: WindowID) -> String? {
        records[id].flatMap {
            NSRunningApplication(processIdentifier: $0.pid)?.localizedName
        }
    }

    private static func refusalMessage(count: Int) -> String {
        count == 1
            ? "Couldn't move that window — the app refused to resize it."
            : "Couldn't move \(count) windows — an app refused to resize."
    }

    var isTrusted: Bool { AXKit.isTrusted }
}
