# 03: Death confirmation excludes sleep

**What to build:** The death-confirmation window must measure the window's absence, not wall time.
Today death confirms when `timestamp.timeIntervalSince(first) >= deathConfirmation` over
wall-clock `Date`s, default 3.0 s (`TilingController.swift:105,108,175,647-655`). Sleep inflates
`timeIntervalSince` with no prune tick running, so a `deadSince` entry left before sleep confirms
on the *first* post-wake tick — the "two prune ticks" protection degenerates to one, and a live
window is untiled with its slot reflowed.

Measure confirmation with a monotonic uptime clock that excludes sleep, or require two distinct
prune *ticks* (a counter on `deadSince`) rather than elapsed time.

**Blocked by:** None (can start immediately).

**Findings:** report M2 (clock half) (`.scratch/multi-display-audit/report.md`).

**Status:** DONE (7e4da22)

- [ ] A window marked dead before a simulated sleep is not confirmed on the first post-wake tick;
      it needs its full confirmation interval *awake* (or its second real tick).
- [ ] Ordinary confirmation still works: a genuinely dead window is pruned after its interval, so
      the fix does not stop death detection.
- [ ] Pinned by a test that advances the injected clock across a sleep gap and asserts the window
      is retained, plus a test that a dead window is still pruned.
- [ ] `LidSleepWakeTests`' controller may need a real `pruneInterval`/clock for this (today it is
      built with `pruneInterval: nil`, `LidSleepWakeTests.swift:32-33`).
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
