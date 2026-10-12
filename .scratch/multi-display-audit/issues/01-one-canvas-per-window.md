# 01: One canvas per window

**What to build:** A window handle must resolve to at most one canvas record at a time. Today
`TilingSpace.undo` allocates a fresh id through the coordinator's table whenever the handle is
absent from *its own* canvas (`TilingSpace.swift:328-334`), and `allocateID` unconditionally
overwrites the global handle→id map (`TilingController.swift:408-414`). So a window evicted on
canvas C, re-tiled on canvas D, then undone on C ends up with two live records — one per canvas —
both writing the same physical window; `spaceOf` is a first-match scan over an unordered
dictionary, so the duplicate resolves nondeterministically.

Enforce the invariant: before any restore re-issues a record for a handle, resolve the handle
globally; if another canvas already holds it, release that record first (or refuse to
double-book). A record for a handle that is already live elsewhere must never be created.

**Blocked by:** None (can start immediately).

**Findings:** report M1 (`.scratch/multi-display-audit/report.md`).

**Status:** ready-for-agent

- [ ] After evict on canvas C → re-tile on canvas D → undo on C, the handle has exactly one live
      record, on exactly one canvas, and both canvases never write it in the same pass.
- [ ] `allocateID` (or its caller) refuses to overwrite an id whose record is still live; the
      conflict is resolved by the controller, which owns the handle table.
- [ ] The duplicate is not visible to `spaceOf`/`allTiledWindowsInfo`: the window is counted once.
- [ ] The sequence is pinned by a test (evict on C, re-tile on D, undo C) asserting one record per
      handle and no cross-canvas write.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
