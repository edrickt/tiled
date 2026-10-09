# 06: The hide-icon confirm names a recovery that works

**What to build:** Checking "Hide menu bar icon" is destructive — the menu bar becomes the only
handle on the app — so its confirmation promises a recovery combo. That promise must name the
recovery that actually works: the Open Settings shortcut **as currently bound** (with its real
label), or a relaunch-only recovery when it is not bound. Today the dialog hard-promises the default
combo even after the user disabled or rebound it, and misdiagnoses "not registered yet (permission
pending)" as "already used by another app".

**Blocked by:** None (can start immediately).

**Findings:** report D19, L9 (`.scratch/robustness-audit/report.md`).

**Status:** ready-for-agent

- [ ] With Open Settings rebound to another combo, the confirm names that combo; with Open Settings
      disabled, the confirm offers the relaunch-only recovery and says so.
- [ ] Pre-trust (nothing registered yet), the confirm names the pending-permission situation, not a
      phantom conflict.
- [ ] The checkbox's standing hint renders the current binding's real label, not a hard-coded combo.
- [ ] The states above are pinned by tests (they are pure decision logic behind the dependency
      provider).
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
