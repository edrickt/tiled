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

**Status:** DONE (5967fc0)

- [x] Pure plans pin the swapped-pair restore, the clash-retained entry,
      and the stale-edit rule before the view moves.
- [x] `ShortcutPark` lands; both codecs and the fixpoint leave the tab.
- [x] One notice sink with fixed priority; the six direct writes are
      deleted.
- [x] T11's product rule is decided and pinned (or the dead branch is
      deleted).
- [x] Gates in `../README.md` all pass (build, test, count; the mutation
      table is deferred per `AGENTS.md`, so it was not run).

## Comments

Landed in `68a9f38` (park + notice models and pure-plan tests) and
`5967fc0` (tab applies the plans, one notice render path, T11 footer).

Gates actually run after each unit: `swift build 2>&1 | grep -E
"warning:|error:"` (empty), `swift test` (908 then 913, 1 skipped), and
`./scripts/check-test-count.sh` (README matched 908 then 913). Baseline
was 900. The mutation table was not run: `AGENTS.md` defers it to the
end of the batch, and this ticket's scope explicitly excludes
`tools/mutation/mutants.json` and `mutate.py`.

Shapes: `ShortcutPark` owns both namespaces (`parkedHotkey.` /
`resetBackupHotkey.`), the one `HotkeyBinding` stored-entry codec, the
stale-edit rule, retry state, and `anyResetBackup()`/`footerTitle`.
`BulkRestorePlan` yields restored/keptEdits/clashes; `SnapshotRestorePlan`
yields accepted/skipped/remaining with the existing fixpoint.
`ShortcutNotice` composes failures, then conflict, then result; the tab
renders it once, and announcement identity is tracked apart from the
label so a rebuild re-shows a persistent failure without speaking it.

T11 decision: the footer is one two-state control. With no readable
snapshot it is Reset Shortcuts and the dialog promises the combos are
kept; with a snapshot the same control is Restore Previous Shortcuts, so
a second reset is unreachable and the "replaces your previous backup"
branch and comment are gone. The title comes only from
`refreshFooter()`/`ShortcutPark.footerTitle`, called from build and
reload. Pinned by `testResetControlIsTwoStateAndNeverOffersASecondReset`
and `testFooterFollowsTheResetSnapshotOnReload`.
