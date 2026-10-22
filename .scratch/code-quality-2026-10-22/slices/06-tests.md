# Tests slice — code-quality audit 2026-10-22

Scope: `Tests/tiledTests`, 61 files, 18,616 lines. Read-only: no build or test run.
Parent's gates stand: **833 green, 1 skipped, ~3.1 s**. The skip is the opt-in
`ExhaustiveUndoTests` (`TILED_EXHAUSTIVE=1`, ~7 s), honestly gated and not a defect.
Method: read the largest/most duplicated suites; grep for circular oracles,
wall-clock waits, refusal scripting, and the named open paths. The suite is mostly
behavior-first (literal copy in `MenuTextTests`, literal rects in `GridLayoutTests`,
literal refusal strings). Findings below are the remaining circular oracles and
the known open paths with no test at all.

## Cross-check of the follow-up findings

| ID | Status | Evidence |
|---|---|---|
| T5 literal end-to-end expectations | **FIXED** | `TilingSpaceTests.swift:35-49` literal quarters rect; `:52-62` literal sixths; `ControllerGatewayTests.swift:705-707` literal refusal. Ticket 17's boxes are met; the harness helper remains for structural assertions, as allowed. |
| T9 focus cache bypasses the injected clock | **STILL PRESENT** | `LiveWindowGateway.swift:222-223,355-365` stamps `Date()`; no focus test exists; `LiveGatewayWiringTests.swift:14-22` injects `now` only for the Space cache. |
| T10 menu slot lists derive from production constants | **STILL PRESENT** | `MenuModelTests.swift:171,194-198` compares to `SlotPresentation` groups that `MenuModel.swift:185-219` itself iterates. |
| T11 reset-over-backup promise unpinned | **STILL PRESENT, and stronger** | `ShortcutsResetBackupTests.swift:145-181` pins only the no-backup promise; `SettingsShortcutsTab.swift:710-718` routes any existing backup to restore, so the overwrite branch (`:731-734`) is unreachable from the button and T11's sequence cannot be driven. |

## Findings

### 1. The refusal-recovery writes are never refused in tests (F21/F22)
**Evidence.** `TilingSpaceTests.swift:311-330` refuses the swap requester once and
lets the displaced home-write succeed; `ReflowTests.swift:398-422` refuses the grow
once and lets the old-rect recovery succeed. Sources discard both second outcomes
(`TilingSpace.swift:628-639,1149-1155`).
**Stays green.** Refuse the second write: the screen keeps the window in one slot
while state records another, with no refusal message — both tests still pass.
**Remedy.** Script `refuseNextWrites(handle, count: 2)`; assert the shared message,
final frames, and occupancies. Read the recovery write through the write policy.
**Tag:** design · **Confidence:** high · **Effort:** S

### 2. An unreadable achieved frame at release silently drops the reassert (F25)
**Evidence.** `TilingController.swift:1156-1168` returns on a nil frame read. The
drag-end tests (`ControllerGatewayTests.swift:632-661,688-708`) leave the frame
readable; none inserts `hideFrames` before `mouseLifted`.
**Stays green.** During the lid-close unreadable transient, release drops the
decision: no occupant is rewritten under the splitters, neighbours stay stale.
**Remedy.** Fall back to a `.grid` reassert when the achieved frame is unreadable;
test release with `hideFrames.insert`, asserting neighbours flush and no silent drop.
**Tag:** design · **Confidence:** high · **Effort:** S

### 3. Focus memoization is untestable and `release` leaves it stale (T9/F26)
**Evidence.** `LiveWindowGateway.swift:222-223` (0.05 s cache), `:355-365` (`Date()`
at write and reads), `:440-454` (`release` never clears `focusedCache`).
`LiveGatewayWiringTests.swift:253-283` tests release without focus;
`FakeGatewayFidelityTests.swift:58-83` proves only the fake forgets focus.
`registerTestWindow` excludes focus (`LiveWindowGateway.swift:456-466`).
**Stays green.** Changing the lifetime, breaking focus-change invalidation, or
returning a released handle from `focusedWindow` has no hermetic test to fail.
**Remedy.** Thread `now` through the focus cache, add a focus resolver seam, clear
the memo in `release`. Test hit, expiry, focus-change invalidation, post-release nil.
**Tag:** design · **Confidence:** high · **Effort:** M

### 4. One pending reassert per canvas; no two-window test (F24)
**Evidence.** `DragTracker.swift:151` stores `[TilingSpaceKey?: WindowID]`;
`:661-668` overwrites, `:712-725` drains only the survivor.
`DragTrackerTests.swift:416-444` covers one window.
**Stays green.** A's trailing edge tick is overwritten by B's movement; the next
release reasserts only B, so A's achieved-frame clamp never reconciles.
**Remedy.** Keep the pending set per window, emit one `.resize` per pending id; add
a two-window trailing-tick test asserting both achieved frames reconcile.
**Tag:** design · **Confidence:** high · **Effort:** M

### 5. The transient-dead destroy quadrant is still untested (F2)
**Evidence.** `ControllerBulkOperationTests.swift:581-628` covers genuinely dead,
live, and `.unknown`. Nothing combines `probeDead` (the documented lid-close
transient, `FakeWindowGateway.swift:129-135`) with `simulateDestroyed`; the fast
path trusts one verdict (`TilingController.swift:1278-1292`).
**Stays green.** A live window's probe says `.dead` during display teardown while
the OS reports destruction; the slot releases at once, bypassing confirmation.
**Remedy.** Add `probeDead.insert(handle); simulateDestroyed(handle)` and assert the
slot survives one probe, then releases if it stays dead. Route element-only `.dead`
through the confirmation clock.
**Tag:** design · **Confidence:** high · **Effort:** S

### 6. Menu slot lists still come from the constant the menu iterates (T10)
**Evidence.** `MenuModelTests.swift:171` asserts `qSlots ==
SlotPresentation.quartersQuads + quartersHalves`; `:194-198` does the sixths
groups — the literals `MenuModel.swift:185-219` iterates
(`HotkeyBinding.swift:143-166`).
**Stays green.** Drop a slot from a group and the menu loop together: headers and
`Slot.allCases.count == 17` still pass, and the menu silently loses a tile row.
**Remedy.** Assert one literal slot-name list per layout; keep the constant-derived
comparison as a secondary shape check.
**Tag:** mechanical · **Confidence:** high · **Effort:** S

### 7. The reset-over-backup promise cannot be reached, let alone pinned (T11)
**Evidence.** `ShortcutsResetBackupTests.swift:145-181` presses twice and asserts
restore; only the no-backup promise is asserted (`:163-165`).
`SettingsShortcutsTab.swift:710-718` sends any state with a backup to restore, so
`confirmAndReset`'s overwrite promise (`:731-734`) is dead from the UI, while the
canvas does replace a second snapshot (`SplitterBackupDragTests.swift:76-91`).
**Stays green.** Delete or mistranslate "This replaces your previous backup"; no
test names it, and no test can detect that the warning is unreachable.
**Remedy.** Decide the rule: offer a deliberate second reset and pin the overwrite
promise through `confirmReset`, or delete the dead branch and stop claiming overwrite
protection. Add the chosen case to `ShortcutsResetBackupTests`.
**Tag:** design · **Confidence:** high · **Effort:** S

### 8. Controller fixtures are copy-pasted; one suite already drifted to the host screen
**Evidence.** 31 `TilingController(` constructions and 30 `ScreenInfo(` literals;
nine suites redeclare screen + setup + `addFocusedWindow` + `canvas`
(`ActionReceiptTests.swift:12-45`, `ControllerBulkOperationTests.swift:13-63`,
`ControllerGatewayTests.swift:11-70`, `UndoIntegrityTests.swift:13-45`,
`ReflowTests.swift:17-36`, `SwapTests.swift:13-31`,
`SpaceIndependenceTests.swift:20-55`, `PerMonitorTests.swift:9-42`,
`ExpandToggleTests.swift:13-36`). `UndoIntegrityTests.swift:13-18` defines
`Self.main` but `:33-38` never passes `screens:`, so that controller tiles against
`NSScreen.screens` (only `:462` uses the fixture).
**Stays green.** A controller that ignores its injected screen provider, or whose
required scheduler/clock wiring changes, passes `UndoIntegrityTests`.
**Remedy.** Pass `screens: { [Self.main] }` now; add one `ControllerHarness` beside
`TilingSpaceHarness` and port the nine suites incrementally.
**Tag:** mechanical · **Confidence:** high · **Effort:** M

### 9. Three large suites mix layers and concerns
**Evidence.** `TilingSpaceTests.swift` is 1,516 lines / 73 tests / 14 MARK sections
(tile through reassert and sequences); `ControllerGatewayTests.swift` is 913 lines /
35 tests across observation, drag-out, convergence, reassert, undo, expansion,
ghost cleanup, and death; `ReflowTests.swift` splits at `:363` into pure
`TilingState` rules and controller wiring.
**Stays green.** Not a behavior regression: the cost is review locality and fixture
drift. A `ReflowTests` failure does not say whether the algebra or the wiring broke.
**Remedy.** Split by behavior into extensions/files; split `ReflowTests` pure vs
controller. Mechanical move, no assertion changes.
**Tag:** mechanical · **Confidence:** medium · **Effort:** M

### 10. One real timer and a fixed 0.3 s wall-clock wait
**Evidence.** `ControllerBulkOperationTests.swift:630-655` uses `pruneInterval:
0.05` and waits on `asyncAfter(deadline: .now() + 0.3)` (`:648`). Other suites drive
prune directly; drag-end/verify schedulers are already injectable
(`ControllerGatewayTests.swift:47-59`).
**Stays green.** Slow or missed prune wiring passes if it fires within 0.3 s, and
the test flakes on a loaded runner; it is ~10% of the 3.1 s suite.
**Remedy.** Inject the prune scheduler like the drag/verify schedulers and fire it;
delete the fixed wait.
**Tag:** design · **Confidence:** medium-high · **Effort:** S

## Smaller notes (not filed)
- Eleven refusal tests assert only `XCTAssertNotNil(canvas.error)` (e.g.
  `TilingSpaceTests.swift:96,114,305,320`); a wrong-but-present sentence passes.
- `TilingSpaceTests.swift:345` uses `try! XCTUnwrap`, which crashes the test process
  on failure instead of failing one case.
- `ReflowTests.swift:419` reads `XCTAssertFalse(!canvas.undoStack.isEmpty)`; the
  double negative slows the reader for no gain.

## Verified solid
- T5's literal anchors are real and outside the implementation; the ticket's intent
  is met even though structural tests still use `harness.rect`.
- Menu copy and announcements are literal sentences (`MenuTextTests.swift`), not
  derived from `MenuText`.
- The fake's release/focus contract has a fidelity suite
  (`FakeGatewayFidelityTests.swift:58-83`), so F20 cannot recur silently on the fake.
- `ExhaustiveUndoTests.swift:227-233` self-tests its structural oracle;
  `:318-322` asserts the search explored enough. The opt-in 7 s cost is well gated.
- Time-dependent controller tests already inject clocks/schedulers where the seam
  exists (`ControllerGatewayTests.swift:47-59`, `LidSleepWakeTests.swift:25-48`).

## Ranked shortlist — fix this week
1. **#1 second-write refusals** — two tests expose silent state/screen disagreement;
   smallest change with the highest correctness payoff.
2. **#2 unreadable frame at release** — one fallback plus one test; today the
   reassert can vanish without a red test.
3. **#3 focus memo (T9/F26)** — inject the clock/resolver and clear on release;
   closes a named testability gap and a real stale-handle window.
4. **#4 per-window pending reasserts** — two-window test first, then the pending set.
5. **#6 literal menu slot lists (T10)** — mechanical one-test change that closes the
   last circular expectation named by the prior audit.
