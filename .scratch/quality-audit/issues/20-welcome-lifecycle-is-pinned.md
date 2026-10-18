# 20: Welcome lifecycle is pinned

**What to build:** Pin the first-run Welcome lifecycle: first build includes the tab, dismissal
persists and selects General, and "Tiled Guide" reopens it even when the window was hidden. The
current tests cover only the already-visible refresh path.

**Blocked by:** 09 (the Welcome truthfulness changes).

**Findings:** T8 (`.scratch/quality-audit/report.md`).

**Status:** DONE (31542b8)

- [ ] First build with `didDismissWelcome == false` includes Welcome and selects it.
- [ ] Dismissal persists, removes the tab, and selects General.
- [ ] Reopening from the menu rebuilds Welcome when the window was hidden.
- [ ] Reopening refreshes the shortcut instructions.
- [ ] Tests use temporary defaults.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
