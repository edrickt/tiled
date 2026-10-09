# 01: A late check only ever judges its own write

**What to build:** Tiled arms a late check for every frame write it performs, to catch the app that
accepts a write and silently ignores it. That check must judge exactly the write that armed it — and
nothing else. Today a refused, clamped, no-op-skipped, or off-Space-deferred write leaves the
previous write's check armed (and the echo trail pointed at a frame the window was never in), so the
late verdict can be paid against a later, legitimate placement — releasing a window from the slot it
visibly occupies — or swallow the first ticks of a later user drag so a long drag snaps back. Make
the expected-write owner's "one write, one life" contract true for every write outcome: each check
judges its own entry, and no outcome leaves a stale check or echo entry behind.

**Blocked by:** None (can start immediately).

**Findings:** report D3, D11, L16 (`.scratch/robustness-audit/report.md`).

**Status:** ready-for-agent

- [ ] A check armed for write A never judges a later write B's entry or a frame the window was never
      in, for B in {refused, clamped, no-op-skipped, deferred}.
- [ ] A no-op skip or off-Space deferral after a performed write voids that write's pending check: the
      window keeps the slot it visibly occupies and no consequence fires.
- [ ] A refused or clamped write leaves no armed echo entry behind: a later user drag is classified
      from its first tick (a >100 pt drag untiles, it does not snap back).
- [ ] A clamp-restore whose own restore write fails re-points the expectation at the frame the window
      is actually in (L16).
- [ ] The interleavings are pinned by tests: performed→refused, performed→skip, performed→deferred,
      refused→performed, all judged at the verify delay.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
