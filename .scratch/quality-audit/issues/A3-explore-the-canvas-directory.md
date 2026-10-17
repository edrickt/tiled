# A3: Explore the canvas directory

**What to build:** A design decision, not code yet. The display+Space→canvas rule is spread
across `withheldCanvas`, `actionSpaceKey`, `activeSpaceKeys`, `isVisible`, and a menu-specific
reimplementation. Decide one directory that answers: which canvas an action targets, which
canvases are visible/current, and how a withheld Space id resolves. Keep ADR 0002's canvas-owned
visible frame and reassert out of it.

**Blocked by:** None (design can start immediately; implementation follows the functional queue).

**Findings:** A3 (`.scratch/quality-audit/report.md`, HTML candidate A3).

**Type:** design

**Status:** TODO

- [ ] The directory's interface and its ownership of the withheld/unknown fallback are agreed.
- [ ] The menu, hotkey dispatch, write policy, and undo all read the same answer.
- [ ] The visibility test seam is headless and injects the display set and Space table.
- [ ] The design is recorded before implementation.
