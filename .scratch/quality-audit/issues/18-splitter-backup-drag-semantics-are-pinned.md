# 18: Splitter-backup drag semantics are pinned

**What to build:** Pin the README's one-step-restore contract at the drag boundary: a drag alone
never arms the restore, a drag after a reset does not clear the parked backup, and a second reset
replaces the parked snapshot. The current tests cover reset/restore but not the drag interleavings.

**Blocked by:** None (can start immediately).

**Findings:** T6 (`.scratch/quality-audit/report.md`).

**Status:** TODO

- [ ] Drag a splitter without resetting: `hasSplitterBackup` stays false.
- [ ] Reset, then drag: the parked backup survives and restores the pre-reset positions.
- [ ] Reset twice: the second reset replaces the previous backup; restore lands the second
      pre-reset positions.
- [ ] The drag/reset semantics are driven through the real controller/tracker path.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
