# A2: Explore the window ownership register

**What to build:** A design decision, not code yet. Window ownership is two stores — canvas
records and the controller's handle→id table — kept in sync by convention; `spaceOf` is a linear
scan over an unordered dictionary. Decide where the one-canvas-per-handle invariant lives, whether
the canvas stops calling upward through `Context.allocateID`, and how the change respects
`CONTEXT.md`'s assignment of records to `TilingSpace`.

**Blocked by:** None (design can start immediately; implementation follows A1 or the functional
queue).

**Findings:** A2 (`.scratch/quality-audit/report.md`, HTML candidate A2).

**Type:** design

**Status:** TODO

- [ ] The domain boundary between records (occupancy/restore) and identity (handle→id) is agreed.
- [ ] The register's operations are named in the glossary if the term is new.
- [ ] The invariant has one home and a headless test seam.
- [ ] The recent bug shapes (refusal, prune, undo reclaim, untile-all) map onto the new operations.
- [ ] The design is recorded before implementation.
