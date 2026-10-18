# 14: App launch and action routing are testable

**What to build:** The launch branches and the hotkey action switch must be pinned without a GUI.
Today no test constructs `AppDelegate`; the helper tests cover menu composition but not the
trusted/untrusted start, first-run Welcome, hidden-icon recovery, or the action→controller route.

Extract the launch/routing decisions behind injectable collaborators and test the branches.

**Blocked by:** 13 (the injected hotkey service).

**Findings:** T2 (`.scratch/quality-audit/report.md`).

**Status:** DONE (702f938)

- [ ] The trusted start and the untrusted explainer path are both testable and pinned.
- [ ] First-run Welcome opens once and stays dismissed.
- [ ] Hidden-icon recovery opens Settings on launch.
- [ ] Every `HotkeyAction` maps to the intended controller call; a swapped route fails a test.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
