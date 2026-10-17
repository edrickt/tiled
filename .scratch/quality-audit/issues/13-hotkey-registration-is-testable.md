# 13: Hotkey registration is testable

**What to build:** Registration and reload must be exercised without a live Carbon process. The
current tests pin constants and an unused route table; no test constructs `HotkeyService`, so
disabled-action skipping, `failedActions`, and `reload` are unverified in the hermetic suite.

Inject a registrar that answers an `OSStatus` (and records the requested bindings), then pin
registration, disabled actions, failures, teardown, and reload.

**Blocked by:** None (can start immediately).

**Findings:** T1 (`.scratch/quality-audit/report.md`).

**Status:** TODO

- [ ] A registrar adapter replaces the direct Carbon registration call at the test seam.
- [ ] Tests pin registration of every enabled action, skipping every disabled action, and the
      failed-action list on a non-`noErr` status.
- [ ] Reload unregisters the old set and registers the new one.
- [ ] Deinit leaves no registration alive (the advertised contract).
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
