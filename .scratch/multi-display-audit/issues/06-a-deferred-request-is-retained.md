# 06: A deferred request is retained

**What to build:** A deferred placement or expansion must be honoured when its canvas becomes
visible, not silently dropped. Today the deferral marks the canvas stale but arms nothing, and
`place` has already removed occupancy (`FrameWriter.swift:76-80`;
`TilingController.swift:277-300,483-492`; `TilingSpace.swift:688-696`), so swipe-back's reassert
re-derives only *current* occupants — the user's requested slot is gone. Expansion is worse: the
deferral is mapped to `.expandRefused` without recording `expanded[id]`, so a toggle on a hidden
canvas can never be reconciled (`TilingSpace.swift:1133-1148,1039-1060`).

Persist the deferred request (placement slot and pending expansion) and re-issue it on swipe-back,
matching the reflow reconciliation.

**Blocked by:** 05 (the deferral contract decides what "retained" means).

**Findings:** report M10, M12 (`.scratch/multi-display-audit/report.md`).

**Status:** ready-for-agent

- [ ] A placement deferred for an invisible canvas lands in its requested slot when the canvas
      becomes visible (swipe back), without a second user action.
- [ ] An ⌥⇧⏎ expand/collapse deferred for an invisible canvas is recorded and applied on return
      (the window is expanded/retiled as requested).
- [ ] Nothing is applied to a canvas that never becomes visible, and the deferred request does not
      leak across canvases.
- [ ] Pinned by tests: hidden placement → swipe-back applies it; hidden expand → swipe-back applies
      it; a deferral for canvas A is not applied to canvas B.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
