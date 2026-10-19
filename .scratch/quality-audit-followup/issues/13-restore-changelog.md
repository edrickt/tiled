# 13: Changelog the atomic shortcut restore (docs)

**What to build:** The retain-and-retry restore plus footer persistence
(`Sources/tiled/SettingsShortcutsTab.swift:763-815`, landed as
`6324502`) is user-visible and pinned but has no `CHANGELOG.md
[Unreleased] Fixed` bullet — a `CODING_STANDARDS.md:17-23`
behavior-docs gap. Add one bullet describing snapshot restore,
retained clashes, and retry.

**Findings:** Follow-up audit F33 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] CHANGELOG `[Unreleased] Fixed` names the atomic restore behavior
- [ ] `./scripts/check-test-count.sh` still passes (docs-only change)
- [ ] Glossary-bound prose (slot, backup, restore)
