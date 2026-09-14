# Controller state machine and plan execution — audit findings

## Summary

Reviewed `TilingController.swift` (1719 lines) and `PlanExecutor.swift` (622 lines) statically against `CONTEXT.md`/`README.md`, plus the gateway seam and the controller-level tests. Two High findings: undoing a layout-switch chapter can leave a canvas holding two layouts at once (the codebase's own `assertHealthy` calls that state "mixed layouts on screen"), and a refused placement can publish "Press ⌃⌥⇧⌘Z to undo" while no undo chapter exists. Four Medium and four Low findings follow; the rest of the slice (main-thread discipline, closure ownership, per-canvas isolation, expand bookkeeping, the swap branch's rollback) held up.

## Findings

### F1 — Undo of a layout-switch chapter restores into a slot of a layout the canvas no longer runs, producing a two-layout occupancy where `activeLayout` is arbitrary [High | High | code-defect]
- Location: `Sources/tiled/TilingController.swift:1002` (pop + unwind), `Sources/tiled/PlanExecutor.swift:421` (blind re-commit), `Sources/tiled/Layout.swift:490-491,501`
- Evidence:
```swift
// PlanExecutor.swift:421 — undo commits the snapshot slot with no layout check
state.commit(window: id, into: entry.slot)
// Layout.swift:490-491 — activeLayout is *derived* from occupancy
var activeLayout: LayoutKind {
    occupantBySlot.keys.first.map(\.layout) ?? .sixths
// Layout.swift:501 — and drives the cross-layout switch decision
if !occupantBySlot.isEmpty, slot.layout != activeLayout {
```
- Trigger (all through the controller, single canvas, no other actions in between):
  1. `W` tiles `.topLeft`, `Z` tiles `.bottomRight` (quarters; no eviction → no chapter).
  2. `W` requests `.sixthLeft` → `switchLayout(evicting: [W,Z])` → `windowsToRestore(requester: W)` restores `Z`, `W` lands in `.sixthLeft`; `settle` pushes chapter `[Z→.bottomRight] + requester W` (`TilingController.swift:462-465`).
  3. `V` tiles `.sixthTopRight` — plain tile, no eviction, so **no chapter is pushed** and the switch chapter is still on top.
  4. ⌃⌥⇧⌘Z → `undoRestoreWindow(W)` untiles the requester, then `executor.undo` commits `Z` into `.bottomRight`.
  Occupancy is now `{.sixthTopRight: V, .bottomRight: Z}` — a sixths slot and a quarters slot in one canvas.
- Impact: `TilingState.activeLayout` becomes `occupantBySlot.keys.first`, i.e. hash-order arbitrary for a two-layout occupancy (and it can change as the map is mutated). It feeds the status glyph (`AppDelegate.swift:200`), the menu's "Layout:" line and *which slot rows exist* (`MenuModel.swift:171: if snapshot.activeLayout == .quarters {`), and `plan`'s switch test (`Layout.swift:501`). So from one state, the same slot hotkey either tiles one window or untiles every tiled window on the canvas, depending on which layout `.first` happens to report. `LayoutSwitchTests.assertHealthy` (line 99-102) explicitly treats this state as unhealthy: `XCTAssertLessThanOrEqual(layouts.count, 1, "\(context): mixed layouts on screen")` — no controller-level test applies that invariant to undo.
- Fix (smallest): in `undoLastDisplacement`'s pre-loop (`TilingController.swift:1017-1024`), also untile occupants whose slot layout differs from the layout of the entries being restored — the loop already exists to make room; it just needs the layout dimension. Alternatively store the canvas's layout in `CanvasState` and have undo restore it.

### F2 — A refused placement after a successful re-house publishes "Press ⌃⌥⇧⌘Z to undo" with no chapter behind it [High | High | code-defect]
- Location: `Sources/tiled/PlanExecutor.swift:340-352`, `Sources/tiled/TilingController.swift:420,462-465`
- Evidence:
```swift
// PlanExecutor.swift:340-352 — runs even when placeResult.error != nil
if let (wid, home) = rehouse {
    state.commit(window: wid, into: home)
    if applyLayout(for: wid, ...) {
        outcome.rehoused = wid
        outcome.notice =
            "\(name) moved to \(SlotPresentation.title(of: home)) to make room. "
                + "Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."
```
The snapshot is gated separately, two `if` blocks later:
```swift
// PlanExecutor.swift:369-376
if placeResult.error == nil, restoreFailures.isEmpty, !evicted.isEmpty {
    outcome.snapshot = snapshot
```
- Trigger: sixths canvas with `b` `.sixthBottomLeft`, `m` `.sixthMiddle`, `r` `.sixthRight` (the layout of `ReflowTests.testRightThirdToRightTwoThirdsReHousesMiddleThird`, line 493). Focus `r`, then `gateway.refuseNextWrites(rHandle)` (the fake's stand-in for the documented "apps that refuse programmatic resizing"), then `controller.handle(slot: .sixthsRightTwoThirds)`. `place(r)` fails → `outcome.error` set, `outcome.snapshot == nil`; the re-house block still commits `m` into `.sixthTopLeft` and sets the notice. `settle` computes `chapter = (nil) + []` and `pushUndo` bails, so the stack is untouched.
- Impact: the menu renders both rows (`MenuModel.swift:132-133` tileError, `159-160` notice): "TestApp couldn't be tiled: the app refused to resize it." next to "TestApp moved to Top Left Sixth to make room. Press ⌃⌥⇧⌘Z to undo." The undo either answers `.nothingToUndo` ("Nothing to undo") or, if an older chapter is on the stack, **undoes that unrelated older event** — the app's own promise is false, and `m`'s displacement has no receipt. No test covers the re-house + refused-place combination.
- Fix: only set `outcome.notice`/`outcome.rehoused` when `placeResult.error == nil && restoreFailures.isEmpty` (i.e. wrap the re-house block's notice in the same condition as the snapshot), or push the re-house move as its own chapter.

### F3 — `lastTileError` is written to the focused canvas but raised/cleared by the acting canvas, so a refusal can be attributed to the wrong canvas, suppressed, or silently dropped [Medium | High | code-defect]
- Location: `Sources/tiled/TilingController.swift:102-104` (setter), `913-916`, `596`, `636`
- Evidence:
```swift
// TilingController.swift:102-104 — every write goes to the *focused* canvas
private(set) var lastTileError: String? {
    get { focusedCanvas().error }
    set { mutateSpace(focusedSpaceKey()) { $0.error = newValue } }
}
// TilingController.swift:913-916 — the check is focused-canvas too
private func reportRestoreFailures(_ failures: [String]) {
    guard !failures.isEmpty, lastTileError == nil else { return }
    lastTileError = MenuText.restoreFailureMessage(failures)
```
- Trigger: two displays, focus on display 1, canvas A. Pick the manage-list row for a window on display 2 (rows come from `allTiledWindowsInfo`, all visible canvases) → `untile(window:)` acts on canvas B (`let space = spaceOf(window: id) ?? focusedSpaceKey()`, line 1337) → the restore is refused → the message is stored on **canvas A**. `applyAll(on: B)`/`pushRects` refusals (lines 596, 636) do the same for `resetDividers(on: B)` and stale reasserts.
- Impact: three observable failures of the "state and screen never silently disagree" promise: (a) if focus moves to display 2 before the menu is next read, the row is gone — the refusal is never shown; (b) an unrelated pre-existing error on canvas A makes `reportRestoreFailures` drop canvas B's new refusal entirely; (c) clearing is scoped to the acting canvas (`mutateSpace(key) { $0.error = nil ... }`, line 365; also `untile`, `handleEvict`, `untileAll`, `undo`), so a stale refusal stays in the menu while the user keeps acting on the canvas that caused it. `lastNotice`'s setter has the identical shape and is dead code (never assigned anywhere in `Sources/`).
- Fix: give the refusal paths the canvas they acted on — e.g. `private func setError(_ message: String?, on space: TilingSpaceKey)` and pass `space` from `untile`/`applyAll`/`resetDividers`/`pushRects` (the tracker's apply closure already resolves `spaceOf(window:)`); or delete the setters and write `mutateSpace(space)` at the call sites.

### F4 — A refused placement after successful evictions untiles the evictees with no notice and no undo chapter (rollback incompleteness) [Medium | High | design-risk]
- Location: `Sources/tiled/PlanExecutor.swift:325-331,369-380`, `Sources/tiled/PlanExecutor.swift:178-190` (same shape in the switch branch)
- Evidence:
```swift
// PlanExecutor.swift:325-331 — restores happen before the requester is written
let restoreFailures = restore(
    evicted.filter { $0 != rehouse?.window },
    state: &state, records: &records, tracker: execution.tracker)
let placeResult = place(
    window: id, into: slot, ...)
```
- Trigger: quarters canvas, `W` at `.topLeft`, `Z` at `.topRight`; focus a new window `X` and press ⌥⇧⌘J (`.leftHalf`) with `X`'s app refusing the resize → `plan` yields `.tile(evicting: [W])`; `applyTile` restores `W` (its frame write succeeds, record dropped), `place(X)` fails, `outcome.snapshot` stays nil, `outcome.reflowFreed` stays nil.
- Impact: `W` visibly pops out of its tile, and the only menu row is `X`'s refusal — no eviction notice (that uses the same `!evicted.isEmpty` + `error == nil` gate, lines 369-380), no reflow (`TilingController.swift:420` requires `outcome.error == nil`), no ⌃⌥⇧⌘Z chapter. The user's window lost its tiling to a request that failed. Contrast `applySwap`, whose comment (`PlanExecutor.swift:206-208`) states the opposite guarantee: "The displaced window moves first, so a refusal anywhere leaves every window where it started." One existing test pins "no undo when the switch didn't cleanly land" for the *restore-refused* case (`PlanExecutorTests.testRestoreFailureLosesToNothingButWinsOverSilence`, line 336), so the intended fix here is at minimum to narrate the destruction and keep it undoable.
- Fix: on `placeResult.error != nil`, re-commit the snapshot entries into their slots and rewrite their slot rects (the working state still has the old slots in `snapshot`), so a refused request is a no-op for everyone; if that write is refused too, fall through to today's behavior but push the snapshot as a chapter and set the eviction notice.

### F5 — RISK: the expand/collapse/retile writes are the only frame writes that skip the off-Space (`isVisible`) guard [Medium | Medium | design-risk]
- Location: `Sources/tiled/TilingController.swift:1441-1500` (`expand`, `collapseExpanded`, `retileExpanded`, `writeExpandedFrame`) vs. `608-619` (`pushRects`), `1363-1410` (`reflow`), `800-802` (`raiseOccupants`)
- Evidence:
```swift
// TilingController.swift:615-619 — every other write path defers
if let windowSpace = spaceOf(window: id), !isVisible(windowSpace) {
    staleSpaces.insert(windowSpace)
    dbg("push win\(id) deferred off-Space")
    continue
}
// TilingController.swift:1494-1497 — expand's write has no such check
guard let record = records[id] else { return false }
tracker.markExpected(id, target)
if gateway.setFrame(record.handle, to: target) { return true }
```
- Trigger (needs a live premise I cannot settle statically): `handleExpandToggle` resolves `id` from `gateway.focusedWindow()`, and `collapseExpanded` can also be invoked for a *swap's* displaced window (`handle(slot:)`, line 372-374). If AX's focused window can ever be a window whose owned canvas is not the Space shown on its display — the exact condition `isVisible` exists to detect, and `isVisible` itself returns `true` for a nil Space id — then ⌥⇧⏎ writes an off-Space window, which README says can pull it onto the visible Space: "Tiled never writes an off-Space window, because an AX resize can pull it onto the visible Space."
- Impact if reachable: an off-Space window is moved onto the current Space and its tile rect is written against the wrong bounds; the README invariant is broken by the one path that has no guard.
- Fix: route the three expand writes through the same check (`guard isVisible(spaceOf(window: id) ?? focusedSpaceKey())` → mark stale and no-op), keeping the state entry so the next reassert applies it.

### F6 — RISK: a window tiled on the nil-Space fallback canvas is unreachable from every menu surface while keeping its slot and undo chapters [Medium | Medium | design-risk]
- Location: `Sources/tiled/TilingController.swift:1624-1640` (`tilingKey`/`activeSpaceID`), `1642-1646` (`isVisible`), `1230-1265` (`allTiledWindowsInfo`), `LiveWindowGateway.swift:355-358,398-418`
- Evidence:
```swift
// TilingController.swift:1642-1646
private func isVisible(_ space: TilingSpaceKey) -> Bool {
    guard let screen = space.screen, let id = space.space else { return true }
    return activeSpaceID(on: screen) == id
}
// LiveWindowGateway.swift:416 — one unresolvable display silently leaves the cache
            else { continue }
```
- Trigger: `LiveWindowGateway.currentSpaces()` maps display→Space by UUID and `continue`s past entries it cannot map, and `activeSpace(on:)` returns `spaceCache[display]` (nil on a miss, refreshed every 0.1 s). Any tiling action taken in that window (or on a display the table can't name) keys the window to `{screen, nil}`, and `setSpaceOwnership` then pins it there for the session (`spaceKeyForRequester`, line ~1245: `if let owned = spaceOf(window: id) { return owned }`).
- Impact: `isVisible` returns `true` for a nil Space id, so Tiled keeps writing that canvas as if visible; but `allTiledWindowsInfo`/`focusedTiledWindowsInfo` only iterate `tilingKey(for: display)` = `{screen, currentSpaceID}`, so the window is absent from the manage list and from "Untile All" while still holding a slot. Its undo chapters are pushed under `{screen, nil}` and `undoLastDisplacement()` reads `focusedSpaceKey()` = `{screen, spaceID}` → ⌃⌥⇧⌘Z can never consume them (only ⌥⇧⌫ still reaches the window).
- Fix: at minimum, have `allTiledWindowsInfo` also list a display's nil-Space canvas when its Space id is unavailable, or reconcile the fallback canvas into the identified canvas on the first successful lookup (re-key `spaceOwnership` and merge occupancy).

### F7 — README claims a move's reflow is undone "together with the event that caused it"; the chapter contains only the reflow [Low | High | doc-gap]
- Location: `README.md` ("Tiling rules" → reflow paragraph), `Sources/tiled/TilingController.swift:461-465`, `Tests/tiledTests/ReflowTests.swift:407-427`
- Evidence: README: "The same reflow runs whenever a tiled window leaves the layout (untile, drag-out, closing the window) or moves to a free tile, and ⌃⌥⇧⌘Z undoes it together with the event that caused it." Code: for a move with no eviction `outcome.requester` and `outcome.snapshot` are both nil (`PlanExecutor.swift:369`), so
```swift
// TilingController.swift:461-463
// ... (a move with no eviction has no chapter of its own, so the reflow starts one).
let chapter = (outcome.snapshot ?? []) + reflowSnapshot
```
and the test pins the resulting partial undo: `testMoveReflowIsUndoableWithoutMovingTheRequester` … `XCTAssertEqual(controller.state.slot(of: 2), .sixthBottomLeft, "the requester keeps the slot it chose")`.
- Trigger: `ReflowTests.testMoveToFreeSlotReflowsVacatedCells` sequence (a `.sixthTopLeft`, b `.sixthMiddle`, c `.sixthRight`; b moves to `.sixthBottomLeft`, c grows to `.sixthsRightTwoThirds`), then ⌃⌥⇧⌘Z: `c` returns to `.sixthRight`, `b` stays at `.sixthBottomLeft`.
- Impact: the user's "undo the last thing" produces a state that never existed (the pre-event state had `b` at `.sixthMiddle`), i.e. a documented recovery promise that the code and its tests do not implement.
- Fix: either add the move to the chapter (snapshot the requester's previous slot rather than `requester: nil`) or correct the README to say the undo restores the reflow only.

### F8 — A failed undo consumes its chapter, contradicting the documented "only a successful undo consumes its entry" [Low | High | doc-gap]
- Location: `Sources/tiled/TilingController.swift:791-796` (comment), `1002` (pop), `1046-1085` (outcome branches)
- Evidence:
```swift
// TilingController.swift:791-796
/// history survives new actions up to `undoDepth`. Only a successful
/// undo consumes its entry, and bulk destructive ops (untile all)
/// start a new chapter.
// TilingController.swift:1002 — popped before anything is attempted
guard let entry = mutateSpace(space, { $0.undoStack.popLast() }) else {
```
- Trigger: `ControllerBulkOperationTests.testUndoAfterEvicteeDied` (line ~296) — the evictee's app is killed, ⌃⌥⇧⌘Z pops the chapter, every entry is skipped by `guard gateway.liveness(of: entry.handle) != .dead`, `restored == 0`, the code sets `MenuText.restoreEvictedWindowsFailure`, and the entry is gone (`XCTAssertFalse(controller.canUndoDisplacement)` in that test).
- Impact: the section comment (the only place stating the retention rule) is wrong; anyone reasoning about "history survives a failed undo" will reason wrongly. Behaviour itself is defensible.
- Fix: fix the comment (or push the entry back when `restored == 0 && dead-only`).

### F9 — `expandedFocusedSlot` (a menu read) creates registry records as a side effect [Low | High | code-defect]
- Location: `Sources/tiled/TilingController.swift:975-982`
- Evidence:
```swift
var expandedFocusedSlot: Slot? {
    guard let handle = gateway.focusedWindow() else { return nil }
    let id = recordID(for: handle) ?? windowID(for: handle)   // ← inserts a record
    guard expanded[id] != nil else { return nil }
```
`windowID(for:)` (line ~1240) writes `records[id] = WindowRecord(handle: handle, preTileFrame: .zero)` and bumps `nextID`.
- Trigger: `AppDelegate.menuSnapshot()` (line 464) evaluates this on every menu build/refresh for any focused window that was never tiled.
- Impact: `records` accumulates entries for windows Tiled never manages (each of which the 5 s prune timer then probes via `gateway.liveness`, i.e. AX work per unmanaged focused window), and `nextID` churns. No user-visible corruption found; it is an unmanaged-state leak plus a write inside a read accessor.
- Fix: `let id = recordID(for: handle); guard let id, expanded[id] != nil else { return nil }`.

### F10 — `untileAll` can leave a placeholder chapter with an empty snapshot ("Restore 0 Evicted Windows") [Low | Medium | code-defect]
- Location: `Sources/tiled/TilingController.swift:851-857` (append), `889-902` (rebuild)
- Evidence:
```swift
mutateSpace(space) {
    $0.undoStack.append((snapshot: [], requester: nil))
    ...
for (slot, id) in chapter {
    guard let handle = handles[id],
          let frame = gateway.frame(of: handle)
    else { continue }
```
- Trigger: `untileAll` while `gateway.frame(of:)` returns nil for every tiled window (the AX-unreadable transient the code documents elsewhere: "During a lid close/open the frame read fails for live windows", `LiveWindowGuard`/`TilingController.swift:112-121`). Every `continue` fires, and the chapter is rewritten to `(snapshot: [], requester: nil)` at line 900-902 instead of being removed.
- Impact: `canUndoDisplacement == true` with `evictedCount == 0` → the menu row reads "Restore 0 Evicted Windows" (`MenuText.swift:9-11`), and pressing it consumes the entry and reports `MenuText.restoreEvictedWindowsFailure` while the notice still says "Untiled N windows. Press ⌃⌥⇧⌘Z to undo." (line 862-864).
- Fix: after the rebuild, `if snapshot.isEmpty { $0.undoStack.removeLast() }` (and set the restore-failure error).

## Verified-clean areas (what I checked and why it held)

- **Main-thread assumption / reentrancy.** Every controller entry point is main-thread in production: AX observers are added to `CFRunLoopGetMain` (`LiveWindowGateway.swift:264-268, 508-512`), AppDelegate actions are main, `DragTracker.schedule` hops via `DispatchQueue.main.async` (`DragTracker.swift:521-540`), and both injected schedulers default to `DispatchQueue.main.asyncAfter` (`DragTracker.swift:141-154`). An AX callback cannot interleave *inside* a synchronous `setFrame` because notifications are delivered as runloop sources; the echo bookkeeping is therefore safely ordered (`markExpected` immediately before each write: `TilingController.swift:633-635`, `PlanExecutor.swift:610-612`). No reentrancy hazard found.
- **Retain cycles.** Every controller-internal closure is `[weak self]` (lazy `executor`/`tracker` contexts, lines 26-58; prune timer and screen observer, 232-252; `scheduleVerification` 466-478; gateway `observe` 1323-1336) and AppDelegate's assignments are weak (`AppDelegate.swift:39-43`). No controller↔delegate↔gateway cycle found.
- **Per-canvas isolation of occupancy/layout/splitters/undo/notices.** `spaces: [TilingSpaceKey: CanvasState]` plus `tracker.grids` keyed on the same `TilingSpaceKey`; verified that every notice/undo push is scoped except the `lastTileError` path in F3, and that `pushRects`/`reflow`/`raiseOccupants` all defer off-Space writes (lines 615-619, 1391-1402, 800-802). `SpaceIndependenceTests` and `PerMonitorTests` exercise the reads.
- **Undo depth cap and chapter construction for the eviction/switch/rehouse paths.** `pushUndo` keeps the freshest `undoDepth = 5` (538-547), `untileAll` rewards its own chapter (851-902), and the re-house chapter returns the victim to the slot it was evicted from (`ReflowTests.testReHouseUndoRestoresTheVictimsOwnSlot`) — correct on the success path; the failure path is F2.
- **The swap branch's rollback really is atomic.** `applySwap` writes the displaced window first and, on either refusal, restores both occupancies and rewrites the displaced window's frame home (`PlanExecutor.swift:225-268`); the state-only rollback after a failure to write the requester is correct because the requester was never written.
- **Pruning / death confirmation.** `deadSince` bookkeeping is correct (`deadSince` refiltered to still-dead ids only, lines 786-788; the confirmation window is honoured per window; `pruneDeadWindows` releases the slot before `pushLeaveUndo`, so a close reflows like any leave); destroy notifications never force a prune the liveness standard calls a maybe (`windowDestroyed`, 1141-1155), all three behaviours test-pinned.
- **Expanded-window bookkeeping across tile/evict/swap/reflow/switch/undo/prune/destroy.** `expanded` is cleared on every exit path that drops a record (`forgetWindow` 1552-1576, `undoRestoreWindow` 1705-1714, `verifyConvergence` 519-531); reflow/applyAll/`trackedSlot` all skip expanded windows (`1506-1525`, 579-590, 1363-1375); a chapter entry can never name a still-expanded window because chapters are built from records that those paths have already cleared. Only the missing *visibility* guard remains (F5).
- **Injected clocks/schedulers vs. real ones.** `pruneInterval`, `scheduleDragEnd`, `scheduleVerify`, `screens`, `deathConfirmation`, `now`, and the mouse-up registrar are all injected; the only real runloop object is the prune timer, and it is `nil` under test (226-241). No hidden `Date()`/`Timer` on a path a test needs to control.
- **Injected-vs-live re-registration after untile-all.** `untileAll` re-observes the same handles under fresh ids; this is safe because `LiveWindowGateway.observe` sets the handlers *before* the `ObservationRegistry.begin` skip check (`LiveWindowGateway.swift:294-322`).

## Residual uncertainty (what static reading cannot decide)

- F1's *visible* symptom depends on Swift's per-process dictionary ordering (`occupantBySlot.keys.first`); the defect (an undefined `activeLayout` for a mixed occupancy) does not, but I could not run the 4-step sequence. The engine reviewer should confirm the mixed-state consequence for `plan` against `MatrixCrossCheckTests`' generator, which does not model undo.
- F5's premise — whether `gateway.focusedWindow()` can name a window whose owned canvas is not the visible Space — needs live AX (a multi-Space, multi-window app). I have no repro, hence RISK not defect.
- F6 needs observation of a real `CGSCopyManagedDisplaySpaces` miss/partial table (`tools/repro/probe-spaces.swift` is the existing instrument); I cannot tell how often `activeSpace(on:)` returns nil on a running multi-display machine.
- Severity of F4 depends on whether "no undo when the placement didn't cleanly land" is intended (one test pins it for the restore-failure case) — I read it as intended for the bookkeeping and unintended for the missing narration.
- Tests are green per the audit brief, but a mutation-testing run is rewriting `Sources/*.swift` right now, so I ran no build/test/git command; every "pinned by test" statement above is from reading the test source, not from an execution.
- `noStagedFiles: true` below is an assertion about *my* run (read-only tools only); I did not and cannot run `git status` under this slice's rules.