# 12: Drag edges: programmatic jump and skipped-write baseline

**What to build:** Two drag-edge fixes:

- a programmatic far jump must not untile merely because an unrelated click lands before the
  debounce fires; the tracker needs a mouse-down/hand-drag signal, not only `mouseLifted`;
- a placement or undo write skipped as already-correct must seed the drag baseline, so a later
  one-tick short drag can snap back instead of leaving the window offset.

**Blocked by:** None (can start immediately).

**Findings:** F14 and F18 (`.scratch/quality-audit/report.md`).

**Status:** TODO

- [ ] A far AX tick followed by an unrelated mouse-up/click is a snapback, not a drag-out.
- [ ] A real single-tick fling decided at its own mouse-up still untiles.
- [ ] A skipped placement/undo write seeds `lastKnownFrames`; a one-tick short drag snaps back.
- [ ] Tests distinguish the programmatic-jump click from a hand fling.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
