# 03: Restore Previous Shortcuts restores atomically

**What to build:** The one-step Restore Previous Shortcuts must restore the whole reset snapshot,
including a pair of actions that swapped their defaults, and must not destroy a backup it could
not apply. Today `restoreResetBackup` clears each backup before calling the per-action duplicate
gate (`SettingsShortcutsTab.swift:747-765`). A swapped pair fails both applies — each action's
backup is still occupied by the other action's current default — and both backups are deleted.

The restore is a complete snapshot, so conflicts **inside** the snapshot must be allowed and
resolved together; conflicts with actions outside the snapshot must still be rejected through the
store's one duplicate gate, with the rejected backup retained and reported.

**Blocked by:** None (can start immediately).

**Findings:** F3 (`.scratch/quality-audit/report.md`); also `robustness-audit` D4.

**Status:** DONE (6324502)

- [ ] Reset → swap Top Left and Top Right → Restore restores both and consumes both backups.
- [ ] A backup whose combo is held by an action outside the snapshot is rejected, retained, and
      named in the inline conflict message; the rest of the snapshot still restores.
- [ ] A second Restore can retry the rejected entry after the external conflict is cleared.
- [ ] The footer button remains "Restore Previous Shortcuts" while any backup is retained.
- [ ] The restore does not write past the store's duplicate gate for an external owner.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
