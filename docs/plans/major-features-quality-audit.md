# Major Features Code-Quality Audit — Implementation Plan

- **Status:** done
- **Date:** 2026-10-19
- **Slug:** `major-features-quality-audit`
- **Brief:** _(none — free-text request "please perform an audit on major features on code quality"; prior audit at `.scratch/quality-audit/report.md` used as context)_
- **Implementation started:** 2026-10-19 @ `3c3a432`

## 1. Context

Tiled is a native macOS window manager (Swift, single `tiled` executable + single `tiledTests` target, `Package.swift`, macOS 13). The last full code-quality & feature-functionality audit ran 2026-10-17 on `master @ 2f07c03` (687 tests, 90/90 mutants) and produced `.scratch/quality-audit/report.md` plus 20 functional/test-seam tickets and 4 architecture candidates. Since then tickets 01 and 03–20 landed (plus follow-up review fixes and an AX placement fix); current `master` is 832/832 green, matching `README.md:246`.

Remaining open items from that arc (`.scratch/quality-audit/README.md`): F2 parked on live display-teardown evidence; A1/A2 awaiting a design phase; A3/A6 exploratory-only. The user now asks for an audit of major features on code quality — i.e. a fresh, read-only audit of the current tree that (a) verifies the landed fixes did not introduce new quality regressions, (b) re-scores code quality per major feature slice, and (c) files any new findings without implementing fixes.

## 2. Goal and success criteria

- **Goal:** Produce a frozen, evidence-backed code-quality audit of every major feature on current `master`, reusing the prior report's method, and file new findings as `.scratch/` tickets without changing product behavior.
- **Success criteria:**
  - [ ] Every major feature slice below has a written verdict with file:line evidence — proven by `docs/plans/major-features-quality-audit.md` phases 2–4 complete and `.scratch/quality-audit-followup/report.md` (or `<slug>-v2` report dir if the hub prefers) merged to the working tree
  - [ ] Baseline gates re-recorded on the audited commit: `swift build` warnings empty, `swift test` 832/832 (or new count with explanation), `./scripts/check-test-count.sh` pass — proven by pasted gate output in the report
  - [ ] No product-behavior change: `git status --short` shows only audit docs (report + tickets) — proven by `git status --short` output in the completion notes
  - [ ] New findings triaged into TODO/DONE/PARKED with `file:line` pointers and severities, cross-referenced against the 2026-10-17 report so duplicates are marked, not re-claimed — proven by the report's triage table

## 3. Non-goals

- Implementing any fix, refactor, or test change in `Sources/` or `Tests/` (audit is read-only; fixes become tickets for a later arc).
- Resolving parked F2 (needs a real display teardown / lid transition with Accessibility grant) or designing A1/A2/A3/A6 (separate design phase).
- Running the live repro suites (`make repro`, `tools/repro/suite.swift`, `multi-display-suite.swift`) or the physical-display checklist — hermetic audit only, same limit as the prior report.
- Running the full mutation gate to completion (`python3 tools/mutation/mutate.py`) unless cheap; the audit reads the last recorded verdicts and spot-checks seams instead.
- Changing project, lint, CI, or release config; touching production/shared systems; committing, pushing, or opening a PR.

## 4. Decisions and assumptions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Audit scope | Delta-plus-coverage: re-audit all 5 slices, depth weighted to changed files since `2f07c03` | Full re-audit honors "major features"; weighting avoids re-proving untouched geometry |
| Report location | New dir `.scratch/quality-audit-followup/report.md`, hub README left frozen | `CODING_STANDARDS.md:28-31`: point-in-time `.scratch` reports are frozen history; correct with a new note |
| Glossary binding | All finding titles/prose use `CONTEXT.md` positive terms (`slot`, `reassert`, `display`, `canvas`, `receipt`); `_Avoid_` terms are defects | `CODING_STANDARDS.md:6-13`, `docs/agents/domain.md` |
| Probes | Temporary harness probes allowed, must be removed before the gate (as in prior audit F1/F2) | Keeps audit read-only in its final diff while permitting reachable-sequence verification |
| Mutation evidence | Record last verdicts from `build/mutation-results.json` + ticket log; do not re-run full table | Full mutation is the implement gate, not the audit gate; audit must stay fast and read-only |

**Assumptions:** `master` stays at 832 green during the audit (any new red is recorded as a pre-existing failure, not fixed); `swift test` remains the hermetic gate (~3 s); F2 live evidence stays unavailable; the auditor has macOS `swift` toolchain only (no GUI/AX grants). If any assumption breaks, record it in section 13 and re-scope before filing tickets.

## 5. Approach

Work slice by slice over the current tree, reusing the prior report's two axes (feature functionality: does documented behavior match the code and is it pinned? code quality: depth, locality, seams, test surface). Start by freezing the baseline (commit sha, gate outputs, changed-file list since `2f07c03`) so every later verdict is anchored. Then audit the engine (pure, highest coverage), the coordinator/AX seam (lifecycle + write policy + live adapter), and the shell (hotkeys, menu, settings, launch) — each ending in a slice verdict with `file:line` evidence.

For each slice, diff behavior docs (`README.md`, `CONTEXT.md`, `CHANGELOG.md [Unreleased]`) against the code, check the ticket-closed claims (did F1/F3–F20 + follow-ups actually pin what they claim?), and hunt the four known quality clusters (expected-write ownership per ADR-0002-adjacent `FrameWriter` → `DragTracker` coupling, handle→canvas ownership scans, display+Space→canvas resolvers, hotkey routing single-source). New findings get HIGH/MEDIUM/LOW + T-gap IDs continuous with the prior report (next free: F21+, T9+, A7+), each with evidence, reachable sequence, test gap, and direction — but no code change.

Rejected alternatives: _implement-as-we-go_ (one line: mixes verdict with fix and invalidates the read-only gate). _Live-suite audit_ (one line: needs GUI/TCC/quiet desktop, explicitly out of scope). _Mutation-complete audit_ (one line: expensive and unnecessary for a read-only pass; spot-checks suffice).

### Test strategy (TDD)

- **Acceptance examples:**
  - Given the audited commit, when `swift test` runs, then all tests pass and the count matches `README.md:246`.
  - Given a claimed-fixed finding (e.g. F1 refusal rollback), when the audit replays its reachable sequence via existing tests + code read, then the fix is confirmed pinned or a regression ticket is filed.
  - Given a new suspicious behavior, when a temporary probe is added, then the probe result is recorded and the probe is removed before the gate.
- **Test levels and seams:** No new tests are added. Evidence comes from reading existing seams: `Tests/tiledTests/FakeWindowGateway.swift`, `TilingSpaceHarness.swift`, `LiveGatewayFakes.swift`, and the per-slice suites listed in phases 2–4.
- **Fixtures and test data:** Existing fakes/harnesses only. Temporary probes (if any) are scratch files outside `Sources/`/`Tests/`, deleted before completion.
- **Red command:** `swift test` (baseline; expected green — any red is recorded as pre-existing, not fixed).
- **Green command:** `swift test` (final; must remain green).
- **Full suite:** `swift test` (~3 s) + `swift build 2>&1 | grep -E "warning:|error:"` (expected empty) + `./scripts/check-test-count.sh`.
- **Regression protection:** The 832-test hermetic suite plus `README.md:246,280` published counts and `scripts/check-test-count.sh`; no test may be weakened, skipped, or deleted.
- **TDD exceptions:** All audit tasks (1.1–5.3) are non-behavioral read-only analysis producing markdown only; no failing test applies. Substitute check for each task is the gate trio (`swift build` warnings empty + `swift test` green + `git status` shows docs only). No behavior change hides behind this exception.
- **Behavioral exceptions:** none (no behavior change is planned; any accidental behavior change must be reverted, not recorded as an exception).
- **Non-testable scope:** Live AX behavior, display teardown/lid transitions (F2), permission dialogs, global hotkey registration against other apps, and multi-display physical checklist — all need GUI/TCC/hardware and are recorded as limits, not verdicts.

## 6. Work breakdown

### Phase 1 — Baseline and feature map

**Outcome:** The audited commit, gate outputs, changed-file list, and slice checklist are frozen so later verdicts are anchored.

- [x] **1.1 Freeze the baseline**
  - **Files:** `README.md` (counts), `VERSION`, `build/mutation-results.json` (read-only), new `.scratch/quality-audit-followup/report.md` (scaffold only)
  - **Changes:** Record `git rev-parse HEAD`, `git status --short`, `git log --oneline 2f07c03..HEAD`, `swift build 2>&1 | grep -E "warning:|error:"`, `swift test` tail, `./scripts/check-test-count.sh`; scaffold the report header (base, method, limits, gates table).
  - **TDD exception:** Non-behavioral evidence gathering; no failing test applies. Substitute check is the three gate commands themselves.
  - **Verify:** `git rev-parse HEAD && git status --short` + `swift build 2>&1 | grep -E "warning:|error:"` (expected empty) + `swift test 2>&1 | tail -5` (expected 832/832) + `./scripts/check-test-count.sh` (expected match)
  - **Depends on:** none

- [x] **1.2 Map changed surface since the last audit**
  - **Files:** `.scratch/quality-audit-followup/report.md` (feature map section)
  - **Changes:** List files changed since `2f07c03` (`git diff --stat 2f07c03..HEAD`), group by the 5 slices, and note which prior findings each change claims to close (tickets 01, 03–20 + follow-ups). Carry forward the prior feature-coverage map as the starting checklist.
  - **TDD exception:** Non-behavioral mapping; existing suite covers behavior. Substitute check: `git diff --stat 2f07c03..HEAD` runs and every changed `Sources/` file appears in exactly one slice.
  - **Verify:** `git diff --stat 2f07c03..HEAD | head -60` + `git log --oneline 2f07c03..HEAD | wc -l`
  - **Depends on:** 1.1

### Phase 2 — Engine audit (Layout, TilingSpace, DragTracker)

**Outcome:** Verdicts on tiling geometry, placement/commit, and gesture quality, with re-verification of F1/F4/F5/F11–F14/F18–F19 fixes.

- [x] **2.1 Audit tiling geometry and placement core**
  - **Files:** `Sources/tiled/Layout.swift`, `Sources/tiled/TilingSpace.swift`, read-only review of `Tests/tiledTests/GridLayoutTests.swift`, `MatrixCrossCheckTests.swift`, `TilingSpaceTests.swift`, `TilingStateTests.swift`, `SwapTests.swift`, `EvictTests.swift`, `ReflowTests.swift`, `LayoutSwitchTests.swift`, `NeighbourRoundingTests.swift`, `MinimumSizeTests.swift`
  - **Changes:** Check plan/commit matrix, swap disjointness, step-aside-before-swap, reflow exact-or-nil + rightmost tie + requester/expanded exclusion, layout-switch untile semantics, per-canvas undo chapters against `CONTEXT.md` (Slot, Layout, Swap, Re-house, Reflow, Displacement, Expand); re-verify F1 (refused move rolls back to prior slot), F4/F5 (undo count truth + cross-canvas deferred-restore discard), F13/F19 (notice ordering, comment accuracy) remain pinned; file F21+ for any new geometry/commit gap with `file:line`, reachable sequence, and test gap.
  - **TDD exception:** Read-only audit; no production change. Substitute check: `swift test --filter 'GridLayout|MatrixCrossCheck|TilingSpace|TilingState|Swap|Evict|Reflow|LayoutSwitch'` green.
  - **Verify:** `swift test --filter 'GridLayout|MatrixCrossCheck|TilingSpace|TilingState|Swap|Evict|Reflow|LayoutSwitch' 2>&1 | tail -4` — expected pass; `git status --short` shows docs only
  - **Depends on:** 1.2

- [x] **2.2 Audit drag-resize and reassert**
  - **Files:** `Sources/tiled/DragTracker.swift`, `Sources/tiled/TilingSpace.swift` (`reassert`/`reassertPlan`/`reconciledGrid`), read-only review of `Tests/tiledTests/DragTrackerTests.swift`, `ReassertPlanTests.swift`, `SplitterBackupDragTests.swift`, `MinimumSizeTests.swift`
  - **Changes:** Check edge/splitter fractions, min-size clamp vs achieved frame, screen-edge snapback, pending-reassert vs Expand interaction (F12), drag-out hand-evidence gating + skipped-write baseline seeding (ticket 12), splitter-backup pin (ticket 18) against `CONTEXT.md` (Splitter, Reassert, Achieved frame, Drag-out, Visible frame); file F21+ for new gesture/reassert gaps.
  - **TDD exception:** Read-only audit. Substitute check: `swift test --filter 'DragTracker|ReassertPlan|SplitterBackupDrag|MinimumSize'` green.
  - **Verify:** `swift test --filter 'DragTracker|ReassertPlan|SplitterBackupDrag|MinimumSize' 2>&1 | tail -4` — expected pass
  - **Depends on:** 1.2

### Phase 3 — Coordinator and AX seam audit (TilingController, FrameWriter, LiveWindowGateway, DisplaySpace)

**Outcome:** Verdicts on lifecycle/ownership/write-policy/live-adapter quality, with F2-parked status confirmed untouched and T3/T5 seams re-checked.

- [x] **3.1 Audit controller lifecycle and canvas ownership**
  - **Files:** `Sources/tiled/TilingController.swift`, `Sources/tiled/DisplaySpace.swift`, `Sources/tiled/ActionReceipt.swift`, `Sources/tiled/ExpandToggleState.swift`, read-only review of `Tests/tiledTests/ControllerBulkOperationTests.swift`, `ControllerGatewayTests.swift`, `SpaceIndependenceTests.swift`, `PerMonitorTests.swift`, `ScreenOwnershipTests.swift`, `DisplayIdentityTests.swift`, `UndoIntegrityTests.swift`, `ExpandToggleTests.swift`, `LidSleepWakeTests.swift`, `ObservationRegistryTests.swift`, `HandleIdentityTests.swift`, `FakeGatewayFidelityTests.swift`
  - **Changes:** Check dispatch/focus/pruning/multi-canvas aggregation, handle→canvas resolution scans (A2), display+Space→canvas resolvers + withheld fallback + absent-display frame (A3), destroy fast path vs death clock (confirm F2 still parked, no silent behavior claim), undo-chapter truth + receipt single-source (tickets 04/05/07), expand-state following (ticket 10), F20 fake-fidelity delta; file F21+/T9+ for new lifecycle/ownership gaps. Glossary: canvas, Space, receipt, deferral, expected write, eviction, displacement.
  - **TDD exception:** Read-only audit. Substitute check: `swift test --filter 'ControllerBulk|ControllerGateway|SpaceIndependence|PerMonitor|ScreenOwnership|DisplayIdentity|UndoIntegrity|ExpandToggle|LidSleep|ObservationRegistry|HandleIdentity|FakeGatewayFidelity'` green.
  - **Verify:** above filter `2>&1 | tail -4` — expected pass
  - **Depends on:** 1.2

- [x] **3.2 Audit write policy and live AX adapter seam**
  - **Files:** `Sources/tiled/FrameWriter.swift`, `Sources/tiled/LiveWindowGateway.swift`, `Sources/tiled/WindowGateway.swift`, read-only review of `Tests/tiledTests/FrameWriterTests.swift`, `LiveGatewayMappingTests.swift`, `LiveGatewayWiringTests.swift`, `AXConversionTests.swift`, `AXLivenessTests.swift`, `AXWriteTests.swift`, `LiveGatewayFakes.swift`
  - **Changes:** Check the one shared write policy (expected / already-correct skip / refused / deferred off-Space), `Result.stands` read sites, swipe-back reconcile, `FrameWriter` → `DragTracker` tolerance/convergence coupling (A1), Space lookup/cache + observer/destroy routing + partial-write recovery testability (ticket 15, T3); confirm coverage split (pure pinned vs live-only) is still honestly documented; file A7+/T9+ for new seam/ownership gaps. Do not construct live AX objects against real hardware.
  - **TDD exception:** Read-only audit. Substitute check: `swift test --filter 'FrameWriter|LiveGateway|AXConversion|AXLiveness|AXWrite'` green.
  - **Verify:** above filter `2>&1 | tail -4` — expected pass
  - **Depends on:** 1.2

### Phase 4 — Shell audit (hotkeys, menu/status, settings/launch)

**Outcome:** Verdicts on hotkey routing, menu truth, settings, and launch/permission quality, with F3/F6–F10/F15–F17/T1/T2/T4/T6–T8 fixes re-verified.

- [x] **4.1 Audit hotkey registration and routing**
  - **Files:** `Sources/tiled/HotkeyService.swift`, `HotkeyBinding.swift`, `HotkeyAction.swift`, `HotkeyActionRouter.swift`, `HotkeyRecorder.swift`, `RecorderButton.swift`, read-only review of `Tests/tiledTests/HotkeyServiceTests.swift`, `HotkeyBindingTests.swift`, `HotkeyActionRouterTests.swift`, `HotkeyRecorderTests.swift`, `HotkeyRegistrationTests.swift`, `FeedbackAndRecorderTests.swift`
  - **Changes:** Check single-route invariant (ticket 16, ex-T4 dead table), registrar seam testability + disabled-skip + `failedActions` + reload (ticket 13, ex-T1), 22-action uniqueness, duplicate rejection, disable/park/restore gates, arrow-key labels (F16 was fixed — confirm), binding storage coverage; file T9+/F21+ for new routing/registration gaps.
  - **TDD exception:** Read-only audit. Substitute check: `swift test --filter 'Hotkey|FeedbackAndRecorder'` green.
  - **Verify:** `swift test --filter 'Hotkey|FeedbackAndRecorder' 2>&1 | tail -4` — expected pass
  - **Depends on:** 1.2

- [x] **4.2 Audit menu, status, and action presentation**
  - **Files:** `Sources/tiled/AppDelegate.swift`, `MenuModel.swift`, `MenuText.swift`, `StatusIcon.swift`, `SlotPreviewView.swift`, `TopAnchoredStackView.swift`, read-only review of `Tests/tiledTests/AppDelegateMenuTests.swift`, `MenuModelTests.swift`, `MenuTextTests.swift`, `StatusIconTests.swift`, `SlotPreviewRenderingTests.swift`, `TestViewText.swift`
  - **Changes:** Check focused-canvas keying (ticket 06, ex-F6), one-receipt menu+announcement path (ticket 07, ex-F7/A5), expand-row collapse state (ticket 10, ex-F11), undo-model copy (ticket 11, ex-F13/F15–F17), literal vs derived expectations (ticket 17, ex-T5); re-scan for menu/announcement disagreement and stale undo-model labels.
  - **TDD exception:** Read-only audit. Substitute check: `swift test --filter 'AppDelegateMenu|MenuModel|MenuText|StatusIcon|SlotPreview'` green.
  - **Verify:** above filter `2>&1 | tail -4` — expected pass
  - **Depends on:** 1.2

- [x] **4.3 Audit settings, permission, welcome, and launch**
  - **Files:** `Sources/tiled/SettingsWindowController.swift`, `SettingsGeneralTab.swift`, `SettingsShortcutsTab.swift`, `SettingsWelcomeTab.swift`, `PermissionWindowController.swift`, `AppSettings.swift`, `AppLaunchPlan.swift`, `NSApplication+Activate.swift`, relevant `AppDelegate.swift` launch/permission/poll sections, read-only review of `Tests/tiledTests/ShortcutsConflictUITests.swift`, `ShortcutsGroupingTests.swift`, `ShortcutsGuidanceTests.swift`, `ShortcutsResetBackupTests.swift`, `SettingsPermissionButtonTests.swift`, `PermissionWindowTests.swift`, `WelcomeInstructionsTests.swift`, `WelcomeLifecycleTests.swift`, `HideIconRecoveryTests.swift`, `AppSettingsTests.swift`, `AppLaunchPlanTests.swift`
  - **Changes:** Check atomic restore (ticket 03, ex-F3 — confirm no backup-destroy regression), hide-icon live-combo promise (ticket 08, ex-F8), Welcome permission/registration truth + lifecycle (tickets 09/20, ex-F9/F10/T8), conflict/failure UI pins (ticket 19, ex-T7), launch-plan/permission branches testability (ticket 14, ex-T2), glossary-bound copy; file F21+/T9+ for new settings/launch gaps.
  - **TDD exception:** Read-only audit. Substitute check: `swift test --filter 'Shortcuts|SettingsPermission|PermissionWindow|Welcome|HideIcon|AppSettings|AppLaunchPlan'` green.
  - **Verify:** above filter `2>&1 | tail -4` — expected pass
  - **Depends on:** 1.2

### Phase 5 — Consolidation and filing

**Outcome:** A frozen follow-up report plus individually filed tickets; the working tree contains docs only.

- [x] **5.1 Write the consolidated report**
  - **Files:** `.scratch/quality-audit-followup/report.md`, `.scratch/quality-audit-followup/README.md` (hub: base, verdict, triage order, gates)
  - **Changes:** Merge slice verdicts into HIGH/MEDIUM/LOW + test-gap + verified-solid + feature-coverage-map sections mirroring the 2026-10-17 report; every finding carries `file:line`, severity, reachable sequence, test gap, and direction; duplicates of F1–F20/T1–T8/A1–A6 are marked as such, not re-claimed; record method, limits (no live verification), and gate outputs.
  - **TDD exception:** Non-behavioral docs. Substitute check: report contains gates table + triage table + per-finding `file:line` pointers; `swift test` still green.
  - **Verify:** `swift test 2>&1 | tail -3` + `./scripts/check-test-count.sh` + `git status --short` (docs only)
  - **Depends on:** 2.1, 2.2, 3.1, 3.2, 4.1, 4.2, 4.3

- [x] **5.2 File new findings as tracker tickets**
  - **Files:** `.scratch/quality-audit-followup/issues/NN-<slug>.md` (one file per new finding, numbered from `01`, per `docs/agents/issue-tracker.md`)
  - **Changes:** Each ticket opens with `# <NN>: <title>`, then `**What to build:**` (n/a — audit finding; state the fix direction), `**Findings:**` (report pointer), `**Status:** TODO`, and an acceptance checklist; use `CONTEXT.md` positive terms in titles. Do not file tickets for already-DONE findings; do not touch `Sources/`/`Tests/`.
  - **TDD exception:** Non-behavioral tracker filing. Substitute check: every report finding ID appears in exactly one ticket or is marked duplicate/parked with reason.
  - **Verify:** `ls .scratch/quality-audit-followup/issues/` + `git status --short`
  - **Depends on:** 5.1

- [x] **5.3 Final end-to-end verification**
  - **Files:** `.scratch/quality-audit-followup/report.md` (gates section), plan section 13
  - **Changes:** Re-run the full gate trio, confirm glossary compliance of new prose (spot-check `_Avoid_` terms: tile/zone, mode/grid, settle, monitor, screen), and record TDD evidence table + deviations + follow-ups in the plan's completion notes.
  - **TDD exception:** Non-behavioral verification. Substitute check: all four gate outputs pasted and green (or red recorded as pre-existing with explanation).
  - **Verify:** `swift build 2>&1 | grep -E "warning:|error:"` (expected empty) + `swift test 2>&1 | tail -3` + `./scripts/check-test-count.sh` + `git status --short`
  - **Depends on:** 5.2

## 7. Parallelization

| Batch | Tasks | Why they can run together |
| --- | --- | --- |
| A | 1.1, 1.2 | Sequential scaffold then map (1.2 needs 1.1's frozen base); single batch, one agent |
| B | 2.1, 2.2, 3.1, 3.2, 4.1, 4.2, 4.3 | Disjoint file slices, read-only, no shared writes; each slice audit can run in parallel once 1.2's map exists |
| C | 5.1, 5.2, 5.3 | Sequential consolidation: report → tickets → final gates; one agent |

## 8. Verification

- [ ] TDD evidence: no behavior-changing task exists; every task records a TDD exception (non-behavioral read-only audit) with the gate trio as substitute check — no trivial-fix or no-seam exceptions claimed
- [ ] Targeted tests: per-slice `swift test --filter '<Slice>'` commands in tasks 2.1–4.3, all green
- [ ] Full test suite: `swift test` — 832/832 green (or new count explained + `README.md:246,280` mismatch filed as a finding, not fixed)
- [ ] Build: `swift build 2>&1 | grep -E "warning:|error:"` — empty
- [ ] Lint/typecheck: no SwiftLint in repo; `CODING_STANDARDS.md` glossary + comment-accuracy review applied to all new prose; `./scripts/check-test-count.sh` passes
- [ ] Manual smoke test: not applicable (hermetic audit; live suite explicitly out of scope — record as a limit in the report)
- [ ] No test was weakened, skipped, or deleted to obtain green
- [ ] All success criteria in section 2 pass

## 9. Risks and mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Audit drifts into fixing (behavior change without a ticket) | Invalidates read-only gate; scope creep | Per-task TDD-exception + `git status` docs-only check; fixes become tickets, never edits |
| Re-claiming already-fixed findings as new | Noise; contradicts frozen history | Cross-reference every candidate against `.scratch/quality-audit/report.md` + ticket shas; mark duplicates |
| Glossary drift in new prose (`settle`, `monitor`, `tile`, `mode`) | `CODING_STANDARDS` violation | Spot-check `_Avoid_` terms in 5.3; use `CONTEXT.md` positive terms in titles |
| Changed-file weighting misses a regression in untouched code | False "verified solid" | Keep the full 5-slice checklist; weighting sets depth, not exclusion |
| F2/A1–A6 scope confusion | Audit tries to resolve parked/design items | Non-goals list them; report confirms parked status, does not resolve |
| Temporary probes left in tree | Dirty diff; gate failure | Probes live outside `Sources/`/`Tests/` and are deleted before 5.3; `git status` proves it |

## 10. Security and data

- **Data created, stored, or exposed:** Audit markdown only (`.scratch/quality-audit-followup/`). No user data, no window contents, no AX snapshots.
- **Auth, privacy, and retention:** No Accessibility grants requested; no live window reads; no secrets or `.env` contents in the report or chat.
- **Abuse and failure exposure:** Read-only plan — no deployment, migration, hotkey, or permission change; nothing user-visible can regress.

## 11. Rollout and rollback

Not applicable (local-only read-only audit; no deployment, flags, or migrations). To reverse: delete `.scratch/quality-audit-followup/` (`rm -rf .scratch/quality-audit-followup`). Never commit, push, or open a PR unless the user explicitly asks (plan-skill guardrail).

## 12. Open items

- [ ] Confirm report home: `.scratch/quality-audit-followup/` (recommended, preserves frozen history) vs appending to `.scratch/quality-audit/` — default to the former per `CODING_STANDARDS.md:28-31`; resolve at approval
- [ ] Confirm depth on unchanged engine files (re-verify pins vs trust prior verdicts) — default: re-verify claimed fixes, trust untouched geometry with spot checks

## 13. Completion notes

### Progress

- 2026-10-19 — 5.1, 5.2, 5.3: consolidated 7 slice verdicts into `.scratch/quality-audit-followup/report.md` (verdict: no HIGH/MEDIUM; F21–F33 + T9–T11; all prior fixes re-confirmed pinned; F2 parked; A1/A2/A3 unchanged). Filed `issues/01`–`issues/16` (one per finding). Final gates: build warnings empty, `swift test` 832/832, `check-test-count` match, `git status` docs-only. Fixed one `_Avoid_` slip ("settles") in a slice note; report + tickets scan clean.

### TDD evidence

| Task | Test | Red (command and failure) | Green (command and result) |
| --- | --- | --- | --- |
| 1.1–5.3 (read-only audit; TDD exceptions) | existing slice suites as substitute cover | n/a — no behavior change, no new tests | `swift test` 832/832 @ `3c3a432` (pre- and post-audit); slice filters: 2.1 → 279/279, 2.2 → 64/64, 3.1 → 223/223, 3.2 → 60/60, 4.1 → 84/84, 4.2 → 86/86, 4.3 → 70/70; `./scripts/check-test-count.sh` match |

### Implementation

- **Summary:** Read-only follow-up audit of `master @ 3c3a432` executed per plan. 7 slice verdicts in `.scratch/quality-audit-followup/slices/`, consolidated report at `.scratch/quality-audit-followup/report.md` (+ hub `README.md`), 16 tracker tickets at `.scratch/quality-audit-followup/issues/01`–`16`. No `Sources/`/`Tests/` change. All prior-arc fixes re-confirmed pinned; 13 new LOW findings (F21–F33) + 3 new LOW test gaps (T9–T11); F2 still parked; A1/A2/A3 unchanged (one further A3 instance recorded as design evidence).
- **TDD exceptions:** Tasks 1.1–5.3 — non-behavioral read-only audit producing markdown only; no failing test applies. Substitute check per task: slice `swift test --filter` green plus the gate trio and `git status` docs-only.
- **Behavioral exceptions:** none.
- **Commands:** `swift build 2>&1 | grep -E "warning:|error:"` → empty; `swift test` → 832/832 (3.1 s); `./scripts/check-test-count.sh` → match; `git status --short` → only `?? .scratch/quality-audit-followup/` + `?? docs/plans/`.
- **Deviations:** (1) Slice auditors wrote intermediate `slices/*.md` files (one owner each) for consolidation in 5.1 — plan tasks implied direct report writes; consolidation merged and renumbered them. (2) Parallel slices minted colliding F21/F22 IDs; orchestrator assigned final F21–F33/T9–T11 in 5.1 (slices 4.x used provisional H/M/S IDs per corrective instruction). (3) `NeighbourRoundingTests`/`MinimumSizeTests` reviewed beyond the 2.1 filter; extra production-adjacent reads in 4.2 (router/receipt/binding seams) stayed within the slice's coordination scope.
- **Follow-ups:** Implement `issues/01`–`16` in a later arc (suggested triage order is in the report); A1/A2 design phases and F2 live evidence remain open; consider `/review major-features-quality-audit`.

### Review

`docs/reviews/major-features-quality-audit.md` _(added by the review skill)_
