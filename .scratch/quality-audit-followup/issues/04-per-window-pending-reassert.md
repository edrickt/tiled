# 04: Keep the pending reassert per window, not per canvas

**What to build:** `pendingReasserts` keeps a single window per canvas
(`Sources/tiled/DragTracker.swift:151`), so a second window's edge
movement overwrites the first window's pending achieved-frame reconcile
(`:661-668`). Keep the pending set per window and emit one resize
decision per pending window.

**Findings:** Follow-up audit F24 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] Two windows' trailing ticks on one canvas both reconcile their achieved frames
- [ ] New two-window trailing-tick test beside `Tests/tiledTests/DragTrackerTests.swift:416-444`
- [ ] Gates: `swift build` warnings empty, `swift test` green, `check-test-count.sh` pass
