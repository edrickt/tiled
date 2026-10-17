# Code-quality & feature-functionality audit — 2026-10-17

Scope: the whole current tree on `master` — the tiling engine (`Layout`, `TilingSpace`,
`DragTracker`), the coordinator and AX adapter seam (`TilingController`, `FrameWriter`,
`LiveWindowGateway`, `DisplaySpace`), the menu/settings/hotkey shell, and the test suite.
Two axes: **feature functionality** (does documented behavior match the code, and is it pinned?)
and **code quality** (depth, locality, seams, test surface).

Base: `master` @ `2f07c03` ("Prepare the 0.2.2 release"), tag `v0.2.2`.
Method: five parallel source+test tracers, one per slice; every finding cites `file:line`; the two
highest findings were reproduced with temporary harness probes (then removed). The multidisplay
audit is merged; the `robustness-audit` branch is **not** merged, and findings that already exist
there are marked as such rather than claimed as new.

Limits: **no live verification** was run by request. The 39-case live suite, the multi-display
suite, and the physical display checklist were not executed. Findings that need a real GUI,
Accessibility grant, or display teardown say so.

---

## Gates

| Gate | Result |
|---|---|
| `swift build`, warnings/errors | clean |
| `swift test` | **687 / 687 green**, ~2.0 s |
| `scripts/check-test-count.sh` | README's 687 matches the suite |
| `python3 tools/mutation/mutate.py` | **90 / 90 valid mutants caught**, no survivors |

Line coverage from `swift test --enable-code-coverage` (`llvm-cov report`): **71.87% overall**.

| File | Lines | Reading |
|---|---:|---|
| `Layout.swift` | 97.23% | engine geometry is well pinned |
| `TilingSpace.swift` | 97.17% | placement/deferral state is well pinned |
| `DragTracker.swift` | 94.87% | gesture logic is well pinned |
| `FrameWriter.swift` | 100% | the policy seam is pinned |
| `TilingController.swift` | 92.50% | lifecycle is mostly pinned |
| `MenuModel.swift` / `MenuText.swift` | 98.99% / 100% | menu composition is pinned |
| `HotkeyBinding.swift` | 100% | binding storage is pinned |
| `SettingsShortcutsTab.swift` | 79.88% | bulk/reset paths are partially pinned |
| `SettingsGeneralTab.swift` | 69.23% | AppKit wiring is partially pinned |
| `HotkeyService.swift` | 30.70% | registration is live-only |
| `LiveWindowGateway.swift` | 20.18% | live-only adapter |
| `AppDelegate.swift` | 17.45% | launch/permission/action wiring is live-only |

The coverage split is honest: the pure engine is nearly fully exercised, while the live adapter
and app shell rely on the live suite. That is a layer split, not by itself a defect — but it
sets the limits of what this hermetic audit can claim.

---

## Verdict

The engine's planning rules are in good shape. The plan/commit matrix, reflow, re-house, swap,
splitter isolation, grid geometry, and per-canvas undo are pinned by tests that use literal
expected values, and the mutation table confirms the suite notices injected bugs.

The functional findings cluster in four places:

1. **Refusal rollback** — a refused move of an already-tiled window drops the slot it still
   visibly occupies (F1), and a refused undo restore is counted as a success (F4).
2. **The death fast path** — a destroy notification trusts a single liveness verdict, including
   the transient `.dead` the adapter documents during display teardown (F2).
3. **Stale deferred work crossing canvases** — a deferred pre-tile restore outlives a retile on
   another canvas (F5).
4. **Presentation truth** — the menu and the announcements can disagree with what the controller
   actually did (F6–F11), and several labels still describe the pre-swap undo model (F15).

The code-quality findings cluster in four seams:

1. The **expected write** is a named domain concept with no owning module: `FrameWriter` imports
   the gesture tracker's tolerance and convergence state, and the canvas and controller each
   carry half the ledger (A1).
2. **Window ownership** is two stores kept in sync by convention, with a linear scan resolving a
   handle to a canvas (A2).
3. **Display+Space → canvas resolution** is four private resolvers plus a menu-specific
   reimplementation (A3).
4. **Hotkey routing** is tested through a function the production callback never calls (A4).

The architecture report with before/after diagrams is at
`file:///var/folders/kw/rdnzrq011p1d0hg_qdtlt8zw0000gn/T/architecture-review-20261017.html`.
The rest of this file is the evidence and the feature map.

---

## HIGH — state corruption, data loss, or clearly wrong user-visible behavior

### F1. A refused move of an already-tiled window deletes the slot it still occupies

**Evidence.** `TilingSpace.place` commits the requested slot, writes it, and on a refusal calls
`forget(id)` unconditionally (`Sources/tiled/TilingSpace.swift:815-828`). `forget` removes the
record, expansion, deferred work, tracker entry, and occupancy (`:847-853`). The comment says the
record goes "with the occupancy", but this branch also handles a **tiled requester moving to a
free slot**, where the occupancy it should roll back to is the one it had before the commit.
`applySwap` does roll back both occupancies (`:557-580`); `place` does not.

**Reachable sequence.** Tile A Top Left. Ask A for Bottom Right (free). A's app refuses the write.
A never moves; it is still visibly in Top Left. State now has no slot for A and no record; the
coordinator drops its handle-table entry. B can then be planned into Top Left as if the cell were
free, overlapping A. That contradicts "One window per tile" (`README.md:121`) and "the window is
left alone … state and screen never silently disagree" (`README.md:179-181`).

**Verified.** A temporary harness probe reproduced it: after the refusal, `state.slot(of: a)` was
`nil`, the frame was still the Top Left rect, and `records` was empty.

**Test gap.** The suite pins the loss as expected: `testRefusedRequesterLeavesTheRehouseVictimAlone`
(`TilingSpaceTests.swift:421-430`) refuses a **tiled** requester's move and asserts
`state.slot(of: m) == nil`. `TilingSpaceTests.swift:926-935` covers a refused re-tile after an
eviction, where forgetting is correct. No test covers a tiled requester refused into a free slot,
and none asserts that the previous slot survives a refusal.

**Direction.** Save the pre-commit slot, and on refusal restore the previous occupancy and keep
the record, exactly as the swap branch does. Only a refused **first** tiling should forget.

### F2. A destroy notification bypasses the death confirmation for a transient dead probe

**Evidence.** `TilingController.windowDestroyed` releases on one `gateway.liveness(of:) == .dead`
verdict (`Sources/tiled/TilingController.swift:1071-1085`). The comment says element identity can
churn while the window lives during display teardowns (`:1064-1069`), but the guard cannot tell a
churned element from a dead app. The adapter documents the other half of the coincidence:
`FakeWindowGateway` models the lid-close transient where AX answers `.invalidUIElement` for
**live** windows during display teardown (`Tests/tiledTests/FakeWindowGateway.swift:121-124`).
When a destroy report and that transient coincide, the slot is released immediately rather than
waiting for the time-confirmed death used by `pruneDeadWindows` (a first sighting, then a later
tick at least `deathConfirmation` after it; `TilingController.swift:722-741`).

**Reachable sequence.** A window is tiled. A display teardown / lid transition makes the AX
element invalid and the liveness probe answer `.dead`; the OS also reports the element destroyed.
`windowDestroyed` releases the handle and the slot on the spot. The app window is still alive; the
tile is gone and the window is untiled.

**Verified.** A temporary controller probe set the fake's `probeDead` and then fired
`simulateDestroyed`: the slot was released immediately, with no pending death. The existing
destroy tests cover `.alive` and `.unknown`, but not `probeDead + simulateDestroyed`
(`ControllerBulkOperationTests.swift:588-635`).

**Live caveat.** The frequency of the coincidence needs a real display teardown; the code path is
proven, the production rate is not.

**Direction.** Keep the fast path for a genuinely dead app/process, but route an element-only
`.dead` through the same pending-death clock, or require the adapter's identity check to confirm
the app still lists no matching window before releasing.

### F3. Restore Previous Shortcuts destroys the backup entries it cannot restore

**Evidence.** `restoreResetBackup` clears each backup **before** applying it
(`Sources/tiled/SettingsShortcutsTab.swift:747-765`). The apply gate rejects a combo another action
now owns (`HotkeyBinding.swift:236-259`). A swapped pair is the clean failure case: Top Left and
Top Right swap their defaults, Reset, then Restore. The first apply sees the other action still
holding the default, is rejected, and its backup is already gone; the second apply then sees the
first default and is rejected too. Both backups are cleared, the button flips back to
"Reset Shortcuts", and the user's custom pair is permanently lost.

**Status.** This is already recorded on the unmerged `robustness-audit` branch as D4. It is still
present on `master`; it is repeated here because this audit is of the current tree, not the branch.

**Test gap.** No test drives Reset → edit/swap → Restore. The store gate is tested; the reset
snapshot is not.

**Direction.** Apply the whole snapshot atomically, or clear only entries that applied. Keep
skipped entries for a later retry.

---

## MEDIUM — edge-case wrong behavior, significant mismatch, or meaningful test gap

### F4. Undo ignores a refused requester restore and overstates the restored count

The controller's undo path calls `restore(window: requester)`, discards its Bool, and always calls
`forgetBookkeeping` (`Sources/tiled/TilingController.swift:940-947`); `TilingSpace.undo`'s
requester branch does the same (`Sources/tiled/TilingSpace.swift:410-416`). If the requester's app
refuses the pre-tile write, the window stays visibly in the slot but its record is released. The
controller then counts `group.count` as restored whenever the canvas returned any notice
(`Sources/tiled/TilingController.swift:948-965`) and narrates `entry.snapshot.count`
(`:968-973`), not the number that actually landed. A refusal can therefore produce "N windows
restored" while one of them was not restored. **Test gap:** `UndoIntegrityTests.swift:230-265`
refuses the requester but asserts only registry/death bookkeeping, not the count.

### F5. A deferred pre-tile restore can fire after the window is retiled on another canvas

`deferredRestores` is keyed by handle and `beginRecord` clears it only on the canvas receiving the
new record (`Sources/tiled/TilingSpace.swift:196-204`). Releasing a record on canvas A while its
restore is deferred leaves the entry on A. Retiling the same window on canvas B issues a fresh id
(`TilingController.allocateID`, `:694-704`) and clears only B's map. When A next becomes visible,
`reconcileDeferredRestores` writes the old A frame (`TilingSpace.swift:925-942`), pulling the
window off B's slot. The comment at `:66-71` claims a retile discards the stale restore; that is
true only within one canvas. **Test gap:** `SpaceIndependenceTests.swift:592-626` reconciles only
on the original canvas.

### F6. The menu can say "Untile 0 Windows" and can hide a real undo row

`MenuModel` gates the undo/reset/untile rows on `tiledWindows`, which spans **every visible
canvas** (`Sources/tiled/MenuModel.swift:239`), but titles Untile by `untileCount`, which is the
**focused canvas** (`Sources/tiled/AppDelegate.swift:534-537`). With windows on a second display
and an empty focused canvas, the row reads "Untile 0 Windows"; clicking it does nothing, then the
delegate announces "All tiled windows restored." Conversely, after Untile All the focused canvas
has no tiled windows, so the undo row disappears even though its undo chapter is still live; the
hotkey still works, but the menu's promise is gone. **Test gap:** the empty `MenuModelTests` case
has `canUndoDisplacement: false`; no cross-canvas mismatch case.

### F7. App-action announcements contradict the controller's no-op feedback

The menu and the global hotkey route both announce success unconditionally: Evict
(`Sources/tiled/AppDelegate.swift:805-807`), Untile All (`:810-817`), Undo (`:923-925`), and
single-window untile (`:928-932`). The controller reports no-op outcomes asynchronously through
`onFeedback` (`TilingController.swift:329, 892, 1212, 1226`). Pressing Undo with an empty stack, or
Evict on an untiled focused window, can therefore speak "Evicted windows restored / Focused window
evicted" and then "Nothing to undo / Window isn't tiled." **Test gap:** no AppDelegate
action-result test; `AppDelegateMenuTests` pins the selector mapping only.

### F8. Hide-icon recovery can promise a disabled or remapped Settings combo

`isSettingsHotkeyRegisteredProvider` returns true whenever the Settings action is not in
`failedActions` (`Sources/tiled/AppDelegate.swift:761-764`). Disabled actions are skipped and never
enter `failedActions` (`HotkeyService.swift:168-169`), so disabling Settings makes the provider
return true. The confirm dialog then hard-promises `⌃⌥⇧⌘,` (`SettingsGeneralTab.swift:237-243`),
which is neither enabled nor necessarily the user's current binding. Hiding the menu bar icon then
removes the only visible handle except relaunch. **Status:** the same provider bug is on the
unmerged `robustness-audit` branch as D19; the remapped-label half is additional.

### F9. Welcome can omit its Accessibility warning when opened untrusted

`WelcomeTab` hides the permission row when its provider is nil (`SettingsWelcomeTab.swift:81`).
The Settings controller is built before AppDelegate assigns that provider
(`AppDelegate.swift:739-741`), and `show()` refreshes shortcut instructions, not the permission row
(`SettingsWindowController.swift:102-109`). The poll only calls `permissionStateDidChange()` when
trust changes (`AppDelegate.swift:160-168`). Opening Settings → Welcome while still untrusted can
therefore show a guide with no warning, even though the guide's first step cannot work.
**Test gap:** `SettingsPermissionButtonTests` covers General and Shortcuts, never Welcome.

### F10. Welcome teaches a dead Top Left combo when registration failed

`refreshShortcutInstructions` reads only `hotkeyStore.binding(for: .topLeft).label`
(`SettingsWelcomeTab.swift:201-207`). A combo that lost global registration still has a label; only
the Shortcuts tab receives `failedActions` (`AppDelegate.swift:755-757`). On a first run where
another app owns the default, the guide says "Press ⌥⇧⌘U" and the key does nothing. **Test gap:**
`WelcomeInstructionsTests` covers disabled and customized bindings, not failed registration.

### F11. The Expand row loses its collapse state for an expanded untiled window

`expandedFocusedSlot` returns the slot only when the expanded window still has one
(`Sources/tiled/TilingController.swift:861-868`). An untiled window expanded with ⌥⇧⏎ has a saved
frame but no slot, so the menu falls back to "Expand to Fill Screen" (`MenuText.swift:25-28`)
although the next press would restore the previous frame, not expand again. **Test gap:** the
expanded-untiled behavior is tested (`ExpandToggleTests.swift:74-84`), the row's state is not.

### F12. A pending edge reassert can survive Expand and rewrite splitters from the screen frame

`DragTracker` arms `pendingReasserts[space]` on any edge move (`DragTracker.swift:607-614`).
Expand goes through `FrameWriter` and `markExpected`, which clears drags but not pending reasserts
(`DragTracker.swift:243-250`). A missed mouse-up or a trailing AX tick leaves the pending resize;
the next `mouseLifted` emits `.resize` (`:638-653`). `reassertPlan` excludes expanded windows from
the rects it writes (`TilingSpace.swift:1458`) but `reconciledGrid` does not exclude them from the
splitter reconciliation (`:1455-1481`), so the full-screen achieved frame can drive the column and
row splits and rewrite neighbours. **Test gap:** `ReassertPlanTests.swift:186-193` covers only a
`.grid` source for an expanded window. Edge-shaped; needs a scheduler/probe test.

---

## LOW — precision, labels, and test hygiene

| ID | Finding | Evidence |
|---|---|---|
| F13 | A re-housed window's notice names the intermediate slot before reflow moves it again. | `TilingSpace.swift:667-669` sets the notice before `settle`'s reflow (`:313-324`); `ReflowTests.swift:591-613` is the exact case and never asserts the notice. |
| F14 | A programmatic far jump plus any unrelated click within the 0.5 s debounce can untile. `mouseLifted` marks every in-flight drag as a mouse-up, and no mouse-down is observed. | `DragTracker.swift:531-553, 638-653`; `testSingleFarTickAtMouseUpUntiles` (`DragTrackerTests.swift:541-556`) cannot distinguish a fling from a programmatic move followed by a click. |
| F15 | Undo labels still describe the old switch-only model: "Undo Last Switch" and "Restore N Evicted Windows", although undo also covers swaps (which evict nobody). | `HotkeyAction.swift:40`, `MenuText.swift:9-12`; both strings are pinned by tests. |
| F16 | Bindable arrow keys render as hex in the menu and VoiceOver: recording ⌥→ yields "⌥0x7C". | `HotkeyBinding.swift:102`; the recorder accepts modified arrows (`HotkeyRecorder.swift:53-64`); `HotkeyBindingTests.swift:47` pins the fallback. |
| F17 | The Disable-all tooltip says "keeps defaults for re-enable", but the code parks the current custom combos and restores them. | `SettingsShortcutsTab.swift:269-270`; `FeedbackAndRecorderTests.swift:347-351` pins the wrong copy. |
| F18 | A placement or undo write skipped as already-correct seeds no drag baseline, so a later one-tick short drag can be dropped and leave the window offset. | `FrameWriter.swift:90-95` returns `.skippedNoOp` without `markExpected`; `TilingSpace.swift:443-451` observes but does not `seedBaseline`. Reassert's skip path already seeds (`:1509`). |
| F19 | Two test comments describe the opposite motion: "grows down" for a survivor that grows up; "70pt above" for an edge that ended 70pt below. | `ReflowTests.swift:386-392`; `ControllerGatewayTests.swift:170-190`. The assertions are correct; the comments are not. This is a CODING_STANDARDS violation. |
| F20 | `FakeWindowGateway.release` leaves the window readable and writable, while the live adapter drops the element and pid. Release-on-a-released-handle bugs can pass on the fake. | `FakeWindowGateway.swift:111-115` vs `LiveWindowGateway.swift:199-211`; also `robustness-audit` G6. |

---

## Test gaps that matter more than the line count

### T1. Hotkey registration and reload are not exercised hermetically

`HotkeyServiceTests` asserts constants and the unused `route` table; no test constructs a
`HotkeyService` or calls `registerHotkeys`/`reload` (`Tests/tiledTests/HotkeyServiceTests.swift:5-7`).
Disabled-action skipping, `failedActions`, and reload are therefore unverified in the suite
(30.70% line coverage). The live repro suite is the only pin. A registrar adapter that returns an
`OSStatus` would make these headless-testable.

### T2. AppDelegate launch, permission, and action routing are unpinned

No test constructs `AppDelegate`; `AppDelegateMenuTests` exercises extracted helpers only
(17.45% coverage). The trusted/untrusted launch branches, the first-run Welcome, the hidden-icon
recovery, and the hotkey action switch (`AppDelegate.swift:142-151`) can regress without a red
test.

### T3. The live AX adapter's wiring is not tested; the fake supplies the answers

No test constructs `LiveWindowGateway`; the pure table parse is pinned
(`LiveGatewayMappingTests`), but the Space lookup/cache, observer registration, destroy routing,
and partial-write recovery are live-only (20.18% coverage). This is expected for an AX adapter,
but it means a hermetic green run cannot speak for those features.

### T4. `HotkeyService.route` is dead production code, and the flagship routing test pins it

`route(forHotKeyID:slotByID:)` (`HotkeyService.swift:98-110`) is called only by
`HotkeyServiceTests.swift:135-166`. The Carbon callback routes through `Context.actionByID`
instead (`HotkeyService.swift:216`). The test's comment calls `route` the callback's "only routing
logic"; it is not on the production path. A drift between the two mappings passes both the table
test and the uniqueness test. **Status:** already recorded on `robustness-audit` as D20.

### T5. Some expected values are derived from the implementation

`TilingSpaceHarness.rect` computes expected rects through the canvas's own `grid.rect`
(`TilingSpaceHarness.swift:95-97`), and several controller tests compare against that helper
(`TilingSpaceTests.swift:38`, `ReflowTests.swift:381-384`,
`ControllerBulkOperationTests.swift:60-62`). `ControllerGatewayTests.swift:580-582` asserts an error
equals `TilingSpace.refusalMessage(count:)`, the same function under test. `GridLayoutTests` has
strong literal coverage, so the pure geometry is not circular; the end-to-end tests are. Pin one
literal rect per layout and one literal refusal string.

### T6. Splitter-backup drag semantics are unpinned

The README promises a drag alone never arms the one-step restore, and a drag after a reset does not
clear it (`README.md:84-92`). Tests cover reset/restore and the reset-backup retitle
(`TilingSpaceTests.swift:1074-1124`, `ControllerBulkOperationTests.swift:498-515`), but no test
drives drag → assert no backup, or reset → drag → assert the parked backup survives.

### T7. Conflict and registration-failure UI is untested

The Shortcuts tab's inline conflict message and registration-failure rows
(`SettingsShortcutsTab.swift:279-289, 647-664`) have store tests (`HotkeyBindingTests`) and menu
warning text tests, but no test reads the labels after a rejected duplicate or a failed action.

### T8. First-run Welcome lifecycle is only half covered

`WelcomeInstructionsTests` covers the already-visible refresh path. It does not cover first build
including Welcome, dismissal persisting and selecting General, or reopening Welcome onto a hidden
window (`SettingsWindowController.swift:172-177, 200-224, 243-256`).

---

## Feature coverage map

| Feature | Pinned? | Strongest pin / gap |
|---|---|---|
| Tile, evict, swap, step-aside, re-house, reflow | Yes | `MatrixCrossCheckTests`, `ReflowTests`, `SwapTests` |
| Layout switch and its undo | Yes (engine) | `LayoutSwitchTests`, `UndoIntegrityTests` |
| Expand/collapse, including untiled and refused | Yes (behavior) | `ExpandToggleTests`; menu state is F11 |
| Drag-resize, min-size clamp, screen edges | Yes (engine) | `GridLayoutTests`, `MinimumSizeTests`, `ReassertPlanTests` |
| Per-display / per-Space isolation | Yes on the fake | `SpaceIndependenceTests`, `PerMonitorTests` |
| Closed-window release and deferred writes | Yes on the fake | `ControllerBulkOperationTests`, `SpaceIndependenceTests`; live destroy path is F2/T3 |
| Undo of evictions/swaps | Yes | `UndoIntegrityTests`, `SwapTests`; refused requester is F4 |
| Hotkey registration, disable, reload | No (hermetic) | live repro only; T1 |
| App launch, permission, action dispatch | No (hermetic) | live/launch only; T2 |
| Shortcuts remap, conflict, disable-all | Partial | `HotkeyBindingTests`, `FeedbackAndRecorderTests`; T7, F3 |
| Welcome / guide lifecycle | Partial | `WelcomeInstructionsTests`; F9/F10/T8 |
| Menu/status presentation | Yes for normal states | `MenuModelTests`, `MenuTextTests`, `StatusIconTests`; F6/F7/F11 |
| Live AX adapter | No (hermetic) | live repro only; T3 |

---

## Verified solid

- **Plan/commit matrix.** Every occupancy × target is replayed against the canvas's plan with one
  layout and no double-booked cells (`MatrixCrossCheckTests`).
- **Tiling algebra.** Swap only when the vacated slot is disjoint; a clean leftover steps aside
  before swap; reflow is exact-or-nil with the rightmost tie and requester/expanded exclusion
  (`TilingStateTests`, `SwapTests`, `ReflowTests`).
- **Grid geometry.** Literal rects, clamps, per-column/per-third splitter independence, partition
  and sweep properties, and the 68 edge mappings (`GridLayoutTests`).
- **Reassert.** Achieved-edge reconciliation, app minimum-size clamp, neighbour rounding, and the
  screen-edge snapback (`ReassertPlanTests`, `MinimumSizeTests`, `GridLayoutTests`).
- **Undo integrity.** Step-aside and swap restore both windows; per-canvas history is bounded and
  isolated; a refused evictee re-tile releases its slot (`UndoIntegrityTests`, `PerMonitorTests`).
- **Per-canvas model.** Display identity by CoreGraphics number, withheld-Space fallback, absent
  display keeps its frame, one handle resolves to one canvas (`DisplayIdentityTests`,
  `SpaceIndependenceTests`, `ScreenOwnershipTests`).
- **Write policy.** No-op skip, off-Space deferral, refusal classification, and swipe-back
  reconciliation of placements, expansions, reflow, and restores (`FrameWriterTests`,
  `SpaceIndependenceTests`).
- **Hotkey binding model.** All 22 actions have unique defaults; duplicate rejection, disable,
  park, and restore-through-the-gate are pinned (`HotkeyBindingTests`, `FeedbackAndRecorderTests`).
- **Mutation gate.** 90/90 mutants caught, including the write policy, deferred reconcile, handle
  adoption, icon canvas key, and death-clock cases.

---

## Suggested triage order

1. **F1** — a refused move must roll back to the previous slot. State corruption with a normal
   gesture; fix first.
2. **F2** — reproduce on a real display teardown, then gate the destroy fast path on a confirmed
   app death rather than a single `.dead` probe.
3. **F3** — make Restore Previous Shortcuts atomic. Already on the robustness branch; land it.
4. **F4–F5** — make undo count/restore truthfully, and clear deferred restores across canvases.
5. **F6–F11** — presentation truth: one action receipt, focused-canvas counts, live labels.
6. **T1–T4** — add the registrar/AppDelegate/live-adapter seams and delete or route through the
   dead hotkey table.
7. **A1/A2** — start the architecture work with the expected-write ledger, then the ownership
   register.

---

## Architecture candidates

The full report is the HTML file linked at the top. In brief (these are seams, not "split the
god object": `TilingSpace` and `TilingController` are large because their interfaces are deep, and
size alone is not the finding):

| ID | Candidate | Strength |
|---|---|---|
| A1 | **Expected-write ledger** — one module owns the write's memory, baseline, echo, and convergence verdict. | Strong |
| A2 | **Window ownership register** — one place owns handle→id and the one-canvas-per-handle invariant. | Strong |
| A3 | **Canvas directory** — one resolver owns display+Space→canvas, the withheld fallback, and visibility. | Worth exploring |
| A4 | **One hotkey route** — the callback and the routing test consume the same mapping, or the dead table goes. | Worth exploring |
| A5 | **Action outcome receipt** — the outcome carries the notice and announcement; AppDelegate presents, never reconstructs. | Worth exploring |
| A6 | **Parked shortcuts module** — both park kinds and their stale/clash rules move out of the 796-line AppKit tab. | Worth exploring |

Top recommendation: **A1, the expected-write ledger**. It is the cleanest deepening: a named
domain concept with no owner, an explicit `FrameWriter` → `DragTracker` leak, and one small
interface that pays back across the writer, tracker, canvas, controller, and three test setups.
A2 is the runner-up and the more urgent bug-history signal, but it needs a glossary conversation
about where records end and identity begins.
