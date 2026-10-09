# 10: Death confirmation cannot prune a live window

**What to build:** Tiled releases a window's slot only when it is confirmed dead — the conservative
death standard is a feature. The geometric confirmation ("is this frame still one of the app's
windows?") compares against a frame baseline that only refreshes when something happens to read the
frame, so a window whose move notifications failed to register, and which the user then dragged,
can be matched against a stale baseline and confirmed dead during a transient probe failure — its
slot released while the window is alive on screen. Make the baseline track reality: successful
probes refresh it, and the match tolerates rounding instead of demanding frame identity.

**Blocked by:** 09 (collision serialisation — the pair shares the live gateway's files).

**Findings:** report D13 (`.scratch/robustness-audit/report.md`).

**Status:** ready-for-agent

- [ ] A successful liveness probe refreshes the frame baseline used by the geometric match.
- [ ] The match tolerates rounding-level frame differences instead of exact identity.
- [ ] The failure scenario is pinned: failed notification registration + user drag + one transient
      probe failure + app's window list answering → the window survives; its slot is not released.
- [ ] The fake models the live behaviours these paths depend on (baseline staleness; the death
      standard's shapes beyond the happy path).
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
