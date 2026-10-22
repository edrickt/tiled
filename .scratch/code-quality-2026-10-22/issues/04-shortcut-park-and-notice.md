# 04: Shortcut park and priority notice

**What to build:** `ShortcutPark` owning both park namespaces, the
stale-edit rule, the snapshot transaction/fixpoint, and retry state, with
two pure plans (`BulkRestorePlan`, `SnapshotRestorePlan`) driving the
tab. A `ShortcutNotice` model with fixed priority (`failures`, then
`conflict`, then `result`) and one announcement per identity change.
Decide the reset/restore button model: either delete the unreachable
"replaces your previous backup" branch and its comment (T11), or make a
second reset an explicit action and keep the promise. Derive the footer
title from `anyResetBackup()` in one place.

**Why:** the 845-line tab is a view, persistence layer, conflict
manager, and rules engine. Six writers race on one `conflictLabel`
(last-writer-wins is F32's root); the park decoders were a second,
unguarded codec (now fixed in `d486aef`); the overwrite promise is dead
from the button.

**Findings:** `../report.md` "Still open 4"; `../slices/05-settings-ui.md`
S1, S3, S4, S6; F32/T11 in `../../quality-audit-followup/report.md`.

**Status:** TODO

- [ ] Pure plans pin the swapped-pair restore, the clash-retained entry,
      and the stale-edit rule before the view moves.
- [ ] `ShortcutPark` lands; both codecs and the fixpoint leave the tab.
- [ ] One notice sink with fixed priority; the six direct writes are
      deleted.
- [ ] T11's product rule is decided and pinned (or the dead branch is
      deleted).
- [ ] Gates in `../README.md` all pass.
