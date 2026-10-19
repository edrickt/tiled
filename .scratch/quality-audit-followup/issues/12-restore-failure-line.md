# 12: Keep the registration-failure line across a skipped restore

**What to build:** `restoreResetBackup` calls `reload` then overwrites
the same conflict line with "Not restored…"
(`Sources/tiled/SettingsShortcutsTab.swift:803-814`), hiding a
registration failure that `reload` just re-surfaced (`:284-295`).
Join both messages on the conflict line, or re-surface failures after
the restore message.

**Findings:** Follow-up audit F32 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] A skipped restore with a live registration failure names both truths on the tab
- [ ] Combined-case test (non-empty `failedActionsProvider` + clash-skipped restore) through the real tab
- [ ] Gates: `swift build` warnings empty, `swift test` green, `check-test-count.sh` pass
