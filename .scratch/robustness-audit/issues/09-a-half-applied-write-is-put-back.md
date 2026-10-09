# 09: A half-applied frame write is put back

**What to build:** Pushing a frame is two Accessibility messages (position, size). The README's
promise is that "a refusing app's window is left alone, not half-moved" — and that must hold when
exactly one of the two messages lands. Today only the position-landed shape is rolled back: if the
position write fails on every attempt while the size write lands, the window stays resized at its old
origin, the app is blamed for a refusal, state rolls back, and the screen disagrees with both.
Restore the window's full pre-write frame whenever exactly one of the pair landed.

**Blocked by:** None (can start immediately).

**Findings:** report D12 (`.scratch/robustness-audit/report.md`).

**Status:** ready-for-agent

- [ ] Size-landed / position-failed restores the pre-write origin and size, and the write reads as
      refused to the caller (state rolls back with the screen).
- [ ] The position-landed / size-failed shape keeps working as before (regression pin).
- [ ] Both orderings are pinned end-to-end: the fake models each half-apply shape, and the restore
      policy itself is covered (not just its pure decision function).
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
