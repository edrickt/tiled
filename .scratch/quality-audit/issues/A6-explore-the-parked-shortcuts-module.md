# A6: Explore the parked shortcuts module

**What to build:** A design decision, not code yet. The disable-all park, the reset backup, the
stale-edit rule, and the clash gate live in a 796-line AppKit view controller, so the deep rule is
tested by building views and clicking buttons. Decide a parked-shortcuts module that owns both
park kinds, their persistence, and the stale/clash rules, with the store's duplicate gate as the
one validation seam.

**Blocked by:** 03 (the atomic restore should land first so the module has a correct behavior to
absorb).

**Findings:** A6 (`.scratch/quality-audit/report.md`, HTML candidate A6).

**Type:** design

**Status:** TODO

- [ ] The module's interface covers park, restore, reset backup, and stale-edit resolution.
- [ ] Persistence is behind a local-substitutable adapter (UserDefaults in production, in-memory
      in tests).
- [ ] The Shortcuts tab renders and delegates; the park rules leave the view controller.
- [ ] The interface is recorded before implementation.
