# 05: One deferred-off-Space contract

**What to build:** `.deferredOffSpace` must mean one thing everywhere. Today `applyLayout` reads it
as failure and rolls the placement back (`TilingSpace.swift:775`), while `writeRects` reads it as
success and lets the reflow state stand for reconciliation on swipe-back (`:867,825-837`). One
policy outcome, two contracts — ticket 06 and 07 both encode whatever this ticket settles.

**Status:** DONE (afa6e98) — the recommended stand-and-reconcile contract is settled.

**Blocked by:** None (can start immediately).

**Findings:** report M9 (`.scratch/multi-display-audit/report.md`).

**Decision (recommended):** a deferred write is **not** a failure anywhere. Deferral retains the
intent and reconciles when the canvas becomes visible (matching `writeRects`); it is narrated as a
deferral ("the Space isn't visible yet"), never as an app refusal. Rationale: the outcome means
"cannot act now, retry later", which is the reflow contract; the placement path's rollback +
"the app refused" narration is what makes M3/M10 user-visible lies. The alternative (roll
everything back) would contradict the reflow reconciliation the code already ships and tests.

- [ ] With the chosen contract, `applyLayout` and `writeRects` agree on what a deferral does to
      state (both stand, or both roll back — not one of each).
- [ ] The deferral narration is distinct from the app-refusal narration and is decided in one
      place (copy stays in `MenuText`).
- [ ] The contract is stated in `CONTEXT.md` (the expected-write / deferral vocabulary) and the
      code comment at `TilingSpace.swift:770-775` no longer contradicts it.
- [ ] The chosen behaviour is pinned by a test for **both** a placement and a reflow, asserting the
      same contract.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
