# 05: A retile clears deferred restores across canvases

**What to build:** A deferred pre-tile restore is keyed by handle on the canvas that untiled the
window. If the same window is retiled on another canvas before that canvas becomes visible, the
old deferred restore must be discarded globally, not only on the receiving canvas. Today
`beginRecord` clears only its own canvas's map, and the old canvas's swipe-back can write the
window off its new slot.

**Blocked by:** 04 (the undo/deferral path it shares).

**Findings:** F5 (`.scratch/quality-audit/report.md`).

**Status:** TODO

- [ ] Untile on canvas A (deferred), retile the same handle on canvas B, then return to A: the
      old restore never fires and the window stays on B.
- [ ] Retiling on the same canvas still clears its own deferred restore (the existing contract).
- [ ] The coordinator clears the stale restore from every canvas when a handle is claimed.
- [ ] A test drives the cross-canvas sequence and asserts no write to the old frame.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
