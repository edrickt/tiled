# 14: Thread the injected clock through the focus memo

**What to build:** The Space-table cache honors the injected `now`
(`Sources/tiled/LiveWindowGateway.swift:786-793`), but the
focus-answer memo stamps `Date()` directly at write and both reads
(`:356-357,361,365`), so its 0.05 s lifetime is pinned only by the
live suite. Thread `now` through the focus-answer read/write/clear
paths the way the Space cache already does.

**Findings:** Follow-up audit T9 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] Focus memo hit, expiry, and callback invalidation are pinned without wall-time sleep
- [ ] New tests through the adapter seam (`Tests/tiledTests/LiveGatewayWiringTests.swift`)
- [ ] Gates: `swift build` warnings empty, `swift test` green, `check-test-count.sh` pass
