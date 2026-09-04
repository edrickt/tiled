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
struct EvictedWindow {
    let handle: WindowHandle
    let slot: Slot
    let preTileFrame: CGRect
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
    func execute(
        decision: TilePlan, requester id: WindowID, slot: Slot,
        state: TilingState, records: [WindowID: WindowRecord], nextID: WindowID,
        tracker: DragTracker, boundsOf: (CGRect) -> CGRect,
        observe: (WindowID) -> Void
    ) -> (outcome: Outcome, state: TilingState, records: [WindowID: WindowRecord], nextID: WindowID) {
        var state = state
        var records = records
        var nextID = nextID
        switch decision {
        case .noop:
            return (Outcome(), state, records, nextID) // unreachable: callers guard noop first
        case .swap(let placements):
            state.commitSwaps(placements)
            var failed = 0
            for occupant in placements.keys {
                if !applyLayout(
                    for: occupant, state: state, records: records,
                    tracker: tracker, boundsOf: boundsOf)
                { failed += 1 }
            }
            var outcome = Outcome()
            if failed > 0 {
                outcome.error = Self.refusalMessage(count: failed)
                outcome.feedback = .refused(windowName: nil)
            }
            log("swap win\(id) -> \(slot.rawValue) placements=\(placements)")
            return (outcome, state, records, nextID)
        case .switchLayout:
            // The requester moves rather than evicts: restore everyone
            // else first (restoring it would delete its record, so `place`
            // would bail and the window would merely untile). Its old tile
            // is vacated by the commit inside `place`.
            let evicted = decision.windowsToRestore(requester: id)
            let snapshot = evicted.compactMap { evictedID in
                records[evictedID].map {
                    EvictedWindow(
                        handle: $0.handle, slot: state.slot(of: evictedID) ?? slot,
                        preTileFrame: $0.preTileFrame)
                }
            }
            let restoreFailures = restore(
                evicted, state: &state, records: &records, tracker: tracker)
            let placeResult = place(
                window: id, into: slot, state: &state, records: &records,
                tracker: tracker, boundsOf: boundsOf, observe: observe)
            var outcome = Outcome()
            if records[id] == nil {
                // `place` bailed (no record): nothing to snapshot.
                reportRestoreFailures(restoreFailures, error: &outcome.error)
            } else if placeResult.error == nil, restoreFailures.isEmpty, !evicted.isEmpty {
                let noun = evicted.count == 1 ? "1 window" : "\(evicted.count) windows"
                outcome.notice =
                    "Switched to \(slot.layout.title) \u{00B7} \(noun) untiled. " +
                    "Undo: Restore \(noun == "1 window" ? "1 Evicted Window" : "\(evicted.count) Evicted Windows")."
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
            let restoreFailures = restore(
                decision.windowsToRestore(requester: id),
                state: &state, records: &records, tracker: tracker)
            let placeResult = place(
                window: id, into: slot, state: &state, records: &records,
                tracker: tracker, boundsOf: boundsOf, observe: observe)
            var outcome = Outcome()
            outcome.error = placeResult.error
            outcome.feedback = placeResult.feedback
            reportRestoreFailures(restoreFailures, error: &outcome.error)
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
            if applyLayout(
                for: id, state: state, records: records,
                tracker: tracker, boundsOf: boundsOf)
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
            return ("Undid layout switch \u{00B7} \(noun) restored.", nil, state, records, nextID)
        }
        return (nil, "Couldn't restore the evicted windows.", state, records, nextID)
    }

    // MARK: Placement

    /// Places `id` into `slot`. Returns the refusal (error + feedback)
    /// when the gateway write fails; nil error means placed.
    private func place(
        window id: WindowID, into slot: Slot,
        state: inout TilingState, records: inout [WindowID: WindowRecord],
        tracker: DragTracker, boundsOf: (CGRect) -> CGRect,
        observe: (WindowID) -> Void
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
            tracker: tracker, boundsOf: boundsOf)
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

    /// Applies `id`'s slot rect on the screen the window currently lives on.
    /// Returns whether the gateway write succeeded (some windows refuse
    /// resizes). The tracker bookkeeps the write for echo suppression.
    @discardableResult
    private func applyLayout(
        for id: WindowID, state: TilingState,
        records: [WindowID: WindowRecord],
        tracker: DragTracker, boundsOf: (CGRect) -> CGRect
    ) -> Bool {
        guard let record = records[id], let slot = state.slot(of: id) else { return false }
        let current = gateway.frame(of: record.handle) ?? record.preTileFrame
        let bounds = boundsOf(current)
        let target = tracker.grid.rect(for: slot, in: bounds)
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
}
