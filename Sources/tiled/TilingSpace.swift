import CoreGraphics
import Foundation

/// A managed window's restore record: its gateway handle plus the frame
/// to restore when untiled. Owned by the canvas the window belongs to;
/// the coordinator derives `spaceOf(window:)` from these records.
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

/// One tiling canvas's module: its occupancy, window records, expansion,
/// splitters, undo chapters, notices, and the placement pipeline (plan,
/// commit, settle, reflow) for that canvas.
///
/// The coordinator keeps focus and handle resolution, the handle->id
/// allocation table, observation, the visible-frame resolution, and the
/// death clock; every piece of per-canvas state lives here. Records being
/// canvas-owned is
/// what makes `spaceOf(window:)` derivable: a window's canvas is the one
/// holding its record, so ownership cannot drift from a second registry.
///
/// `notice`/`error` stay readable on the canvas: the placement writes
/// them as it settles, so the menu surface reads the canvas that acted.
struct TilingSpace {
    var state = TilingState()
    var undoStack: [(snapshot: [EvictedWindow], requester: WindowID?)] = []
    var splitterBackup: GridLayout?
    /// Splitter fractions for this canvas. The tracker moves them through
    /// its `GridProvider`, which reads and writes here.
    var grid = GridLayout()
    /// The one display geometry this canvas tiles against: the visible
    /// frame of the display the canvas lives on. The coordinator resolves
    /// it when the canvas is established and refreshes it on a display
    /// change, a swipe back, and a splitter reset; the canvas only stores
    /// and reads it. Every rect on the canvas derives from this one frame,
    /// so two occupants can never disagree about where their shared edge
    /// is. Never resolved from a window's own frame.
    var visibleFrame: CGRect = .zero
    /// Managed windows: the handle to reach them plus the frame untiling
    /// restores. A window records here when the coordinator hands it
    /// over, and leaves when an action forgets it.
    var records: [WindowID: WindowRecord] = [:]
    /// Windows expanded over the layout by the ⌥⇧⏎ toggle, keyed by id,
    /// holding the frame to restore for windows that had no slot when
    /// expanded (tiled windows retile into their slot instead, so their
    /// entry is unused). Expanded windows keep their slot in `state`:
    /// expanding acts like focusing, covering the layout without erasing
    /// it, but the tracker reads them as untiled (`trackedSlot`), so
    /// echoes of the expand write and hand drags of the covering window
    /// never mutate splitters or trigger drag-out untile.
    var expanded: [WindowID: CGRect] = [:]
    /// Pre-tile restores whose frame write deferred off-Space: the window
    /// is already untiled (record gone, slot released), but writing its
    /// frame blind could pull it onto the visible Space. The parked
    /// handle lands where it was by the swipe-back reassert, which drops
    /// the entry. Keyed by handle, so re-tiling the window before
    /// reconciliation discards the stale restore.
    var deferredRestores: [WindowHandle: DeferredRestore] = [:]
    var notice: String?
    var error: String?

    /// One parked off-Space pre-tile restore: the id the write policy
    /// echoes under (the window's record is gone) plus the frame to land
    /// on when the canvas becomes visible.
    struct DeferredRestore: Equatable {
        let id: WindowID
        let frame: CGRect
    }

    /// Depth cap for the per-canvas displacement undo: enough history to
    /// survive a tile-tile-realize rhythm without growing unbounded in a
    /// hotkey-heavy session. The chapters themselves live here, beside
    /// the occupancy they describe.
    static let undoDepth = 5

    /// Everything an action needs from the coordinator: the collaborators
    /// that reach back into live state. Records, expansion, splitters, and
    /// undo chapters are this canvas's own; the context never carries them.
    struct Context {
        let gateway: WindowGateway
        let frameWriter: FrameWriter
        let tracker: DragTracker
        /// The canvas every write without a better owner belongs to: the
        /// canvas this action is running on.
        let space: TilingSpaceKey
        /// Issues a fresh id and hands the window to the coordinator's
        /// handle->id table. Called when a record must be rebuilt from a
        /// handle alone (a pruned undo entry, an untile-all re-observation).
        let allocateID: (WindowHandle) -> WindowID
        let log: (String) -> Void
    }

    /// What one action returns: the typed result the coordinator maps to
    /// feedback, plus the coordinator effects it applies. `notice` and
    /// `error` are not here: they stay readable on the canvas.
    struct Outcome {
        enum Result: Equatable {
            /// The action committed.
            case placed
            /// The request's write was refused. The name is for the
            /// announcement (nil when the app named nothing).
            case refused(windowName: String?)
            /// The request's write was deferred: its canvas is on a
            /// Mission Control Space the user cannot see, so nothing was
            /// written. Not a failure: the intent stands and reconciles
            /// when the Space becomes visible, and the announcement says
            /// so rather than blaming the app.
            case deferred
            /// The window already occupies the requested slot: strict no-op.
            case alreadyTiled
            /// The evict key found no slot to release.
            case nothingToEvict
            /// An expand or retile write was refused.
            case expandRefused(windowName: String?)
        }
        var result: Result = .placed
        /// The window to focus once everything settled: a swap's displaced
        /// window. Focus effects stay coordinator-side.
        var focusAfter: WindowID?
        /// Windows the coordinator must now observe (their records landed).
        var observe: [WindowID] = []
        /// Windows the canvas released: the coordinator clears its handle
        /// table, death clock, and pending verification for them.
        var forget: [WindowID] = []
        /// Restored windows sit below the arrangement they left.
        var raise: Bool = false
        /// Windows whose convergence must be verified one delay later.
        var verify: [WindowID] = []
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

    // MARK: Records

    /// Ensures `id` has a record on this canvas. The coordinator resolves
    /// the handle->id table and hands the window over before an action
    /// that needs its restore frame.
    mutating func attach(_ id: WindowID, handle: WindowHandle) {
        if records[id] == nil {
            beginRecord(id, handle: handle, frame: .zero)
        }
    }

    /// Creates a window's record and drops any parked off-Space restore
    /// for its handle: the window is being tiled again, so the stale
    /// restore must never fire on the swipe back and yank it out of its
    /// new slot.
    private mutating func beginRecord(_ id: WindowID, handle: WindowHandle, frame: CGRect) {
        records[id] = WindowRecord(handle: handle, preTileFrame: frame)
        deferredRestores[handle] = nil
    }

    func record(of id: WindowID) -> WindowRecord? { records[id] }

    func handle(of id: WindowID) -> WindowHandle? { records[id]?.handle }

    /// Whether `id` is currently expanded over the layout.
    func isExpanded(_ id: WindowID) -> Bool { expanded[id] != nil }

    /// Drops a window the convergence check judged silently ignored:
    /// occupancy and record go, nothing is written. The coordinator owns
    /// the narration and the death/verification bookkeeping.
    mutating func discard(window id: WindowID, context: Context) {
        forget(id, context: context)
    }

    // MARK: Placement

    /// One placement request: `slot` for `requester`. Plans, commits,
    /// settles, and reflows; the canvas's own notice/error record what
    /// happened, and the returned `Outcome` carries the coordinator
    /// effects. The coordinator collapses an expanded requester before
    /// calling; a swap's expanded displaced window is collapsed here,
    /// between planning and committing, exactly where it always was.
    mutating func apply(slot: Slot, requester id: WindowID, context: Context) -> Outcome {
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
            _ = collapseExpanded(displaced, context: context)
        }
        return execute(decision: decision, requester: id, slot: slot, context: context)
    }

    /// Commits a decided plan for `requester` into `slot`: dispatches to
    /// the per-kind branch, then settles (forget, reflow, narration,
    /// verification, undo chapter). Internal so branch behaviour stays
    /// testable with a directly chosen plan.
    mutating func execute(
        decision: TilePlan, requester id: WindowID, slot: Slot, context: Context
    ) -> Outcome {
        let commit: Commit
        switch decision {
        case .noop:
            // Unreachable: callers guard noop first.
            return Outcome(result: .alreadyTiled)
        case .switchLayout:
            commit = applySwitchLayout(
                decision, requester: id, slot: slot, context: context)
        case .swap(let displaced):
            commit = applySwap(
                displaced, decision: decision, requester: id, slot: slot,
                context: context)
        case .tile:
            commit = applyTile(
                decision, requester: id, slot: slot, context: context)
        }
        return settle(decision, commit: commit, requester: id, context: context)
    }

    /// The placement half of settle: untiled windows give up their
    /// records (the coordinator clears its handle table), the cells the
    /// event freed reflow into one survivor, restored windows sit below
    /// the arrangement, a swap's displaced window takes focus, and the
    /// event is narrated, verified, and made undoable. One chapter per
    /// event, so a single ⌃⌥⇧⌘Z puts back everything this settled.
    private mutating func settle(
        _ decision: TilePlan, commit: Commit, requester id: WindowID,
        context: Context
    ) -> Outcome {
        var outcome = Outcome()
        switch (commit.refusal, commit.deferred) {
        case (let refusal?, _):
            // A restore failure carries no window name: the outcome stays
            // `.placed` and the canvas's `error` speaks for it.
            outcome.result = refusal.windowName.map { .refused(windowName: $0) } ?? .placed
        case (nil, true):
            outcome.result = .deferred
        case (nil, false):
            outcome.result = .placed
        }
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
            reflowSnapshot = reflow(freed, excluding: skip, context: context)
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
            records[displaced] != nil
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
        snapshot: [EvictedWindow], requester: WindowID?, context: Context
    ) -> UndoOutcome {
        var result = UndoOutcome()
        if let requester {
            _ = restore(window: requester, context: context)
        }
        var restored = 0
        for entry in snapshot {
            // Skip confirmed deaths only: an unknown liveness (busy app)
            // still attempts the restore: the write re-probes, and a
            // failed attempt is reported, not silently skipped.
            guard context.gateway.liveness(of: entry.handle) != .dead else { continue }
            // Handles whose records were pruned need fresh ids, issued
            // through the coordinator's table so the window stays
            // resolvable by handle.
            let id: WindowID
            if let existing = records.first(where: { $0.value.handle == entry.handle })?.key {
                id = existing
            } else {
                id = context.allocateID(entry.handle)
                beginRecord(id, handle: entry.handle, frame: .zero)
            }
            guard var record = records[id] else { continue }
            record.preTileFrame = entry.preTileFrame
            records[id] = record
            state.commit(window: id, into: entry.slot)
            result.observe.append(id)
            // The frame may already be correct (e.g. an untile-all chapter
            // whose windows still sit at their pre-tile frames, or a
            // settle frame the gateway applied late): skip the write and
            // count it restored. Rewriting an identical frame is not just
            // wasteful: on a settling window it re-arms echo tracking
            // and risks a phantom drag-out.
            if let record = records[id],
                let slot = state.slot(of: id),
                let current = context.gateway.frame(of: record.handle),
                current == grid.rect(for: slot, in: visibleFrame)
            {
                context.log("undo SKIP-WRITE win\(id) already placed")
                restored += 1
            } else if applyLayout(for: id, context: context, on: entry.space).stands {
                // A deferred off-Space write stands: the window keeps its
                // slot and reconciles when the canvas becomes visible.
                restored += 1
            } else {
                forget(id, context: context)
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
        _ decision: TilePlan, requester id: WindowID, slot: Slot, context: Context
    ) -> Commit {
        var commit = Commit()
        // The requester moves rather than evicts: restore everyone
        // else first (restoring it would delete its record, so `place`
        // would bail and the window would merely untile). Its old tile
        // is vacated by the commit inside `place`.
        let evicted = decision.windowsToRestore(requester: id)
        let snapshot = evicted.compactMap { evictedID in
            snapshotEntry(for: evictedID, fallback: slot, space: context.space)
        }
        let restoreFailures = restore(evicted, context: context)
        let placeResult = place(
            window: id, into: slot, context: context, observed: &commit.observed,
            deferred: &commit.deferred)
        if records[id] == nil {
            // `place` bailed (no record): nothing to snapshot.
            Self.reportRestoreFailures(restoreFailures, refusal: &commit.refusal)
        } else if placeResult == nil, restoreFailures.isEmpty, !evicted.isEmpty {
            let noun = evicted.count == 1 ? "1 window" : "\(evicted.count) windows"
            // Narrate the event AND the recovery: the notice is the
            // hotkey user's only record of a mass-untile, and the
            // undo row may sit below the fold. One sentence, one
            // cue: no menu-title splicing, just the combo.
            commit.notice =
                "Switched to \(slot.layout.title) \u{00B7} \(noun) untiled. "
                + "Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."
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
        context: Context
    ) -> Commit {
        var commit = Commit()
        guard let previous = state.slot(of: id),
            let displacedOriginal = state.slot(of: displaced),
            records[id] != nil, records[displaced] != nil
        else {
            // Degenerate plan (untiled requester or a window that
            // vanished): degrade to the ordinary eviction path, with the
            // real closure set. The live expansion map would let a
            // re-house pick up an expanded evictee, which the documented
            // rule forbids: an expanded window comes back to earth by
            // untangling, never by moving into the freed slot while it
            // still covers the layout.
            context.log("swap DEGENERATE win\(id) -> \(slot.rawValue); falling back to tile")
            return applyTile(
                .tile(evicting: [displaced]), requester: id,
                slot: slot, context: context)
        }
        // Snapshot before any commit: each entry carries its window's
        // own former tile, so undo replays the swap backwards.
        let snapshot = [(displaced, displacedOriginal), (id, previous)].compactMap {
            (entryID, formerSlot) in
            snapshotEntry(for: entryID, fallback: formerSlot, space: context.space)
        }
        state.commit(window: displaced, into: previous)
        commit.observed.append(displaced)
        let displacedWrite = applyLayout(for: displaced, context: context, on: context.space)
        if displacedWrite == .refused {
            // The refused write moved nothing on screen: the rollback
            // is state-only, restoring both occupancies.
            state.commit(window: displaced, into: displacedOriginal)
            state.commit(window: id, into: previous)
            context.log("swap FAILED displaced win\(displaced) -> \(previous.rawValue)")
            commit.refusal = refusal(for: displaced, context: context)
            return commit
        }
        if displacedWrite == .deferredOffSpace { commit.deferred = true }
        state.commit(window: id, into: slot)
        commit.observed.append(id)
        let requesterWrite = applyLayout(for: id, context: context, on: context.space)
        if requesterWrite == .refused {
            // Roll the whole swap back: the displaced window's frame
            // visibly moved, so it is written home; the requester was
            // never written, so only its occupancy restores.
            state.commit(window: displaced, into: displacedOriginal)
            state.commit(window: id, into: previous)
            applyLayout(for: displaced, context: context, on: context.space)
            context.log("place FAILED win\(id) -> \(slot.rawValue); swap rolled back")
            commit.refusal = refusal(for: id, context: context)
            return commit
        }
        if requesterWrite == .deferredOffSpace { commit.deferred = true }
        // A swap untiles nobody, but it does move a window the user
        // didn't touch: the notice names it and its landing tile.
        let displacedName = appName(displaced, context: context) ?? "That window"
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
        _ decision: TilePlan, requester id: WindowID, slot: Slot, context: Context
    ) -> Commit {
        var commit = Commit()
        let evicted = decision.windowsToRestore(requester: id)
        // The eviction notice names the displaced app when known: the
        // user's first question after a surprise eviction is "where did
        // Safari go?"; a count answers bookkeeping, not memory. One
        // named app reads alone; more read as first-plus-count.
        // Names resolve BEFORE the restore deletes the records:
        // `restore` nils each record as it frees the slot, so
        // naming after would degrade every eviction to a count.
        let evictedNames = evicted.compactMap { appName($0, context: context) }
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
        if evicted.count == 1, !isExpanded(evicted[0]),
            let home = state.rehousingHome(
                evicting: evicted[0], for: slot, vacating: previous)
        {
            rehouse = (evicted[0], home)
        }
        var snapshot = evicted.compactMap { evictedID in
            snapshotEntry(for: evictedID, fallback: slot, space: context.space)
        }
        // A tiled requester's vacated tile joins the chapter, exactly as
        // in a swap chapter: undo returns the requester to the slot it
        // vacated instead of releasing a window that was tiled before
        // the request. A fresh requester adds no entry: its undo is the
        // pre-tile restore.
        if let previous,
            let entry = snapshotEntry(for: id, fallback: previous, space: context.space)
        {
            snapshot.append(entry)
        }
        let restoreFailures = restore(
            evicted.filter { $0 != rehouse?.window }, context: context)
        let placeResult = place(
            window: id, into: slot, context: context, observed: &commit.observed,
            deferred: &commit.deferred)
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
            let write = applyLayout(for: wid, context: context, on: context.space)
            if write.stands {
                // A deferred off-Space write stands: the victim keeps the
                // freed slot and reconciles when the canvas is visible.
                if write == .deferredOffSpace { commit.deferred = true }
                commit.rehoused = wid
                let name = appName(wid, context: context) ?? "That window"
                commit.notice =
                    "\(name) moved to \(SlotPresentation.title(of: home)) to make room. "
                        + "Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."
            } else {
                _ = restore(window: wid, context: context)
                context.log("rehouse FAILED win\(wid) -> \(home.rawValue); falling back to eviction")
            }
        } else if let (wid, _) = rehouse {
            _ = restore(window: wid, context: context)
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
        /// A placement or re-house write was deferred off-Space: its
        /// state stands, so the event narrates the deferral rather than
        /// an app refusal.
        var deferred = false

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
    private func snapshotEntry(
        for evictedID: WindowID, fallback: Slot, space: TilingSpaceKey?
    ) -> EvictedWindow? {
        evictedEntry(
            for: evictedID, slot: state.slot(of: evictedID) ?? fallback, space: space)
    }

    /// One undo entry for `id`'s `slot`: the handle to find it again, the
    /// slot to return it to, the frame it held. Nil when the record is
    /// gone.
    private func evictedEntry(
        for id: WindowID, slot: Slot, space: TilingSpaceKey?
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
    private func refusal(for id: WindowID, context: Context) -> Refusal {
        let name = appName(id, context: context) ?? "That window"
        return Refusal(
            message: Self.refusalMessage(windowName: name),
            windowName: name)
    }

    // MARK: Placement helpers

    /// Places `id` into `slot`. Returns the refusal when the gateway write
    /// fails; nil means placed (or deferred: a deferred off-Space write
    /// stands, and `deferred` reports it so the event narrates it).
    private mutating func place(
        window id: WindowID, into slot: Slot,
        context: Context, observed: inout [WindowID], deferred: inout Bool
    ) -> Refusal? {
        guard var record = records[id] else { return nil }
        if state.slot(of: id) == nil {
            // First tiling: remember where to restore when untiled.
            // A window moving between overlapping slots (e.g. Left -> BottomLeft)
            // keeps its original pre-tile frame.
            record.preTileFrame = context.gateway.frame(of: record.handle) ?? record.preTileFrame
            records[id] = record
        }
        state.commit(window: id, into: slot)
        observed.append(id)
        let result = applyLayout(for: id, context: context, on: context.space)
        if result == .refused {
            // The window refused the frame (some apps ignore AX resizes):
            // roll back occupancy so state and screen agree, and say so.
            state.remove(window: id)
            context.tracker.forget(id)
            context.log("place FAILED win\(id) -> \(slot.rawValue)")
            return refusal(for: id, context: context)
        }
        // A deferred off-Space write is not a failure: the occupancy
        // stands and reconciles when the canvas becomes visible.
        if result == .deferredOffSpace { deferred = true }
        context.log("place win\(id) -> \(slot.rawValue)")
        return nil
    }

    /// Drops the window's record, expansion, tracker entries, and
    /// occupancy. Callers perform any frame write first; this only
    /// forgets. Shared by untiling, silent-ignore rollback, and untile-all.
    private mutating func forget(_ id: WindowID, context: Context) {
        records[id] = nil
        expanded[id] = nil
        context.tracker.forget(id)
        state.remove(window: id)
    }

    /// Restores the window's pre-tile frame and releases its slot, going
    /// through the one write policy every other push shares: a target the
    /// window already holds is skipped, and a canvas the user cannot see
    /// defers rather than writing blind. Returns false only when the
    /// gateway refused the write, so the caller can say so instead of
    /// silently leaving a stray window behind. The coordinator's undo
    /// reuses this for the chapter's requester.
    @discardableResult
    mutating func restore(window id: WindowID, context: Context) -> Bool {
        var restored = true
        if let record = records[id], record.preTileFrame != .zero {
            let result = context.frameWriter.write(
                id, handle: record.handle, to: record.preTileFrame,
                bounds: visibleFrame, on: context.space, check: .none)
            if result == .deferredOffSpace {
                // Deferred: nothing was written. Park the restore so the
                // swipe-back reassert lands it once the canvas is visible.
                deferredRestores[record.handle] = DeferredRestore(
                    id: id, frame: record.preTileFrame)
            }
            restored = result.stands
        }
        forget(id, context: context)
        return restored
    }

    /// Restores every window in `ids`, returning the display names of
    /// those whose pre-tile frame refused to restore.
    private mutating func restore(_ ids: [WindowID], context: Context) -> [String] {
        var failures: [String] = []
        for evicted in ids {
            let name = appName(evicted, context: context) ?? "A window"
            if !restore(window: evicted, context: context) {
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

    /// Writes every parked off-Space pre-tile restore now that the canvas
    /// is visible, then drops it: the restore's intent stands and lands
    /// here, exactly as a deferred reflow lands on the reassert. A canvas
    /// still hidden re-parks; a genuine refusal narrates the shared
    /// restore-failure message. The window is already untiled, so its
    /// tracker entry is cleared after the write (no phantom expectation).
    private mutating func reconcileDeferredRestores(context: Context) {
        guard !deferredRestores.isEmpty else { return }
        var remaining: [WindowHandle: DeferredRestore] = [:]
        var failures: [String] = []
        for (handle, parked) in deferredRestores {
            let result = context.frameWriter.write(
                parked.id, handle: handle, to: parked.frame,
                bounds: visibleFrame, on: context.space, check: .none)
            context.tracker.forget(parked.id)
            switch result {
            case .written, .skippedNoOp:
                break
            case .deferredOffSpace:
                remaining[handle] = parked
            case .refused:
                failures.append(context.gateway.appName(of: handle) ?? "A window")
            }
        }
        deferredRestores = remaining
        if !failures.isEmpty {
            error = MenuText.restoreFailureMessage(failures)
        }
    }

    /// Applies `id`'s slot rect on `space` (nil selects the display-less
    /// fallback for legacy/headless snapshots). Returns the shared write
    /// policy's result; the tracker bookkeeps the write for echo
    /// suppression. Every caller reads it through `Result.stands`: only a
    /// gateway refusal is a failure. A deferred off-Space write stands —
    /// the canvas is not written blind, and the committed state reconciles
    /// when the canvas becomes visible — exactly as `writeRects` treats a
    /// deferred reflow.
    @discardableResult
    private func applyLayout(
        for id: WindowID, context: Context, on space: TilingSpaceKey?
    ) -> FrameWriter.Result {
        guard let record = records[id], let slot = state.slot(of: id) else { return .refused }
        let bounds = visibleFrame
        let target = grid.rect(for: slot, in: bounds)
        // The shared write policy: a no-op target counts as success
        // without a write, and a hidden canvas defers. The check is
        // `.none`: settle schedules the plan's convergence check, so a
        // per-write check would double-schedule. No canvas
        // (legacy/headless snapshots) resolves to the display-less
        // fallback, which the visibility policy treats as visible.
        let canvas = space ?? .displayless
        let result = context.frameWriter.write(
            id, handle: record.handle, to: target, bounds: bounds, on: canvas, check: .none)
        context.log(
            "applyLayout win\(id) slot=\(slot.rawValue) bounds=\(bounds) "
                + "target=\(target) result=\(result)")
        return result
    }

    private func appName(_ id: WindowID, context: Context) -> String? {
        records[id].flatMap { context.gateway.appName(of: $0.handle) }
    }

    // MARK: Reflow

    /// Applies reflow on this canvas after a tiled window left it or
    /// freed cells by moving: the one survivor whose cells merge with
    /// the freed cells into a whole slot moves into it, the rightmost
    /// candidate winning ties (see `TilingState.reflow`). Callers have
    /// already removed the leaving window; the requester, evicted, and
    /// expanded windows never grow (the expanded exclusion lives here
    /// now, not with the pure rule). A hole no survivor merges into
    /// exactly stays empty. Refused writes roll every survivor back and
    /// the generic refusal message lands on this canvas, so state and
    /// screen never disagree about who holds the freed cells.
    ///
    /// Returns the undo entries for the survivors that moved: callers
    /// fold them into the triggering event's undo chapter, or start one
    /// when the reflow stands alone.
    @discardableResult
    mutating func reflow(
        _ freed: Set<TileCell>, excluding: Set<WindowID> = [], context: Context
    ) -> [EvictedWindow] {
        guard !freed.isEmpty else { return [] }
        // Expanded windows keep covering the layout; they never grow.
        let skip = excluding.union(
            Set(state.occupants.filter { expanded[$0.value] != nil }.map(\.value)))
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
            if records[move.window] != nil {
                rects[move.window] = grid.rect(for: move.to, in: visibleFrame)
            }
        }
        if writeRects(rects, context: context).failed > 0 {
            var rolled = state
            for move in moves { rolled.commit(window: move.window, into: move.from) }
            state = rolled
            var oldRects: [WindowID: CGRect] = [:]
            for move in moves {
                if records[move.window] != nil {
                    oldRects[move.window] = grid.rect(for: move.from, in: visibleFrame)
                }
            }
            _ = writeRects(oldRects, context: context)
            return []
        }
        context.log("reflow \(moves.map { "win\($0.window)->\($0.to.rawValue)" }.joined(separator: ", "))")
        return moves.compactMap { move in
            evictedEntry(for: move.window, slot: move.from, space: context.space)
        }
    }

    /// One push pass through the shared write policy: the pairs the
    /// gateway actually wrote, which the reassert reads back as achieved
    /// frames, plus the refusal count reflow rolls back on. A deferred
    /// (off-Space) write is not a failure: the FrameWriter has already
    /// marked the canvas stale and the pushed state stands for
    /// reconciliation when the canvas becomes visible — the placement
    /// path's contract, read through the same `Result.stands`.
    private struct WritePass {
        var written: [(id: WindowID, target: CGRect)] = []
        var failed = 0
    }

    /// Performs one push through the shared write policy, counting
    /// refusals and recording the generic refusal message on this canvas.
    /// Shared by reflow and the reassert.
    private mutating func writeRects(_ rects: [WindowID: CGRect], context: Context) -> WritePass {
        var pass = WritePass()
        for (id, target) in rects {
            guard let record = records[id] else { continue }
            let result = context.frameWriter.write(
                id, handle: record.handle, to: target, bounds: visibleFrame,
                on: context.space, check: .rollback)
            switch result {
            case .written: pass.written.append((id: id, target: target))
            case .refused: pass.failed += 1
            case .skippedNoOp, .deferredOffSpace: break
            }
        }
        // Refusals land on the canvas whose windows refused, not on
        // whatever happens to be focused when the menu is next read.
        if pass.failed > 0 {
            error = Self.refusalMessage(count: pass.failed)
        }
        return pass
    }

    static func refusalMessage(count: Int) -> String {
        count == 1
            ? "Couldn't move that window: the app refused to resize it."
            : "Couldn't move \(count) windows: an app refused to resize."
    }

    /// The standard refusal sentence for a window whose resize its app
    /// refused. One declaration, so the placement branch and the late
    /// convergence rollback cannot drift apart.
    static func refusalMessage(windowName name: String) -> String {
        "\(name) couldn't be tiled: the app refused to resize it."
    }

    // MARK: Untile / evict / release

    /// Restores one window to its pre-tile frame and releases its slot,
    /// then lets the freed cells reflow (when `reflowing`). The freed
    /// cells' survivor moves into them and shares the leave's undo
    /// chapter; the restore itself keeps no chapter (the frame IS the
    /// recovery).
    mutating func untile(window id: WindowID, reflowing: Bool, context: Context) -> Outcome {
        error = nil
        notice = nil
        let slot = state.slot(of: id)
        let name = appName(id, context: context) ?? "A window"
        if !restore(window: id, context: context) {
            error = MenuText.restoreFailureMessage([name])
        }
        guard reflowing else { return Outcome(forget: [id]) }
        return leave(window: id, from: slot, context: context)
    }

    /// Evicts one window: the untile path, refusing early when the
    /// window holds no slot. The coordinator answers `.nothingToEvict`.
    mutating func evict(window id: WindowID, context: Context) -> Outcome {
        guard state.slot(of: id) != nil else {
            return Outcome(result: .nothingToEvict)
        }
        return untile(window: id, reflowing: true, context: context)
    }

    /// Releases a confirmed-dead window: the untile path without a frame
    /// write (the window is gone), reflowing its freed cells and pushing
    /// the survivor chapter. The coordinator's prune and destroy paths
    /// call this once the death standard agrees.
    mutating func release(window id: WindowID, context: Context) -> Outcome {
        leave(window: id, from: state.slot(of: id), context: context)
    }

    /// Drag-out untile: the drop IS the placement, so the pre-tile frame
    /// is never written. The freed cells still reflow and the survivor is
    /// raised, chapter and all.
    mutating func untileFromDrag(window id: WindowID, context: Context) -> Outcome {
        error = nil
        notice = nil
        return leave(window: id, from: state.slot(of: id), context: context)
    }

    /// The shared tail of every leave: drop the record, reflow the freed
    /// cells into the mergeable survivor, and make the survivor's growth
    /// undoable. The caller performs any frame write first, and gets the
    /// survivor raise back.
    private mutating func leave(
        window id: WindowID, from slot: Slot?, context: Context
    ) -> Outcome {
        forget(id, context: context)
        let moves = reflow(slot?.cells ?? [], context: context)
        pushUndo(snapshot: moves, requester: nil)
        return Outcome(forget: [id], raise: true)
    }

    /// Dissolves every window on this canvas in one undo chapter. The
    /// chapter lists each dissolved (slot, pre-tile frame) pair, and undo
    /// re-applies the slot rect on top of the restored frame: the window
    /// visibly returns to the arrangement, not just to its pre-tile
    /// frame. Fresh ids are issued for the re-observed windows (their
    /// records were released).
    mutating func untileAll(context: Context) -> Outcome {
        error = nil
        notice = nil
        var outcome = Outcome()
        let chapter = state.occupants
        let noun = chapter.count == 1 ? "1 window" : "\(chapter.count) windows"
        if !chapter.isEmpty {
            beginUndoChapter()
            notice = "Untiled \(noun). Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."
            // Prime the tracker's intent for the slot rects the undo will
            // write: the live frames are pre-tile settle frames, and the
            // diff must measure against where we're going, not where the
            // restore just put us. Without this the undo's own writes
            // read as a user drag and the grid moves under them.
            for (slot, id) in chapter {
                if records[id] != nil {
                    let target = grid.rect(for: slot, in: visibleFrame)
                    context.tracker.markExpected(id, target)
                }
            }
        }
        // Handles first: the restore clears each record, so resolve every
        // handle while the canvas still knows them.
        var handles: [WindowID: WindowHandle] = [:]
        for id in state.tiledWindows {
            handles[id] = records[id]?.handle
        }
        var failures: [String] = []
        for id in state.tiledWindows {
            let name = appName(id, context: context) ?? "A window"
            if !restore(window: id, context: context) {
                failures.append(name)
            }
        }
        if !failures.isEmpty {
            error = MenuText.restoreFailureMessage(failures)
        }
        // Rebuild the chapter from the frames untile-all just restored:
        // each window now sits at its pre-tile frame with no record, so
        // re-observe it there and pair it with its dissolved slot. The
        // undo then retiles the live window back into place.
        if !chapter.isEmpty {
            var snapshot: [EvictedWindow] = []
            for (slot, id) in chapter {
                guard let handle = handles[id],
                      let frame = context.gateway.frame(of: handle)
                else { continue }
                let fresh = context.allocateID(handle)
                // Re-observed for the undo chapter, not re-tiled: keep any
                // parked off-Space restore so the swipe back still lands it.
                records[fresh] = WindowRecord(handle: handle, preTileFrame: frame)
                outcome.observe.append(fresh)
                snapshot.append(EvictedWindow(
                    handle: handle, slot: slot, preTileFrame: frame, space: context.space))
            }
            if snapshot.isEmpty {
                // Every frame read failed (the AX-unreadable
                // transient): nothing can be restored, so the
                // placeholder chapter goes. A "Restore 0 Evicted
                // Windows" row would offer an undo that can only
                // report failure.
                _ = undoStack.popLast()
                // The sticky notice must not offer a key that no
                // longer has a chapter behind it.
                notice = "Untiled \(noun)."
            } else {
                undoStack[undoStack.count - 1] = (snapshot: snapshot, requester: nil)
            }
        }
        outcome.forget = chapter.values.map { $0 }
        return outcome
    }

    // MARK: Expand toggle

    /// Expands the window to fill its screen; a second toggle retiles it
    /// to its previous tile (or restores its previous frame when it
    /// wasn't tiled). Layout state is untouched: a tiled window keeps its
    /// slot while expanded, exactly like focusing it.
    mutating func expandToggle(window id: WindowID, context: Context) -> Outcome {
        if expanded[id] != nil {
            return collapseExpanded(id, context: context)
        }
        return expand(id, context: context)
    }

    private mutating func expand(_ id: WindowID, context: Context) -> Outcome {
        guard let record = records[id] else { return Outcome() }
        let current = context.gateway.frame(of: record.handle) ?? record.preTileFrame
        // No readable frame anywhere: the window has no sane geometry to
        // return to on collapse, so refuse to guess.
        guard current != .zero else { return Outcome() }
        let target = visibleFrame
        error = nil
        notice = nil
        let result = writeExpandedFrame(id, to: target, context: context)
        if result.accepted {
            expanded[id] = current
            context.log("expand win\(id) -> \(target)")
            return Outcome()
        }
        // Every non-accepted expanded write answers `.expandRefused`,
        // deferred included (the old feedback shape); only a genuine
        // refusal records a message on the canvas.
        if let message = result.refusal {
            error = message
        }
        return Outcome(result: .expandRefused(windowName: appName(id, context: context)))
    }

    /// Unexpands `id`, recording the refusal on this canvas and returning
    /// it through the outcome. The coordinator announces the refusal for
    /// a pressed toggle; `apply` folds it in at its own precedence
    /// (a placement refusal overwrites it, exactly as before).
    @discardableResult
    mutating func collapseExpanded(_ id: WindowID, context: Context) -> Outcome {
        guard let saved = expanded[id] else { return Outcome() }
        expanded[id] = nil
        error = nil
        notice = nil
        var refusal: String?
        var answered = false
        if state.slot(of: id) != nil {
            if let result = retileExpanded(id, context: context) {
                refusal = result.refusal
                answered = !result.accepted
            }
        } else if records[id] != nil {
            let result = writeExpandedFrame(id, to: saved, context: context)
            refusal = result.refusal
            answered = !result.accepted
            if result.accepted {
                context.log("collapse win\(id) -> saved \(saved)")
            }
        }
        if let refusal {
            error = refusal
        }
        // A deferred or refused retile answers `.expandRefused`; a
        // collapse with no record (nothing to write) stays silent.
        guard answered else { return Outcome() }
        return Outcome(result: .expandRefused(windowName: appName(id, context: context)))
    }

    /// Re-applies an expanded window's slot rect after collapse; the
    /// write result comes back for the caller to fold. Nil when the
    /// window's record or slot is already gone: nothing was written.
    /// Uses the canvas's own grid directly, not plan execution: the
    /// window never left its slot, so there is nothing to restore or
    /// evict.
    private func retileExpanded(_ id: WindowID, context: Context) -> ExpandedWrite? {
        guard records[id] != nil, let slot = state.slot(of: id) else { return nil }
        let target = grid.rect(for: slot, in: visibleFrame)
        let result = writeExpandedFrame(id, to: target, context: context)
        context.log("retile expanded win\(id) -> \(slot.rawValue) target=\(target)")
        return result
    }

    /// One expected frame write via the gateway: the shared shape of the
    /// expand, collapse, and retile writes. Expansion has no rollback
    /// path of its own, so it declares no convergence check; a refusal
    /// comes back as its message for the caller to record.
    private enum ExpandedWrite: Equatable {
        /// The frame is where intended (written, or already correct).
        case accepted
        /// The canvas is not the visible Space: nothing written, nothing
        /// recorded; expansion stays out of state.
        case deferred
        /// The gateway refused: message for the window's canvas.
        case refused(String)

        var accepted: Bool { self == .accepted }

        /// The refusal message to record, when the gateway refused.
        var refusal: String? {
            if case .refused(let message) = self { return message }
            return nil
        }
    }

    private func writeExpandedFrame(
        _ id: WindowID, to target: CGRect, context: Context
    ) -> ExpandedWrite {
        guard let record = records[id] else { return .deferred }
        // The shared write policy: the off-Space guard defers a hidden
        // canvas (the expansion stays out of state), and a no-op target
        // counts as success without a write.
        let result = context.frameWriter.write(
            id, handle: record.handle, to: target, bounds: visibleFrame,
            on: context.space, check: .none)
        switch result {
        case .written, .skippedNoOp: return .accepted
        case .deferredOffSpace: return .deferred
        case .refused: return .refused(Self.refusalMessage(count: 1))
        }
    }

    // MARK: Splitter reset / restore

    /// Snaps all splitters back to defaults and re-tiles everyone. The
    /// displaced fractions are kept as a one-step restore (same pattern
    /// as the shortcuts reset backup), so the app's "destruction is
    /// always reversible" ethic holds for drag positions too.
    mutating func resetSplitters(context: Context) -> Outcome {
        splitterBackup = grid
        grid = GridLayout()
        error = nil
        notice = nil
        return reassert(.grid, context: context)
    }

    /// Restores the splitter fractions parked by the last reset. Nil
    /// backup (fresh install, or already restored once) is a no-op, and
    /// the coordinator answers false.
    @discardableResult
    mutating func restoreSplitters(context: Context) -> Outcome {
        guard let backup = splitterBackup else { return Outcome() }
        grid = backup
        splitterBackup = nil
        error = nil
        notice = "Splitters restored to their pre-reset positions."
        return reassert(.grid, context: context)
    }

    /// Whether a splitter backup is parked: drives the menu row title
    /// ("Reset Splitters" vs "Restore Previous Splitters").
    var hasSplitterBackup: Bool { splitterBackup != nil }

    /// Count for the undo menu title: the freshest chapter's windows, or
    /// 0 when no chapter is parked.
    var evictedCount: Int { undoStack.last?.snapshot.count ?? 0 }

    // MARK: Reassert

    /// The trigger for one reassert. A small sum type, not a request
    /// object: `.resize` is an edge drag's settle (the app's achieved
    /// frame is authoritative), `.grid` is every path that already knows
    /// its splitters are right (display change, swipe back, splitter
    /// reset, title-bar snapback). No scope set and no convergence knob:
    /// the coordinator's mouse-up wires `.resize` in stage 3, and a
    /// future overlay-handle gesture would add its own case, not a
    /// speculative one now.
    enum ReassertSource: Equatable {
        /// An edge resize settled: reconcile the dragged window's
        /// splitters back to the edge the app actually achieved, then map
        /// every rect under the reconciled grid.
        case resize(dragged: WindowID, achieved: CGRect)
        /// The splitters are already right: map every rect as they stand.
        case grid
    }

    /// A reassert's pure result: the reconciled splitters plus every
    /// in-scope occupant's target rect. No gateway, clock, or scheduler
    /// touched it; the effectful wrapper stores and writes it.
    struct ReassertPlan: Equatable {
        var grid: GridLayout
        var rects: [WindowID: CGRect]
    }

    /// The pure half of a reassert: reconcile the splitters for a resize
    /// (leave them alone otherwise), then derive every tiled,
    /// non-expanded occupant's rect under this canvas's one visible
    /// frame. The dragged window's achieved edge is reconciled into the
    /// splitters BEFORE any rect is mapped, so neighbours abut the window
    /// itself rather than a splitter the app could not reach.
    func reassertPlan(_ source: ReassertSource) -> ReassertPlan {
        let reconciled = reconciledGrid(source)
        var rects: [WindowID: CGRect] = [:]
        for (slot, occupant) in state.occupants where expanded[occupant] == nil {
            rects[occupant] = reconciled.rect(for: slot, in: visibleFrame)
        }
        return ReassertPlan(grid: reconciled, rects: rects)
    }

    /// The grid a reassert maps against. `.grid` leaves the splitters
    /// alone; `.resize` moves each of the dragged window's movable edges
    /// back to the achieved frame's edge, so the splitter sits where the
    /// window actually landed. The two-thirds hidden-divider rule is the
    /// grid's own, shared with the live drag loop.
    private func reconciledGrid(_ source: ReassertSource) -> GridLayout {
        guard case .resize(let dragged, let achieved) = source,
            let slot = state.slot(of: dragged)
        else { return grid }
        let occupied = Set(state.occupants.keys)
        var reconciled = grid
        for edge in TileEdge.allCases {
            guard let boundary = GridLayout.boundary(edge: edge, slot: slot) else { continue }
            let position = Self.position(of: edge, in: achieved)
            reconciled.update(
                boundary: boundary, toPosition: position, in: visibleFrame,
                centeringTwoThirds: GridLayout.centeringTwoThirds(
                    on: boundary, draggedSlot: slot, occupants: occupied))
        }
        return reconciled
    }

    /// The effectful half: store the reconciled splitters, seed the drag
    /// loop's diff baselines for every in-scope occupant (a skipped or
    /// deferred write never reaches the loop's own mark), write every
    /// rect through the one write policy, then reconcile each *written*
    /// occupant's achieved edge back onto the splitter it rides. A
    /// degenerate visible frame has no rects to derive, so nothing is
    /// stored or written.
    @discardableResult
    mutating func reassert(_ source: ReassertSource, context: Context) -> Outcome {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            context.log("reassert skipped: degenerate visibleFrame \(visibleFrame)")
            return Outcome()
        }
        // A deferred pre-tile restore lands here, on the swipe back that
        // reasserts this canvas: the parked window was never written
        // blind, and its frame is restored now that the canvas is visible.
        reconcileDeferredRestores(context: context)
        var plan = reassertPlan(source)
        grid = plan.grid
        seedBaselines(plan.rects, context: context)
        var pass = writeRects(plan.rects, context: context)
        // A neighbour whose app rounds or insets the frame it is written
        // falls short of the splitter and leaves a gap. Read every
        // written occupant's achieved frame back; a diverged splitter
        // edge moves its splitter to the achieved position, then the
        // layout is re-planned and re-written. Bounded: the reported
        // row-rounding case converges in one extra pass, and the cap
        // stops two neighbours that each pull the shared splitter their
        // way from oscillating forever. Only written occupants are read
        // back: a skipped no-op write has no new achieved frame.
        for _ in 0..<Self.maxAchievedEdgePasses {
            guard reconcileAchievedEdges(pass.written, context: context) else { break }
            plan = reassertPlan(.grid)
            seedBaselines(plan.rects, context: context)
            pass = writeRects(plan.rects, context: context)
        }
        return Outcome()
    }

    /// How many achieved-edge corrective passes one reassert may run.
    /// The reported row-rounding case converges in one extra pass (the
    /// neighbour pulls the splitter to its achieved edge, and the second
    /// readback finds the geometry already flush); the small cap stops
    /// two neighbours that each pull the shared splitter their way from
    /// oscillating forever.
    private static let maxAchievedEdgePasses = 2

    /// Seeds the drag loop's diff baseline for every rect a reassert is
    /// about to write: a skipped or deferred write never reaches
    /// markExpected, so without the seed the first drag after the
    /// reassert diffs against a stale frame and is misread.
    private func seedBaselines(_ rects: [WindowID: CGRect], context: Context) {
        for (id, rect) in rects {
            context.tracker.seedBaseline(id, rect)
        }
    }

    /// Reconciles every written occupant's achieved edge back onto the
    /// splitter that edge rides, returning whether any splitter moved.
    /// An app that rounds or insets a programmatically-written frame can
    /// leave a neighbour short of the splitter, opening a gap; the
    /// achieved edge is authoritative, exactly as the dragged window's
    /// is, so the splitter follows it and the tiles abut. An edge on a
    /// screen edge has no boundary (fixed) and is left alone: the
    /// residual an app cannot remove lands there, never between tiles.
    /// The readback is the one effect the pure plan cannot perform, so it
    /// lives here, in the effectful half.
    private mutating func reconcileAchievedEdges(
        _ written: [(id: WindowID, target: CGRect)], context: Context
    ) -> Bool {
        var reconciled = grid
        let occupied = Set(state.occupants.keys)
        var changed = false
        for entry in written {
            guard let slot = state.slot(of: entry.id),
                let record = records[entry.id],
                let achieved = context.gateway.frame(of: record.handle)
            else { continue }
            for edge in TileEdge.allCases {
                guard let boundary = GridLayout.boundary(edge: edge, slot: slot)
                else { continue }
                let target = Self.position(of: edge, in: entry.target)
                let landed = Self.position(of: edge, in: achieved)
                guard abs(landed - target) > DragTracker.noOpWriteTolerance
                else { continue }
                if reconciled.update(
                    boundary: boundary, toPosition: landed, in: visibleFrame,
                    centeringTwoThirds: GridLayout.centeringTwoThirds(
                        on: boundary, draggedSlot: slot, occupants: occupied))
                {
                    changed = true
                }
            }
        }
        grid = reconciled
        return changed
    }

    /// The screen-space position of one frame edge (AppKit coords).
    private static func position(of edge: TileEdge, in frame: CGRect) -> CGFloat {
        switch edge {
        case .left: frame.minX
        case .right: frame.maxX
        case .top: frame.maxY
        case .bottom: frame.minY
        }
    }
}
