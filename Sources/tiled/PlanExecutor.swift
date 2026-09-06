import AppKit
import CoreGraphics
import Foundation

/// A managed window's restore record: its gateway handle plus the frame
/// to restore when untiled. Owned by the controller's registry; read and
/// mutated by plan execution.
struct WindowRecord {
    let handle: WindowHandle
    var preTileFrame: CGRect
}

/// A window evicted by a layout switch, enabling one-step undo.
/// Records are rebuilt from live handles on undo; dead windows are skipped.
/// `screen` tags the tiling space the window returns to: undo retiles
/// per-monitor, so a restored window lands on the display it left.
struct EvictedWindow {
    let handle: WindowHandle
    let slot: Slot
    let preTileFrame: CGRect
    /// Nil = legacy single-space snapshots (pre-per-monitor), restored
    /// into the requester's space.
    var screen: ScreenID? = nil
}

/// Executes tiling plans: the branch interaction of tile / swap / switch
/// plus snapshot, restore, rollback, and notice logic.
///
/// Previously interleaved with focus, prune, and dispatch inside
/// `TilingController.handle`; the real bugs hid in how the branches
/// shared snapshot and error state, not in any one branch. Now the whole
/// execution — deciding writes, performing them via the gateway and
/// tracker, and reporting refusals — lives behind `execute`, testable
/// through it with a fake gateway.
///
/// The controller keeps focus resolution, ghost pruning, and change
/// dispatch; this module owns everything from a decided plan onward.
final class PlanExecutor {
    /// What execution decided: user-facing state the controller applies.
    struct Outcome {
        var feedback: TilingController.Feedback?
        var notice: String?
        var error: String?
        /// One-step undo for any destructive plan: the windows displaced to
        /// make room, rebuilt from live handles on undo. Layout switches
        /// and ordinary evictions share one recovery path — the more
        /// frequent, silent eviction is exactly the case that needs it.
        var snapshot: [EvictedWindow]?
        var requester: WindowID?
    }

    private let gateway: WindowGateway
    private let log: (String) -> Void

    init(gateway: WindowGateway, log: @escaping (String) -> Void = { _ in }) {
        self.gateway = gateway
        self.log = log
    }

    // MARK: Execution

    /// Commits `decision` for `requester` into `slot`. Takes state,
    /// records, and the next id by value and returns the updated copies
    /// alongside the outcome: holding `inout` across the call would trip
    /// Swift's exclusivity checker, since the `observe`/`resolveID`
    /// closures read the controller's live registry while execution runs.
    /// Copies are trivial (a handful of tiled windows). Record creation
    /// for pruned undo handles happens on the local copy via `nextID`,
    /// so it stays visible to the rest of the call.
    ///
    /// `screen` names the tiling space every placement belongs to (the
    /// plan was decided over one space's state, so all its windows share
    /// one display): every slot-rect write derives from that screen's
    /// splitter grid. Nil — headless tests and legacy snapshots — selects
    /// the legacy shared grid.
    func execute(
        decision: TilePlan, requester id: WindowID, slot: Slot,
        state: TilingState, records: [WindowID: WindowRecord], nextID: WindowID,
        tracker: DragTracker, boundsOf: (CGRect) -> CGRect,
        observe: (WindowID) -> Void,
        screenOf: (WindowID) -> ScreenID? = { _ in nil },
        screen: ScreenID? = nil
    ) -> (outcome: Outcome, state: TilingState, records: [WindowID: WindowRecord], nextID: WindowID) {
        var state = state
        var records = records
        var nextID = nextID
        // The eviction notice names the displaced app when known: the
        // user's first question after a surprise eviction is "where did
        // Safari go?" — a count answers bookkeeping, not memory. One
        // named app reads alone; more read as first-plus-count.
        let evictionNames = { [self] (evicted: [WindowID]) in
            evicted.compactMap { appName(for: $0, records: records) }
        }
        switch decision {
        case .noop:
            return (Outcome(), state, records, nextID) // unreachable: callers guard noop first
        case .swap(let placements):
            // A swap is atomic: either every window lands in its new slot
            // or the whole exchange is called off. Writes go in slot
            // reading order (top-to-bottom, left-to-right) so the write
            // sequence is deterministic, and on any refusal every window
            // is written back to its pre-swap frame — a refused exchange
            // must never leave two windows stacked in one tile (the
            // refused window's frame never vacated it) or a half-moved
            // shuffle behind. State stays untouched on refusal: the
            // windows keep their old slots, matching their old frames.
            let order = Slot.readingOrderedCases
            let ordered = placements.sorted { a, b in
                let ia = order.firstIndex(of: a.value)!
                let ib = order.firstIndex(of: b.value)!
                return ia != ib ? ia < ib : a.key < b.key
            }
            var preSwapFrames: [WindowID: CGRect] = [:]
            for (window, _) in ordered {
                if let record = records[window], let frame = gateway.frame(of: record.handle) {
                    preSwapFrames[window] = frame
                }
            }
            var planned = state
            planned.commitSwaps(placements)
            var failed: [WindowID] = []
            for (occupant, _) in ordered {
                if !applyLayout(
                    for: occupant, state: planned, records: records,
                    tracker: tracker, boundsOf: boundsOf, screen: screen)
                { failed.append(occupant) }
            }
            var outcome = Outcome()
            if !failed.isEmpty {
                // Call the whole exchange off: restore every pre-swap
                // frame (the refused window's is a no-op write; partners
                // that already moved return to where they were). Echo
                // bookkeeping follows the restored frames — nobody is
                // forgotten, everyone is still tiled at their old slot.
                for (window, frame) in preSwapFrames {
                    tracker.markExpected(window, frame)
                    if let record = records[window] {
                        _ = gateway.setFrame(record.handle, to: frame)
                    }
                }
                let names = failed.compactMap { appName(for: $0, records: records) }
                outcome.error = Self.swapRefusalMessage(names: names)
                outcome.feedback = .refused(windowName: Self.swapRefusalName(names: names))
            } else {
                state = planned
            }
            log("swap win\(id) -> \(slot.rawValue) placements=\(placements) failed=\(failed)")
            return (outcome, state, records, nextID)
        case .switchLayout:
            // The requester moves rather than evicts: restore everyone
            // else first (restoring it would delete its record, so `place`
            // would bail and the window would merely untile). Its old tile
            // is vacated by the commit inside `place`.
            let evicted = decision.windowsToRestore(requester: id)
            let snapshot = evicted.compactMap { evictedID in
                Self.snapshotEntry(
                    for: evictedID, state: state, records: records, fallback: slot,
                    screen: screenOf(evictedID))
            }
            let restoreFailures = restore(
                evicted, state: &state, records: &records, tracker: tracker)
            let placeResult = place(
                window: id, into: slot, state: &state, records: &records,
                tracker: tracker, boundsOf: boundsOf, observe: observe, screen: screen)
            var outcome = Outcome()
            if records[id] == nil {
                // `place` bailed (no record): nothing to snapshot.
                reportRestoreFailures(restoreFailures, error: &outcome.error)
            } else if placeResult.error == nil, restoreFailures.isEmpty, !evicted.isEmpty {
                let noun = evicted.count == 1 ? "1 window" : "\(evicted.count) windows"
                // Narrate the event AND the recovery: the notice is the
                // hotkey user's only record of a mass-untile, and the
                // undo row may sit below the fold. One sentence, one
                // cue — no menu-title splicing, just the combo.
                outcome.notice =
                    "Switched to \(slot.layout.title) \u{00B7} \(noun) untiled. " +
                    "Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."
                outcome.snapshot = snapshot
                outcome.requester = id
            } else {
                outcome.error = placeResult.error
                outcome.feedback = placeResult.feedback
                reportRestoreFailures(restoreFailures, error: &outcome.error)
            }
            log("switchLayout win\(id) -> \(slot.rawValue) decision=\(decision)")
            return (outcome, state, records, nextID)
        case .tile:
            let evicted = decision.windowsToRestore(requester: id)
            // Names resolve BEFORE the restore deletes the records:
            // `restoreWindow` nils each record as it frees the slot, so
            // naming after would degrade every eviction to a count.
            let evictedNames = evictionNames(evicted)
            let snapshot = evicted.compactMap { evictedID in
                Self.snapshotEntry(
                    for: evictedID, state: state, records: records, fallback: slot,
                    screen: screenOf(evictedID))
            }
            let restoreFailures = restore(
                decision.windowsToRestore(requester: id),
                state: &state, records: &records, tracker: tracker)
            let placeResult = place(
                window: id, into: slot, state: &state, records: &records,
                tracker: tracker, boundsOf: boundsOf, observe: observe, screen: screen)
            var outcome = Outcome()
            outcome.error = placeResult.error
            outcome.feedback = placeResult.feedback
            reportRestoreFailures(restoreFailures, error: &outcome.error)
            if placeResult.error == nil, restoreFailures.isEmpty, !evicted.isEmpty {
                // Ordinary eviction gets the same narrative as a layout
                // switch: a notice naming the displaced app plus the shared
                // one-step undo. The switch was never special — it was
                // just the first destruction anyone bothered to narrate.
                outcome.snapshot = snapshot
                outcome.requester = id
                outcome.notice = Self.evictionNotice(names: evictedNames, count: evicted.count)
            }
            return (outcome, state, records, nextID)
        }
    }

    /// Undoes a layout switch: restores the requester to its pre-tile
    /// frame and returns every surviving evicted window to its slot.
    /// Returns the notice or error for the controller to apply.
    func undo(
        snapshot: [EvictedWindow], requester: WindowID?,
        state: TilingState, records: [WindowID: WindowRecord], nextID: WindowID,
        tracker: DragTracker, boundsOf: (CGRect) -> CGRect,
        observe: (WindowID) -> Void
    ) -> (notice: String?, error: String?, state: TilingState, records: [WindowID: WindowRecord], nextID: WindowID) {
        var state = state
        var records = records
        var nextID = nextID
        if let requester {
            _ = restoreWindow(
                id: requester, state: &state, records: &records, tracker: tracker)
        }
        var restored = 0
        for entry in snapshot {
            guard gateway.isAlive(entry.handle) else { continue }
            // Handles whose records were pruned need fresh ids, issued
            // here on the local copy so the creation stays visible to
            // the commit and write below (a controller-side creation
            // would land in a different dictionary).
            let id: WindowID
            if let existing = records.first(where: { $0.value.handle == entry.handle })?.key {
                id = existing
            } else {
                id = nextID
                nextID += 1
                records[id] = WindowRecord(handle: entry.handle, preTileFrame: .zero)
            }
            guard var record = records[id] else { continue }
            record.preTileFrame = entry.preTileFrame
            records[id] = record
            state.commit(window: id, into: entry.slot)
            observe(id)
            // The frame may already be correct (e.g. an untile-all chapter
            // whose windows still sit at their pre-tile frames, or a
            // settle frame the gateway applied late): skip the write and
            // count it restored. Rewriting an identical frame is not just
            // wasteful — on a settling window it re-arms echo tracking
            // and risks a phantom drag-out. The grid is the destination
            // screen's, not the legacy shared one.
            if let record = records[id],
               let slot = state.slot(of: id),
               let current = gateway.frame(of: record.handle),
               current == tracker.grid(for: entry.screen).rect(for: slot, in: boundsOf(current))
            {
                log("undo SKIP-WRITE win\(id) already placed")
                restored += 1
            } else if applyLayout(
                for: id, state: state, records: records,
                tracker: tracker, boundsOf: boundsOf, screen: entry.screen)
            {
                restored += 1
            } else {
                state.remove(window: id)
                records[id] = nil
                tracker.forget(id)
            }
        }
        if restored > 0 {
            let noun = restored == 1 ? "1 window" : "\(restored) windows"
            // The undo itself must not push a new chapter: restoration is
            // the consumption of history, not a new destruction. (The
            // controller pops before calling, so the only way a push
            // could happen here is a nested execute — which never does.)
            return ("Undid displacement \u{00B7} \(noun) restored.", nil, state, records, nextID)
        }
        return (nil, "Couldn't restore the evicted windows.", state, records, nextID)
    }

    // MARK: Eviction narrative

    /// One snapshot entry per displaced window, captured before the
    /// restore deletes its record: the handle to find it again, the slot
    /// to return it to, the frame it held before tiling. `fallback` is
    /// the slot to use when occupancy is already gone by capture time —
    /// only the switch branch knows the requested slot.
    private static func snapshotEntry(
        for evictedID: WindowID, state: TilingState, records: [WindowID: WindowRecord],
        fallback: Slot, screen: ScreenID? = nil
    ) -> EvictedWindow? {
        records[evictedID].map {
            EvictedWindow(
                handle: $0.handle, slot: state.slot(of: evictedID) ?? fallback,
                preTileFrame: $0.preTileFrame, screen: screen)
        }
    }

    /// The eviction notice: names the displaced app when known ("where
    /// did Safari go?" beats "1 window moved"), plus the shared
    /// one-step undo with its global reach. Falls back to the real
    /// evicted count when the gateway names nothing — never a hardcoded
    /// "1 window" for N unnamed windows.
    private static func evictionNotice(names: [String], count: Int) -> String {
        let head: String
        switch names.count {
        case 0:
            head = count == 1
                ? "1 window went back to where it was."
                : "\(count) windows went back to where they were."
        case 1:
            head = "\(names[0]) went back to where it was."
        case 2:
            head = "\(names[0]) and \(names[1]) went back to where they were."
        default:
            head = "\(names[0]) and \(names.count - 1) more went back to where they were."
        }
        let pronoun = names.count <= 1 && count <= 1 ? "it" : "them"
        return head + " Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."
    }

    /// Places `id` into `slot`. Returns the refusal (error + feedback)
    /// when the gateway write fails; nil error means placed.
    private func place(
        window id: WindowID, into slot: Slot,
        state: inout TilingState, records: inout [WindowID: WindowRecord],
        tracker: DragTracker, boundsOf: (CGRect) -> CGRect,
        observe: (WindowID) -> Void, screen: ScreenID?
    ) -> (error: String?, feedback: TilingController.Feedback?) {
        guard var record = records[id] else { return (nil, nil) }
        if state.slot(of: id) == nil {
            // First tiling: remember where to restore when untiled.
            // A window moving between overlapping slots (e.g. Left -> BottomLeft)
            // keeps its original pre-tile frame.
            record.preTileFrame = gateway.frame(of: record.handle) ?? record.preTileFrame
            records[id] = record
        }
        state.commit(window: id, into: slot)
        observe(id)
        if !applyLayout(
            for: id, state: state, records: records,
            tracker: tracker, boundsOf: boundsOf, screen: screen)
        {
            // The window refused the frame (some apps ignore AX resizes):
            // roll back occupancy so state and screen agree, and say so.
            state.remove(window: id)
            tracker.forget(id)
            let name = appName(for: id, records: records) ?? "That window"
            log("place FAILED win\(id) -> \(slot.rawValue)")
            return (
                "\(name) couldn't be tiled — the app refused to resize it.",
                .refused(windowName: name))
        }
        log("place win\(id) -> \(slot.rawValue)")
        return (nil, nil)
    }

    /// Restores the window's pre-tile frame and releases its slot.
    /// Returns false when the restore was attempted and refused, so the
    /// caller can say so instead of silently leaving a stray window behind.
    @discardableResult
    private func restoreWindow(
        id: WindowID, state: inout TilingState,
        records: inout [WindowID: WindowRecord], tracker: DragTracker
    ) -> Bool {
        var restored = true
        if let record = records[id], record.preTileFrame != .zero {
            restored = gateway.setFrame(record.handle, to: record.preTileFrame)
        }
        records[id] = nil
        tracker.forget(id)
        state.remove(window: id)
        return restored
    }

    /// Untiles every window in `ids`, returning the display names of those
    /// whose pre-tile frame refused to restore.
    private func restore(
        _ ids: [WindowID], state: inout TilingState,
        records: inout [WindowID: WindowRecord], tracker: DragTracker
    ) -> [String] {
        var failures: [String] = []
        for evicted in ids {
            let name = appName(for: evicted, records: records) ?? "A window"
            if !restoreWindow(id: evicted, state: &state, records: &records, tracker: tracker) {
                failures.append(name)
            }
        }
        return failures
    }

    /// Reports restore failures unless a more relevant error (e.g. the
    /// requested tiling itself failing) already took the slot.
    private func reportRestoreFailures(_ failures: [String], error: inout String?) {
        guard !failures.isEmpty, error == nil else { return }
        if failures.count == 1 {
            error =
                "Couldn't restore “\(failures[0])” — it may still be sitting in its old tile."
        } else {
            error =
                "Couldn't restore \(failures.count) windows — they may still be sitting in their old tiles."
        }
    }

    /// Applies `id`'s slot rect on `screen` (the tiling space the plan
    /// belongs to; nil selects the legacy shared grid). Returns whether
    /// the gateway write succeeded (some windows refuse
    /// resizes). The tracker bookkeeps the write for echo suppression.
    @discardableResult
    private func applyLayout(
        for id: WindowID, state: TilingState,
        records: [WindowID: WindowRecord],
        tracker: DragTracker, boundsOf: (CGRect) -> CGRect, screen: ScreenID?
    ) -> Bool {
        guard let record = records[id], let slot = state.slot(of: id) else { return false }
        let current = gateway.frame(of: record.handle) ?? record.preTileFrame
        let bounds = boundsOf(current)
        let target = tracker.grid(for: screen).rect(for: slot, in: bounds)
        tracker.markExpected(id, target)
        let ok = gateway.setFrame(record.handle, to: target)
        log("applyLayout win\(id) slot=\(slot.rawValue) bounds=\(bounds) target=\(target) ok=\(ok)")
        return ok
    }

    private func appName(for id: WindowID, records: [WindowID: WindowRecord]) -> String? {
        records[id].flatMap { gateway.appName(of: $0.handle) }
    }

    private static func refusalMessage(count: Int) -> String {
        count == 1
            ? "Couldn't move that window — the app refused to resize it."
            : "Couldn't move \(count) windows — an app refused to resize."
    }

    /// Swap refusals name the app like the tile path does: same failure
    /// class, same attribution. One named window reads alone; more read
    /// as the first name plus a count.
    private static func swapRefusalMessage(names: [String]) -> String {
        switch names.count {
        case 0:
            return "Couldn't move that window — the app refused to resize it."
        case 1:
            return "\(names[0]) couldn't be swapped — the app refused to resize it."
        default:
            return "\(names[0]) and \(names.count - 1) more couldn't be swapped — "
                + "an app refused to resize."
        }
    }

    /// The announcement name for a swap refusal: the app when known,
    /// never the tile path's "That window" fallback for a move that
    /// wasn't a tiling.
    private static func swapRefusalName(names: [String]) -> String? {
        names.first
    }
}
