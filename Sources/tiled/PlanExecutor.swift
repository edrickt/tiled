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
/// `space` tags the tiling canvas the window returns to: undo retiles
/// per display and per Space, so a restored window lands on the canvas
/// it left. Nil = legacy snapshots (pre-per-monitor), restored into the
/// requester's canvas.
struct EvictedWindow {
    let handle: WindowHandle
    let slot: Slot
    let preTileFrame: CGRect
    var space: TilingSpaceKey? = nil
}

/// Executes tiling plans: the branch interaction of tile / switch
/// plus snapshot, restore, rollback, and notice logic.
///
/// Previously interleaved with focus, prune, and dispatch inside
/// `TilingController.handle`; the real bugs hid in how the branches
/// shared snapshot and error state, not in any one branch. Now the whole
/// execution (deciding writes, performing them via the gateway and
/// tracker, and reporting refusals) lives behind `execute`, testable
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
        /// and ordinary evictions share one recovery path: the more
        /// frequent, silent eviction is exactly the case that needs it.
        var snapshot: [EvictedWindow]?
        var requester: WindowID?
        /// Cells the placement freed (eviction remainders, the requester's
        /// vacated tile) for the controller's reflow to hand to the
        /// mergeable survivor. Nil when the placement or a restore failed:
        /// the screen must agree with state before anyone grows into it.
        /// The controller applies reflow, not this module, so there is
        /// exactly one reflow applier; the requester and expanded windows
        /// are excluded there.
        var reflowFreed: Set<TileCell>?
        /// A lone evicted window that was re-housed instead of untiled:
        /// still tiled, in the one slot the request left free. The
        /// controller must not forget it, and its convergence is
        /// verified like any placement.
        var rehoused: WindowID?
    }

    private let gateway: WindowGateway
    /// The shared write policy, injected: plan placements must not grow a
    /// second copy of the no-op / off-Space / echo rules.
    private let frameWriter: FrameWriter
    private let log: (String) -> Void

    init(
        gateway: WindowGateway, frameWriter: FrameWriter,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.gateway = gateway
        self.frameWriter = frameWriter
        self.log = log
    }

    // MARK: Execution

    /// The pair a plan branch commits against: occupancy plus window
    /// records, handed to a branch and returned by it. Value semantics are
    /// what make a half-rolled-back branch safe to hand back at all.
    struct Working {
        var state: TilingState
        var records: [WindowID: WindowRecord]
    }

    /// Everything a plan branch needs that is not the decision itself:
    /// the gateway work it performs and the canvas it belongs to, bundled
    /// so each branch names what it acts on instead of repeating ten
    /// parameters.
    struct Execution {
        let tracker: DragTracker
        let boundsOf: (CGRect) -> CGRect
        let observe: (WindowID) -> Void
        let spaceOf: (WindowID) -> TilingSpaceKey?
        let isExpanded: (WindowID) -> Bool
        let space: TilingSpaceKey?
    }

    /// Commits `decision` for `requester` into `slot`. Takes state,
    /// records, and the next id by value and returns the updated copies
    /// alongside the outcome: holding `inout` across the call would trip
    /// Swift's exclusivity checker, since the `observe`/`resolveID`
    /// closures read the controller's live registry while execution runs.
    /// Copies are trivial (a handful of tiled windows). Record creation
    /// for pruned undo handles happens on the local copy via `nextID`,
    /// so it stays visible to the rest of the call.
    ///
    /// This is only the dispatcher: each plan kind commits in its own
    /// `applySwitchLayout` / `applySwap` / `applyTile`, which take the
    /// same `Working` by value and hand it back, so a branch that rolled
    /// part-way back returns a consistent pair rather than a shared
    /// object it half-mutated.
    ///
    /// `space` names the tiling canvas every placement belongs to (the
    /// plan was decided over one Space's state, so all its windows share
    /// one display and Space): every slot-rect write derives from that
    /// canvas's splitter grid. Nil (headless tests and legacy snapshots)
    /// selects the legacy shared grid.
    func execute(
        decision: TilePlan, requester id: WindowID, slot: Slot,
        state: TilingState, records: [WindowID: WindowRecord], nextID: WindowID,
        tracker: DragTracker, boundsOf: @escaping (CGRect) -> CGRect,
        observe: @escaping (WindowID) -> Void,
        spaceOf: @escaping (WindowID) -> TilingSpaceKey? = { _ in nil },
        isExpanded: @escaping (WindowID) -> Bool = { _ in false },
        space: TilingSpaceKey? = nil
    ) -> (outcome: Outcome, state: TilingState, records: [WindowID: WindowRecord], nextID: WindowID) {
        let working = Working(state: state, records: records)
        let execution = Execution(
            tracker: tracker, boundsOf: boundsOf, observe: observe,
            spaceOf: spaceOf, isExpanded: isExpanded, space: space)
        let committed: (outcome: Outcome, working: Working)
        switch decision {
        case .noop:
            // Unreachable: callers guard noop first.
            return (Outcome(), state, records, nextID)
        case .switchLayout:
            committed = applySwitchLayout(
                decision, requester: id, slot: slot,
                working: working, execution: execution)
        case .swap(let displaced):
            committed = applySwap(
                displaced, decision: decision, requester: id, slot: slot,
                working: working, execution: execution)
        case .tile:
            committed = applyTile(
                decision, requester: id, slot: slot,
                working: working, execution: execution)
        }
        return (committed.outcome, committed.working.state, committed.working.records, nextID)
    }

    /// The layout-switch branch: the requester moves rather than evicting,
    /// so everyone else in the way is restored first (restoring the
    /// requester would delete its record and the placement would bail).
    private func applySwitchLayout(
        _ decision: TilePlan, requester id: WindowID, slot: Slot,
        working: Working, execution: Execution
    ) -> (outcome: Outcome, working: Working) {
        var state = working.state
        var records = working.records
        // The requester moves rather than evicts: restore everyone
        // else first (restoring it would delete its record, so `place`
        // would bail and the window would merely untile). Its old tile
        // is vacated by the commit inside `place`.
        let evicted = decision.windowsToRestore(requester: id)
        let snapshot = evicted.compactMap { evictedID in
            Self.snapshotEntry(
                for: evictedID, state: state, records: records, fallback: slot,
                space: execution.spaceOf(evictedID))
        }
        let restoreFailures = restore(
            evicted, state: &state, records: &records, tracker: execution.tracker)
        let placeResult = place(
            window: id, into: slot, state: &state, records: &records,
            tracker: execution.tracker, boundsOf: execution.boundsOf, observe: execution.observe, space: execution.space)
        var outcome = Outcome()
        if records[id] == nil {
            // `place` bailed (no record): nothing to snapshot.
            reportRestoreFailures(restoreFailures, error: &outcome.error)
        } else if placeResult.error == nil, restoreFailures.isEmpty, !evicted.isEmpty {
            let noun = evicted.count == 1 ? "1 window" : "\(evicted.count) windows"
            // Narrate the event AND the recovery: the notice is the
            // hotkey user's only record of a mass-untile, and the
            // undo row may sit below the fold. One sentence, one
            // cue: no menu-title splicing, just the combo.
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
        return (outcome, Working(state: state, records: records))
    }

    /// The swap branch: both windows stay tiled, the displaced one taking
    /// the tile the requester vacates. The displaced window moves first, so
    /// a refusal anywhere leaves every window where it started.
    private func applySwap(
        _ displaced: WindowID, decision: TilePlan, requester id: WindowID, slot: Slot,
        working: Working, execution: Execution
    ) -> (outcome: Outcome, working: Working) {
        var state = working.state
        let records = working.records
        guard let previous = state.slot(of: id),
            let displacedOriginal = state.slot(of: displaced),
            records[id] != nil, records[displaced] != nil
        else {
            // Degenerate plan (untiled requester or a window that
            // vanished): degrade to the ordinary eviction path, with the
            // real closure set. An `isExpanded` that always answers false
            // would let a re-house pick up an expanded evictee, which the
            // documented rule forbids: an expanded window comes back to
            // earth by untangling, never by moving into the freed slot
            // while it still covers the layout.
            log("swap DEGENERATE win\(id) -> \(slot.rawValue); falling back to tile")
            return applyTile(
                .tile(evicting: [displaced]), requester: id,
                slot: slot, working: Working(state: state, records: records),
                execution: execution)
        }
        // Snapshot before any commit: each entry carries its window's
        // own former tile, so undo replays the swap backwards.
        let snapshot = [(displaced, displacedOriginal), (id, previous)].compactMap {
            (entryID, formerSlot) in
            Self.snapshotEntry(
                for: entryID, state: state, records: records, fallback: formerSlot,
                space: execution.spaceOf(entryID))
        }
        var outcome = Outcome()
        state.commit(window: displaced, into: previous)
        execution.observe(displaced)
        if !applyLayout(
            for: displaced, state: state, records: records,
            tracker: execution.tracker, boundsOf: execution.boundsOf, space: execution.space)
        {
            // The refused write moved nothing on screen: the rollback
            // is state-only, restoring both occupancies.
            state.commit(window: displaced, into: displacedOriginal)
            state.commit(window: id, into: previous)
            log("swap FAILED displaced win\(displaced) -> \(previous.rawValue)")
            let refusal = Self.refusal(for: displaced, records: records, gateway: gateway)
            outcome.error = refusal.error
            outcome.feedback = refusal.feedback
            return (outcome, Working(state: state, records: records))
        }
        state.commit(window: id, into: slot)
        execution.observe(id)
        if !applyLayout(
            for: id, state: state, records: records,
            tracker: execution.tracker, boundsOf: execution.boundsOf, space: execution.space)
        {
            // Roll the whole swap back: the displaced window's frame
            // visibly moved, so it is written home; the requester was
            // never written, so only its occupancy restores.
            state.commit(window: displaced, into: displacedOriginal)
            state.commit(window: id, into: previous)
            applyLayout(
                for: displaced, state: state, records: records,
                tracker: execution.tracker, boundsOf: execution.boundsOf, space: execution.space)
            log("place FAILED win\(id) -> \(slot.rawValue); swap rolled back")
            let refusal = Self.refusal(for: id, records: records, gateway: gateway)
            outcome.error = refusal.error
            outcome.feedback = refusal.feedback
            return (outcome, Working(state: state, records: records))
        }
        // A swap untiles nobody, but it does move a window the user
        // didn't touch: the notice names it and its landing tile.
        let displacedName = appName(for: displaced, records: records) ?? "That window"
        outcome.notice =
            "\(displacedName) moved to \(SlotPresentation.title(of: previous)) "
                + "to make room. Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."
        outcome.snapshot = snapshot
        outcome.requester = id
        log(
            "swap win\(id) -> \(slot.rawValue), win\(displaced) -> \(previous.rawValue)")
        return (outcome, Working(state: state, records: records))
    }

    /// The tile branch: evict whoever overlaps, place the requester, and
    /// re-house a lone evictee into the one whole slot the request left
    /// free. Hands the freed cells to the controller, which owns the one
    /// reflow applier.
    private func applyTile(
        _ decision: TilePlan, requester id: WindowID, slot: Slot,
        working: Working, execution: Execution
    ) -> (outcome: Outcome, working: Working) {
        var state = working.state
        var records = working.records
        let evicted = decision.windowsToRestore(requester: id)
        // The eviction notice names the displaced app when known: the
        // user's first question after a surprise eviction is "where did
        // Safari go?"; a count answers bookkeeping, not memory. One
        // named app reads alone; more read as first-plus-count.
        let evictionNames = { [self] (evicted: [WindowID]) in
            evicted.compactMap { appName(for: $0, records: records) }
        }
        // Names resolve BEFORE the restore deletes the records:
        // `restoreWindow` nils each record as it frees the slot, so
        // naming after would degrade every eviction to a count.
        let evictedNames = evictionNames(evicted)
        // Slots leave the state before reflow sees them: the evicted
        // slots and the requester's vacated tile together form the
        // freed region the survivors may absorb.
        let evictedSlots = evicted.compactMap { state.slot(of: $0) }
        let previous = state.slot(of: id)
        // Re-house: a lone evictee need not lose its tiling. If the
        // cells the request leaves free form exactly one whole slot,
        // the victim re-tiles into it instead of untangling (the
        // middle third evicted by the right two-thirds moves into
        // the free top-left sixth). Expanded windows skip it: they
        // come back to earth by untangling, not by moving.
        var rehouse: (window: WindowID, home: Slot)?
        if evicted.count == 1, !execution.isExpanded(evicted[0]),
            let home = state.rehousingHome(
                evicting: evicted[0], for: slot, vacating: previous)
        {
            rehouse = (evicted[0], home)
        }
        let snapshot = evicted.compactMap { evictedID in
            Self.snapshotEntry(
                for: evictedID, state: state, records: records, fallback: slot,
                space: execution.spaceOf(evictedID))
        }
        let restoreFailures = restore(
            evicted.filter { $0 != rehouse?.window },
            state: &state, records: &records, tracker: execution.tracker)
        let placeResult = place(
            window: id, into: slot, state: &state, records: &records,
            tracker: execution.tracker, boundsOf: execution.boundsOf, observe: execution.observe, space: execution.space)
        var outcome = Outcome()
        outcome.error = placeResult.error
        outcome.feedback = placeResult.feedback
        reportRestoreFailures(restoreFailures, error: &outcome.error)
        let clean = placeResult.error == nil && restoreFailures.isEmpty
        // Re-house commit: once the requester sits, the victim moves
        // into the one free slot and stays tiled. The move only happens
        // when the requester's own placement landed: making room for a
        // request that failed would move the victim for nothing, report
        // no destruction to undo, and promise an undo that cannot exist.
        // A refused re-house write falls back to the plain eviction.
        if let (wid, home) = rehouse, clean {
            state.commit(window: wid, into: home)
            if applyLayout(
                for: wid, state: state, records: records,
                tracker: execution.tracker, boundsOf: execution.boundsOf, space: execution.space)
            {
                outcome.rehoused = wid
                let name = appName(for: wid, records: records) ?? "That window"
                outcome.notice =
                    "\(name) moved to \(SlotPresentation.title(of: home)) to make room. "
                        + "Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."
            } else {
                _ = restoreWindow(
                    id: wid, state: &state, records: &records, tracker: execution.tracker)
                log("rehouse FAILED win\(wid) -> \(home.rawValue); falling back to eviction")
            }
        } else if let (wid, _) = rehouse {
            _ = restoreWindow(
                id: wid, state: &state, records: &records, tracker: execution.tracker)
            log("rehouse SKIPPED win\(wid): requester placement failed")
        }
        if clean {
            // Hand the freed region to the controller: it owns the one
            // reflow applier, which drops the cells the requester
            // covers again (they are occupied, so only true remainders
            // reach the survivors) and grows the one mergeable
            // survivor, folding its undo entries into this chapter.
            var freed = Set(evictedSlots.flatMap { $0.cells })
            if let previous {
                freed.formUnion(previous.cells)
            }
            outcome.reflowFreed = freed
        }
        if restoreFailures.isEmpty, !evicted.isEmpty {
            // Ordinary eviction gets the same narrative as a layout
            // switch: a notice naming the displaced app plus the shared
            // one-step undo. The switch was never special; it was
            // just the first destruction anyone bothered to narrate.
            // A re-house already narrated itself (the victim moved,
            // nobody went back). The chapter is pushed even when the
            // requester's own write was refused: the evictees really did
            // go home, and without it that destruction would be silent
            // and unrecoverable. The requester joins the chapter only
            // when it actually landed.
            outcome.snapshot = snapshot
            outcome.requester = clean ? id : nil
            if outcome.notice == nil {
                outcome.notice = Self.evictionNotice(names: evictedNames, count: evicted.count)
            }
        }
        return (outcome, Working(state: state, records: records))
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
            // Skip confirmed deaths only: an unknown liveness (busy app)
            // still attempts the restore: the write re-probes, and a
            // failed attempt is reported, not silently skipped.
            guard gateway.liveness(of: entry.handle) != .dead else { continue }
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
            // wasteful: on a settling window it re-arms echo tracking
            // and risks a phantom drag-out. The grid is the destination
            // canvas's, not the legacy shared one.
            if let record = records[id],
               let slot = state.slot(of: id),
               let current = gateway.frame(of: record.handle),
               current == tracker.grid(for: entry.space).rect(for: slot, in: boundsOf(current))
            {
                log("undo SKIP-WRITE win\(id) already placed")
                restored += 1
            } else if applyLayout(
                for: id, state: state, records: records,
                tracker: tracker, boundsOf: boundsOf, space: entry.space)
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
            // could happen here is a nested execute, which never does.)
            return ("Undid displacement \u{00B7} \(noun) restored.", nil, state, records, nextID)
        }
        return (nil, MenuText.restoreEvictedWindowsFailure, state, records, nextID)
    }

    // MARK: Eviction narrative

    /// One snapshot entry per displaced window, captured before the
    /// restore deletes its record: the handle to find it again, the slot
    /// to return it to, the frame it held before tiling. `fallback` is
    /// the slot to use when occupancy is already gone by capture time;
    /// only the switch branch knows the requested slot.
    private static func snapshotEntry(
        for evictedID: WindowID, state: TilingState, records: [WindowID: WindowRecord],
        fallback: Slot, space: TilingSpaceKey? = nil
    ) -> EvictedWindow? {
        records[evictedID].map {
            EvictedWindow(
                handle: $0.handle, slot: state.slot(of: evictedID) ?? fallback,
                preTileFrame: $0.preTileFrame, space: space)
        }
    }

    /// The eviction notice: names the displaced app when known ("where
    /// did Safari go?" beats "1 window moved"), plus the shared
    /// one-step undo with its global reach. Falls back to the real
    /// evicted count when the gateway names nothing: never a hardcoded
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
        return head + " Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."
    }

    /// The refusal pair for a failed swap write: names the window whose
    /// resize was refused (the displaced window on its move, the requester
    /// on its own), matching the `place` refusal wording.
    private static func refusal(
        for id: WindowID, records: [WindowID: WindowRecord], gateway: WindowGateway
    ) -> (error: String, feedback: TilingController.Feedback) {
        let name = records[id].flatMap { gateway.appName(of: $0.handle) } ?? "That window"
        return (
            "\(name) couldn't be tiled: the app refused to resize it.",
            .refused(windowName: name))
    }

    /// Places `id` into `slot`. Returns the refusal (error + feedback)
    /// when the gateway write fails; nil error means placed.
    private func place(
        window id: WindowID, into slot: Slot,
        state: inout TilingState, records: inout [WindowID: WindowRecord],
        tracker: DragTracker, boundsOf: (CGRect) -> CGRect,
        observe: (WindowID) -> Void, space: TilingSpaceKey?
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
            tracker: tracker, boundsOf: boundsOf, space: space)
        {
            // The window refused the frame (some apps ignore AX resizes):
            // roll back occupancy so state and screen agree, and say so.
            state.remove(window: id)
            tracker.forget(id)
            let name = appName(for: id, records: records) ?? "That window"
            log("place FAILED win\(id) -> \(slot.rawValue)")
            return (
                "\(name) couldn't be tiled: the app refused to resize it.",
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
        error = MenuText.restoreFailureMessage(failures)
    }

    /// Applies `id`'s slot rect on `space` (the tiling canvas the plan
    /// belongs to; nil selects the legacy shared grid). Returns whether
    /// the gateway write succeeded (some windows refuse
    /// resizes). The tracker bookkeeps the write for echo suppression.
    @discardableResult
    private func applyLayout(
        for id: WindowID, state: TilingState,
        records: [WindowID: WindowRecord],
        tracker: DragTracker, boundsOf: (CGRect) -> CGRect, space: TilingSpaceKey?
    ) -> Bool {
        guard let record = records[id], let slot = state.slot(of: id) else { return false }
        let current = gateway.frame(of: record.handle) ?? record.preTileFrame
        let bounds = boundsOf(current)
        let target = tracker.grid(for: space).rect(for: slot, in: bounds)
        // The shared write policy: a no-op target counts as success
        // without a write, and a hidden canvas defers (false: the branch
        // rolls back). The check is `.none`: settle schedules the plan's
        // convergence check, so a per-write check would double-schedule.
        // No canvas (legacy/headless snapshots) resolves to the
        // display-less fallback, which the visibility policy treats as
        // visible.
        let canvas = space ?? .displayless
        let result = frameWriter.write(
            id, handle: record.handle, to: target, on: canvas, check: .none)
        log(
            "applyLayout win\(id) slot=\(slot.rawValue) bounds=\(bounds) "
                + "target=\(target) result=\(result)")
        // A transiently unresolvable Space (the window-server table can
        // answer nil while the canvas key still carries an id) defers the
        // write: writing blind could pull the window onto the visible
        // Space. The branch rolls the placement back with its standard
        // refusal, the only user-facing failure vocabulary this path has.
        return result.isAccepted
    }

    private func appName(for id: WindowID, records: [WindowID: WindowRecord]) -> String? {
        records[id].flatMap { gateway.appName(of: $0.handle) }
    }
}
