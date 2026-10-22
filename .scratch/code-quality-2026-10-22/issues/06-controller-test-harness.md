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

**Status:** TODO

- [ ] `UndoIntegrityTests` passes its injected screen (smallest fix
      first, independent of the harness).
- [ ] `ControllerHarness` lands; suites ported without assertion
      changes.
- [ ] Prune scheduler injected; the wall-clock wait is gone.
- [ ] Gates in `../README.md` all pass.
