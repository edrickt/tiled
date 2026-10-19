# 10: Delete the dead menu title helpers

**What to build:** `Sources/tiled/AppDelegate.swift:749-759` defines
private `undoDisplacementTitle` and `untileAllTitle` with no caller —
the live menu path builds both titles from the snapshot
(`Sources/tiled/MenuModel.swift:281-298`). The dead `untileAllTitle`
counts every visible canvas, the exact mismatch ticket 06 removed.
Delete both helpers; the snapshot path already owns both titles.

**Findings:** Follow-up audit F30 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] Both helpers deleted; no caller added (deletion is the pin)
- [ ] Gates: `swift build` warnings empty, `swift test` green, `check-test-count.sh` pass
