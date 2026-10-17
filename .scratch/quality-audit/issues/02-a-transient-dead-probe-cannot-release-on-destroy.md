# 02: A transient dead probe cannot release on a destroy report

**What to build:** A destroy notification must accelerate a confirmed death, not confirm one by
itself. Today `TilingController.windowDestroyed` releases the slot on a single
`gateway.liveness(of:) == .dead` verdict (`TilingController.swift:1071-1085`). The adapter
documents the collision: during a display teardown or lid transition the element can be destroyed
while the window lives, and liveness can answer `.dead` transiently. The slot is then released
with no pending-death confirmation, and a live window is untiled.

The fast path still matters: a genuinely closed window must release within the documented
two-second budget (README window-lifecycle section), not wait out the 5s prune tick plus the 3s
confirmation. So the ticket needs a distinction between "the app/process is gone" and "this
element is gone but the app still owns the window", not simply routing every destroy report
through the slow clock.

Start with the live evidence: reproduce the collision on a real display teardown or lid transition
with `TILED_DEBUG=1`, or step through the adapter's `liveness` verdicts for a destroyed element
whose app still lists the window. Then add the test seam the fake can drive
(`probeDead + simulateDestroyed`) and gate the release on a confirmed death.

**Blocked by:** 01 (the placement/rollback ticket changes the same release/forget paths).

**Findings:** F2 (`.scratch/quality-audit/report.md`).

**Status:** PARKED (needs live display-teardown evidence; the code path is reproduced, the production frequency is not)

- [ ] The live collision is reproduced or ruled out on real AX; the evidence is recorded in the
      ticket's Comments.
- [ ] A destroy report with a transient `.dead` probe does not release the slot; the window keeps
      its record and slot until death is confirmed.
- [ ] A genuinely closed window still releases within the documented two-second budget.
- [ ] The fake can model the transient and the confirmed-death paths; both are pinned by tests.
- [ ] A hidden or background canvas's destroy report never writes a frame.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
