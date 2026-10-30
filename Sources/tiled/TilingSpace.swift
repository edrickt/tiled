import CoreGraphics
import Foundation

/// A managed window's restore record: its gateway handle plus the frame
/// to restore when untiled. Owned by the canvas the window belongs to;
/// the directory derives canvas ownership from these records.
struct WindowRecord {
    let handle: WindowHandle
    var preTileFrame: CGRect
}

/// One window in an undo chapter: it was evicted, moved by a re-house or
/// swap, or grew by reflow. The chapter is a displacement, not necessarily
/// an eviction.
///
/// Records are rebuilt from live handles on undo; dead windows are skipped.
/// `space` tags the tiling canvas the window returns to: undo retiles
/// per display and per Space, so a restored window lands on the canvas
/// it left. Nil = legacy snapshots (pre-per-canvas), restored onto the
/// canvas being undone.
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
/// The `WindowRegister` keeps handle identity, the death clock, and
/// pending convergence checks; the `CanvasDirectory` keeps display + Space
/// resolution, the canvas table, visibility, stale marks, and the visible
/// frame refresh. Every piece of per-canvas state lives here. Records being
/// canvas-owned is what makes the directory's owner lookup derivable: a
/// window's canvas is the one holding its record, so ownership cannot
/// drift from a second registry.
///
/// `notice`/`error` stay readable on the canvas: the placement writes
/// them as it settles, so the menu surface reads the canvas that acted.
struct TilingSpace {
    /// One eviction's undo chapter: the windows to re-place (each tagged
    /// with the canvas it returns to) and the action's requester, whose
    /// pre-tile frame the controller restores.
    typealias UndoChapter = (snapshot: [EvictedWindow], requester: WindowID?)

    var state = TilingState()
    var undoStack: [UndoChapter] = []
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
    /// frame blind could pull it onto the visible Space. The deferred
    /// handle lands where it was by the swipe-back reassert, which drops
    /// the entry. Keyed by handle, so re-tiling the window before
    /// reconciliation discards the stale restore; the coordinator clears
    /// it on every canvas, so a retile elsewhere discards this one too.
    var deferredRestores: [WindowHandle: DeferredRestore] = [:]
    var notice: String?
    var error: String?

    /// One deferred off-Space pre-tile restore: the id the write policy
    /// echoes under (the window's record is gone) plus the frame to land
    /// on when the canvas becomes visible.
    struct DeferredRestore: Equatable {
        let id: WindowID
        let frame: CGRect
    }

    /// A tiling request or expand/collapse whose write deferred off-Space:
    /// the user's request is retained and re-issued by the swipe-back
    /// reassert, exactly as a deferred restore lands. Keyed by id (unlike
    /// a deferred restore, whose record is gone): the window is still
    /// owned by this canvas, so it can be reconciled by re-writing its
    /// committed rect. A newer request for the same window replaces the
    /// older one, so the user's last intent wins.
    var deferredRequests: [WindowID: DeferredRequest] = [:]

    /// One retained off-Space request. A slot request re-issues its
    /// committed slot rect on return; an expand/collapse re-issues the
    /// frame the toggle would have written (the screen frame, or the
    /// saved one).
    enum DeferredRequest: Equatable {
        /// A tiling request deferred off-Space. The slot is re-derived
        /// from state on return, not retained here: a stored copy could
        /// silently disagree with a swap committed before the reconcile.
        case slot
        /// An expansion deferred off-Space: the pre-expand frame to
        /// remember (`expanded[id]`) once the expansion lands.
        case expand(saved: CGRect)
        /// A collapse of an untiled expanded window deferred off-Space:
        /// the saved frame to land on.
        case collapse(frame: CGRect)
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
        /// register. Called when a record must be rebuilt from a
        /// handle alone (a pruned undo entry, an untile-all re-observation).
        let allocateID: (WindowHandle) -> WindowID
        /// Drops `handle`'s deferred pre-tile restore on every canvas.
        let discardDeferredRestores: (WindowHandle) -> Void
        let log: (String) -> Void
    }

    /// What one action returns: the typed result the coordinator maps to
    /// its receipt, plus the coordinator effects it applies. `notice` and
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
            /// An explicit layout switch untiled `untiled` windows. The
            /// layout changed even when a restore was refused.
            case switched(layout: LayoutKind, untiled: Int)
            /// The canvas already shows the requested layout: strict no-op.
            case alreadyInLayout(LayoutKind)
        }
        var result: Result = .placed
        /// The window to focus once everything settled: a swap's displaced
        /// window. Focus effects stay coordinator-side.
        var focusAfter: WindowID?
        /// Windows the coordinator must now observe (their records landed).
        var observe: [WindowID] = []
        /// Windows the canvas released: the coordinator forgets the id,
        /// death clock, and pending verification for them.
        var forget: [WindowID] = []
        /// Restored windows sit below the arrangement they left.
        var raise: Bool = false
        /// Windows whose convergence must be verified one delay later.
        var verify: [WindowID] = []
    }

    /// What restoring one chapter group onto a canvas did: the windows
    /// now tiled here (the coordinator must observe them), the names of
    /// windows whose frame write was refused, and the windows the canvas
    /// released. No narration: the controller owns the chapter's story,
    /// and the canvas only supplies this primitive.
    struct ChapterRestore {
        struct Failure: Equatable {
            let handle: WindowHandle
            let name: String
        }

        var restored: [WindowID] = []
        var failures: [Failure] = []
        /// Windows the restore released: a refused re-tile forgets the
        /// record, so the coordinator forgets the id, death clock, and
        /// pending verification for them, exactly as it does for a tiling
        /// request's `forget`.
        var forget: [WindowID] = []
    }

    // MARK: Records

    /// Ensures `id` has a record on this canvas. The coordinator resolves
    /// the register and hands the window over before an action
    /// that needs its restore frame.
    mutating func attach(_ id: WindowID, handle: WindowHandle) {
        if records[id] == nil {
            beginRecord(id, handle: handle, frame: .zero)
        }
    }

    /// Creates a window's record and drops any deferred off-Space restore
    /// for its handle: the window is being tiled again, so the stale
    /// restore must never fire on the swipe back and yank it out of its
    /// new slot.
    private mutating func beginRecord(_ id: WindowID, handle: WindowHandle, frame: CGRect) {
        records[id] = WindowRecord(handle: handle, preTileFrame: frame)
        deferredRestores[handle] = nil
        deferredRequests[id] = nil
    }

    /// Drops any deferred pre-tile restore for `handle` on this canvas.
    mutating func discardDeferredRestore(for handle: WindowHandle) {
        deferredRestores[handle] = nil
    }

    func record(of id: WindowID) -> WindowRecord? { records[id] }

    func handle(of id: WindowID) -> WindowHandle? { records[id]?.handle }

    /// Whether this canvas still holds something a menu or bulk action
    /// must reach: occupants, or undo chapters whose windows can return.
    /// An orphaned record (a refused first placement) is not enough.
    var holdsAnything: Bool { !state.occupants.isEmpty || !undoStack.isEmpty }

    /// Whether `id` is currently expanded over the layout.
    func isExpanded(_ id: WindowID) -> Bool { expanded[id] != nil }

    /// What the expand toggle would do for `id` on this canvas: expand,
    /// retile into the slot it still holds, or return to its saved frame.
    func expandToggleState(of id: WindowID) -> ExpandToggleState {
        guard expanded[id] != nil else { return .expands }
        return state.slot(of: id).map(ExpandToggleState.returnsToSlot)
            ?? .returnsToPreviousFrame
    }

    /// Drops a window the convergence check judged silently ignored:
    /// occupancy and record go, nothing is written. The coordinator owns
    /// the narration and the death/verification bookkeeping.
    mutating func discard(window id: WindowID, context: Context) {
        forget(id, context: context)
    }

    // MARK: Placement

    /// One tiling request: `slot` for `requester`. Plans, commits,
    /// settles, and reflows; the canvas's own notice/error record what
    /// happened, and the returned `Outcome` carries the coordinator
    /// effects. The coordinator collapses an expanded requester before
    /// calling; a swap's expanded displaced window is collapsed here,
    /// between planning and committing, exactly where it always was.
    mutating func apply(slot: Slot, requester id: WindowID, context: Context) -> Outcome {
        // A new tiling request supersedes any retained expand/collapse
        // for this window: the user's last intent is the slot.
        deferredRequests[id] = nil
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
    /// records (the coordinator forgets its register entries), the cells the
    /// event freed reflow into one survivor, restored windows sit below
    /// the arrangement, a swap's displaced window takes focus, and the
    /// event is narrated, verified, and made undoable. One chapter per
    /// event, so a single Undo puts back everything this event displaced.
    private mutating func settle(
        _ decision: TilePlan, commit: Commit, requester id: WindowID,
        context: Context
    ) -> Outcome {
        var commit = commit
        var outcome = Outcome()
        if let placement = commit.failures.first(where: { $0.kind == .placement }) {
            // The requester's or displaced window's own write was refused:
            // the outcome names it for the announcement.
            outcome.result = .refused(windowName: placement.windowName)
        } else if commit.failures.contains(where: { $0.kind == .restore }) {
            // A restore-only failure carries no placement name: the
            // outcome stays `.placed` and the canvas's `error` speaks.
            outcome.result = .placed
        } else if commit.deferred {
            outcome.result = .deferred
        }
        // Restored-not-re-housed windows: untiled for good. A re-housed
        // window is the exception: it stayed tiled in the slot the
        // request left free, so its record and observation survive.
        outcome.forget = decision.windowsToRestore()
            .filter { !commit.rehoused.contains($0) }
        // A degraded swap's decision names nobody, but its eviction did
        // untangle a window: report it unless the fallback re-housed it.
        outcome.forget += commit.forgotten.filter { !commit.rehoused.contains($0) }
        // A refused placement releases the requester's record (see
        // `place`). Record presence is the ownership primitive, so the
        // coordinator must clear its handle-table entry too: a later
        // request then re-resolves the window from its live frame,
        // landing on whichever display it is actually on.
        if commit.requesterReleased {
            outcome.forget.append(id)
        }
        // The action's failures: the plan branch's own list plus whatever
        // its reflow pass refused. `commit.clean` stays the branch's
        // placement/restore verdict, so a failed reflow still leaves the
        // settled event's focus and verification rules unchanged.
        var actionFailures = commit.failures
        // Reflow: the cells the event freed (eviction remainders, the
        // requester's vacated tile) flow into the one survivor that
        // merges with them into a whole slot. Skipped when the placement
        // or a restore failed: the screen must agree with state before
        // anyone grows into it. The requester, the evicted, and expanded
        // windows never grow.
        var reflowSnapshot: [EvictedWindow] = []
        if commit.clean, let freed = commit.reflowFreed, !freed.isEmpty {
            // The re-housed window is the one "evictee" that stayed
            // tiled, so it may grow: it re-houses into the slot the
            // request left free, and the cells the requester vacated
            // reflow into it (a left two-thirds blocker of a left-third
            // request ends up as the right two-thirds, not the bare
            // middle third).
            let skip = Set(
                ([id] + decision.windowsToRestore())
                    .filter { !commit.rehoused.contains($0) })
            let reflow = reflow(freed, excluding: skip, context: context)
            reflowSnapshot = reflow.undoEntries
            actionFailures += reflow.failures
        }
        // Reflow can grow a re-housed window into a larger slot (the
        // left two-thirds blocker of a left-third request ends up as the
        // right two-thirds), so narrate only after it runs, with the slot
        // each window actually holds now. The chapter's re-housed set —
        // not the decision's restore list — is the source: a degraded swap
        // stays `.swap`, whose restore list is empty, and its fallback
        // still re-houses and still narrates.
        let homes = commit.rehoused.sorted().compactMap { wid -> (name: String?, slot: Slot)? in
            guard let finalSlot = state.slot(of: wid) else { return nil }
            return (name: appName(wid, context: context), slot: finalSlot)
        }
        if !homes.isEmpty {
            commit.notice = Self.rehouseNotice(homes: homes)
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
        if let message = Self.failureMessage(actionFailures) {
            self.error = message
        }
        if commit.clean {
            // Late convergence check: a silent ignore (gateway success,
            // app never moved) is invisible at write time, so verify one
            // verify-delay later via the echo trail; no extra AX traffic
            // on the hot path. Windows that converged, produced any frames,
            // or were re-written since are skipped; only total silence
            // rolls back. Cancelled by the next placement's scheduling
            // (a newer write supersedes) and by forget paths.
            outcome.verify = verificationWindows(for: decision, requester: id)
            outcome.verify.append(
                contentsOf: decision.windowsToRestore().filter { commit.rehoused.contains($0) })
        }
        outcome.observe = commit.observed
        // The reflow's survivors share the event's undo chapter: undo
        // restores the pre-event world in one ⌃⇧⌘Z (a move with no
        // eviction has no chapter of its own, so the reflow starts one).
        // A re-housed window that then grew carries two entries: keep
        // the first (its pre-event slot), or undo's last-write-wins
        // would park it in the intermediate re-house slot.
        var chapter = (commit.snapshot ?? []) + reflowSnapshot
        var seenHandles = Set<WindowHandle>()
        chapter.removeAll { !seenHandles.insert($0.handle).inserted }
        pushUndo(snapshot: chapter, requester: commit.requester)
        return outcome
    }

    /// Records a destructive outcome on the undo stack: keeps the
    /// freshest `undoDepth` recoveries, dropping the oldest. A new tiling
    /// action pushes; it never silently invalidates: depth, not amnesia,
    /// bounds the history.
    ///
    /// Every entry a canvas pushes is tagged with that canvas (`context`
    /// is the pushing canvas), so undo restores on the canvas that pushed;
    /// `TilingController.restoreChapter` still groups by tag so a legacy
    /// untagged entry lands on the canvas being undone. Chapters are
    /// in-memory only, so no cross-canvas tag exists today.
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
        case .tile: [id]
        case .swap(let displaced): [id, displaced]
        case .noop: []
        }
    }

    // MARK: Undo

    /// One chapter group's evictees return to this canvas: each survivor
    /// is committed into its slot and its frame written. The controller
    /// owns chapter restoration (it is the only holder of the canvas
    /// table), so this primitive narrates nothing and restores no
    /// requester. A refused re-tile keeps the slot the window visibly
    /// held before the undo (mirroring `place`); a window that was
    /// already untiled is forgotten. Every refusal is named in
    /// `failures`, so a partial failure can surface instead of hiding
    /// behind a success sentence. `retained` names slots a requester
    /// visibly kept after refusing to leave: entries overlapping one, or
    /// contradicting its layout, stay untiled rather than double-book it.
    mutating func restoreEvictees(
        _ group: [EvictedWindow], retained: [Slot] = [], context: Context
    ) -> ChapterRestore {
        var result = ChapterRestore()
        var retained = retained
        for entry in group {
            if retained.contains(where: {
                $0.overlaps(entry.slot) || $0.layout != entry.slot.layout
            }) {
                // The retained requester owns the cells this evictee would
                // return to. The evictee stays untiled, and the chapter's
                // story must name it: a successful requester otherwise
                // makes the undo look complete while this window is still
                // missing from its slot.
                result.failures.append(
                    ChapterRestore.Failure(
                        handle: entry.handle,
                        name: context.gateway.appName(of: entry.handle) ?? "A window"))
                continue
            }
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
            guard let record = records[id] else { continue }
            // Capture the transaction before the chapter overwrites the
            // record's pre-tile frame: rollback restores exactly this slot
            // and record when the re-tile is refused.
            var move = MoveAttempt(
                moving: id, into: entry.slot, in: self, space: entry.space)
            var updated = record
            updated.preTileFrame = entry.preTileFrame
            records[id] = updated
            // The shared write policy skips a frame the window already
            // holds (an untile-all chapter still at its pre-tile frames,
            // a settle the gateway applied late) and seeds the drag
            // baseline; a deferred off-Space write stands and reconciles
            // when the canvas becomes visible.
            if move.commit(in: &self, context: context).stands {
                // The re-place landed (or stands deferred): it claims the
                // handle, so every canvas's older deferred restore for it
                // is stale.
                discardDeferredRestore(for: entry.handle)
                context.discardDeferredRestores(entry.handle)
                result.restored.append(id)
            } else {
                // The re-tile was refused: name the window before any
                // record goes, then let the transaction restore the slot
                // it visibly holds or forget an already-untiled window.
                let name = appName(id, context: context) ?? "A window"
                let previous = move.from
                var reverseFailures: [Failure] = []
                move.rollback(
                    in: &self, context: context, failures: &reverseFailures)
                if let previous {
                    // The window still owns a slot on this canvas, so an
                    // older deferred restore elsewhere is stale even
                    // though this particular write was refused.
                    discardDeferredRestore(for: entry.handle)
                    context.discardDeferredRestores(entry.handle)
                    retained.append(previous)
                } else {
                    // The window never returned to this canvas. Its
                    // pre-tile restore on the canvas it came from stays
                    // live: do not claim or discard it on this refusal.
                    result.forget.append(id)
                }
                result.failures.append(
                    ChapterRestore.Failure(handle: record.handle, name: name))
                // A refused reverse write is part of the same window's
                // failure: the coordinator dedupes by handle, so the
                // chapter still names the window once.
                for failure in reverseFailures {
                    result.failures.append(
                        ChapterRestore.Failure(
                            handle: record.handle, name: failure.windowName))
                }
            }
        }
        return result
    }

    // MARK: Layout switch

    /// Switches this canvas to `target`, untiling everything first.
    ///
    /// The layout is a canvas choice, not an occupancy side effect. Every
    /// tiled window is restored to its pre-tile frame (an expanded window
    /// included, to the frame it had before tiling), the board empties,
    /// and the canvas adopts `target`. The snapshot is taken before the
    /// restores drop the records, in id order, so undo can put the whole
    /// pre-switch world back in one chapter. A zero-window switch pushes no
    /// chapter: the layout change itself is narrated but there is nothing
    /// destructive to reverse.
    mutating func switchLayout(to target: LayoutKind, context: Context) -> Outcome {
        guard target != state.layout else { return Outcome(result: .alreadyInLayout(state.layout)) }
        error = nil
        notice = nil
        let tiled = state.tiledWindows.sorted()
        let snapshot: [EvictedWindow] = tiled.compactMap { id in
            guard let slot = state.slot(of: id) else { return nil }
            return evictedEntry(for: id, slot: slot, space: context.space)
        }
        primeTracker(for: state.occupants, context: context)
        let failures = restore(tiled, context: context)
        adoptLayout(target)
        pushUndo(snapshot: snapshot, requester: nil)
        if let message = Self.failureMessage(failures) {
            error = message
        }
        notice = MenuText.switchedLayoutNotice(
            layout: target, untiled: tiled.count,
            undoable: !snapshot.isEmpty && snapshot.count == tiled.count)
        context.log("switchLayout -> \(target.rawValue) untiled=\(tiled.count)")
        return Outcome(
            result: .switched(layout: target, untiled: tiled.count),
            forget: tiled)
    }

    /// Adopts a layout on this canvas. Callers empty the board first:
    /// `TilingState.setLayout` is the only writer and refuses a non-empty
    /// board, so two layouts can never coexist.
    mutating func adoptLayout(_ new: LayoutKind) {
        state.setLayout(new)
    }

    // MARK: Plan branches

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
            var fallback = applyTile(
                .tile(evicting: [displaced]), requester: id,
                slot: slot, context: context)
            fallback.forgotten.append(displaced)
            return fallback
        }
        // Snapshot before any commit: each entry carries its window's
        // own former tile, so undo replays the swap backwards.
        let snapshot = [(displaced, displacedOriginal), (id, previous)].compactMap {
            (entryID, formerSlot) in
            snapshotEntry(for: entryID, fallback: formerSlot, space: context.space)
        }
        // Both windows move: any retained request each carried is
        // superseded by the swap.
        deferredRequests[displaced] = nil
        deferredRequests[id] = nil
        var displacedMove = MoveAttempt(
            moving: displaced, into: previous, in: self, space: context.space)
        // Capture the requester's attempt before the displaced window
        // occupies the requester's vacated tile: the swap deliberately
        // double-books that slot for one write, so reading its slot after
        // the displaced commit would find nil.
        var requesterMove = MoveAttempt(
            moving: id, into: slot, in: self, space: context.space)
        let displacedWrite = displacedMove.commit(in: &self, context: context)
        commit.observed.append(displaced)
        if displacedWrite == .refused {
            // The refused write moved nothing on screen: both attempts roll
            // back, and any refused reverse write joins the displaced
            // window's refusal. The displaced commit had already taken the
            // requester's vacated tile in state, so the requester's
            // occupancy must be restored alongside it.
            var failures = [
                placementFailure(for: displaced, slot: previous, context: context)
            ]
            displacedMove.rollback(in: &self, context: context, failures: &failures)
            requesterMove.rollback(in: &self, context: context, failures: &failures)
            context.log("swap FAILED displaced win\(displaced) -> \(previous.rawValue)")
            commit.failures = failures
            return commit
        }
        if displacedWrite == .deferredOffSpace { commit.deferred = true }
        let requesterWrite = requesterMove.commit(in: &self, context: context)
        commit.observed.append(id)
        if requesterWrite == .refused {
            // Roll the whole swap back: every reverse write the transaction
            // runs appends its own refusal, so the requester's refusal and
            // a failed home write are both named by the action's one
            // composed sentence.
            var failures = [
                placementFailure(for: id, slot: slot, context: context)
            ]
            requesterMove.rollback(in: &self, context: context, failures: &failures)
            displacedMove.rollback(in: &self, context: context, failures: &failures)
            commit.failures = failures
            context.log("place FAILED win\(id) -> \(slot.rawValue); swap rolled back")
            return commit
        }
        if requesterWrite == .deferredOffSpace { commit.deferred = true }
        // A swap untiles nobody, but it does move a window the user
        // didn't touch: the notice names it and its landing tile.
        let displacedName = appName(displaced, context: context) ?? "That window"
        commit.notice =
            "\(displacedName) moved to \(SlotPresentation.title(of: previous))"
                + " to make room." + MenuText.undoRecoveryHint
        commit.snapshot = snapshot
        commit.requester = id
        context.log(
            "swap win\(id) -> \(slot.rawValue), win\(displaced) -> \(previous.rawValue)")
        return commit
    }

    /// The tile branch: evict whoever overlaps, place the requester, and
    /// keep the windows in the way tiled — a lone evictee re-houses into
    /// the one whole slot the request left free, and a group of two or
    /// more mirrors to the other side. Hands the freed cells to settle,
    /// which owns the one reflow applier.
    private mutating func applyTile(
        _ decision: TilePlan, requester id: WindowID, slot: Slot, context: Context
    ) -> Commit {
        var commit = Commit()
        let evicted = decision.windowsToRestore()
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
        // come back to earth by untangling, not by moving. A group of two
        // or more reflects instead: every window in the way keeps its own
        // shape on the other side, so the request displaces nobody.
        var rehouse: [WindowID: Slot] = [:]
        if evicted.count == 1, !isExpanded(evicted[0]),
            let home = state.rehousingHome(
                evicting: evicted[0], for: slot, vacating: previous)
        {
            rehouse = [evicted[0]: home]
        } else if !evicted.contains(where: { isExpanded($0) }),
            let homes = state.mirroredHomes(evicting: evicted, for: slot, requester: id)
        {
            rehouse = homes
        }
        var snapshot = evicted.compactMap { evictedID in
            snapshotEntry(for: evictedID, fallback: slot, space: context.space)
        }
        // A tiled requester's vacated tile joins the chapter, exactly as
        // in a swap chapter: undo returns the requester to the slot it
        // vacated instead of releasing a window that was tiled before
        // the request. A fresh requester adds no entry: its undo is the
        // pre-tile restore. Capture the entry before the write, but add
        // it only if the requester actually moved; a refused move keeps
        // its old slot, so it displaced nobody.
        let requesterEntry = previous.flatMap {
            snapshotEntry(for: id, fallback: $0, space: context.space)
        }
        let restoreFailures = restore(
            evicted.filter { rehouse[$0] == nil }, context: context)
        let placement = place(
            window: id, into: slot, context: context, observed: &commit.observed)
        switch placement {
        case .noRecord:
            break
        case .refused(let failures, let released):
            commit.failures += failures
            commit.requesterReleased = released
        case .placed(let deferred):
            commit.deferred = deferred
        }
        // A restore refusal is its own failure now: it names the window
        // beside a refused placement instead of being dropped by
        // precedence.
        commit.failures += restoreFailures
        let clean = commit.clean
        if clean, let requesterEntry {
            snapshot.append(requesterEntry)
        }
        // Re-house commit: once the requester sits, each window that
        // stayed tiled moves into its home. The move only happens
        // when the requester's own placement landed: making room for a
        // request that failed would move a window for nothing, report
        // no destruction to undo, and promise an undo that cannot exist.
        // A refused re-house write falls back to the plain eviction for
        // that one window — its neighbours keep the halls they reached.
        // A refused fallback restore is a real failure: count it, and
        // keep the "went back" notice off the board.
        var restorationFailed = false
        for wid in evicted {
            guard let home = rehouse[wid] else { continue }
            guard clean else {
                let failures = restore([wid], context: context)
                commit.failures += failures
                if !failures.isEmpty { restorationFailed = true }
                context.log("rehouse SKIPPED win\(wid): requester placement failed")
                continue
            }
            deferredRequests[wid] = nil
            state.commit(window: wid, into: home)
            let write = applyLayout(for: wid, context: context, on: context.space)
            if write.stands {
                // A deferred off-Space write stands: the window keeps the
                // freed slot and reconciles when the canvas is visible.
                if write == .deferredOffSpace { commit.deferred = true }
                commit.rehoused.insert(wid)
            } else {
                let failures = restore([wid], context: context)
                commit.failures += failures
                // Sticky: a later window's landed restore must not turn
                // an earlier refusal back off and let the board claim
                // every window went back.
                if !failures.isEmpty { restorationFailed = true }
                context.log(
                    "rehouse FAILED win\(wid) -> \(home.rawValue); falling back to eviction")
            }
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
            // A re-house narrates itself in settle, after reflow can move
            // the victim again. The chapter is pushed even when the
            // requester's own write was refused: the evictees really did
            // go home, and without it that destruction would be silent
            // and unrecoverable. The requester joins the chapter only
            // when it actually landed.
            commit.snapshot = snapshot
            commit.requester = clean ? id : nil
            if !restorationFailed, commit.notice == nil, commit.rehoused.isEmpty {
                commit.notice = Self.evictionNotice(names: evictedNames, count: evicted.count)
            }
        }
        return commit
    }

    /// One refused write in an action: which window, what the action was
    /// trying to do, and the frame it meant to put there. The push layer
    /// appends every refusal to the action's list; `failureMessage`
    /// composes the canvas's one sentence, so no branch has to decide
    /// whether its failure outranks another.
    struct Failure: Equatable {
        enum Kind: Equatable {
            /// A named placement or swap write: "X couldn't be tiled".
            case placement
            /// A reflow or reassert batch write, counted rather than named.
            case move
            /// A pre-tile restore or a rollback's reverse write: the
            /// window may still sit in its old tile.
            case restore
        }

        let windowName: String
        let kind: Kind
        let frame: CGRect
    }

    /// The pair a plan branch commits and hands back: the canvas folds
    /// `error`/`notice` into its own readable state, `snapshot`/
    /// `requester`/`rehoused` into the undo chapter and verification, and
    /// `observed` into the coordinator effects.
    private struct Commit {
        var failures: [Failure] = []
        var notice: String?
        var snapshot: [EvictedWindow]?
        var requester: WindowID?
        var reflowFreed: Set<TileCell>?
        /// Windows that stayed tiled by re-housing: the request made room
        /// for them, so they keep their record and are never restored.
        var rehoused: Set<WindowID> = []
        var observed: [WindowID] = []
        /// A placement or re-house write was deferred off-Space: its
        /// state stands, so the event narrates the deferral rather than
        /// an app refusal.
        var deferred = false
        /// A refused first placement released the requester's record, so
        /// the coordinator must clear its handle-table entry too. The
        /// transaction reports this instead of making `settle` re-probe
        /// record presence.
        var requesterReleased = false
        /// Windows this branch untangled on a degraded path whose original
        /// decision (a swap) would not name them for forgetting.
        var forgotten: [WindowID] = []

        /// True when nothing failed: neither a placement write nor any
        /// restore or reflow write.
        var clean: Bool { failures.isEmpty }
    }

    /// What `place` did: the occupancy committed and the write landed (or
    /// deferred off-Space), the write was refused and rolled back, or the
    /// window had no record to place. `released` says a refused first
    /// tiling dropped the requester's record, so the coordinator learns it
    /// from the branch instead of re-reading record presence.
    private enum PlacementResult {
        case placed(deferred: Bool)
        case refused([Failure], released: Bool)
        case noRecord
    }

    /// One window's move in an action: the slot it leaves, the slot it
    /// takes, and the record to put back if the move is rolled back.
    /// `commit` owns the occupancy change and the forward write through the
    /// one policy; `rollback` owns the reverse write and appends its
    /// refusal to the action's failure list. Callers never write the
    /// reverse frame themselves and cannot drop its outcome.
    private struct MoveAttempt {
        let id: WindowID
        let from: Slot?
        let to: Slot
        let previousRecord: WindowRecord?
        /// The canvas the write targets. Nil is the display-less fallback
        /// of a legacy undo snapshot; everything else passes the action's
        /// canvas.
        let space: TilingSpaceKey?
        private var landing: FrameWriter.Result?

        init(
            moving id: WindowID, into to: Slot, in canvas: TilingSpace,
            space: TilingSpaceKey? = nil
        ) {
            self.id = id
            self.from = canvas.state.slot(of: id)
            self.to = to
            self.previousRecord = canvas.records[id]
            self.space = space
        }

        /// Commits the target occupancy and writes it through the shared
        /// policy. A window with no record still moves in state (the
        /// reflow batch's defensive case) but has no frame to write.
        @discardableResult
        mutating func commit(
            in canvas: inout TilingSpace, context: TilingSpace.Context
        ) -> FrameWriter.Result {
            canvas.state.commit(window: id, into: to)
            guard canvas.records[id] != nil else {
                landing = .skippedNoOp
                return .skippedNoOp
            }
            let result = canvas.applyLayout(
                for: id, context: context, on: space ?? context.space)
            landing = result
            return result
        }

        /// Restores the captured slot and record, then writes the reverse
        /// frame home when the forward write reached the gateway: a
        /// refusal can still be a partial write the app left behind, so
        /// the old frame is reasserted rather than trusted. A deferred
        /// write never touched the screen and needs no reverse. A refused
        /// reverse write appends itself to `failures`; the caller cannot
        /// discard it.
        mutating func rollback(
            in canvas: inout TilingSpace, context: TilingSpace.Context,
            failures: inout [Failure]
        ) {
            let reachedGateway = landing != nil && landing != .deferredOffSpace
            guard let from else {
                // A refused first tiling has no slot to return to: the
                // record goes with the occupancy.
                canvas.forget(id, context: context)
                return
            }
            canvas.state.commit(window: id, into: from)
            canvas.records[id] = previousRecord
            guard reachedGateway, canvas.records[id] != nil else { return }
            guard canvas.applyLayout(
                for: id, context: context, on: space ?? context.space) == .refused
            else { return }
            failures.append(
                Failure(
                    windowName: canvas.appName(id, context: context) ?? "A window",
                    kind: .restore,
                    frame: canvas.grid.rect(for: from, in: canvas.visibleFrame)))
        }
    }

    // MARK: Eviction narrative

    /// The re-house notice: the windows stayed tiled, so the notice names
    /// where they moved. Composed in `settle` after reflow, when every
    /// final slot is known. One window keeps its own sentence; two named
    /// windows each get a verb and a slot; anything else — a third window,
    /// or a name AX could not answer — falls back to a count, because a
    /// sentence with "That window" twice tells nobody where anything went.
    static func rehouseNotice(homes: [(name: String?, slot: Slot)]) -> String {
        guard let first = homes.first else { return "" }
        let head: String
        switch homes.count {
        case 1:
            let name = first.name ?? "That window"
            head = "\(name) moved to \(SlotPresentation.title(of: first.slot)) to make room."
        case 2 where homes.allSatisfy({ $0.name != nil }):
            head =
                "\(first.name!) moved to \(SlotPresentation.title(of: first.slot))"
                + " and \(homes[1].name!) moved to \(SlotPresentation.title(of: homes[1].slot))"
                + " to make room."
        case 2:
            head = "2 windows moved to the other side to make room."
        default:
            head = first.name.map {
                "\($0) and \(homes.count - 1) other windows moved to the other side to make room."
            } ?? "\(homes.count) windows moved to the other side to make room."
        }
        return head + MenuText.undoRecoveryHint
    }

    /// One snapshot entry per displaced window, captured before the
    /// restore deletes its record: the handle to find it again, the slot
    /// to return it to, the frame it held before tiling. `fallback` is
    /// the branch's requested slot, used when occupancy is already gone by
    /// capture time.
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
        return head + MenuText.undoRecoveryHint
    }

    /// A refused placement or swap write, named for the announcement and
    /// carrying the frame the branch meant to write.
    private func placementFailure(
        for id: WindowID, slot: Slot, context: Context
    ) -> Failure {
        Failure(
            windowName: appName(id, context: context) ?? "That window",
            kind: .placement,
            frame: grid.rect(for: slot, in: visibleFrame))
    }

    /// The one canvas sentence for an action's failures. Each kind speaks
    /// once: named placement refusals, counted batch moves, and named
    /// restores keep their own wording, and a second refusal cannot
    /// overwrite the first.
    static func failureMessage(_ failures: [Failure]) -> String? {
        guard !failures.isEmpty else { return nil }
        var sentences: [String] = []
        let placements = failures.filter { $0.kind == .placement }
        if !placements.isEmpty {
            sentences.append(
                placements.count == 1
                    ? refusalMessage(windowName: placements[0].windowName)
                    : refusalMessage(count: placements.count))
        }
        let moves = failures.filter { $0.kind == .move }
        if !moves.isEmpty {
            sentences.append(refusalMessage(count: moves.count))
        }
        let restores = failures.filter { $0.kind == .restore }
        if !restores.isEmpty {
            sentences.append(
                MenuText.restoreFailureMessage(restores.map(\.windowName)))
        }
        return sentences.joined(separator: " ")
    }

    // MARK: Placement helpers

    /// Places `id` into `slot`. A refusal rolls the occupancy back through
    /// the move transaction; a deferred off-Space write stands and is
    /// returned as such so the event narrates the deferral.
    private mutating func place(
        window id: WindowID, into slot: Slot,
        context: Context, observed: inout [WindowID]
    ) -> PlacementResult {
        guard var record = records[id] else { return .noRecord }
        var move = MoveAttempt(moving: id, into: slot, in: self)
        if move.from == nil {
            // First tiling: remember where to restore when untiled.
            // A window moving between overlapping slots (e.g. Left -> BottomLeft)
            // keeps its original pre-tile frame.
            record.preTileFrame = context.gateway.frame(of: record.handle) ?? record.preTileFrame
            records[id] = record
        }
        let result = move.commit(in: &self, context: context)
        observed.append(id)
        if result == .refused {
            // Name the window before the record (the only source of its
            // app name) can go, then let the move restore the slot or
            // forget a first tiling's record. A refused reverse write
            // joins the same action's list.
            var failures = [
                placementFailure(for: id, slot: slot, context: context)
            ]
            let released = move.from == nil
            move.rollback(in: &self, context: context, failures: &failures)
            if let previous = move.from {
                context.log(
                    "place FAILED win\(id) -> \(slot.rawValue); kept \(previous.rawValue)")
            } else {
                context.log("place FAILED win\(id) -> \(slot.rawValue)")
            }
            return .refused(failures, released: released)
        }
        // A deferred off-Space write is not a failure: the occupancy
        // stands and reconciles when the canvas becomes visible. Retain
        // the requested slot so the swipe-back reassert re-issues it,
        // exactly as a deferred reflow reconciles.
        if result == .deferredOffSpace {
            deferredRequests[id] = .slot
        }
        context.log("place win\(id) -> \(slot.rawValue)")
        return .placed(deferred: result == .deferredOffSpace)
    }

    /// Drops the window's record, expansion, tracker entries, and
    /// occupancy. Callers perform any frame write first; this only
    /// forgets. Shared by untiling, silent-ignore rollback, and untile-all.
    private mutating func forget(_ id: WindowID, context: Context) {
        records[id] = nil
        expanded[id] = nil
        deferredRequests[id] = nil
        context.tracker.forget(id)
        state.remove(window: id)
    }

    /// Restores the window's pre-tile frame and releases its slot, going
    /// through the one write policy every other push shares: a target the
    /// window already holds is skipped, and a canvas the user cannot see
    /// defers rather than writing blind. Returns false only when the
    /// gateway refused the write, so the caller can say so instead of
    /// silently leaving a stray window behind. A refused write normally
    /// releases the slot too; undo's fresh requester passes
    /// `keepingOccupancyOnRefusal` so the window stays the owner of the
    /// slot it visibly holds, mirroring `place`'s rollback. The
    /// coordinator's undo reuses this for the chapter's requester.
    @discardableResult
    mutating func restore(
        window id: WindowID, context: Context, keepingOccupancyOnRefusal: Bool = false
    ) -> Bool {
        var restored = true
        var refused = false
        if let record = records[id], record.preTileFrame != .zero {
            let result = context.frameWriter.write(
                id, handle: record.handle, to: record.preTileFrame,
                bounds: visibleFrame, on: context.space, check: .none)
            if result == .deferredOffSpace {
                // Deferred: nothing was written. Retain the restore so the
                // swipe-back reassert lands it once the canvas is visible.
                deferredRestores[record.handle] = DeferredRestore(
                    id: id, frame: record.preTileFrame)
            }
            restored = result.stands
            refused = result == .refused
        }
        if refused, keepingOccupancyOnRefusal { return false }
        forget(id, context: context)
        return restored
    }

    /// Restores every window in `ids`, returning one failure per refused
    /// pre-tile write. The frame is captured before the restore releases
    /// the record, so the failure carries the intent that did not land.
    private mutating func restore(_ ids: [WindowID], context: Context) -> [Failure] {
        var failures: [Failure] = []
        for evicted in ids {
            let name = appName(evicted, context: context) ?? "A window"
            let frame = records[evicted]?.preTileFrame ?? .zero
            if !restore(window: evicted, context: context) {
                failures.append(
                    Failure(windowName: name, kind: .restore, frame: frame))
            }
        }
        return failures
    }

    /// One reconcile pass over a map of deferred work: attempt every
    /// entry through `write` and keep only the ones still held off-Space,
    /// dropping the rest. A landed write is done; a refused one is
    /// recorded by the `write` closure (which owns the message). The one
    /// skeleton shared by the deferred-restore and deferred-request
    /// reconciles, so neither can drift on what a deferral retains.
    private static func reconcile<Key: Hashable, Value>(
        _ pending: [Key: Value],
        write: (Key, Value) -> FrameWriter.Result
    ) -> [Key: Value] {
        var remaining: [Key: Value] = [:]
        for (key, value) in pending where write(key, value) == .deferredOffSpace {
            remaining[key] = value
        }
        return remaining
    }

    /// Writes every deferred off-Space pre-tile restore now that the
    /// canvas is visible, then drops it: the restore's intent stands and
    /// lands here, exactly as a deferred reflow lands on the reassert. A
    /// canvas still hidden defers it again; a genuine refusal narrates
    /// the shared restore-failure message. The window is already untiled,
    /// so its tracker entry is cleared after the write (no phantom
    /// expectation).
    private mutating func reconcileDeferredRestores(context: Context) {
        guard !deferredRestores.isEmpty else { return }
        var failures: [String] = []
        // A window that died while parked can never land its restore:
        // writing against its released handle reads as an app refusal and
        // the notice would name a window the user closed. Drop it here,
        // where the death becomes visible, instead of narrating a ghost.
        let pending = deferredRestores.filter {
            context.gateway.liveness(of: $0.key) != .dead
        }
        deferredRestores = Self.reconcile(pending) { handle, restore in
            let result = context.frameWriter.write(
                restore.id, handle: handle, to: restore.frame,
                bounds: visibleFrame, on: context.space, check: .none)
            context.tracker.forget(restore.id)
            if result == .refused {
                failures.append(context.gateway.appName(of: handle) ?? "A window")
            }
            return result
        }
        if !failures.isEmpty {
            error = MenuText.restoreFailureMessage(failures)
        }
    }

    /// Re-issues every retained slot/expand request now that the canvas is
    /// visible, dropping each as it lands: the deferred-intent half of the
    /// swipe-back reassert, mirroring `reconcileDeferredRestores`. A
    /// canvas still hidden defers the request again; a genuine refusal
    /// narrates the shared message. An expand lands by writing the screen
    /// frame and recording `expanded[id]`, so the plan that follows leaves
    /// the covering window where it is.
    private mutating func reconcileDeferredRequests(context: Context) {
        guard !deferredRequests.isEmpty else { return }
        // The record is the ownership primitive: a request whose window
        // left this canvas is stale and simply dropped.
        let pending = deferredRequests.filter { records[$0.key] != nil }
        var failures = 0
        deferredRequests = Self.reconcile(pending) { id, request in
            switch request {
            case .slot:
                return applyLayout(for: id, context: context, on: context.space)
            case .expand(let saved):
                let result = writeExpandedFrame(id, to: visibleFrame, context: context)
                if result == .written || result == .skippedNoOp {
                    expanded[id] = saved
                }
                if result == .refused { failures += 1 }
                return result
            case .collapse(let frame):
                let result = writeExpandedFrame(id, to: frame, context: context)
                if result == .refused { failures += 1 }
                return result
            }
        }
        if failures > 0 {
            error = Self.refusalMessage(count: failures)
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

    /// What one reflow pass produced: the undo entries for survivors that
    /// moved, plus every refused write in the batch. A failed pass rolls
    /// all survivors back and returns no undo entries; its failures still
    /// travel to the action that triggered it.
    struct ReflowResult {
        var undoEntries: [EvictedWindow] = []
        var failures: [Failure] = []
    }

    /// Applies reflow on this canvas after a tiled window left it or
    /// freed cells by moving: the one survivor whose cells merge with
    /// the freed cells into a whole slot moves into it, the rightmost
    /// candidate winning ties (see `TilingState.reflow`). Callers have
    /// already removed the leaving window; the requester, evicted, and
    /// expanded windows never grow (the expanded exclusion lives here
    /// now, not with the pure rule). A hole no survivor merges into
    /// exactly stays empty. Refused writes roll every survivor back
    /// through the move transaction and return their failures, so state
    /// and screen never disagree about who holds the freed cells.
    ///
    /// Returns the undo entries for the survivors that moved: callers
    /// fold them into the triggering event's undo chapter, or start one
    /// when the reflow stands alone.
    @discardableResult
    mutating func reflow(
        _ freed: Set<TileCell>, excluding: Set<WindowID> = [], context: Context
    ) -> ReflowResult {
        guard !freed.isEmpty else { return ReflowResult() }
        // Expanded windows keep covering the layout; they never grow.
        let skip = excluding.union(
            Set(state.occupants.filter { expanded[$0.value] != nil }.map(\.value)))
        let placements = state.reflow(freed: freed, excluding: skip)
        guard !placements.isEmpty else { return ReflowResult() }
        // One transaction per survivor: commit writes the grown slot, and
        // rollback owns the old rect when the batch must return to its
        // pre-reflow state.
        var moves: [MoveAttempt] = []
        for (wid, target) in placements.sorted(by: { $0.key < $1.key }) {
            guard state.slot(of: wid) != nil else { continue }
            moves.append(
                MoveAttempt(
                    moving: wid, into: target, in: self, space: context.space))
        }
        guard !moves.isEmpty else { return ReflowResult() }
        // A hidden canvas's survivors grow in state now but are written
        // when the user swipes back: sizing an off-Space window can move
        // it onto the visible Space, which would break the independence
        // the layout exists to provide. The FrameWriter defers those
        // writes and marks the canvas stale for the swipe back.
        var failures: [Failure] = []
        for index in moves.indices {
            guard moves[index].commit(in: &self, context: context) == .refused
            else { continue }
            failures.append(
                Failure(
                    windowName: appName(moves[index].id, context: context) ?? "A window",
                    kind: .move,
                    frame: grid.rect(for: moves[index].to, in: visibleFrame)))
        }
        if !failures.isEmpty {
            // The batch is all-or-nothing: every survivor returns to the
            // slot it held, and every forward write that reached the
            // gateway is reversed. A refused reverse write joins the same
            // list instead of being discarded.
            for index in moves.indices {
                moves[index].rollback(
                    in: &self, context: context, failures: &failures)
            }
            return ReflowResult(failures: failures)
        }
        context.log("reflow \(moves.map { "win\($0.id)->\($0.to.rawValue)" }.joined(separator: ", "))")
        return ReflowResult(
            undoEntries: moves.compactMap { move in
                move.from.flatMap {
                    evictedEntry(for: move.id, slot: $0, space: context.space)
                }
            })
    }

    /// One push pass through the shared write policy: the pairs the
    /// gateway actually wrote, which the reassert reads back as achieved
    /// frames, plus every refused write for the action's failure list. A
    /// deferred (off-Space) write is not a failure: the FrameWriter has
    /// already marked the canvas stale and the pushed state stands for
    /// reconciliation when the canvas becomes visible — the placement
    /// path's contract, read through the same `Result.stands`.
    private struct WritePass {
        var written: [(id: WindowID, target: CGRect)] = []
        var failures: [Failure] = []
    }

    /// Performs one push through the shared write policy, collecting each
    /// refusal with the frame it meant to write. The caller composes the
    /// canvas error once for the action.
    private func writeRects(_ rects: [WindowID: CGRect], context: Context) -> WritePass {
        var pass = WritePass()
        for (id, target) in rects {
            guard let record = records[id] else { continue }
            let result = context.frameWriter.write(
                id, handle: record.handle, to: target, bounds: visibleFrame,
                on: context.space, check: .rollback)
            switch result {
            case .written: pass.written.append((id: id, target: target))
            case .refused:
                pass.failures.append(
                    Failure(
                        windowName: appName(id, context: context) ?? "A window",
                        kind: .move, frame: target))
            case .skippedNoOp, .deferredOffSpace: break
            }
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
            // No slot: not tiled, so any record the window still wears is
            // stale ownership. Drop it: a record exists only while the
            // window is tiled, and the coordinator clears its handle
            // table through the outcome.
            forget(id, context: context)
            return Outcome(result: .nothingToEvict, forget: [id])
        }
        return untile(window: id, reflowing: true, context: context)
    }

    /// Releases a window with no frame write: the untile path without the
    /// restore (the window is gone or is leaving this canvas), reflowing
    /// its freed cells and pushing the survivor chapter. The coordinator's
    /// prune and destroy paths call this once the death standard agrees;
    /// it also releases a live record another canvas is about to claim, so
    /// a handle never resolves to two canvases at once.
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
        let reflow = reflow(slot?.cells ?? [], context: context)
        pushUndo(snapshot: reflow.undoEntries, requester: nil)
        if let message = Self.failureMessage(reflow.failures) {
            error = message
        }
        return Outcome(forget: [id], raise: true)
    }

    /// Prime the tracker's intent for the slot rects a following undo will
    /// write: the live frames are pre-tile settle frames, and the diff must
    /// measure against where we're going, not where the restore just put
    /// us. Without this the undo's own writes read as a user drag and the
    /// grid moves under them. Shared by untile-all and the layout switch.
    private func primeTracker(
        for occupants: [Slot: WindowID], context: Context
    ) {
        for (slot, id) in occupants where records[id] != nil {
            let target = grid.rect(for: slot, in: visibleFrame)
            context.tracker.markExpected(id, target)
        }
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
            notice = "Untiled \(noun)." + MenuText.undoRecoveryHint
            primeTracker(for: chapter, context: context)
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
                // deferred off-Space restore so the swipe back still lands it.
                records[fresh] = WindowRecord(handle: handle, preTileFrame: frame)
                outcome.observe.append(fresh)
                snapshot.append(EvictedWindow(
                    handle: handle, slot: slot, preTileFrame: frame, space: context.space))
            }
            if snapshot.isEmpty {
                // Every frame read failed (the AX-unreadable
                // transient): nothing can be restored, so the
                // placeholder chapter goes. A "Restore 0 Windows"
                // row would offer an undo that can only report
                // failure.
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
        // A fresh toggle supersedes any request already retained for this
        // window.
        deferredRequests[id] = nil
        let result = writeExpandedFrame(id, to: target, context: context)
        switch result {
        case .written, .skippedNoOp:
            // The expansion landed: an edge drag that never reached
            // mouse-up is stale, and its release must not reconcile the
            // splitters from the screen-sized frame.
            context.tracker.clearPendingReassert(id)
            expanded[id] = current
            context.log("expand win\(id) -> \(target)")
            return Outcome()
        case .deferredOffSpace:
            // The canvas is not visible: retain the expansion so the
            // swipe-back reassert issues it, and narrate the deferral —
            // never an app refusal (the app did nothing wrong).
            deferredRequests[id] = .expand(saved: current)
            return Outcome(result: .deferred)
        case .refused:
            error = Self.refusalMessage(count: 1)
            return Outcome(result: .expandRefused(windowName: appName(id, context: context)))
        }
    }

    /// Unexpands `id`, recording the refusal on this canvas and returning
    /// it through the outcome. The coordinator announces the refusal for
    /// a pressed toggle; `apply` folds it in at its own precedence
    /// (a tiling request's refusal overwrites it, exactly as before).
    @discardableResult
    mutating func collapseExpanded(_ id: WindowID, context: Context) -> Outcome {
        guard let saved = expanded[id] else { return Outcome() }
        expanded[id] = nil
        error = nil
        notice = nil
        // A fresh toggle supersedes any request already retained for this
        // window.
        deferredRequests[id] = nil
        var result: FrameWriter.Result?
        let tiled = state.slot(of: id) != nil
        if tiled {
            result = retileExpanded(id, context: context)
        } else if records[id] != nil {
            result = writeExpandedFrame(id, to: saved, context: context)
        }
        guard let result else { return Outcome() }
        switch result {
        case .written, .skippedNoOp:
            // A landed collapse supersedes a stale edge drag exactly as an
            // expansion does.
            context.tracker.clearPendingReassert(id)
            if !tiled {
                context.log("collapse win\(id) -> saved \(saved)")
            }
            return Outcome()
        case .deferredOffSpace:
            // The canvas is not visible: retain the collapse so the
            // swipe-back reassert issues it. A tiled collapse re-tiles
            // into its committed slot; an untiled one returns to the
            // saved frame.
            if state.slot(of: id) != nil {
                deferredRequests[id] = .slot
            } else {
                deferredRequests[id] = .collapse(frame: saved)
            }
            return Outcome(result: .deferred)
        case .refused:
            error = Self.refusalMessage(count: 1)
            return Outcome(result: .expandRefused(windowName: appName(id, context: context)))
        }
    }

    /// Re-applies an expanded window's slot rect after collapse; the
    /// write result comes back for the caller to fold. Nil when the
    /// window's record or slot is already gone: nothing was written.
    /// Uses the canvas's own grid directly, not plan execution: the
    /// window never left its slot, so there is nothing to restore or
    /// evict.
    private func retileExpanded(_ id: WindowID, context: Context) -> FrameWriter.Result? {
        guard records[id] != nil, let slot = state.slot(of: id) else { return nil }
        let target = grid.rect(for: slot, in: visibleFrame)
        let result = writeExpandedFrame(id, to: target, context: context)
        context.log("retile expanded win\(id) -> \(slot.rawValue) target=\(target)")
        return result
    }

    /// One expected frame write via the gateway: the shared shape of the
    /// expand, collapse, and retile writes. Expansion has no rollback
    /// path of its own, so it declares no convergence check. Returns the
    /// shared write policy's result, so expand, collapse, and the
    /// swipe-back reconcile read a deferral and a refusal exactly as
    /// `applyLayout` and the reflow push do.
    private func writeExpandedFrame(
        _ id: WindowID, to target: CGRect, context: Context
    ) -> FrameWriter.Result {
        // Every caller holds the record. A missing one is not a deferral
        // (there is no canvas to wait for), so refuse rather than claim an
        // intent that stands; `.refused` rolls back instead of parking a
        // request that would reconcile forever.
        guard let record = records[id] else { return .refused }
        // The shared write policy: the off-Space guard defers a hidden
        // canvas (the caller retains the toggle for the swipe-back
        // reassert), and a no-op target counts as success without a write.
        return context.frameWriter.write(
            id, handle: record.handle, to: target, bounds: visibleFrame,
            on: context.space, check: .none)
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
        notice = MenuText.splittersRestoredAnnouncement()
        return reassert(.grid, context: context)
    }

    /// The number of tiled windows on this canvas: the scope the
    /// focused-canvas menu rows act on.
    var tiledCount: Int { state.occupants.count }

    /// Whether a splitter backup is parked: drives the menu row title
    /// ("Reset Splitters" vs "Restore Previous Splitters").
    var hasSplitterBackup: Bool { splitterBackup != nil }

    /// Count for the undo menu title: the freshest chapter's displaced
    /// windows, or 0 when no chapter is parked. Named for the undo model,
    /// not eviction: a swap chapter displaces without untiling anyone.
    var displacedCount: Int { undoStack.last?.snapshot.count ?? 0 }

    /// Whether the last chapter has anything to restore. Menu visibility
    /// and the row's count are one fact, so an empty placeholder chapter
    /// can never show a "Restore 0 Displaced Windows" row.
    var canUndoDisplacement: Bool { displacedCount > 0 }

    // MARK: Reassert

    /// The trigger for one reassert. A small sum type, not a request
    /// object: `.resize` is an edge drag's reassert (the app's achieved
    /// frame is authoritative), `.grid` is every path that already knows
    /// its splitters are right (display change, swipe back, splitter
    /// reset, title-bar snapback). No scope set and no convergence knob:
    /// the coordinator's mouse-up wires `.resize`, and a
    /// future overlay-handle gesture would add its own case, not a
    /// speculative one now.
    enum ReassertSource: Equatable {
        /// An edge resize settled: reconcile the dragged window's
        /// splitters back to the edge the app actually achieved, then map
        /// every rect under the reconciled grid. A nil achieved frame is
        /// the unreadable transient: keep the splitters as stored and
        /// still map every rect, so neighbours never go stale.
        case resize(dragged: WindowID, achieved: CGRect?)
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
    /// window actually landed. An expanded dragged window is excluded:
    /// its achieved frame covers the screen by definition, and a stale
    /// edge drag that survived an Expand must never reconcile the
    /// splitters (or the neighbours) from that frame. The two-thirds
    /// hidden-splitter rule is the grid's own, shared with the live drag
    /// loop.
    private func reconciledGrid(_ source: ReassertSource) -> GridLayout {
        guard case .resize(let dragged, let achieved) = source,
            let achieved,
            expanded[dragged] == nil,
            let slot = state.slot(of: dragged)
        else { return grid }
        let occupied = Set(state.occupants.keys)
        var reconciled = grid
        for edge in TileEdge.allCases {
            reconciled.update(
                edge: edge, of: slot, toPosition: edge.position(in: achieved),
                in: visibleFrame, occupants: occupied)
        }
        return reconciled
    }

    /// The effectful half: store the reconciled splitters, write every
    /// rect through the one write policy (which seeds the drag loop's
    /// diff baseline for any write it cannot arm an echo for), then
    /// reconcile each *written* occupant's achieved edge back onto the
    /// splitter it rides. A
    /// degenerate visible frame has no rects to derive, so nothing is
    /// stored or written.
    @discardableResult
    mutating func reassert(_ source: ReassertSource, context: Context) -> Outcome {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            context.log("reassert skipped: degenerate visibleFrame \(visibleFrame)")
            return Outcome()
        }
        // A deferred pre-tile restore lands here, on the swipe back that
        // reasserts this canvas: the deferred window was never written
        // blind, and its frame is restored now that the canvas is visible.
        reconcileDeferredRestores(context: context)
        // A deferred placement or expand/collapse lands here too: its
        // intent was retained, and re-issuing it now that the canvas is
        // visible is what makes the swipe back honour the request.
        reconcileDeferredRequests(context: context)
        var plan = reassertPlan(source)
        grid = plan.grid
        var failures: [Failure] = []
        var pass = writeRects(plan.rects, context: context)
        failures += pass.failures
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
            pass = writeRects(plan.rects, context: context)
            failures += pass.failures
        }
        // Refusals land on the canvas whose windows refused, not on
        // whatever happens to be focused when the menu is next read.
        if let message = Self.failureMessage(failures) {
            error = message
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

    /// Reconciles every written occupant's achieved edge back onto the
    /// splitter that edge rides, returning whether any splitter moved.
    /// An app that rounds or insets a programmatically-written frame can
    /// leave a neighbour short of the splitter, opening a gap; the
    /// achieved edge is authoritative, exactly as the dragged window's
    /// is, so the splitter follows it and the tiles abut. An edge on a
    /// screen edge has no boundary (fixed) and is left alone: the
    /// residual an app cannot remove lands there, never between tiles.
    /// A window whose app *floor* refused the requested shrink grew past
    /// its target instead of falling short; it keeps its floor where it
    /// stands and the splitter stays where the drag put it, so the two
    /// windows overlap rather than the drag being pulled back by a size
    /// the neighbour cannot give up. The readback is the one effect the
    /// pure plan cannot perform, so it lives here, in the effectful half.
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
            // The clamp signature is a size the app grew past the target
            // on that axis: only a floor refuses a shrink. A window that
            // landed smaller fell short (rounded or inset) and its edge
            // still owns the splitter.
            let floorClampedWidth =
                achieved.width - entry.target.width > DragTracker.noOpWriteTolerance
            let floorClampedHeight =
                achieved.height - entry.target.height > DragTracker.noOpWriteTolerance
            for edge in TileEdge.allCases {
                let floorClamped =
                    edge == .left || edge == .right ? floorClampedWidth : floorClampedHeight
                guard !floorClamped else { continue }
                let target = edge.position(in: entry.target)
                let landed = edge.position(in: achieved)
                guard abs(landed - target) > DragTracker.noOpWriteTolerance
                else { continue }
                if reconciled.update(
                    edge: edge, of: slot, toPosition: landed,
                    in: visibleFrame, occupants: occupied)
                {
                    changed = true
                }
            }
        }
        grid = reconciled
        return changed
    }

}
