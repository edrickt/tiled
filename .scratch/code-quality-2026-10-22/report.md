# Code-quality audit — 2026-10-22

Scope: the whole tree on `master` @ `47dea76`, six read-only slice
reviews (engine, controller/write path, input/launch, presentation,
settings UI, tests), then a remediation pass on the findings that
could land safely with tests. Method: the thermo-nuclear code-quality
review rubric — structural simplification first, then boundary and
test-quality findings.

Base: `master` @ `47dea76`. Prior audits: `../quality-audit/report.md`
(2026-10-17) and `../quality-audit-followup/report.md` (2026-10-19).
This pass re-checks every open follow-up finding and files new
structural candidates as one-or-two-sentence notes in the slice files.

## Gates

| Gate | At audit start | At hand-off |
|---|---|---|
| `swift build`, warnings/errors | clean | clean |
| `swift test` | 833 green, 1 skipped | **845 green, 1 skipped** |
| `scripts/check-test-count.sh` | README 833 matches | README 845 matches |
| `tools/mutation/mutate.py` | last run 143/143 | see the run recorded with this report |

## Verdict

The engine and the write policy remain the strongest parts of the
tree: the plan matrix, tiling algebra, reassert, undo chapters, write
policy, receipt path, and hotkey route are all pinned by behavior
tests. The maintainability debt is concentrated in four places:

1. **The write transaction is hand-rolled five times.** `place`,
   both halves of `applySwap`, `restoreEvictees`, and `reflow` each
   capture different pre-state, decide separately whether a rollback
   re-writes a frame, and drop the reverse write's outcome. F21 was
   one dropped outcome; the durable fix is one `MoveAttempt` plus an
   action-scoped failure list (A1).
2. **Canvas and window identity have no one owner.** Eleven canvas
   resolvers, three visible-canvas enumerations, four controller maps,
   and eight handle-keyed dictionaries in the live adapter make the
   same invariants conventional rather than typed (A2/A3).
3. **The AppDelegate is lifecycle, presenter, and icon renderer in one
   1,076-line file.** The menu snapshot claims to be everything the
   menu reads but excludes hotkey labels, so `force: true` bypasses the
   diff. A `MenuBarPresenter` with one honest snapshot removes the
   duplicate focus reads and the force path (P1–P3).
4. **The 845-line Shortcuts tab is a view, persistence layer, conflict
   manager, and rules engine.** A parked-combo model plus a priority
   notice model would delete the last-writer-wins message contract
   (A6/S1/S3).

No HIGH findings. The functional edge cases that remain are LOW:
absorption past the drag margin (F23), the Carbon callback seam
(F28/F29), and the dead reset-over-backup promise (T11).

## Fixed in this pass

Each row is a behavior-preserving cleanup or a LOW correctness fix with
a new pin; every commit passed `swift build`, the targeted suites, and
the full suite before landing.

| Finding | Change | Commit |
|---|---|---|
| F30, T10 | Deleted the dead menu-title helpers and `RecorderButton.slot`; the menu test now asserts literal slot lists instead of the production constants it also iterates. | `67ded73` |
| F26, T9 | `FocusMemo` owns the focus answer; stamps use the injected clock, the focus observer clears it, and `release` drops the handle it names. Three wiring tests pin hit, expiry, and invalidation. | `0d030f2` |
| F24 | Pending edge reasserts are a per-window set, not a canvas-keyed map. Two windows edge-dragging on one canvas both reconcile on mouse-up. | `92f53fe` |
| F25 | `ReassertSource.resize` carries an optional achieved frame; an unreadable read keeps the stored splitters and still maps and writes every rect. Pinned at the pure plan and through the drag-end route. | `70a738c` |
| F31, P4 | Splitter reset/restore return one `ActionReceipt`; the menu and reset hotkey share `resetOrRestoreSplitters()`, so the hotkey restores a parked backup instead of overwriting it. A refused reassert is no longer announced as a successful reset. | `ed099df` |
| F32 | A skipped shortcut restore joins its result with the registration-failure sentences instead of overwriting them on the one live-region line. | `517e85b` |
| F27, F33 | README names the live adapter's hermetic seam; CHANGELOG records the atomic shortcut restore and the other behavior fixes. | `83df397` |
| F21 | A swap rollback reads the displaced window's home write; a second refusal is named beside the requester's refusal instead of leaving a silent screen/state disagreement. A scripted second-write refusal pins it. | `a67c0c9` |
| Settings S2 | One guarded `HotkeyBinding` stored-entry codec serves the store and both park namespaces; corrupt negative modifiers fall back instead of trapping. | `d486aef` |

## Still open — prioritized

### 1. A1: one expected-write transaction and one failure list

The engine slice's findings 1–2. A single-window `MoveAttempt`
(`from`, `to`, previous record) owns rollback and its reverse write; an
action-scoped `[Failure]` collected by the push layer replaces the one
`Refusal` slot and `reportRestoreFailures`' precedence rule. This is the
durable fix for the F21/F22 class and the canvas-side half of the
expected-write ledger. `FrameWriter`'s clamp repair (controller S8)
belongs in the same ledger: it currently writes a second time, ignores
the result, and arms an expectation anyway.

Evidence: `slices/01-engine.md` findings 1–2; `slices/02-controller-write.md`
S8. Classification: design, M/L.

### 2. A2/A3: a window register and a canvas directory

`WindowRegister` owns `windowIDs`, `nextID`, `deadSince`, and
`pendingVerifications`, with `forget` clearing all of them. Ownership
stays derived from canvas records; an id→canvas map would contradict
the canvas's own ownership rule. `CanvasDirectory` owns the `spaces`
table, stale marks, last focus, visibility, the withheld fallback, and
one `visibleKeys()` enumeration; the mechanical first half is deleting
the four test-only display-scoped overloads and collapsing the four
`holdsAnything` copies. The live adapter's eight handle-keyed
dictionaries want one `WindowBinding` struct plus a derived token index.

Evidence: `slices/02-controller-write.md` S1, S2, S7. Classification:
design, M.

### 3. P1–P3, P5: one menu-bar presenter and one honest snapshot

Extract `MenuBarPresenter` (one `MenuBarSnapshot { menu, icon }`, the
last-snapshot diff, `menuOpen`, NSMenu construction, show/hide) and
`StatusIconRenderer` (snapshot in, `NSImage` out). Put hotkey labels in
the snapshot so `MenuModel.items` needs no live binding closure and
`force: true` can be deleted. Build one `MenuReads` value from the
canvas key so `activeWarnings` cannot re-resolve focus. Collapse
`Feedback` and the four receipt-overlay fields into `ActionReceipt` plus
one `NoticePresentation`.

Evidence: `slices/04-presentation.md` P1–P3, P5. Classification:
design, L.

### 4. A6: a shortcut park model and a priority notice

`ShortcutPark` owns both park namespaces, the stale-edit rule, the
snapshot transaction/fixpoint, and retry state; two pure plans drive
the tab. `ShortcutNotice` gives the one live-region line a fixed
priority (`failures`, then `conflict`, then `result`) and one
announcement per identity change. Decide the reset/restore button model:
either delete the unreachable "replaces your previous backup" branch
(T11) or make a second reset an explicit action.

Evidence: `slices/05-settings-ui.md` S1, S3, S4, S6. Classification:
design, M.

### 5. F23, F28, F29: input seams

- **F23** — the tick classifier is a magnitude-ordered if-ladder; a
  size-dominant first tick beyond the 8pt margin yanks a splitter.
  Replace it with one pure `TickShape` classifier (noise bound plus a
  dominance ratio) and pin the absorbed-translation and drifty-grab
  shapes (`slices/03-input-launch.md` S3).
- **F28/F29** — the Carbon callback and the process-wide handler are
  static state inside a per-service object. Extract
  `CarbonHotkeyEventRouter` with `dispatch(hotKeyID:deliver:)`; the
  service clears the handler on teardown. Tests can then drive the
  parse/resolve/hop step hermetically (`slices/03-input-launch.md` S2).

Classification: design, M each.

### 6. Test hygiene

Add one `ControllerHarness` beside `TilingSpaceHarness`; nine suites
redeclare screen, setup, `addFocusedWindow`, and `canvas`, and
`UndoIntegrityTests` already drifted to `NSScreen.screens`. Inject the
prune scheduler instead of the fixed 0.3s wait. T11's premise is
currently unreachable, not merely unpinned — settle the product rule
first. The transient-dead destroy quadrant (F2) still needs live
teardown evidence, as its ticket says.

Evidence: `slices/06-tests.md` findings 5, 7–10. Classification:
mechanical, M; F2 parked.

## Verified solid

The slice reviews re-confirmed: plan/commit matrix and tiling algebra;
swap, step-aside, re-house, and reflow election; layout switch and undo
chapters; reassert and achieved-edge reconciliation; the write policy's
one `stands` reading; the receipt path for the four covered actions;
one derived hotkey route; the registrar seam; the launch plan and
action router; the focused-canvas menu counts; and the literal
end-to-end expectations added by the prior audit (T5).

## Method and limits

Read-only slice reviews were done by six parallel reviewers; the
consolidation and every edit were done in the main checkout, one
commit per verifiable unit. No live AX run and no physical-display
checklist were executed. The mutation gate is the remaining check; see
its recorded result below.

## Slice files

- `slices/01-engine.md` — TilingSpace, Layout, ExpandToggleState.
- `slices/02-controller-write.md` — TilingController, gateways, FrameWriter.
- `slices/03-input-launch.md` — DragTracker, hotkeys, AppLaunchPlan.
- `slices/04-presentation.md` — AppDelegate, MenuModel, MenuText, StatusIcon.
- `slices/05-settings-ui.md` — Settings tabs and shared controls.
- `slices/06-tests.md` — suite quality and open coverage.
