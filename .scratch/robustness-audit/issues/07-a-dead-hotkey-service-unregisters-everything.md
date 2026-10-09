# 07: A dead HotkeyService unregisters everything

**What to build:** A HotkeyService owns global hotkey registrations for its whole life and must give
them all back at the end of it. Tearing one down (or replacing it) must leave nothing registered:
no phantom combos swallowing keys system-wide, no double registration when a replacement service
registers the same combos. Today the teardown cleans up the event handler but not the registrations
themselves. While here, put the registration calls where tests can reach them (the handler already
has an injectable install/remove seam) so the lifecycle is pinnable at all.

**Blocked by:** None (can start immediately).

**Findings:** report D18 (`.scratch/robustness-audit/report.md`).

**Status:** ready-for-agent

- [ ] After teardown, every registration the service installed is unregistered; the combos are free
      system-wide.
- [ ] A replacement service registering the same combos dispatches exactly once per press (no double
      dispatch, no registration failure).
- [ ] Register / reload / teardown are pinned by tests through a seam (no hard-coded Carbon calls in
      the paths under test).
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
