# Code-quality follow-up audit — 2026-10-19 (scaffold)

Scope: the whole current tree on `master` — same five slices and two axes
(feature functionality, code quality) as the 2026-10-17 audit
(`.scratch/quality-audit/report.md`). Delta-weighted: depth follows the
changed surface since `2f07c03`; untouched files get spot checks only.

Base: `master` @ `3c3a432` ("Resume mutation runs from the last verdicts").
Prior base: `master` @ `2f07c03` (v0.2.2, 687 tests, 90/90 mutants).
44 commits, 88 files changed between the two bases.

Method: seven parallel slice audits (one per plan task 2.1–4.3), each
read-only; every new finding cites `file:line` and is cross-referenced
against the prior report so duplicates are marked, not re-claimed.
Finding IDs continue the prior sequence (next free: F21+, T9+, A7+).

Limits: **no live verification** — same limit as the prior audit. The
live repro suite, multi-display suite, and physical-display checklist were
not executed. F2 stays parked on live display-teardown evidence; A1/A2
await their design phase and A3/A6 stay exploratory.

---

## Gates (audited commit `3c3a432`)

| Gate | Result |
|---|---|
| `swift build`, warnings/errors | clean (`grep -E "warning:|error:"` empty) |
| `swift test` | **832 / 832 green**, ~3.1 s |
| `scripts/check-test-count.sh` | README's 832 matches the suite |
| `python3 tools/mutation/mutate.py` | not re-run (read-only audit); last verdicts in `build/mutation-results.json` |

`git status --short` at audit start: only `?? docs/plans/` (this plan sheet).

---

## Changed surface since `2f07c03`, grouped by slice

Changed `Sources/` (19 files): `ActionReceipt.swift` (new),
`AppDelegate.swift`, `AppLaunchPlan.swift` (new), `DragTracker.swift`,
`ExpandToggleState.swift` (new), `FrameWriter.swift`, `HotkeyAction.swift`,
`HotkeyActionRouter.swift` (new), `HotkeyBinding.swift`,
`HotkeyService.swift`, `LiveWindowGateway.swift` (+521), `MenuModel.swift`,
`MenuText.swift`, `SettingsGeneralTab.swift`, `SettingsShortcutsTab.swift`,
`SettingsWelcomeTab.swift`, `SettingsWindowController.swift`,
`TilingController.swift` (+554), `TilingSpace.swift` (+300).
Also: `README.md`, `CONTEXT.md`, `CHANGELOG.md [Unreleased]`,
`tools/mutation/*`, most of `Tests/`, and the whole
`.scratch/quality-audit/` ticket arc (01–20 + A1/A2/A3/A6).

Unchanged `Sources/` (12 files, spot-check only): `AppSettings.swift`,
`DisplaySpace.swift`, `HotkeyRecorder.swift`, `Layout.swift`, `main.swift`,
`NSApplication+Activate.swift`, `PermissionWindowController.swift`,
`RecorderButton.swift`, `SlotPreviewView.swift`, `StatusIcon.swift`,
`TopAnchoredStackView.swift`, `WindowGateway.swift`.

New test files since the prior audit: `ActionReceiptTests.swift`,
`AppLaunchPlanTests.swift`, `HotkeyActionRouterTests.swift`,
`HotkeyRegistrationTests.swift`, `LiveGatewayWiringTests.swift`,
`ShortcutsConflictUITests.swift`, `ShortcutsResetBackupTests.swift`,
`SplitterBackupDragTests.swift`, `WelcomeLifecycleTests.swift`,
`HideIconRecoveryTests.swift` (+ `LiveGatewayFakes.swift`).

Slice → prior-ticket claims to re-verify:

| Slice (plan task) | Changed files | Re-verify claims |
|---|---|---|
| Geometry + placement (2.1) | `TilingSpace.swift` | F1, F4, F5, F13, F19 |
| Drag + reassert (2.2) | `DragTracker.swift`, `TilingSpace.swift` | F12, ticket 12 (F14/F18), ticket 18 (T6) |
| Controller + ownership (3.1) | `TilingController.swift`, `ActionReceipt.swift`, `ExpandToggleState.swift` | F2 (parked), tickets 04/05/07, ticket 10, F20 |
| Write policy + AX seam (3.2) | `FrameWriter.swift`, `LiveWindowGateway.swift` | ticket 15 (T3), T5 |
| Hotkeys (4.1) | `HotkeyService.swift`, `HotkeyBinding.swift`, `HotkeyAction.swift`, `HotkeyActionRouter.swift` | tickets 13 (T1), 16 (T4), F16 |
| Menu + presentation (4.2) | `AppDelegate.swift`, `MenuModel.swift`, `MenuText.swift` | tickets 06 (F6), 07 (F7/A5), 10 (F11), 11, 17 (T5) |
| Settings + launch (4.3) | `Settings*`, `AppLaunchPlan.swift`, `AppDelegate.swift` launch sections | ticket 03 (F3), 08 (F8), 09/20 (F9/F10/T8), 19 (T7), 14 (T2) |

---

## Verdict

No HIGH and no MEDIUM findings. Every claimed fix from the 2026-10-17
arc re-verified pinned with no regressions: F1/F4/F5/F13/F19 (slice
2.1), F12/ticket-12/ticket-18 (2.2), tickets 04/05/07/10 plus F20
(3.1), ticket-15/T5-slice (3.2), ticket-13/ticket-16/F16 (4.1), tickets
06/07/10/11/17-slice (4.2), tickets 03/08/09/14/19/20 (4.3). F2 is
still parked (no live teardown evidence gathered, none claimed); A1 is
unchanged (no ledger module exists); A2/A3 are unchanged with one
further A3 instance recorded as design evidence (test-only
display-scoped overloads resolve the bare `tilingKey` while reads use
`actionSpaceKey` — no production caller, not a finding).

Thirteen new LOW functional findings (F21–F33) and three new LOW test
gaps (T9–T11) are filed below and as `issues/01`–`issues/16`. The
pattern across F21/F22/F25/F26: second-write and post-release outcomes
at the edges of the write policy go unread — each needs consecutive
failures or a narrow timing window, none corrupts the common path.
The engine core (plan matrix, Swap/step-aside election, Reflow,
layout-switch chapters, reassert, drag gating, write policy,
receipt path, hotkey route, settings restore) is verified solid.

---

## HIGH — state corruption, data loss, or clearly wrong user-visible behavior

None. No HIGH findings in this audit.

---

## MEDIUM — edge-case wrong behavior, significant mismatch, or meaningful test gap

None. No MEDIUM findings in this audit.

---

## LOW — precision, labels, and test hygiene

### F21. A Swap home-write after a refused requester write goes unread

**Evidence.** `Sources/tiled/TilingSpace.swift:629-639`: when the
requester write is refused, both occupancies are restored in state and
the displaced window is written home (`:635`), but that write's outcome
is discarded while the requester's refusal becomes the branch's whole
story. (Slice `slices/2.1-geometry-placement.md`.)

**Reachable sequence.** Window A seated Top Left, B seated Top Right.
A asks for Top Right; the plan is a Swap. B's write into Top Left
lands; A's write into Top Right is refused. The code restores both
occupancies and writes B toward Top Right. When that home-write is
refused too, B visibly remains in Top Left while state records Top
Right — the disagreement F1 removed, through the back door.

**Test gap.** `testSwapRefusalByRequesterRollsDisplacedBack`
(`Tests/tiledTests/TilingSpaceTests.swift:311-330`) pins the successful
home-write only; no test refuses the second write.

**Direction.** Read the home-write through the shared write policy; on
refusal, surface the shared restore-failure message on the canvas
rather than keeping a silent disagreement (the displaced-first-write
refusal path at `:616-624` shows the shape).

### F22. A Reflow recovery rewrite after a refused grow write goes unread

**Evidence.** `Sources/tiled/TilingSpace.swift:1143-1155`: when a grow
write is refused, survivor occupancies roll to their prior slots and
the old rects are re-written (`:1153`), discarding that pass's outcome.
(Slice `slices/2.1-geometry-placement.md`.)

**Reachable sequence.** A survivor grows into freed cells on the
display; its grow write is refused, so state returns it to its prior
slot and re-writes the old rect. When that recovery write is refused
as well, the survivor visibly holds the grown slot while state records
the prior one, and Reflow reports no entries — a silent disagreement
with no chapter.

**Test gap.** `testRefusedReflowWriteRollsTheSurvivorBack`
(`Tests/tiledTests/ReflowTests.swift:398-411`) pins the successful
recovery only; no test refuses the old-rect rewrite.

**Direction.** Observe the recovery pass; on refusal, surface the
shared refusal message on the canvas (the `writeRects` helper at
`:1177-1196` already owns that message).

### F23. Absorption past the translation margin still misroutes the first tick

**Evidence.** `Sources/tiled/DragTracker.swift:499-504` routes any tick
whose size change exceeds `translationMargin` (`:190`) straight to the
splitter path, and the comment at `:496-498` records the residual: an
app absorbing more than the margin still misroutes its first tick.
(Slice `slices/2.2-drag-reassert.md`.)

**Reachable sequence.** A slot occupant whose app silently rounds a
written frame by more than 8pt receives its first hand title-drag tick;
the origin travels with the drag while the size delta trips the margin,
so the tick reads as an edge grab and yanks the shared splitter by the
full origin delta. The following release issues a snapback (a `.grid`
reassert), which rewrites the window home but leaves the yanked
splitter in place.

**Test gap.** `Tests/tiledTests/DragTrackerTests.swift:532-571` pins the
small-absorption shape and the genuinely size-dominant shape, but no
test pins behavior past the margin: the residual lives only in the
comment.

**Direction.** Consult the hand-evidence signal (or the echo trail)
before routing a size-dominant first tick to the splitters, or bound
the first-tick splitter travel; pin the chosen bound with a
beyond-margin absorption test.

### F24. One pending reassert per canvas — a second edge movement supersedes the first window's achieved-frame reconcile

**Evidence.** `pendingReasserts` keeps a single window per canvas
(`Sources/tiled/DragTracker.swift:151`), and every edge movement
overwrites it (`:661-668`); the release drains whatever entry remains
(`:712-730`). (Slice `slices/2.2-drag-reassert.md`.)

**Reachable sequence.** Window A edge-drags on a canvas, releases, then
a trailing AX report re-arms A; before the next release window B on the
same canvas moves an edge, overwriting the entry with B. The next
release reasserts only B. B's reassert still rewrites A into its
reconciled slot, but A's own achieved-frame clamp reconcile never runs,
so a clamp A suffered stays unreconciled until a later reassert names A.

**Test gap.** `Tests/tiledTests/DragTrackerTests.swift:416-444` pins the
single-window trailing-tick shape; no test drives two windows' pending
entries on one canvas.

**Direction.** Keep the pending set per window and emit one resize
decision per pending window; pin with a two-window trailing-tick test
asserting both achieved frames reconcile.

### F25. An unreadable achieved frame at release silently drops the resize

**Evidence.** The coordinator's drag-end route returns without any
reassert when the achieved-frame read fails
(`Sources/tiled/TilingController.swift:1156-1168`, the
`guard ... else { return }` at `:1159`). (Slice
`slices/2.2-drag-reassert.md`.)

**Reachable sequence.** A release decision fires while the AX frame read
is in its unreadable transient (the lid-close shape the convergence
path already treats as can't-judge at
`Sources/tiled/DragTracker.swift:322-326`): the stored splitter
fractions keep the live-stored positions but no reassert runs, so
neighbours are not rewritten under them until some later reassert.

**Test gap.** No slice test drives the release route with an unreadable
achieved frame; the unreadable-frame leniency is pinned only for the
convergence verdict (`Tests/tiledTests/DragTrackerTests.swift:759-797`).

**Direction.** On an unreadable achieved frame, fall back to a `.grid`
reassert of the owning canvas so occupants still rewrite under the
stored splitters; pin with a release-during-unreadable-frame test.

### F26. A released handle can still answer the focused-window query inside the memoization window

**Evidence.** `focusedWindow` returns the memoized handle without
revalidating it (`Sources/tiled/LiveWindowGateway.swift:355-367`);
`release` drops the element, pid, frame source, handlers, and baseline
but never clears the memoized focus answer (`:440-454`). (Slice
`slices/3.2-write-policy-ax.md`.)

**Reachable sequence.** Focus a window (memoizes the handle) → its death
is confirmed and the coordinator releases it → a slot action within
0.05 s reads `focusedWindow` and receives the released handle.
Downstream the frame read answers nil, so the likely outcome is a
refusal message rather than the "no focused window" answer — a
transient, self-healing misdirection, never a stuck state.

**Test gap.** `focusedWindow` has no hermetic test (it needs the
system-wide AX read); nothing pins post-release focus answers.

**Direction.** Clear the memoized focus answer in `release` when it
names the released handle (and route its stamps through the injected
`now`, see T9).

### F27. README still partitions the live adapter to the live suite only (docs)

**Evidence.** `README.md:285-289` says the unit suite "drives the pure
engine through `FakeWindowGateway`" while "the live adapter
(`LiveWindowGateway`) is exercised by `scripts/run-repro.sh`". Since
ticket 15, the adapter's Space cache, observer routing, destroy
delivery, adoption, release pruning, and write-pair recovery run
hermetically in `Tests/tiledTests/LiveGatewayWiringTests.swift:11-397`
with no grant. (Slice `slices/3.2-write-policy-ax.md`.)

**Reachable sequence.** A reader auditing hermetic coverage concludes
the adapter is live-only and misses the existing seam.

**Test gap.** None (docs only).

**Direction.** One sentence naming the hermetic adapter seam beside the
live-suite sentence; optionally name the residual live-only paths
(focus resolution, element registry fallback, app-list assembly).

### F28. The Carbon callback body runs only against live events

**Evidence.** `carbonCallback` parses the event parameter, resolves
through `route`, and hops to the main queue
(`Sources/tiled/HotkeyService.swift:280-298`). The suite pins `route`
and the performer, but nothing drives the callback itself — the
installer is stubbed out in every registration test
(`Tests/tiledTests/HotkeyRegistrationTests.swift:26-31`), and no test
synthesizes a Carbon event. (Slice `slices/4.1-hotkeys.md`.)

**Reachable sequence.** A regression inside the callback (wrong
parameter name, a dropped async hop, a bypass around `route`) stays
green; only the live suite would notice.

**Test gap.** No seam for the callback's resolve-and-invoke step.

**Direction.** Expose a test-only entry that maps an id to a handler
invocation without a Carbon event, or inject the main-queue hop, so the
callback body is pinned the way `route` already is. Residual of
T4/ticket 16, not a duplicate: ticket 16 closed the dead-table half.

### F29. The shared handler outlives service teardown

**Evidence.** Registrations retire on deinit
(`Sources/tiled/HotkeyService.swift:222-224`), but the handler lives on
the process-wide shared context (`:187-203`) and is never cleared
alongside them. A replaced service's closure stays armed until the next
assignment. (Slice `slices/4.1-hotkeys.md`.)

**Reachable sequence.** Replace the service (or release it) without
assigning a new handler → a Carbon event invokes the stale closure.
Bounded today: the AppDelegate call site captures weakly
(`Sources/tiled/AppDelegate.swift:180`), so the worst outcome is a
dropped fire, never a use-after-release.

**Test gap.** No test pins handler behavior across service replacement;
the registration tests never touch `handler`.

**Direction.** State the ownership rule at the handler declaration (who
clears, and when), or pin replacement ordering through the registrar
seam.

### F30. Dead title helpers keep the pre-ticket-06 all-canvas count

**Evidence.** `Sources/tiled/AppDelegate.swift:749-759` defines private
`undoDisplacementTitle` and `untileAllTitle`; repo-wide grep shows no
caller — the live menu path builds both titles from the snapshot in
`Sources/tiled/MenuModel.swift:281-298` instead. The dead
`untileAllTitle` counts `controller.tiledWindowsInfo` (every visible
canvas), the exact mismatch ticket 06 removed. (Slice
`slices/4.2-menu-presentation.md`.)

**Reachable sequence.** None at runtime (uncalled). A future edit wiring
these helpers back into the menu would reintroduce "Untile N Windows"
counted across canvases.

**Test gap.** No test can pin dead code; deletion is the pin.

**Direction.** Delete both helpers; the snapshot path
(`MenuModel.swift:287-298` with `AppDelegate.swift:577-582`) already
owns both titles.

### F31. Splitter actions stay outside the one-receipt path

**Evidence.** Menu `resetDividers` announces fixed sentences without a
controller verdict (`Sources/tiled/AppDelegate.swift:888-906`,
sentences at `:893-895,905`), while the hotkey route calls
`controller.resetDividers()` and announces nothing
(`Sources/tiled/HotkeyActionRouter.swift:72-74`). The controller
returns `Void`/`Bool`, never an `ActionReceipt`
(`Sources/tiled/TilingController.swift:857-898`), unlike the four
receipt-covered actions. The restore sentence is also worded twice:
canvas notice (`Sources/tiled/TilingSpace.swift:1504`) and delegate
literal (`AppDelegate.swift:894`). (Slice
`slices/4.2-menu-presentation.md`.)

**Reachable sequence.** Press the reset-dividers hotkey with an empty
focused canvas — the controller resets fractions silently (no receipt,
no sentence); the menu row for the same action cannot exist there
(`MenuModel.swift:299-308`), so the two surfaces describe the action
differently by construction. A refused splitter write has no refusal
sentence on either surface (reset clears `error` at
`TilingSpace.swift:1490`).

**Test gap.** No test asserts what a splitter action says (or stays
silent for); receipt tests cover evict/untile/undo only.

**Direction.** Return an `ActionReceipt` from the splitter actions (or
document the silence as intended), route both menu and hotkey through
`present(_)` (`AppDelegate.swift:925-937`), and source the restore
sentence once.

### F32. The restore skip message overwrites the registration-failure line

**Evidence.** `reload`
(`Sources/tiled/SettingsShortcutsTab.swift:238-246`) clears the
conflict line then re-surfaces registration failures (`:284-295`);
`restoreResetBackup` calls `reload` (`:803-804`) and then overwrites
the same single line with "Not restored…" (`:807-814`). (Slice
`slices/4.3-settings-launch.md`.)

**Reachable sequence.** A failed registration is showing beside its
recorder → press Restore Previous Shortcuts with an externally claimed
combo → the "Not restored" line replaces the failure line until the
next re-read. Both truths compete for one announcement line; the
failure stays visible in the menu, but the tab stops naming it.

**Test gap.** No test combines a non-empty `failedActionsProvider` with
a clash-skipped restore.

**Direction.** Join both messages on the conflict line, or re-surface
failures after the restore message, with a combined-case test through
the real tab.

### F33. Atomic Restore Previous Shortcuts has no CHANGELOG entry (docs)

**Evidence.** `Sources/tiled/SettingsShortcutsTab.swift:763-815`
implements the retain-and-retry restore plus footer persistence;
`CHANGELOG.md:7-65` (`[Unreleased] Fixed`) carries sibling bullets for
Welcome and hide-icon recovery but none for the restore change. The
landing change `6324502` touched behavior, `Sources`, `Tests`, and
counts only. (Slice `slices/4.3-settings-launch.md`.)

**Reachable sequence.** Reset Shortcuts → swap two defaults → Restore
Previous Shortcuts → both land, or a clash is retained, named, and
retryable with the footer persisting. User-visible, pinned,
undocumented — a `CODING_STANDARDS.md:17-23` behavior-docs gap.

**Test gap.** None (behavior pinned by `ShortcutsResetBackupTests`).

**Direction.** Add one `[Unreleased] Fixed` bullet describing snapshot
restore, retained clashes, and retry.

---

## Test gaps that matter more than the line count

### T9. The focus-answer memoization lifetime is untestable — its stamps bypass the injected clock

**Evidence.** The Space-table cache honors the injected `now`
(`Sources/tiled/LiveWindowGateway.swift:786-793`), but the focus cache
stamps `Date()` directly at write and both reads (`:356-357,361,365`),
and the focus callback clears it through the shared live instance
(`:1156-1161`). (Slice `slices/3.2-write-policy-ax.md`.)

**Reachable sequence.** Any test wanting to pin the 0.05 s memoization
or its invalidation must sleep on wall time; none does, so the lifetime
is pinned only by the live suite.

**Direction.** Thread `now` through the focus-answer read/write/clear
paths the way the Space cache already does. The Space-cache half of
ticket 15 is done; this is the focus-cache remainder.

### T10. Slot-list expectations derive from the production constants under test

**Evidence.** `Tests/tiledTests/MenuModelTests.swift:171` compares the
submenu's slots to `SlotPresentation.quartersQuads +
SlotPresentation.quartersHalves`, and `:194-198` to the sixths groups —
the same constants `MenuModel.items` iterates to build those rows
(`Sources/tiled/MenuModel.swift:185-190,208-219`). An omission in both
places passes. (Slice `slices/4.2-menu-presentation.md`.)

**Reachable sequence.** Static (test-only circularity); e.g. a slot
dropped from `SlotPresentation` and the model together stays green.
Headers and layout-change rows are literal; only the full lists derive.

**Direction.** Assert one literal slot-name list per layout (as ticket
17 did for rects and the refusal string), keeping the constant-derived
form as a secondary shape check.

### T11. The reset-over-backup overwrite promise is unpinned

**Evidence.** `Sources/tiled/SettingsShortcutsTab.swift:731-734` builds
the "This replaces your previous backup…" promise when a backup already
exists; the suite asserts only the no-backup promise
(`Tests/tiledTests/ShortcutsResetBackupTests.swift:163-165`), and no
test anywhere names the overwrite wording. (Slice
`slices/4.3-settings-launch.md`.)

**Reachable sequence.** Reset Shortcuts (backup parked) → Reset
Shortcuts again → confirm → first snapshot replaced wholesale. The
dialog wording is the only guard; a regression to the wrong promise
stays green while the dialog misleads at the destructive step.

**Direction.** Extend `ShortcutsResetBackupTests` through the existing
`confirmReset` seam (`SettingsShortcutsTab.swift:70`) to capture the
second promise and assert the first snapshot is replaced only after
confirm.

---

## Feature coverage map

| Feature | Pinned? | Strongest pin / gap |
|---|---|---|
| Tile, evict, swap, step-aside, re-house, reflow | Yes | `MatrixCrossCheckTests`, `ReflowTests`, `SwapTests`; new LOW edges F21/F22 (second-write outcomes unread) |
| Layout switch and its undo | Yes (engine) | `LayoutSwitchTests`, `UndoIntegrityTests` |
| Expand/collapse, including untiled and refused | Yes (behavior + row) | `ExpandToggleTests`, `MenuModelTests`, `MenuTextTests` |
| Drag-resize, min-size clamp, screen edges | Yes (engine) | `GridLayoutTests`, `MinimumSizeTests`, `ReassertPlanTests`; new LOW edges F23/F24/F25 |
| Per-display / per-Space isolation | Yes on the fake | `SpaceIndependenceTests`, `PerMonitorTests` |
| Closed-window release and deferred writes | Yes on the fake | `ControllerBulkOperationTests`, `SpaceIndependenceTests`; destroy path still parked (F2); new LOW edge F26 |
| Undo of evictions/swaps | Yes | `UndoIntegrityTests`, `SwapTests`, `ActionReceiptTests` |
| Hotkey registration, disable, reload | Yes (hermetic since ticket 13) | `HotkeyRegistrationTests`; new LOW edges F28/F29 (callback body, handler lifetime) |
| App launch, permission, action dispatch | Yes (through pure plan + router) | `AppLaunchPlanTests`, `HotkeyActionRouterTests`; `AppDelegate` itself still unconstructed (honest limit) |
| Shortcuts remap, conflict, disable-all | Yes | `HotkeyBindingTests`, `FeedbackAndRecorderTests`, `ShortcutsConflictUITests`, `ShortcutsResetBackupTests`; new LOW edges F32/F33/T11 |
| Welcome / guide lifecycle | Yes | `WelcomeInstructionsTests`, `WelcomeLifecycleTests`, `SettingsPermissionButtonTests` |
| Menu/status presentation | Yes for normal states | `MenuModelTests`, `MenuTextTests`, `StatusIconTests`; new LOW edges F30/F31/T10 |
| Live AX adapter | Partial (hermetic seam since ticket 15) | `LiveGatewayWiringTests`, `AX*Tests`; residual live-only paths documented; new LOW edges T9/F27 |

---

## Verified solid

Carried forward from 2026-10-17 and re-confirmed on `3c3a432` (each
with its re-verification pin in the slice notes):

- **Plan/commit matrix, tiling algebra, grid geometry, reassert,
  undo integrity, per-canvas model, write policy, hotkey binding
  model** — as in the prior report's list, now plus: refusal rollback
  to the prior slot (F1), truthful undo counts (F4), cross-canvas
  deferred-restore discard with the refused re-place carve-out (F5),
  focused-canvas menu keying (F6), one receipt per action (F7),
  live-combo hide-icon recovery (F8), Welcome truth (F9/F10),
  expand row + pending-reassert discipline (F11/F12), post-reflow
  notice + displacement copy + keycap labels + parked-combo tooltip
  (F13/F15–F17), drag-out hand gating + skipped-write seeding (F14/F18),
  literal end-to-end expectations (T5), splitter-backup drag semantics
  (T6), conflict/failure UI (T7), Welcome lifecycle (T8), registrar +
  reload + teardown seam (T1), launch-plan + router seam (T2), live
  adapter seam + fake parity (T3/F20), one hotkey route (T4).
- **Mutation gate.** Not re-run (read-only audit); last verdicts in
  `build/mutation-results.json` (143/143 per the prior arc's final
  gates plus review/AX-placement follow-ups).

---

## Suggested triage order

1. **F21–F22** — read second-write outcomes through the write policy
   (Swap home-write, Reflow recovery). Same shape, same message owner.
2. **F25–F26 + T9** — focus/frame transients: unreadable-frame
   fallback, focus-memo clearing, injected clock for the focus cache.
3. **F31–F32 + T11** — splitter receipt coverage and the Shortcuts-tab
   message lines (conflict line, overwrite promise).
4. **F23–F24** — drag edge cases (margin absorption, per-window pending
   set). Small design surface; bound and pin.
5. **F28–F30 + T10** — dead code and derived expectations (callback
   seam, dead title helpers, literal slot lists). Cheap, mechanical.
6. **F27 + F33 + H-handler note (F29)** — docs accuracy (README seam
   sentence, CHANGELOG restore bullet) and the handler ownership rule.

---

## Architecture candidates

No new A7+ candidates. Status carried forward: **A1 unchanged** (no
ledger module; tolerance import and split ownership persist — slice
3.2); **A2 unchanged** (linear handle→canvas scan persists — slice
3.1); **A3 unchanged** with one further instance for the design phase
(test-only display-scoped overloads resolve the bare `tilingKey` while
reads use `actionSpaceKey`; no production caller — slice 3.1); **A4
closed** by ticket 16 (one derived route); **A5 closed** by ticket 07
(one receipt); **A6 untouched** (exploratory, out of scope).
