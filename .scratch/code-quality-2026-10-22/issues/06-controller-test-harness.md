# 06: One controller test harness

**What to build:** a `ControllerHarness` beside `TilingSpaceHarness`
owning the screen literal, the fake gateway, the controller
construction, `addFocusedWindow`, and `canvas`. Port the nine suites
that currently redeclare that setup. Inject the prune scheduler the way
the drag-end and verify schedulers already are, and delete the fixed
0.3s wall-clock wait.

**Why:** 31 controller constructions and 30 `ScreenInfo` literals;
`UndoIntegrityTests` defines `Self.main` but never passes `screens:`, so
that suite tiles against the host screen. The fixed wait is ~10% of the
suite and flakes on a loaded runner.

**Findings:** `../report.md` "Still open 6"; `../slices/06-tests.md`
findings 8–10.

**Status:** DONE (75db32a)

- [x] `UndoIntegrityTests` passes its injected screen (smallest fix
      first, independent of the harness).
- [x] `ControllerHarness` lands; suites ported without assertion
      changes.
- [x] Prune scheduler injected; the wall-clock wait is gone.
- [x] Gates in `../README.md` all pass. (The full mutation table is
      deferred per `AGENTS.md`; the operator asked for no mutation run
      on this ticket.)

## Comments

Commits: `1f527fc` (inject the undo suite's screen), `4ba27d8`
(harness + receipt suite), `a0a0aa6` (bulk operations), `26494c6`
(gateway), `9e3dad5` (undo integrity), `69a8b3c` (reflow, swap,
expand), `8972910` (Space independence), `3d3cffb` (per-display),
`75db32a` (prune seam + rewritten prune test).

All nine named suites now use `ControllerHarness`: `ActionReceiptTests`,
`ControllerBulkOperationTests`, `ControllerGatewayTests`,
`UndoIntegrityTests`, `ReflowTests`, `SwapTests`,
`SpaceIndependenceTests`, `PerMonitorTests`, `ExpandToggleTests`.
Bespoke scenario helpers stay on top (`tileSixthsSession`, `tileOnLeft`
/ `tileOnRight`, the Space switcher, and the smaller local scenarios);
assertions, expected values, and test names are unchanged. Local
controllers built inside tests (custom clocks, a second display, a
withheld Space) also go through the harness, so they no longer fall
back to the host screen.

Harness shape: `ControllerHarness(screens:)` owns a reference-backed
screen list (mutable mid-test for plug/unplug), the
`FakeWindowGateway`, the `TilingController`, `addFocusedWindow`, and
`canvas`. Init also takes `activeSpaces`, `pruneInterval`,
`scheduleDragEnd`, `scheduleVerify`, `schedulePrune`,
`deathConfirmation`, `now`, and `uptime`. Defaults are the test
choices: no prune interval, immediate death confirmation, and
schedulers that record their fires instead of touching the runloop.

Prune seam: `TilingController.PruneScheduler` is
`(interval, fire) -> cancel`, matching the drag-end/verify scheduler
shape. The production `schedulePruneOnMain` keeps the 5-second
repeating timer in `.common` mode, and `deinit` invokes the stored
cancel. `testPruneTimerFiresAndReleasesSlots` captures the prune
closure, fires it manually, and asserts the same release and
`onChange` behavior; the fixed 0.3 s `asyncAfter` wait is gone.

Gates run after each unit and at the end: `swift build` with no
warnings/errors, `swift test` (913 executed, 1 skipped, 0 failures),
and `./scripts/check-test-count.sh` (README's 913 matches). Test count
is unchanged, so README needed no count edit.
