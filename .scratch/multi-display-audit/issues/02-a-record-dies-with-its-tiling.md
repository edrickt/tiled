# 02: A record dies with its tiling

**What to build:** A canvas record must exist only while the window is tiled. Today a refused
placement removes occupancy but leaves `records[id]` intact (`TilingSpace.swift:690-697`; `settle`
only forgets `decision.windowsToRestore`, `:224-225`), and `handleEvict` calls `attach` *before*
`evict` and returns early on `.nothingToEvict` without any forget
(`TilingController.swift:1104-1113`; `TilingSpace.swift:139-143`). Because `spaceKeyForRequester`
returns `spaceOf(window:)` first (`TilingController.swift:584-593`), a record that survives a
refused tile or a no-op evict silently pins the window's canvas: a later "drag to the second
monitor and tile" writes it back to the *first* monitor. Separately, an undo restore that fails
forgets the window on the canvas but leaves its `windowIDs` entry behind
(`TilingSpace.swift:353-357`; `TilingController.swift:854-861`).

Make record presence the ownership primitive: forget on refusal and on `.nothingToEvict`, and
clear the handle table for every id a canvas forgets.

**Blocked by:** 01 (collision — both touch the record/ownership path).

**Findings:** report M6, L2 (`.scratch/multi-display-audit/report.md`).

**Status:** DONE (6400622)

- [ ] After a refused first placement, no record and no canvas ownership remain for the window.
- [ ] Pressing Evict on an untiled window (`.nothingToEvict`) leaves no record behind.
- [ ] After such a no-op/refusal, tiling the window on another display places it on *that*
      display, not the previous canvas.
- [ ] A failed undo restore clears the handle→id entry (and the `deadSince` clock) for every id
      the canvas forgets, not just the requester.
- [ ] Pinned by tests: refused-tile record state, `.nothingToEvict` record state, cross-display
      re-tile after each, and the failed-restore bookkeeping.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
