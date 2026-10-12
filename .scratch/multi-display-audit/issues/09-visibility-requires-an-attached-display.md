# 09: Visibility requires an attached display

**What to build:** A canvas whose display is no longer attached must never be written. `isVisible`
returns `true` unconditionally whenever `space.space == nil`
(`TilingController.swift:1291-1294`) and never checks that `space.screen` is still in the current
display set. A canvas established while the OS withheld a Space id has key `(screen: D, space: nil)`;
after display D is unplugged, `spaceOf` still resolves it (`TilingController.swift:1252-1257`), so
`handle(slot:)` → `place` → `applyLayout` → `FrameWriter.write` passes the visibility guard and
writes — using the main display's visible frame, which `refreshVisibleFrames` has already written
into the removed canvas (see ticket 10). An unplugged window is re-laid-out against the main display
instead of being deferred, violating the "never write a removed canvas in the dark" contract.

Gate visibility on screen presence first: a key whose `screen` is not in the current provider is
not visible regardless of `space == nil`. Keep "nil Space is visible" only for genuinely
display-less keys.

**Blocked by:** None (can start immediately).

**Findings:** report M7 (`.scratch/multi-display-audit/report.md`).

**Status:** DONE (4101d37)

- [ ] After a display is unplugged, a hotkey targeting a window on that display's (withheld,
      nil-Space) canvas defers instead of writing; the canvas is marked stale.
- [ ] On replug, the window is reasserted against the restored display's geometry.
- [ ] The genuinely display-less canvas (headless/tests, `TPSKey.displayless`) is still treated as
      visible — existing behaviour unchanged.
- [ ] Pinned by tests: nil-Space canvas + unplug → hotkey defers, no write; replug → reassert.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
