# 01: A refused move keeps the old slot

**What to build:** When an already-tiled window asks for another slot and the app refuses the
frame write, the window must stay the same occupant of the slot it visibly holds. Today
`TilingSpace.place` commits the requested slot, and on a refusal calls `forget`, deleting the
record and occupancy (`TilingSpace.swift:815-828`). The window never moved on screen, so state and
screen now disagree, and another request can claim its old slot and write over it.

A refused **first** tiling still has no old slot: that path keeps the current forget-and-announce
behavior. A refused move during a layout switch must also restore the previous occupancy and the
old layout (the layout is derived from the occupants, so restoring the slot restores the layout).

**Blocked by:** None (can start immediately).

**Findings:** F1 (`.scratch/quality-audit/report.md`).

**Status:** DONE (bb3819d)

- [ ] A tiled requester refused into a free slot keeps its previous slot, record, and pre-tile
      frame; the window's live frame is unchanged.
- [ ] A tiled requester refused into an occupied slot keeps its previous slot; the evictees are
      restored exactly as today; the refused requester is not forgotten.
- [ ] A refused first tiling still releases the record and reports the refusal.
- [ ] A refused layout-switch move restores the old slot and the old active layout.
- [ ] The existing test that pins the loss as expected is updated to the corrected contract.
- [ ] A red-green test covers the free-slot case (the case the suite never had).
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
