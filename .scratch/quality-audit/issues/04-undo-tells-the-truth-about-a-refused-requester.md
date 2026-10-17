# 04: Undo tells the truth about a refused reveal

**What to build:** Undo must count and narrate the windows that actually landed. A refused
requester restore currently stays visibly in its slot, loses its record, and is still counted in
the "N windows restored" notice (`TilingController.undoLastDisplacement`, `TilingSpace.undo`). The
refusal must be reported, and the count must be the successful restores, not the chapter size.

**Blocked by:** 01 (the same requester rollback/forget path).

**Findings:** F4 (`.scratch/quality-audit/report.md`).

**Status:** TODO

- [ ] A refused requester restore leaves the window's visible state consistent and is narrated
      as a failure, not hidden behind a success notice.
- [ ] The undo notice counts only the windows that actually restored.
- [ ] The chapter is consumed once; a retry after the app accepts the write behaves predictably.
- [ ] Tests cover one successful evictee plus one refused requester.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
