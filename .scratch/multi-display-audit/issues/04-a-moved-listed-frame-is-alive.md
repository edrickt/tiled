# 04: A moved listed frame is alive

**What to build:** When the OS lists a window whose frame has moved, the gateway must not call it
dead. Today the app-match check requires the listed frame to equal the cached `lastFrames`
baseline within 1 pt (`LiveWindowGateway.swift:185,240-251,297-300,754-768`), but the baseline is
only refreshed on frame *reads* — so a window macOS relocated or rescaled during sleep, with a
transiently failing per-window probe, can yield `.dead`. Combined with the wall-clock clock
(ticket 03), that prunes a live window on the first post-wake tick.

Treat a window that the app lists as alive (a changed frame is membership, not death), and refresh
the baseline on a successful probe/listing.

**Blocked by:** 03 (collision — both touch the death path).

**Findings:** report M2 (frame half) (`.scratch/multi-display-audit/report.md`).

**Status:** DONE (b163b6d)

- [ ] A window that appears in the app's window list but at a moved/rescaled frame is **not**
      reported dead.
- [ ] A successful liveness probe refreshes the cached baseline, so a subsequent comparison does
      not judge against a stale frame.
- [ ] Genuine death is unaffected: a window absent from the app's list still reaches `.dead`.
- [ ] Pinned by tests: listed-but-moved → alive; probe refreshes baseline; absent → dead.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
