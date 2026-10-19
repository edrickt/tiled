# 08: Pin the Carbon callback body through a test seam

**What to build:** `carbonCallback`
(`Sources/tiled/HotkeyService.swift:280-298`) parses the event,
resolves through `route`, and hops to the main queue — but nothing
drives it (the installer is stubbed in every registration test). Expose
a test-only entry that maps an id to a handler invocation without a
Carbon event, or inject the main-queue hop, so the callback body is
pinned the way `route` already is.

**Findings:** Follow-up audit F28 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] A regression inside the callback (parameter, hop, bypass around `route`) turns a test red
- [ ] New test beside `Tests/tiledTests/HotkeyServiceTests.swift:135-159`
- [ ] Gates: `swift build` warnings empty, `swift test` green, `check-test-count.sh` pass
