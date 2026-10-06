import CoreGraphics
import Foundation

/// A managed window's restore record: its gateway handle plus the frame
/// to restore when untiled. Owned by the coordinator's registry during
/// stage 2; read and mutated by the canvas's placement pipeline.
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

/// One tiling canvas's module: its occupancy, undo chapters, splitter
/// backup, notices, and the placement pipeline (plan, commit, settle,
/// reflow) for that canvas.
///
/// Previously the pipeline was split across `TilingState.plan`,
/// `PlanExecutor`, `TilingController.settle`, and `TilingController.reflow`;
/// every caller had to re-derive the restore set, the reflow exclusions,
/// and the undo chapter. Now one request runs its whole path here and
/// returns one `Outcome` naming the effects the coordinator applies
/// (observation, forgotten records, focus, verification). The occupancy
/// is the canvas's; the records, tracker, and expansion still belong to
/// the coordinator for this stage and travel through `Context`.
///
/// `notice`/`error` stay readable on the canvas: the placement writes
/// them as it settles, so the menu surface reads the canvas that acted.
struct TilingSpace {
    var state = TilingState()
    var undoStack: [(snapshot: [EvictedWindow], requester: WindowID?)] = []
    var splitterBackup: GridLayout?
    var notice: String?
    var error: String?

    /// Depth cap for the per-canvas displacement undo: enough history to
    /// survive a tile-tile-realize rhythm without growing unbounded in a
    /// hotkey-heavy session. The chapters themselves live here, beside
    /// the occupancy they describe.
    static let undoDepth = 5

    /// Everything a placement needs from the coordinator: the
    /// coordinator-owned values threaded by value and the collaborators
    /// that reach back into live state.
    ///
    /// `records`/`nextID` are threaded in and read back out after the
    /// call: holding the coordinator's registry `inout` across the call
    /// would trip Swift's exclusivity checker, since collaborator
    /// closures (`observe`, `spaceOf`) read the live registry while the
    /// phase runs. Copies are trivial (a handful of tiled windows), and
    /// record creation for pruned undo handles happens on this copy via
    /// `nextID`, so it stays visible to the rest of the call.
    struct Context {
        var records: [WindowID: WindowRecord] = [:]
        var nextID: WindowID = 1
        let gateway: WindowGateway
        let frameWriter: FrameWriter
        let tracker: DragTracker
        let boundsOf: (CGRect) -> CGRect
        /// The canvas every write without a better owner belongs to: the
        /// canvas this placement is running on.
        let space: TilingSpaceKey
        /// The canvas a window's frame writes and verification belong to
        /// (nil when untiled/unknown).
        var spaceOf: (WindowID) -> TilingSpaceKey? = { _ in nil }
        /// Whether `id` is currently expanded over the layout.
        var isExpanded: (WindowID) -> Bool = { _ in false }
        /// Collapses `id` (a swap's displaced window) and returns the
        /// refusal message when its frame write was refused: the caller
        /// owns the canvas's error for the duration of `apply` and folds
        /// the message in at the right precedence.
        var collapseExpanded: (WindowID) -> String? = { _ in nil }
        var log: (String) -> Void = { _ in }
    }

    /// What one placement returns: the typed result the coordinator maps
    /// to feedback, plus the coordinator effects it applies. `notice` and
    /// `error` are not here: they stay readable on the canvas.
    struct Outcome {
        enum Result: Equatable {
            /// The request committed: the requester's own write landed.
            case placed
            /// The requester's write was refused. The name is for the
            /// announcement (nil when the app named nothing).
            case refused(windowName: String?)
            /// The window already occupies the requested slot: strict no-op.
            case alreadyTiled
        }
        var result: Result = .placed
        /// The window to focus once everything settled: a swap's displaced
        /// window. Focus effects stay coordinator-side.
        var focusAfter: WindowID?
        /// Windows the coordinator must now observe (their commit landed).
        var observe: [WindowID] = []
        /// Windows whose records the placement destroyed (evicted, not
        /// re-housed): the coordinator forgets them.
        var forget: [WindowID] = []
        /// Restored windows sit below the arrangement they left.
        var raise: Bool = false
        /// Windows whose convergence must be verified one delay later.
        var verify: [WindowID] = []
        /// The requester, when its placement landed cleanly: the
        /// coordinator sets canvas ownership from this commit.
        var requester: WindowID?
    }

    /// What one undo returns: narration plus observation requests. Kept
    /// out of `Outcome` because one undo chapter can span several
    /// canvases and the notice lands on the canvas the chapter belonged
    /// to, not on every destination it restores windows to.
    struct UndoOutcome {
        var notice: String?
        var error: String?
        var observe: [WindowID] = []
    }

    // MARK: Placement

    /// One placement request: `slot` for `requester`. Plans, commits,
    /// settles, and reflows; the canvas's own notice/error record what
    /// happened, and the returned `Outcome` carries the coordinator
    /// effects. The coordinator collapses an expanded requester before
    /// calling; a swap's expanded displaced window is collapsed here,
    /// between planning and committing, exactly where it always was.
    mutating func apply(
        slot: Slot, requester id: WindowID, context: inout Context
    ) -> Outcome {
        let decision = state.plan(window: id, into: slot)
        guard decision != .noop else {
            return Outcome(result: .alreadyTiled)
        }
        // Clear this canvas's slate (not the focused one: the requester
        // may tile onto a background display or Space while focus sits
        // elsewhere).
        error = nil
        notice = nil
        if case .swap(let displaced) = decision {
            error = context.collapseExpanded(displaced)
        }
        return execute(decision: decision, requester: id, slot: slot, context: &context)
    }

    /// Commits a decided plan for `requester` into `slot`: dispatches to
    /// the per-kind branch, then settles (forget, reflow, narration,
    /// verification, undo chapter). Internal so branch behaviour stays
    /// testable with a directly chosen plan.
    mutating func execute(
        decision: TilePlan, requester id: WindowID, slot: Slot, context: inout Context
    ) -> Outcome {
        let commit: Commit
        switch decision {
        case .noop:
            // Unreachable: callers guard noop first.
            return Outcome(result: .alreadyTiled)
        case .switchLayout:
            commit = applySwitchLayout(
                decision, requester: id, slot: slot, context: &context)
        case .swap(let displaced):
            commit = applySwap(
                displaced, decision: decision, requester: id, slot: slot,
                context: &context)
        case .tile:
            commit = applyTile(
                decision, requester: id, slot: slot, context: &context)
        }
        return settle(decision, commit: commit, requester: id, context: &context)
    }

    /// The placement half of settle: untiled windows give up their
    /// records (the coordinator forgets them), the cells the event freed
    /// reflow into one survivor, restored windows sit below the
    /// arrangement, a swap's displaced window takes focus, and the event
    /// is narrated, verified, and made undoable. One chapter per event,
    /// so a single ⌃⌥⇧⌘Z puts back everything this settled.
    private mutating func settle(
        _ decision: TilePlan, commit: Commit, requester id: WindowID,
        context: inout Context
    ) -> Outcome {
        var outcome = Outcome()
        outcome.result = commit.refusal?.windowName.map { .refused(windowName: $0) } ?? .placed
        // Restored-not-re-housed windows: untiled for good. A re-housed
        // window is the exception: it stayed tiled in the slot the
        // request left free, so its record and observation survive.
        outcome.forget = decision.windowsToRestore(requester: id)
            .filter { $0 != commit.rehoused }
        // Reflow: the cells the event freed (eviction remainders, the
        // requester's vacated tile) flow into the one survivor that
        // merges with them into a whole slot. Skipped when the placement
        // or a restore failed: the screen must agree with state before
        // anyone grows into it. The requester, the evicted, and expanded
        // windows never grow.
        var reflowSnapshot: [EvictedWindow] = []
        if commit.clean, let freed = commit.reflowFreed, !freed.isEmpty {
            let skip = Set([id] + decision.windowsToRestore(requester: id))
            reflowSnapshot = reflow(freed, excluding: skip, context: &context)
        }
        // Restored windows sit BELOW the arrangement they left: an
        // evictee returns to its pre-tile frame and must never cover the
        // occupants that stayed (or the requester). No focus change.
        outcome.raise = !outcome.forget.isEmpty
        // A swap leaves the user's attention on the window that took the
        // requester's old tile: focus follows the displaced window. The
        // degenerate fallback (a plain eviction) deletes its record, so
        // the guard keeps focus untouched there and after refusals.
        if case .swap(let displaced) = decision, commit.clean,
            context.records[displaced] != nil
        {
            outcome.focusAfter = displaced
        }
        self.notice = commit.notice
        if let refusal = commit.refusal { self.error = refusal.message }
        if commit.clean {
            // Late convergence check: a silent ignore (gateway success,
            // app never moved) is invisible at write time, so verify one
            // verify-delay later via the echo trail; no extra AX traffic
            // on the hot path. Windows that converged, produced any frames,
            // or were re-written since are skipped; only total silence
            // rolls back. Cancelled by the next placement's scheduling
            // (a newer write supersedes) and by forget paths.
            outcome.verify = verificationWindows(for: decision, requester: id)
            if let rehoused = commit.rehoused {
                outcome.verify.append(rehoused)
            }
        }
        outcome.observe = commit.observed
        // Successful placements own the requester's canvas: the window
        // tiles where it sits, and never migrates mid-session. Refused
        // writes roll back occupancy, so ownership follows the commit.
        outcome.requester = commit.clean ? id : nil
        // The reflow's survivors share the event's undo chapter: undo
        // restores the pre-event world in one ⌃⇧⌘Z (a move with no
        // eviction has no chapter of its own, so the reflow starts one).
        let chapter = (commit.snapshot ?? []) + reflowSnapshot
        pushUndo(snapshot: chapter, requester: commit.requester)
        return outcome
    }

    /// Records a destructive outcome on the undo stack: keeps the
    /// freshest `undoDepth` recoveries, dropping the oldest. A new tiling
    /// action pushes; it never silently invalidates: depth, not amnesia,
    /// bounds the history.
    mutating func pushUndo(snapshot: [EvictedWindow]?, requester: WindowID?) {
        guard let snapshot, !snapshot.isEmpty else { return }
        beginUndoChapter()
        undoStack[undoStack.count - 1] = (snapshot: snapshot, requester: requester)
    }

    /// Opens an undo chapter with an empty placeholder. Untile-all fills
    /// it in only after its windows restored (the snapshot is built from
    /// the frames they land on), and drops the placeholder when nothing
    /// can be restored; the depth cap lives here so no caller repeats it.
    mutating func beginUndoChapter() {
        undoStack.append((snapshot: [], requester: nil))
        if undoStack.count > Self.undoDepth {
            undoStack.removeFirst(undoStack.count - Self.undoDepth)
        }
    }

    /// The convergence checks one settled plan owns: the placed windows,
    /// plus a re-housed evictee when there is one.
    private func verificationWindows(for decision: TilePlan, requester id: WindowID) -> [WindowID] {
        switch decision {
        case .tile, .switchLayout: [id]
        case .swap(let displaced): [id, displaced]
        case .noop: []
        }
    }

    // MARK: Undo

    /// Undoes a chapter on this canvas: restores the requester to its
    /// pre-tile frame and returns every surviving evicted window to its
    /// slot. Returns the notice or error for the coordinator, which
    /// aggregates multi-canvas chapters and narrates on the chapter's
    /// own canvas.
    mutating func undo(
        snapshot: [EvictedWindow], requester: WindowID?, context: inout Context
    ) -> UndoOutcome {
        var result = UndoOutcome()
        if let requester {
            _ = restoreWindow(id: requester, context: &context)
        }
        var restored = 0
        for entry in snapshot {
            // Skip confirmed deaths only: an unknown liveness (busy app)
            // still attempts the restore: the write re-probes, and a
            // failed attempt is reported, not silently skipped.
            guard context.gateway.liveness(of: entry.handle) != .dead else { continue }
            // Handles whose records were pruned need fresh ids, issued
            // here on the local copy so the creation stays visible to
            // the commit and write below.
            let id: WindowID
            if let existing = context.records.first(where: { $0.value.handle == entry.handle })?.key {
                id = existing
            } else {
                id = context.nextID
                context.nextID += 1
                context.records[id] = WindowRecord(handle: entry.handle, preTileFrame: .zero)
            }
            guard var record = context.records[id] else { continue }
            record.preTileFrame = entry.preTileFrame
            context.records[id] = record
            state.commit(window: id, into: entry.slot)
            result.observe.append(id)
            // The frame may already be correct (e.g. an untile-all chapter
            // whose windows still sit at their pre-tile frames, or a
            // settle frame the gateway applied late): skip the write and
            // count it restored. Rewriting an identical frame is not just
            // wasteful: on a settling window it re-arms echo tracking
            // and risks a phantom drag-out. The grid is the destination
            // canvas's, not the legacy shared one.
            if let record = context.records[id],
                let slot = state.slot(of: id),
                let current = context.gateway.frame(of: record.handle),
                current == context.tracker.grid(for: entry.space).rect(
                    for: slot, in: context.boundsOf(current))
            {
                context.log("undo SKIP-WRITE win\(id) already placed")
                restored += 1
            } else if applyLayout(
                for: id, state: state, context: context, space: entry.space)
            {
                restored += 1
            } else {
                state.remove(window: id)
                context.records[id] = nil
                context.tracker.forget(id)
            }
        }
        if restored > 0 {
            let noun = restored == 1 ? "1 window" : "\(restored) windows"
            // The undo itself must not push a new chapter: restoration is
            // the consumption of history, not a new destruction.
            result.notice = "Undid displacement \u{00B7} \(noun) restored."
        } else {
            result.error = MenuText.restoreEvictedWindowsFailure
        }
        return result
    }

    // MARK: Plan branches

    /// The layout-switch branch: the requester moves rather than evicting,
    /// so everyone else in the way is restored first (restoring the
    /// requester would delete its record and the placement would bail).
    private mutating func applySwitchLayout(
        _ decision: TilePlan, requester id: WindowID, slot: Slot, context: inout Context
    ) -> Commit {
        var commit = Commit()
        // The requester moves rather than evicts: restore everyone
        // else first (restoring it would delete its record, so `place`
        // would bail and the window would merely untile). Its old tile
        // is vacated by the commit inside `place`.
        let evicted = decision.windowsToRestore(requester: id)
        let snapshot = evicted.compactMap { evictedID in
            Self.snapshotEntry(
                for: evictedID, state: state, records: context.records, fallback: slot,
                space: context.spaceOf(evictedID))
        }
        let restoreFailures = restore(evicted, context: &context)
        let placeResult = place(
            window: id, into: slot, context: &context, observed: &commit.observed)
        if context.records[id] == nil {
            // `place` bailed (no record): nothing to snapshot.
            Self.reportRestoreFailures(restoreFailures, refusal: &commit.refusal)
        } else if placeResult == nil, restoreFailures.isEmpty, !evicted.isEmpty {
            let noun = evicted.count == 1 ? "1 window" : "\(evicted.count) windows"
            // Narrate the event AND the recovery: the notice is the
            // hotkey user's only record of a mass-untile, and the
            // undo row may sit below the fold. One sentence, one
            // cue: no menu-title splicing, just the combo.
            commit.notice =
                "Switched to \(slot.layout.title) \u{00B7} \(noun) untiled. " +
                "Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."
            commit.snapshot = snapshot
            commit.requester = id
        } else {
            commit.refusal = placeResult
            Self.reportRestoreFailures(restoreFailures, refusal: &commit.refusal)
        }
        context.log("switchLayout win\(id) -> \(slot.rawValue) decision=\(decision)")
        return commit
    }

    /// The swap branch: both windows stay tiled, the displaced one taking
    /// the tile the requester vacates. The displaced window moves first, so
    /// a refusal anywhere leaves every window where it started.
    private mutating func applySwap(
        _ displaced: WindowID, decision: TilePlan, requester id: WindowID, slot: Slot,
        context: inout Context
    ) -> Commit {
        var commit = Commit()
        guard let previous = state.slot(of: id),
            let displacedOriginal = state.slot(of: displaced),
            context.records[id] != nil, context.records[displaced] != nil
        else {
            // Degenerate plan (untiled requester or a window that
            // vanished): degrade to the ordinary eviction path, with the
            // real closure set. An `isExpanded` that always answers false
            // would let a re-house pick up an expanded evictee, which the
            // documented rule forbids: an expanded window comes back to
            // earth by untangling, never by moving into the freed slot
            // while it still covers the layout.
            context.log("swap DEGENERATE win\(id) -> \(slot.rawValue); falling back to tile")
            return applyTile(
                .tile(evicting: [displaced]), requester: id,
                slot: slot, context: &context)
        }
        // Snapshot before any commit: each entry carries its window's
        // own former tile, so undo replays the swap backwards.
        let snapshot = [(displaced, displacedOriginal), (id, previous)].compactMap {
            (entryID, formerSlot) in
            Self.snapshotEntry(
                for: entryID, state: state, records: context.records, fallback: formerSlot,
                space: context.spaceOf(entryID))
        }
        state.commit(window: displaced, into: previous)
        commit.observed.append(displaced)
        if !applyLayout(
            for: displaced, state: state, context: context, space: context.space)
        {
            // The refused write moved nothing on screen: the rollback
            // is state-only, restoring both occupancies.
            state.commit(window: displaced, into: displacedOriginal)
            state.commit(window: id, into: previous)
            context.log("swap FAILED displaced win\(displaced) -> \(previous.rawValue)")
            commit.refusal = Self.refusal(
                for: displaced, records: context.records, gateway: context.gateway)
            return commit
        }
        state.commit(window: id, into: slot)
        commit.observed.append(id)
        if !applyLayout(
            for: id, state: state, context: context, space: context.space)
        {
            // Roll the whole swap back: the displaced window's frame
            // visibly moved, so it is written home; the requester was
            // never written, so only its occupancy restores.
            state.commit(window: displaced, into: displacedOriginal)
            state.commit(window: id, into: previous)
            applyLayout(
                for: displaced, state: state, context: context, space: context.space)
            context.log("place FAILED win\(id) -> \(slot.rawValue); swap rolled back")
            commit.refusal = Self.refusal(
                for: id, records: context.records, gateway: context.gateway)
            return commit
        }
        // A swap untiles nobody, but it does move a window the user
        // didn't touch: the notice names it and its landing tile.
        let displacedName = Self.appName(
            for: displaced, records: context.records, gateway: context.gateway) ?? "That window"
        commit.notice =
            "\(displacedName) moved to \(SlotPresentation.title(of: previous)) "
                + "to make room. Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."
        commit.snapshot = snapshot
        commit.requester = id
        context.log(
            "swap win\(id) -> \(slot.rawValue), win\(displaced) -> \(previous.rawValue)")
        return commit
    }

    /// The tile branch: evict whoever overlaps, place the requester, and
    /// re-house a lone evictee into the one whole slot the request left
    /// free. Hands the freed cells to settle, which owns the one reflow
    /// applier.
    private mutating func applyTile(
        _ decision: TilePlan, requester id: WindowID, slot: Slot, context: inout Context
    ) -> Commit {
        var commit = Commit()
        let evicted = decision.windowsToRestore(requester: id)
        // The eviction notice names the displaced app when known: the
        // user's first question after a surprise eviction is "where did
        // Safari go?"; a count answers bookkeeping, not memory. One
        // named app reads alone; more read as first-plus-count.
        // Names resolve BEFORE the restore deletes the records:
        // `restoreWindow` nils each record as it frees the slot, so
        // naming after would degrade every eviction to a count.
        let evictedNames = evicted.compactMap {
            Self.appName(for: $0, records: context.records, gateway: context.gateway)
        }
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
        if evicted.count == 1, !context.isExpanded(evicted[0]),
            let home = state.rehousingHome(
                evicting: evicted[0], for: slot, vacating: previous)
        {
            rehouse = (evicted[0], home)
        }
        let snapshot = evicted.compactMap { evictedID in
            Self.snapshotEntry(
                for: evictedID, state: state, records: context.records, fallback: slot,
                space: context.spaceOf(evictedID))
        }
        let restoreFailures = restore(
            evicted.filter { $0 != rehouse?.window }, context: &context)
        let placeResult = place(
            window: id, into: slot, context: &context, observed: &commit.observed)
        commit.refusal = placeResult
        Self.reportRestoreFailures(restoreFailures, refusal: &commit.refusal)
        let clean = commit.clean
        // Re-house commit: once the requester sits, the victim moves
        // into the one free slot and stays tiled. The move only happens
        // when the requester's own placement landed: making room for a
        // request that failed would move the victim for nothing, report
        // no destruction to undo, and promise an undo that cannot exist.
        // A refused re-house write falls back to the plain eviction.
        if let (wid, home) = rehouse, clean {
            state.commit(window: wid, into: home)
            if applyLayout(
                for: wid, state: state, context: context, space: context.space)
            {
                commit.rehoused = wid
                let name = Self.appName(
                    for: wid, records: context.records, gateway: context.gateway) ?? "That window"
                commit.notice =
                    "\(name) moved to \(SlotPresentation.title(of: home)) to make room. "
                        + "Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."
            } else {
                _ = restoreWindow(id: wid, context: &context)
                context.log("rehouse FAILED win\(wid) -> \(home.rawValue); falling back to eviction")
            }
        } else if let (wid, _) = rehouse {
            _ = restoreWindow(id: wid, context: &context)
            context.log("rehouse SKIPPED win\(wid): requester placement failed")
        }
        if clean {
            // Hand the freed region to settle: it owns the one reflow
            // applier, which drops the cells the requester covers again
            // (they are occupied, so only true remainders reach the
            // survivors) and grows the one mergeable survivor, folding
            // its undo entries into this chapter.
            var freed = Set(evictedSlots.flatMap { $0.cells })
            if let previous {
                freed.formUnion(previous.cells)
            }
            commit.reflowFreed = freed
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
            commit.snapshot = snapshot
            commit.requester = clean ? id : nil
            if commit.notice == nil {
                commit.notice = Self.evictionNotice(names: evictedNames, count: evicted.count)
            }
        }
        return commit
    }

    /// The pair a plan branch commits and hands back: the canvas folds
    /// `error`/`notice` into its own readable state, `snapshot`/
    /// `requester`/`rehoused` into the undo chapter and verification, and
    /// `observed` into the coordinator effects.
    private struct Commit {
        var refusal: Refusal?
        var notice: String?
        var snapshot: [EvictedWindow]?
        var requester: WindowID?
        var reflowFreed: Set<TileCell>?
        var rehoused: WindowID?
        var observed: [WindowID] = []

        /// True when nothing failed: neither the placement write nor any
        /// restore. A restore failure carries a message but no window
        /// name, so it is a `Refusal` too.
        var clean: Bool { refusal == nil }
    }

    /// A refused frame write: the standard message plus the window name
    /// for the announcement (nil when the failure was a restore, not a
    /// resize refusal).
    private struct Refusal {
        var message: String
        var windowName: String?
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
        evictedEntry(
            for: evictedID, slot: state.slot(of: evictedID) ?? fallback,
            records: records, space: space)
    }

    /// One undo entry for `id`'s `slot`: the handle to find it again, the
    /// slot to return it to, the frame it held. Nil when the record is
    /// gone.
    private static func evictedEntry(
        for id: WindowID, slot: Slot, records: [WindowID: WindowRecord],
        space: TilingSpaceKey? = nil
    ) -> EvictedWindow? {
        records[id].map {
            EvictedWindow(
                handle: $0.handle, slot: slot, preTileFrame: $0.preTileFrame, space: space)
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

    /// The refusal for a failed placement or swap write: names the window
    /// whose resize was refused, matching the standard wording.
    private static func refusal(
        for id: WindowID, records: [WindowID: WindowRecord], gateway: WindowGateway
    ) -> Refusal {
        let name = records[id].flatMap { gateway.appName(of: $0.handle) } ?? "That window"
        return Refusal(
            message: "\(name) couldn't be tiled: the app refused to resize it.",
            windowName: name)
    }

    // MARK: Placement helpers

    /// Places `id` into `slot`. Returns the refusal when the gateway write
    /// fails; nil means placed.
    private mutating func place(
        window id: WindowID, into slot: Slot,
        context: inout Context, observed: inout [WindowID]
    ) -> Refusal? {
        guard var record = context.records[id] else { return nil }
        if state.slot(of: id) == nil {
            // First tiling: remember where to restore when untiled.
            // A window moving between overlapping slots (e.g. Left -> BottomLeft)
            // keeps its original pre-tile frame.
            record.preTileFrame = context.gateway.frame(of: record.handle) ?? record.preTileFrame
            context.records[id] = record
        }
        state.commit(window: id, into: slot)
        observed.append(id)
        if !applyLayout(for: id, state: state, context: context, space: context.space) {
            // The window refused the frame (some apps ignore AX resizes):
            // roll back occupancy so state and screen agree, and say so.
            state.remove(window: id)
            context.tracker.forget(id)
            context.log("place FAILED win\(id) -> \(slot.rawValue)")
            return Self.refusal(
                for: id, records: context.records, gateway: context.gateway)
        }
        context.log("place win\(id) -> \(slot.rawValue)")
        return nil
    }

    /// Restores the window's pre-tile frame and releases its slot.
    /// Returns false when the restore was attempted and refused, so the
    /// caller can say so instead of silently leaving a stray window behind.
    @discardableResult
    private mutating func restoreWindow(id: WindowID, context: inout Context) -> Bool {
        var restored = true
        if let record = context.records[id], record.preTileFrame != .zero {
            restored = context.gateway.setFrame(record.handle, to: record.preTileFrame)
        }
        context.records[id] = nil
        context.tracker.forget(id)
        state.remove(window: id)
        return restored
    }

    /// Untiles every window in `ids`, returning the display names of those
    /// whose pre-tile frame refused to restore.
    private mutating func restore(_ ids: [WindowID], context: inout Context) -> [String] {
        var failures: [String] = []
        for evicted in ids {
            let name = Self.appName(
                for: evicted, records: context.records, gateway: context.gateway) ?? "A window"
            if !restoreWindow(id: evicted, context: &context) {
                failures.append(name)
            }
        }
        return failures
    }

    /// Reports restore failures unless a more relevant refusal (e.g. the
    /// requested tiling itself failing) already took the slot.
    private static func reportRestoreFailures(_ failures: [String], refusal: inout Refusal?) {
        guard !failures.isEmpty, refusal == nil else { return }
        refusal = Refusal(message: MenuText.restoreFailureMessage(failures), windowName: nil)
    }

    /// Applies `id`'s slot rect on `space` (the tiling canvas the plan
    /// belongs to; nil selects the legacy shared grid). Returns whether
    /// the gateway write succeeded (some windows refuse
    /// resizes). The tracker bookkeeps the write for echo suppression.
    @discardableResult
    private func applyLayout(
        for id: WindowID, state: TilingState,
        context: Context, space: TilingSpaceKey?
    ) -> Bool {
        guard let record = context.records[id], let slot = state.slot(of: id) else { return false }
        let current = context.gateway.frame(of: record.handle) ?? record.preTileFrame
        let bounds = context.boundsOf(current)
        let target = context.tracker.grid(for: space).rect(for: slot, in: bounds)
        // The shared write policy: a no-op target counts as success
        // without a write, and a hidden canvas defers (false: the branch
        // rolls back). The check is `.none`: settle schedules the plan's
        // convergence check, so a per-write check would double-schedule.
        // No canvas (legacy/headless snapshots) resolves to the
        // display-less fallback, which the visibility policy treats as
        // visible.
        let canvas = space ?? .displayless
        let result = context.frameWriter.write(
            id, handle: record.handle, to: target, on: canvas, check: .none)
        context.log(
            "applyLayout win\(id) slot=\(slot.rawValue) bounds=\(bounds) "
                + "target=\(target) result=\(result)")
        // A transiently unresolvable Space (the window-server table can
        // answer nil while the canvas key still carries an id) defers the
        // write: writing blind could pull the window onto the visible
        // Space. The branch rolls the placement back with its standard
        // refusal, the only user-facing failure vocabulary this path has.
        return result.isAccepted
    }

    private static func appName(
        for id: WindowID, records: [WindowID: WindowRecord], gateway: WindowGateway
    ) -> String? {
        records[id].flatMap { gateway.appName(of: $0.handle) }
    }

    // MARK: Reflow

    /// Applies reflow on this canvas after a tiled window left it or
    /// freed cells by moving: the one survivor whose cells merge with
    /// the freed cells into a whole slot moves into it, the rightmost
    /// candidate winning ties (see `TilingState.reflow`). Callers have
    /// already removed the leaving window; the requester, evicted, and
    /// expanded windows never grow. A hole no survivor merges into
    /// exactly stays empty. Refused writes roll every survivor back and
    /// the generic refusal message lands on this canvas, so state and
    /// screen never disagree about who holds the freed cells.
    ///
    /// Returns the undo entries for the survivors that moved: callers
    /// fold them into the triggering event's undo chapter, or start one
    /// when the reflow stands alone.
    @discardableResult
    mutating func reflow(
        _ freed: Set<TileCell>, excluding: Set<WindowID>, context: inout Context
    ) -> [EvictedWindow] {
        guard !freed.isEmpty else { return [] }
        // Expanded windows keep covering the layout; they never grow.
        let skip = excluding.union(
            Set(state.occupants.filter { context.isExpanded($0.value) }.map(\.value)))
        let placements = state.reflow(freed: freed, excluding: skip)
        guard !placements.isEmpty else { return [] }
        var moves: [(window: WindowID, from: Slot, to: Slot)] = []
        for (wid, target) in placements.sorted(by: { $0.key < $1.key }) {
            guard let from = state.slot(of: wid) else { continue }
            state.commit(window: wid, into: target)
            moves.append((wid, from, target))
        }
        // A hidden canvas's survivors grow in state now but are written
        // when the user swipes back: sizing an off-Space window can move
        // it onto the visible Space, which would break the independence
        // the layout exists to provide. The FrameWriter defers those
        // writes and marks the canvas stale for the swipe back.
        var rects: [WindowID: CGRect] = [:]
        for move in moves {
            if let target = context.tracker.rect(for: move.window, slot: move.to) {
                rects[move.window] = target
            }
        }
        if writeReflow(rects, context: &context) > 0 {
            var rolled = state
            for move in moves { rolled.commit(window: move.window, into: move.from) }
            state = rolled
            var oldRects: [WindowID: CGRect] = [:]
            for move in moves {
                if let old = context.tracker.rect(for: move.window, slot: move.from) {
                    oldRects[move.window] = old
                }
            }
            _ = writeReflow(oldRects, context: &context)
            return []
        }
        context.log("reflow \(moves.map { "win\($0.window)->\($0.to.rawValue)" }.joined(separator: ", "))")
        return moves.compactMap { move in
            Self.evictedEntry(
                for: move.window, slot: move.from,
                records: context.records, space: context.space)
        }
    }

    /// Performs one reflow push through the shared write policy, counting
    /// refusals and recording the generic refusal message on this canvas.
    /// Deferred (off-Space) writes are not failures: the FrameWriter has
    /// already marked the canvas stale and the grown state stands.
    private mutating func writeReflow(_ rects: [WindowID: CGRect], context: inout Context) -> Int {
        var failed = 0
        for (id, target) in rects {
            guard let record = context.records[id] else { continue }
            // The window's own canvas scopes the write; the placement's
            // canvas is the fallback for a window whose record has no
            // canvas yet.
            let canvas = context.spaceOf(id) ?? context.space
            if context.frameWriter.write(
                id, handle: record.handle, to: target, on: canvas, check: .rollback)
                == .refused
            {
                failed += 1
            }
        }
        // Refusals land on the canvas whose windows refused, not on
        // whatever happens to be focused when the menu is next read.
        if failed > 0 {
            error = Self.refusalMessage(count: failed)
        }
        return failed
    }

    static func refusalMessage(count: Int) -> String {
        count == 1
            ? "Couldn't move that window: the app refused to resize it."
            : "Couldn't move \(count) windows: an app refused to resize."
    }
}
