# Robustness & quality audit — 2026-10-08

Scope: **main feature** — tiling core (`Layout`, `TilingSpace`, `TilingController`), the AX write
path (`WindowGateway`, `LiveWindowGateway`, `WriteExpectations`, `DragTracker`, `DisplaySpace`), the
hotkey/settings/app shell, and the whole test suite — for robustness (edge cases, failure modes,
state-vs-screen divergence) and quality (seams, locality, test gaps). Method: four parallel auditors
cross-checked against `CONTEXT.md`'s rules literally; every finding cites `file:line`; the top four
findings were re-verified by hand against the source before filing.

Baseline: `6f600c4`. Gates at audit time: `swift build` warning-free; **691 tests green (0 failures)**;
86/86 mutation targets live (see mutation section). The architecture review queue (candidates A1–A7,
defects 1–8) cleared earlier today at `4e9391b` — nothing here re-opens it.

**Heads of terms**: the domain words in `CONTEXT.md` are used exactly (slot, canvas, eviction, swap,
reflow, re-house, expand, drag-out, requester, expected write); the quality findings use the
codebase-design vocabulary (module, interface, depth, seam, adapter, leverage, locality).

---

## Verdict

The core is in good shape: the planning rules in `CONTEXT.md` are almost all pinned by tests, the
geometry is single-source, and the previously fixed defect classes (Carbon handler lifetime, UInt32
traps, duplicate-binding gate) stay fixed. The findings cluster in three places:

1. **Undo after a destructive-but-refused event** (D1, D2, D5, D8): the "destruction must stay
   recoverable" rule the code itself states is honoured by `applyTile` but not by its siblings.
2. **The expected-write owner's supersede story** (D3, D11): every *performed* write supersedes,
   but the refusal / clamp / no-op-skip / deferral paths leave the previous check armed against a
   stale entry — the exact invariant the module's own comment promises.
3. **Data-loss and dead-recovery paths in the settings shell** (D4, D19): two UI paths can destroy
   or promise things the user cannot get back.

Findings: **4 High**, **17 Medium**, **14 Low**, plus test/fake/mutation gaps.

---

## Open questions — decide before the fixes

**OQ1. `CONTEXT.md:46` over-scopes the undo-chapter rule.** "One undo chapter covers the event and
its reflow together" reads as covering untile/drag-out/close too, but the code deliberately keeps a
chapter only for the reflow move (`TilingSpace.swift:863-865` "the restore itself keeps no chapter
(the frame IS the recovery)"), pinned by `Tests/tiledTests/ReflowTests.swift:447-462` ("the evicted
window stays untiled" on undo). The code is right — re-tiling a drag-out on undo would contradict
"the drop is the placement" (`CONTEXT.md:58`). **Recommend (a): scope the sentence to
eviction-by-request.** (b) would change undo semantics.

**OQ2. `CONTEXT.md:54` vs swap of an expanded blocker.** "An expanded window … never re-houses or
steps aside" omits swap, yet an expanded blocker *can* be swapped after `apply` collapses it
(`Layout.swift:541-546`, `TilingSpace.swift:179-181`). Defensible ("comes back to earth before
moving"), but the spec list should state it. **Recommend: keep the behaviour, add swap-with-collapse
to the sentence.**

**OQ3. Which side owns `.deferredOffSpace` semantics (D15)?** `applyLayout` rolls the placement back
and narrates an app refusal; `writeRects` lets the state stand and reconciles on swipe-back. Both
readings are internally argued in comments; they cannot both be right. **Recommend: `writeRects`'s
reading (state stands, reconciled on the swipe) with a distinct "Space unknown" message instead of
the app-refusal sentence** — but this is a behaviour call for the owner.

---

## HIGH — state corruption / data loss / user-visible wrong behaviour

### D1. A refused placement during a layout switch destroys the whole arrangement with no undo

`Sources/tiled/TilingSpace.swift:356-379` (snapshot built at 356-358, committed **only** in the
middle branch at 374-375) vs. the tile branch's deliberate opposite at `TilingSpace.swift:540-552`
and its comment at 543-551 ("The chapter is pushed even when the requester's own write was refused:
the evictees really did go home, and without it that destruction would be silent and unrecoverable").

`applySwitchLayout` sets `commit.snapshot` only when `placeResult == nil, restoreFailures.isEmpty,
!evicted.isEmpty`. If the requester's write is refused, control hits the `else` branch (376-379),
which sets the refusal and **drops the snapshot** — so `settle` (`TilingSpace.swift:260-261`) pushes
nothing. A layout switch is the most destructive action in the app (it restores *every* tiled window
via `restore(evicted, …)` at 359), and after the refusal all of those windows are already home with
`forgetBookkeeping` applied (`TilingController.swift:398-400`). Undo then answers `.nothingToUndo`
(`TilingController.swift:890-894`).

Reachable: five quarters tiled; focus an untiled window whose app refuses resizes; press a sixths
hotkey. All five untile silently behind "couldn't be tiled"; undo does nothing. The tile-branch
equivalent is pinned by `Tests/tiledTests/UndoIntegrityTests.swift:152-169` — **the switch case has
no test**.

Direction: move `commit.snapshot = snapshot` (and `requester: …`) out of the success-only branch so
any switch that restored ≥1 window stays undoable, mirroring `applyTile`. *(Hand-verified.)*

### D2. Undo of a switch does not return a tiled switch-requester to the slot it vacated

`TilingSpace.swift:355-358` (switch snapshot omits the requester's former slot; contrast
`TilingSpace.swift:494-498` in `applyTile` and `:410-413` in `applySwap`, both of which append it),
`TilingController.swift:861-867` (undo's contract), `CONTEXT.md:50` ("a tiled requester returns to
the slot it vacated").

On undo the requester goes through `canvas.restore(window:)` (`TilingController.swift:924-934`),
which writes its *pre-tile* frame and forgets it. A requester that was tiled before the switch ends
the undo untiled at an ancient frame while everyone else returns to their slots. Tile and swap
branches get this right and it is pinned (`ReflowTests.swift:591-607`, `SwapTests.swift:144-172`);
`UndoIntegrityTests.swift:97-117` uses an *untiled* switch requester, where pre-tile restore is
correct.

Reachable: A=topLeft, B=topRight; B requests a sixths slot (switch); undo → B floats at its pre-tile
frame; before the switch it held topRight.

Direction: append a snapshot entry for the tiled requester in `applySwitchLayout`, as `applyTile`
does. *(Hand-verified: the switch snapshot maps over `evicted` only.)*

### D3. The supersede invariant is skipped by refusal/clamp/no-op-skip/deferral — a stale late check can discard a window from a slot it legitimately holds

`Sources/tiled/WriteExpectations.swift:212` (`noteExpected` runs **before** the gateway call at 214),
`:214-217` (`.refused` returns with the entry armed at the refused target and no `cancelCheck`),
`:228-240` (clamp-restore re-notes at `previous`, returns `.refused`, never touches `checks`),
`:197-211` (`.deferredOffSpace` / `.skippedNoOp` return early without cancelling),
`:241-244` (the comment: "a newer write supersedes (cancels) the older" — true only for performed
writes), `:298-307` (`fireCheck` judges whatever `expected[id]` currently holds),
`Sources/tiled/TilingController.swift:441-470` (`discardIgnoredWindow` releases the slot).

A check armed for write A survives a later write B whenever B is refused, clamped, no-op-skipped, or
deferred. When the check fires 3.5 s later it judges B's entry (or A's, depending on path) against
the window's *current* frame. Scenario (no-op skip variant): a silently-ignoring app sits at
BottomLeft's rect; the user tiles it TopLeft (performed, silently ignored, check armed); within 3.5 s
re-tiles it BottomLeft (no-op skip, no supersede). The check fires, sees the live frame far from the
old TopLeft target, returns `.ignored`, and `.slotCommit` **discards the window from BottomLeft** —
the slot it visibly occupies. The refused-write variant is worse: the entry points at a target the
window was never in, so *any* subsequent legitimate placement can be judged "ignored".

`WriteExpectationsTests.swift:181-200` pins supersede only for two *performed* writes; `:124-138`
pins a refused write in isolation; the interleavings are untested.

Direction: tie each `PendingCheck` to the entry serial it armed (judge only if `expected[id]` is
still that entry), or make the refusal/clamp/skip/deferral paths cancel the pending check and clear
the stale entry explicitly. *(Hand-verified; both framings — engine-side and controller-side — are
the same root.)*

### D4. "Restore Previous Shortcuts" permanently destroys the backup entries it fails to restore

`Sources/tiled/SettingsShortcutsTab.swift:764-783` (clear at 768 runs **before** `hotkeyStore.apply`
at 769), `:722-756` (the promise: "Your current combos are kept; use Restore Previous Shortcuts to
get them back").

On `.duplicate` the combo is correctly not stored — but the snapshot entry is already deleted and
`sender.title = "Reset Shortcuts"` (779) flips unconditionally, so `anyResetBackup()` (727) offers no
retry. The message "Not restored: X (taken by Y)" implies the restore is resolvable; it is not. The
parallel bulk-enable path keeps the park on a clash by design (`SettingsShortcutsTab.swift:469-475`,
pinned by `FeedbackAndRecorderTests.swift:265-296`); the reset-backup path has neither the treatment
nor a test.

Reachable: Reset Shortcuts → assign one of the old combos to another action → click Restore Previous
Shortcuts → that entry is reported "taken" and its backup is silently deleted forever.

Direction: clear the backup entry only on `.applied` (mirror the bulk-enable rule); pin the clash
path with a test. *(Hand-verified.)*

---

## MEDIUM — robustness risk / significant quality issue

| # | Finding | Evidence | Scenario / direction |
|---|---------|----------|----------------------|
| D5 | **A failed restore write drops the whole undo chapter** even though other evictees really were untiled | `TilingSpace.swift:540` (`if restoreFailures.isEmpty`), `:365-375`, `:689-709` (restore forgets even when refused) | One evictee refusing its pre-tile restore disarms undo for *all*. Keep the snapshot whenever `evicted` is non-empty (D1's fix covers the switch branch). |
| D6 | **Cross-canvas undo can double-book one window** across two canvases and clobber the handle→id table | `TilingSpace.swift:304-317` (`allocateID` on no local record), `TilingController.swift:428-434` (steals `windowIDs[handle]`), `:1371-1376` (`spaceOf` order-dependent) | Window evicted on A, re-tiled on B, undo on A → two records/slots for one window; the next `reassert` yanks it back. Resolve the handle globally before `allocateID`. |
| D7 | **Rollback corrective-write results are discarded** — a refused rollback leaves screen and state diverged | `TilingSpace.swift:427-437` (`_ = applyLayout` at 433), `:520-527` (`_ = restore` twice), `:799-812` | An app that refuses the first write refuses the rollback write too; the window stays at the requester's vacated tile while state claims otherwise. Fold the refusal into `commit.refusal`/`failures`. |
| D8 | **Undo's blocker untiles discard failures**, hiding a dropped blocker behind the success sentence | `TilingController.swift:915-917` (result discarded), `TilingSpace.swift:866-873` (each `untile` clears `error`), `:953-967` | Refused blocker untile → blocker forgotten anyway, "N windows restored." shown. Collect into `failures` so the existing precedence covers them. Untested. |
| D9 | **Degenerate swap fallback reports the wrong plan identity to `settle`**, leaking the restored window past `forget` | `TilingSpace.swift:392-407`, `:189-208`, `:228-229` (`decision`-derived forget is `[]` for `.swap`) | Latent today (`plan` can't produce it) — but it is exactly the "Commit knows the truth, `settle` re-derives from the stale decision" seam. Let `Commit` carry the effective restore/forget set. |
| D10 | **A missed `preTileFrame` capture loses the restore target forever** | `TilingSpace.swift:653-658` (`?? record.preTileFrame` swallows), `:689-696` (zero frame = silent no-write restore) | A transient frame-read failure at first tiling (the lid-close class) means every later eviction "restores" the window nowhere while narrating "went back to where it was". Retry the capture while the frame is still `.zero`. |
| D11 | **Unowned echo entries swallow the start of a future user drag** | `WriteExpectations.swift:212-217, 236-237` (entry armed, never cleared on refusal), `:339-399` (close ticks extend life; stale clear unreachable), `DragTracker.swift:304-339` (drag anchored at first unswallowed tick) | A refused placement at 14:00 leaves an entry whose 32 pt echo radius eats the first ticks of a later drag → a long gesture measures short and snaps back. Time-box armed entries or un-arm on the refusal/clamp paths (D3's fix largely subsumes this). |
| D12 | **`setFrame` never rolls back a size-landed/position-failed half-apply** | `LiveWindowGateway.swift:907-958` (only `previousOrigin` saved), `AXWrite.needsPositionRestore` at `:945, 991-993`, `FakeWindowGateway.swift:97-104`, `AXWriteTests.swift:117-130` | Position write refused on every attempt while size lands → window resized at its old origin; callers roll state back ("the app refused") and the screen shows a half-applied frame. Snapshot both origin and size; restore the full frame when exactly one write landed. |
| D13 | **Geometric death confirmation can prune a live window** against a stale `lastFrames` baseline | `LiveWindowGateway.swift:75, 182-187` (baseline refreshes only on reads), `:227-266` (successful probe doesn't refresh), `:853-865` (death by frame identity, <1 pt), `TilingController.swift:701-724` | Failed notification registration + user drag + transient probe failure → `.dead` one tick later, slot released for a live window. Refresh the baseline on successful probes; match with tolerance. |
| D14 | **Worst-case main-thread stall per write ≈ 6.3 s**, far past the code's own latency claims | `LiveWindowGateway.swift:51` (1 s timeout per message), `:970-1020` (synchronous retries + sleep), `:984-986` (claim counts only sleeps), `TilingSpace.swift:827-844` (per-rect writes) | One wedged app among the occupants stalls hotkeys, the drag loop, and the menu for seconds per pushed rect. Skip-and-mark-stale after the first timeout instead of retrying synchronously. |
| D15 | **`.deferredOffSpace` is failure in `applyLayout`, success in `writeRects`** — the placement is lost with a lying refusal message | `TilingSpace.swift:724-748` vs `:820-844`, `WriteExpectations.swift:47-49, 194-201`, `LiveWindowGateway.swift:475-486` (0.1 s Space-cache TTL) | A slow AX write expires the Space cache mid-action → the placement rolls back and narrates "the app refused to resize it". See OQ3. |
| D16 | **Pre-tile restores bypass the off-Space deferral policy** | `TilingSpace.swift:689-696` (gateway-direct write) vs `WriteExpectations.swift:194-201` | The exact hazard the deferral exists to prevent (pulling a hidden-Space window through Mission Control) is reachable on the restore path, which also has no echo suppression. Route `restore`'s write through the owner. |
| D17 | **Cross-display short drags snap back into the wrong display's geometry** | `DragTracker.swift:323-339` (snapback uses `boundsOf(drag.lastFrame)`), `TilingController.swift:62, 604-620`, `:1371-1376` (canvas never migrates) | A <100 pt drag whose majority share crosses displays snaps into the other display's slots while the record stays put. Snap back against the window's own canvas bounds. |
| D18 | **`c278b18` is half complete: `HotkeyService.deinit` leaves its Carbon hot key registrations alive** | `HotkeyService.swift:155-160` (deinit), `:166-172` (only `reload()` unregisters), `:129-131` (the fix's own doc contract) | A deallocated service leaves every `EventHotKeyRef` registered system-wide with no handler; a replacement service double-registers. Latent (`start()` runs once) but the advertised contract is false. Unregister in `deinit`. |
| D19 | **`isSettingsHotkeyRegistered` answers the wrong question** — the hide-icon confirm can promise a dead recovery combo | `AppDelegate.swift:701-704`, `HotkeyService.swift:174-197` (179: disabled ≠ failed), `SettingsGeneralTab.swift:294-319` (302-308), `SettingsDependencies.swift:31-33` | Disable/remap "Open Settings" → the destructive confirm still hard-promises "press ⌃⌥⇧⌘, anywhere". Answer "is the *current* binding live, and what is its label"; render the real label. |
| D20 | **`HotkeyService.route` is dead code**; the flagship routing test pins a function production never calls | `HotkeyService.swift:93-110` vs `:215-233` + `:112-120`, `HotkeyServiceTests.swift:134-168` | An id-switch drift passes the dead table + uniqueness test yet silently misroutes live hotkeys. Make the callback consume the tested `route` (or drop it and pin `Context.actionByID`). |
| D21 | **Hidden icon defeats the refresh diff** — a full NSMenu is built and discarded on every refresh pass | `AppDelegate.swift:396-440` (nil `statusItem` ⇒ `hasMenu` false ⇒ rebuild every pass), `:51-54`, `:369-378` | With the icon hidden, every app switch / tiling tick builds the whole menu tree and assigns it to nil — the exact waste the diff exists to prevent. Treat "no status item" as a terminal no-op in the plan. |

---

## LOW — quality / hygiene / minor

| # | Finding | Evidence |
|---|---------|----------|
| L1 | Eviction notice undercounts when only some evictees are named (`case 1/2` key off `names.count`, not `count`) | `TilingSpace.swift:618-633` |
| L2 | Re-house fallback's own restore failure is discarded (`_ = restore` twice) | `TilingSpace.swift:520-527` |
| L3 | Undo of tiled-requester chapters visibly bounces the requester through its pre-tile frame under a fresh id (leaky seam: tests must know about id reissue) | `TilingController.swift:920-934`, `TilingSpace.swift:296-340`, `ReflowTests.swift:602` |
| L4 | `CONTEXT.md` mismatches: OQ1 (`:46`), OQ2 (`:54`), and D2 (`:50` — code wrong, spec right) | — |
| L5 | Swap-displaced collapse outcome discarded; `error` can coexist with a later success `notice` | `TilingSpace.swift:179-181` |
| L6 | `untileAll` placeholder pop after a frame-read failure has already evicted the oldest real chapter (depth cap) | `TilingSpace.swift:279-284, 927-989` |
| L7 | Caps Lock pressed *while modifiers are held* records a caps-lock binding (57 missing from `modifierKeyCodes`) | `HotkeyRecorder.swift:9-11, 21-27, 50-65` |
| L8 | `tileGap` clamp is NaN-unsafe (`min`/`max` propagate NaN) → NaN frames from `defaults write … nan` | `AppSettings.swift:39-50` |
| L9 | Hide-icon confirm misattributes "not registered yet (untrusted)" as "taken by another app" | `AppDelegate.swift:701-704`, `SettingsGeneralTab.swift:306-308` |
| L10 | ⌫-clear on an app action parks a binding nothing ever reads (dead persisted state); key namespaces string-built in three places | `SettingsShortcutsTab.swift:638-653, 561-579, 437-504`, `HotkeyBinding.swift:283-285` |
| L11 | Recorder binds system-reserved combos (⌘Q/⌘W/⌘Space/⌘Tab) and the store registers them globally (also a keyboard trap while armed) | `HotkeyRecorder.swift:50-65`, `HotkeyBinding.swift:260-266`, `RecorderButton.swift:106-134` |
| L12 | `RecorderButton`'s window-close observer binds to the first window and never re-targets | `RecorderButton.swift:59-80` |
| L13 | No registration-time de-duplication; corrupt defaults can double-register one combo | `HotkeyService.swift:174-197`, `HotkeyBinding.swift:230-235` |
| L14 | Dead `excluding` plumbing across publish (`DragTracker` → `TilingController` → `TilingSpace`, dropped on the floor) | `DragTracker.swift:92, 524-562`, `TilingController.swift:544-557`, `TilingSpace.swift:1192-1198` |
| L15 | `pendingResizeApplies` outlives `forget`; per-canvas scoping falls back to all-canvas reassert | `DragTracker.swift:402, 482-489, 207-211, 511-522` |
| L16 | Clamp-restore ignores its own restore write's result (`_ = gateway.setFrame` at 231) | `WriteExpectations.swift:228-240` |
| L17 | Title-bar vs edge classification uses exact `CGSize` equality (rounding perturbation misclassifies) | `DragTracker.swift:288-293` |
| L18 | Stale comment describing retired architecture ("controller untile()s every window in plan's evicting list") | `TilingStateTests.swift:325-329` |

---

## Test gaps

**Rules in `CONTEXT.md` with no test pinning them:**

| # | Rule | Implementing code | Nearest test |
|---|------|-------------------|--------------|
| G1 | Gap: "an expanded window ignores it" | `TilingSpace.swift:1014` (no gap) vs `:1086` | `TilingSpaceTests.swift:843` — but harness gap defaults to 0 (`TilingSpaceHarness.swift:27`) |
| G2 | Gap: "the same across layouts" — sixths + gap never tested | `Layout.swift:430-440` | `GridLayoutTests.swift:38-84` (quarters slots only) |
| G3 | Step-aside's one non-containment case (left two-thirds blocking right two-thirds → steps into left third) | `Layout.swift:577-589` | **None** — containment variants pinned at `ReflowTests.swift:275-318`; `UndoIntegrityTests.swift:239-270` inverts the roles |
| G4 | Expected write: the verify delay and the production scheduler | `WriteExpectations.swift:80-88` | **None** — every test injects its own scheduler |
| G5 | Gap uniformity "across displays and Spaces" | structural (`TilingController.swift:93`, `TilingSpace.swift:85`) | none asserting non-zero gap on a second display |

**Behaviour gaps found by the engine audit** (each pairs with a finding above): refused switch
placement keeping the destruction undoable (D1), tiled switch-requester undo (D2), skip/deferral ×
supersede interleaving (D3), reset-backup clash path (D4), refused blocker untile (D8),
partially-named eviction notices (L1), cross-canvas undo of a re-tiled window (D6).

**Test-quality findings:**

- **Q1 (High) — `MatrixCrossCheckTests`'s re-house oracle is the code under test.** The cross-check
  asserts the canvas re-housed "into the one free slot" by calling `model.rehousingHome(…)` — the
  same pure function the canvas calls (`TilingSpace.swift:481`; `MatrixCrossCheckTests.swift:67-78`).
  A wrong home is agreed with, not caught; rule correctness rests solely on `ReflowTests` scenario
  pins — exactly where G3's example is missing. Survivor assertion is `XCTAssertNotNil` only.
- **Q2 (High) — `TilingSpaceHarness` swallows the publish path** (`apply: { _, _ in }`,
  `TilingSpaceHarness.swift:67`) and defaults `gap: 0` (`:25-27`): wrong neighbour pushes are
  unobservable from the canvas suite and most canvas coverage runs gap-free.
- **Q3 (High) — harness never observes silent-ignore consequences** (`TilingSpaceHarness.swift:37-51`
  omits `onConsequence`; the parameter defaults to a no-op at `WriteExpectations.swift:162`).
- **Q4–Q7 (Medium)**: id-issuance-order assertions (`EvictTests.swift:86-93`); white-box state
  injection standing in for `expand()`/`place()` bookkeeping (`TilingSpaceTests.swift:316, 621,
  1020, 135, 376`); near-vacuous notice assertion `contains("Z")` (`SwapTests.swift:84-93`); test
  name promising more than asserted (`TilingSpaceTests.swift:1015`).
- **Q8–Q11 (Low)**: wall-clock dependence (`ControllerBulkOperationTests.swift:651-676` real 0.3 s
  sleep; display-dependent `DisplayIdentityTests.swift:85-100` with graceful skip); triplicated
  controller scaffolding instead of a shared harness (`SwapTests.swift:13-52`, `ReflowTests.swift`,
  `EvictTests.swift`, `ExpandToggleTests.swift`, `UndoIntegrityTests.swift`; `assertHealthy` ×3);
  stale comment (`TilingStateTests.swift:325-329`); double-negative assertions
  (`ReflowTests.swift:419-421`, `UndoIntegrityTests.swift:286-288, 419`).

**Fake fidelity — where a green test can mask a live bug:**

- **G6** — fake `release()` is non-destructive but live's drops the element (`FakeWindowGateway.swift:111-115`
  vs `LiveWindowGateway.swift:182-210`): undo-on-released-handle shapes can "pass" on the fake.
- **G7** — `focusChangesFocused = false` (documented "system ignores activation" mode) is used by
  zero tests (`FakeWindowGateway.swift:30-35`).
- **G8** — live write *glue* untested: only the pure `AXWrite` policy is; dropping the origin-restore
  or reordering the write pair keeps the suite green (`LiveWindowGateway.swift:898-958`,
  `AXWriteTests.swift:10-130`).
- **G9** — production timers never run in tests (`WriteExpectations.swift:83-88`,
  `DragTracker.swift:137-160`): delays, cancellation, and main-queue wiring are unexercised.
- **G10** — coordinate-space refusals (`NSScreen.screens` empty) unmodeled in the fake
  (`LiveWindowGateway.swift:894, 911`).
- **G11** — echo streams are scripted, not fuzzed; out-of-order/late notification races are
  construct-only (`FakeWindowGateway.swift:210-213`).

**Mutation-coverage gaps** (`tools/mutation/mutants.json`, 86 targets, all live; `mutate.py` sound):
no mutant guards gap geometry (`Layout.swift:430-440`), reflow's exact-or-empty rule
(`Layout.swift:665, 677-679`), step-aside exactness + step-aside-beats-swap gate
(`Layout.swift:579-588, 543`), free-region requester exclusion (`Layout.swift:621-623`), the
one-chapter-folds-event-and-reflow rule (`TilingSpace.swift:260-261, 269-273`), eviction-writes-pre-tile
/ drag-out-writes-nothing (`TilingSpace.swift:689-696, 898-901`), the consequence *bodies*
(`TilingController.swift:456-486`), swap focus ordering, `restoreChapter` death skip, production
timers, snapback/escape heuristics, `axisOnAnimationPath` math, eviction-notice wording.

---

## Verified solid (traced, not just read)

- **Planning rules**: requester never evicts itself; eviction lists sorted; swap requires a disjoint
  vacated tile; step-aside beats swap; degenerate leftover falls back to eviction — all pinned
  (`Layout.swift:478-485, 522-547`, `TilingStateTests.swift:88-156`).
- **Geometry single-source**: `SlotGeometry` drives cells, overlap, and rects; gap half/full split
  and clamps pinned (`Layout.swift:48-127, 411-440`, `GridLayoutTests.swift:38-90, 1192-1263`).
- **Reflow core**: grow-into-whole-slot, rightmost tie-break, holes stay empty, requester/expanded
  never grow (`Layout.swift:658-704`, `TilingSpace.swift:771-818`, `ReflowTests.swift:40-184`).
- **Expanded semantics** (never grows / re-houses / steps aside; untangles on eviction) — pinned.
- **Expected-write lifecycle for performed writes**: arm-before-write, tick verdicts, clamp
  detection (Firefox floor, Terminal rounding), unreadable-frame = can't-judge, intent surviving
  `forget` (`WriteExpectations.swift`, `WriteExpectationsTests.swift`, `FakeGatewayFidelityTests`).
- **Liveness standard**: conservative `.unknown`, geometric death confirmation, one app walk per
  pass, destroy notification accelerates but never replaces the standard
  (`LiveWindowGateway.swift:828-865`, `AXLivenessTests.swift`).
- **Carbon handler lifetime** (c278b18) core: retention, deinit removal, per-instance install,
  no-use-after-free — pinned (`CarbonEventHandler.swift:15-39`, `CarbonEventHandlerTests.swift:17-85`)
  (D18 is the remaining half).
- **UInt32 trap surface closed** via `HotkeyBindingCodec` + the shared corrupt table against all
  three readers; **duplicate gate** complete for UI writes; **bulk-enable park semantics** correct
  and pinned (`HotkeyBinding.swift`, `CorruptHotkeyEntries.swift`, `FeedbackAndRecorderTests`).
- **Menu refresh path**: one capture, one plan, one writer; open-menu deferral and in-place refill
  pinned (`AppDelegate.swift:203-241, 383-458`, `AppDelegateMenuTests`).
- **Drag-out / snapback / fast-drag gap stability**; per-display and per-Space canvas independence;
  hidden-canvas deferral; undo integrity including step-aside chapters and partial-failure narration.
- No production-reachable force-unwraps/`try!`/`fatalError` found in scope.

---

## Suggested triage order

1. **D3 + D11** (one fix family in `WriteExpectations`): the supersede invariant is the module's
   stated contract and its breach can discard a live window — small change, pinned by new
   interleaving tests.
2. **D1 + D2 + D5** (one fix family in `applySwitchLayout`/chapter policy): align the switch branch
   with `applyTile`'s "destruction stays undoable" rule; spec already says the answer for D2.
3. **D4** (settings data loss): one-line ordering fix + a test mirroring
   `FeedbackAndRecorderTests.swift:265-296`.
4. **D19, D18, D20** (hotkey shell correctness): small, self-contained, each with a named contract
   the code violates.
5. **D12, D13** (live gateway): widen the fake at the same time (G6–G8) so the fixes are pinnable.
6. D6–D10, D14–D17 as capacity allows; D9 is latent but its fix removes a whole failure family.

Each family is a `/implement`-ready unit; the test gaps in its row are its red tests. Per the issue
tracker convention (`docs/agents/issue-tracker.md`), families can be cut as tickets under a new
`.scratch/robustness-audit/issues/` arc with blocking edges (D3 before D11; D1 before D5).
