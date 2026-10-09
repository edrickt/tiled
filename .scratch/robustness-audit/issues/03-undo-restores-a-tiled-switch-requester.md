# 03: Undo restores a tiled switch-requester to its vacated slot

**What to build:** Undo of a chapter must put the pre-event world back exactly. For a layout switch,
a requester that was tiled before the switch returns to the slot it vacated — not to its pre-tile
frame — matching what the tile and swap branches already do and what the glossary's undo rule
promises ("a tiled requester returns to the slot it vacated"). Today the switch's undo sends such a
requester back to an ancient pre-tile frame and untiled, while everyone else returns to their slots.

**Blocked by:** 02 (shares the switch chapter's snapshot construction).

**Findings:** report D2 (`.scratch/robustness-audit/report.md`); `CONTEXT.md` term **Re-house**
(undo sentence).

**Status:** ready-for-agent

- [ ] Tiled requester + switch + undo → the requester lands back in the slot it vacated; every other
      window lands in its pre-switch slot.
- [ ] An untiled requester's undo behaviour is unchanged (pre-tile restore).
- [ ] The chapter records the tiled requester the way the tile and swap branches already do; the case
      is pinned by tests at both the canvas and controller levels.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
