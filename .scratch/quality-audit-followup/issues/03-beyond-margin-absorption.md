# 03: Pin beyond-margin absorption on the first drag tick

**What to build:** A slot occupant whose app absorbs more than the
translation margin misroutes its first hand title-drag tick to the
splitter path (`Sources/tiled/DragTracker.swift:499-504`; residual
documented at `:496-498`). Consult the hand-evidence signal (or the
echo trail) before routing a size-dominant first tick to the splitters,
or bound the first-tick splitter travel.

**Findings:** Follow-up audit F23 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] A beyond-margin absorption tick no longer yanks the shared splitter (or the bound is pinned)
- [ ] New test beside `Tests/tiledTests/DragTrackerTests.swift:532-571` pins the past-margin shape
- [ ] Gates: `swift build` warnings empty, `swift test` green, `check-test-count.sh` pass
