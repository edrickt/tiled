# Documentation recheck — 2026-10-15

Independent verification of every published doc at `bbe8742` (the
2026-10-15 corrections commit; code identical to `ab6ce65`). Supersedes
nothing; complements `report-2026-10-15.md`, whose fixes this pass
re-verified and whose two rewrites (R4, M2) introduced the main defects
found here. Scope: `README.md`, `CONTEXT.md`, `CHANGELOG.md`,
`SECURITY.md`, `docs/` (ADRs, release notes, UI plan),
`tools/repro/multi-display-checklist.md`. Method: every behavioral claim
checked against source and tests; `swift test` re-run (677 tests, 0
failures); `python3 tools/mutation/mutate.py` re-run (84/84 mutants
caught in 3m16s on the 8 GB M1 Air); historical counts checked at the
`v0.1.0` and `v0.2.0` tags. All fixes below are **applied in the working
tree alongside this report**.

## Fixes applied

| # | Where | Problem → fix | Evidence |
|---|-------|---------------|----------|
| 1 | `README.md` Reset Splitters section | "after a reset or a drag the same row is titled Restore Previous Splitters" was false: only a reset parks the backup; a drag alone leaves the row titled Reset Splitters, and drag→reset→restore returns the post-drag (pre-reset) positions, never pre-drag. Reworded: a reset parks the pre-reset positions; a drag alone never arms the restore (and doesn't clear a parked one). | `TilingSpace.swift:1393-1399` (sole writer of `splitterBackup`), `:1405-1416`, `MenuModel.swift:281-282`, `AppDelegate.swift:531` |
| 2 | `README.md` Live resizing section | "After a drag the same row is titled Restore Previous Splitters, restoring the pre-drag splits instead." Same defect as #1. Reworded to the reset-parked restore. | same as #1 |
| 3 | `tools/repro/multi-display-checklist.md` scenario 8 | "Drag a splitter first (so a splitter backup exists)" asserted a backup the drag never creates; the retitle sentence was muddled. Reworded: drag for custom positions, the **Reset Splitters** use parks them and retitles the row, the restore consumes the park. | `TilingSpace.swift:1393-1412`, `AppDelegate.swift:820-837` |
| 4 | `SECURITY.md` preferences bullet | "Two preferences" undercounted what persists in `dev.tiled.app`. Replaced with the full list: `hideMenuBarIcon`, `didDismissWelcome`; shortcut overrides (`hotkey.*`) plus parked and reset-backup copies (`parkedHotkey.*`, `resetBackupHotkey.*`); `collapsedShortcutSections`; the `TiledSettings` window frame autosave. | `AppSettings.swift:7-8`, `HotkeyBinding.swift:177,214-218`, `SettingsShortcutsTab.swift:537-539,566-570,770-772`, `SettingsWindowController.swift:92` |
| 5 | `README.md` Live resizing | "Vertical and horizontal splitters are independent per column (quarters) or per third (sixths)" overstated: the vertical divider is shared (quarters routes all three interior vertical lines through one `columnSplit`; sixths' two dividers span all rows). Only the row splitters are per column/per third. Reworded to "The row splitters are independent per column…". | `Layout.swift:242-249` (`verticalBoundary`), `:214-217,222-228` (per-column/per-third row splits) |
| 6 | `.scratch/ui-polish/ui-audit.md` | Captures were cited at `docs/ui-audit-captures/`, which does not exist; they live in `.scratch/ui-polish/ui-audit-captures/`. Both references fixed. | directory listing |
| 7 | `tools/repro/destroy-notification-probe.swift`, `README.md` | Usage read `<pid> [close|kill]` but the mode is required (`close (default)` was stale too). Changed to `<pid> <close|kill>` in the probe header, the `close` legend, and the README. | `destroy-notification-probe.swift:37-40` |

## Verified accurate (no change)

- **Counts**: 677 tests (fresh run); 39 live cases (33 `verify` calls,
  S15 looped ×3 → 35, plus 4 direct checks); 84-mutant table all caught
  in 3m16s (README's "~3-4 min"); 613 tests / 50 mutants at `v0.2.0`;
  551 / 44 at `v0.1.0`; ADR 0001's "84 mutants" and "655-test suite"
  match its commit `65acd1d`.
- **Hotkeys**: all 17 slot + 5 app-action defaults, modifiers, and the
  22 count match `HotkeyService.swift`; remap/disable/park/reset
  behaviors and conflict handling match `HotkeyBinding.swift` /
  `HotkeyRecorder.swift` / `SettingsShortcutsTab.swift`.
- **Menu**: active-layout-only slot list, single switch row, top-level
  Expand/Evict rows, `Untile N Windows`/`Restore Previous Splitters`
  titles, `Tiled Guide`, layout-switch notice, warning summary — all
  match `MenuModel.swift` / `MenuText.swift` / `AppDelegate.swift`.
- **Tiling rules**: no-op self-tile, swap with focus-follows and its
  fallbacks, step-aside, re-house, rightmost-wins reflow, layout-switch
  requester placement, drag-out (~50pt, drop decides, missed-mouse-up
  debounce fallback, programmatic far jump still snaps back) — all match
  `Layout.swift`, `TilingSpace.swift`, `DragTracker.swift`; the
  unreleased CHANGELOG entries match the same code.
- **Canvas/display model**: per display+Space canvases keyed on the
  CoreGraphics display number, withheld-Space fallback treated visible,
  stale marking with no off-Space writes, absent display keeps frame,
  splitters, and undo — match `DisplaySpace.swift`,
  `TilingController.swift`, `FrameWriter.swift`.
- **CONTEXT.md**: every `_Code_` reference exists (`TilingSpace`,
  `TilingSpaceKey`, `visibleFrame`, `reassert`/`reassertPlan`,
  `execute(decision:)`, `FrameWriter.Result.stands`,
  `deferredOffSpaceAnnouncement`, `GridBoundary`); `Context.boundsOf` is
  gone.
- **Build / release / CI**: Makefile targets, `VERSION`, ad-hoc signing,
  macOS 13 minimum, universal zip + `.sha256`, release tag check, and
  the tests workflow all match `Makefile`, `scripts/`, and the
  workflows; SECURITY.md's no-network, `dlsym`/SkyLight, single-binary,
  and `SMAppService` claims hold.
- **Checklist**: setup/step 2 (suite kills both apps via trap, refuses
  while an installed app runs, `TILED_DEBUG=1` support) and scenarios
  1-7 match the script and code.
- **ADRs 0001/0002**: no contradictions; ADR 0002's "decide-only
  tracker still commits live splitter fractions" is exactly right
  (`DragTracker.processResize`).

## Flagged, not edited (historical records)

- `CHANGELOG.md:42-44` and `docs/release-notes/v0.2.0.md:23-25`
  ("then press it again to restore the previous positions") remain true
  of the menu row only; the ⌥⇧R hotkey has always reset and replaced the
  backup (`AppDelegate.swift:150`). Carried over from the 2026-10-15
  audit as a known historical overstatement; a one-line note in the next
  release's entry would close it without rewriting 0.2.0.
- `CHANGELOG.md:47-48` and `docs/release-notes/v0.2.0.md:22`
  ("Customized combos render … instead of being hardcoded"): true for
  the menu rows, but outcome notices still embed "Press ⌃⌥⇧⌘Z to undo."
  (`TilingSpace.swift:508-509,587,669,786,1203`) and the General tab
  embeds "⌃⌥⇧⌘," (`SettingsGeneralTab.swift:122,129,239`). Historical
  overstatement; optionally noted alongside the item above.

## Environment note

The mutation run is the same 84-mutant table CI never runs (it is a
local gate); the re-run confirms both the README's timing claim and that
the current suite still catches every injected bug (84/84 CAUGHT, no
survivors or unresolved entries).
