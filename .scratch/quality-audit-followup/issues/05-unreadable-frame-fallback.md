# 05: Fall back to a canvas reassert on an unreadable achieved frame

**What to build:** The coordinator's drag-end route returns without any
reassert when the achieved-frame read fails
(`Sources/tiled/TilingController.swift:1156-1168`, guard at `:1159`).
Fall back to a `.grid` reassert of the owning canvas so occupants still
rewrite under the stored splitters.

**Findings:** Follow-up audit F25 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] Release during an unreadable-frame transient still rewrites occupants under stored splitters
- [ ] New release-during-unreadable-frame test (convergence leniency at `Tests/tiledTests/DragTrackerTests.swift:759-797` is the neighbour pin)
- [ ] Gates: `swift build` warnings empty, `swift test` green, `check-test-count.sh` pass
