# 16: Pin the reset-over-backup overwrite promise

**What to build:** `Sources/tiled/SettingsShortcutsTab.swift:731-734`
builds the "This replaces your previous backup…" promise when a backup
already exists, but the suite asserts only the no-backup promise
(`Tests/tiledTests/ShortcutsResetBackupTests.swift:163-165`). Extend
`ShortcutsResetBackupTests` through the existing `confirmReset` seam
(`SettingsShortcutsTab.swift:70`) to capture the second promise and
assert the first snapshot is replaced only after confirm.

**Findings:** Follow-up audit T11 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] Second-reset promise wording pinned; replacement-only-after-confirm pinned
- [ ] Gates: `swift build` warnings empty, `swift test` green, `check-test-count.sh` pass
