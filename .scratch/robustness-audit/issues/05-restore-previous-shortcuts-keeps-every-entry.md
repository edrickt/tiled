# 05: Restore Previous Shortcuts restores or keeps every entry

**What to build:** "Restore Previous Shortcuts" is the undo for Reset Shortcuts: the reset dialog
promises "Your current combos are kept; use Restore Previous Shortcuts to get them back". A restore
that hits a clash must never destroy the entry it cannot restore. Today the backup entry is cleared
before the restore is attempted, so a combo the user has since reassigned is reported "Not restored
(taken by …)" and then lost forever, with the button flipping to "Reset Shortcuts" so no retry
exists. Keep the clash-reported entry in the backup, exactly as the Disable-all park already does.

**Blocked by:** None (can start immediately).

**Findings:** report D4 (`.scratch/robustness-audit/report.md`).

**Status:** ready-for-agent

- [ ] A clash-reported entry survives in the backup; after the user frees the combo, pressing the
      button again restores it.
- [ ] Entries successfully restored are cleared; the button's title reflects whether any backup
      entry remains.
- [ ] The reset dialog's promise is true in every outcome (first reset, second reset with the
      overwrite warning, partial restore).
- [ ] The clash path is pinned by a test mirroring the bulk-enable park test.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
