# 08: Hide-icon recovery names a live combo

**What to build:** The hide-icon confirm must only promise a recovery combo that is actually
registered, and it must name the user's current Settings binding, not the old default. Today the
provider checks only `failedActions`; a disabled Settings action is skipped and never fails, and a
remapped Settings action still renders `⌃⌥⇧⌘,`.

**Blocked by:** None (can start immediately).

**Findings:** F8 (`.scratch/quality-audit/report.md`); robustness-audit D19.

**Status:** DONE (ede868c)

- [ ] Disabling the Settings action makes the hide-icon confirm take the relaunch-only path.
- [ ] Remapping Settings makes the confirm name the live binding.
- [ ] A registered default still names the default combo.
- [ ] The provider and dialog are unit-tested without hiding the real icon.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
