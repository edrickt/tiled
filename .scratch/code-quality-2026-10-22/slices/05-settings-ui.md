# Slice 05 — Settings UI

Read-only audit of `SettingsShortcutsTab.swift` (845), `SettingsWindowController.swift` (301),
`SettingsWelcomeTab.swift` (279), `SettingsGeneralTab.swift` (275), `RecorderButton.swift` (202),
`PermissionWindowController.swift` (165), `SlotPreviewView.swift` (100),
`TopAnchoredStackView.swift` (10), `AppSettings.swift` (26). Base `master` @ `47dea76`.
No source changed, no build or test run.

## Verdict

The settings surface is not one bad file; it is **one missing type and one missing owner**. The
Shortcuts tab is a view, a persistence layer, a conflict manager, and a small rules engine; its
single `conflictLabel` is the only message channel; its reset/restore button is a hidden mode. The
shell and tabs then trade views, sizes, providers, and one-shot booleans to compensate. Extract a
`ShortcutPark` model (A6) and a `ShortcutNotice` model, give the tab a stable container, and the
AppKit layer becomes build/render/route. F32 falls out of the message model; T11's premise turns
out not to be reachable at all.

## Cross-check of open findings

| Finding | Status | Current evidence |
|---|---|---|
| **F32** restore skip overwrites registration failure | **STILL PRESENT** | `reload()` clears then surfaces failures (`SettingsShortcutsTab.swift:238-246`, `284-295`); `restoreResetBackup` calls `reload()` (`:803-804`) then `showConflict("Not restored…")` (`:807-814`), replacing the failure text. No test combines a failed action with a clash-skipped restore. |
| **T11** reset-over-backup promise unpinned | **STILL PRESENT (unpinned), premise corrected** | Promise at `:731-734`; only the no-backup promise is asserted (`ShortcutsResetBackupTests.swift:163-165`); grep finds "replaces your previous backup" only in source. But the sequence "Reset → Reset again" is unreachable: after a reset the same button becomes Restore and `resetShortcuts` routes to restore (`:710-720`). The overwrite branch is dead copy, not merely unpinned. |
| **F33** CHANGELOG missing for atomic restore | **STILL PRESENT (docs only)** | `[Unreleased] Fixed` (`CHANGELOG.md:9-71`) has no snapshot-restore bullet; its only reset-adjacent line is the Disable-all tooltip (`:27-28`). |
| **A6** parked shortcuts module | **STILL ABSENT** | No park type/module exists; both namespaces and their rules remain private members of `ShortcutsTab` (`:542-563`, `:819-844`). `issues/A6-…` is still TODO. Note: splitter parking already has an owner in `TilingSpace`; the shortcuts park is the remaining half. |

---

## S1. A6: `ShortcutPark` — two park namespaces and their rules are domain logic trapped in the view

**Evidence.** Two codecs with the same shape and different prefixes (`SettingsShortcutsTab.swift:542-563`, `819-844`); the stale-edit rule and clash gate (`:437-464`); the snapshot transaction plus fixpoint loop (`:770-802`); retry/title reporting (`:805-814`); `anyResetBackup()` scans every case (`:842-844`) from four call sites. The recorder path repeats the same "mutate, fire, reload, compose" tail (`:616-676`).

**Reader-load / user-visible risk.** "A swapped pair restores as one snapshot" and "an edit made while disabled beats a stale park" are deep rules stated only in prose, tested only by building the whole tab and clicking buttons. The restore reimplements the duplicate gate with `hotkeyStore.set` (`:800`) because `apply` cannot express a transaction, so the store is no longer the one validation seam; a missed fixpoint case writes two actions onto one combo, and one then fails registration.

**Code-judo.** New `Sources/tiled/ShortcutPark.swift`: `ParkKind` (section/reset), persistence behind a small `ParkStore` protocol (UserDefaults adapter, in-memory in tests), and two pure plans — `BulkRestorePlan` (restored, keptEdits, clashes) and `SnapshotRestorePlan` (accepted, skipped, remaining). The tab applies plans through `HotkeyStore` and renders. Add "parked combo" to `CONTEXT.md`: the dialog already uses the word, the glossary has no entry.

**Branches that disappear.** The stale-park `if/else` (`:437-452`), the `guard let restored`/apply switch (`:453-464`), the fixpoint (`:784-798`), both codec pairs, and the title ternary (`:805-806`). **design · high confidence · M** (first slice S: codec + plans).

## S2. The park decoders are a second, unguarded copy of `HotkeyStore`'s binding codec

**Evidence.** `parkedBinding` (`:546-552`) and `resetBackupBinding` (`:823-829`) both pass a stored `Int` straight into `UInt32(modifiers)`. `HotkeyStore.binding` (`HotkeyBinding.swift:199-213`) guards the same field and documents why: "a negative modifiers is corrupt data … must not reach UInt32 (a trap)." The write halves are duplicated too (`:554-559`, `831-836`).

**Reader-load / user-visible risk.** A corrupt or legacy negative `modifiers` entry traps when the tab opens or restores, while the store deliberately survives identical data. Four copies of the encoding will keep drifting.

**Code-judo.** One codec on the type that owns the persisted binding: `HotkeyBinding.init?(storedEntry:)` and `var storedEntry: [String: Int]`, used by `HotkeyStore` and both parks. Delete both park codec pairs.

**Branches that disappear.** The two decode ladders and the two write dictionaries. **mechanical · high confidence · S**

## S3. One `conflictLabel` carries six message kinds with last-writer-wins ordering (root of F32)

**Evidence.** Declaration `:78`, build `:141-154`; `showConflict` `:692-699`, `clearConflict` `:701-704`. Writers: `reload` (`:244-245`), clear-park (`:635-640`), registration failure (`:652-657`), duplicate (`:658-669`), bulk report (`:472-482`), restore skip (`:807-814`). `reload()` clears first, then `surfaceHotkeyFailures` writes; every later writer silently overwrites. `showConflict` also re-announces a persistent registration failure on every reload or rebuild, and there is no silent-update path.

**Reader-load / user-visible risk.** Exactly F32: a skipped restore erases the registration-failure line. Every new message author must know the ordering. VoiceOver users hear the same failure again after each bulk toggle or reopen.

**Code-judo.** A pure `ShortcutNotice` model with fixed priority (`failures`, then `conflict`, then `result`), joined by one `render()` in the tab, one announcement only when the notice identity changes. The label becomes a single sink; callers return notices instead of writing.

**Branches that disappear.** Six direct `showConflict`/`clearConflict` call sites and the "clear in reload, re-add later" contract. **design · high confidence · S**

## S4. The view lifecycle is a two-way protocol the shell half-wires; `build` is not a complete render

**Evidence.** `buildSize` (`SettingsShortcutsTab.swift:498-500`), `onContentRebuilt` (`:501-502`), `rebuildContent` (`:517-528`); shell side `shortcutsView` (`SettingsWindowController.swift:194-197`, a one-caller wrapper whose only job is to stash the size), `replaceShortcutsView` (`:199-203`), `shortcutsItemIndex` (`:158-161`), `windowDidResize` (`:296-300`). `windowDidResize` has no caller anywhere in the repo and the controller never becomes the window delegate, so the resize mechanism its comment promises never runs. `shortcutRow` (`:322-355`) leaves all 22 recorders blank; only `reload` (`:238-241`) fills them, while bulk buttons and the footer self-initialize. Welcome's presence needs a one-shot mutable flag (`forceWelcomeOnce`, `:240-251`) plus a separate hidden-window open sequence that repeats `show()` (`:211-221`).

**Reader-load / user-visible risk.** Build→reload is an order contract; any future build path that forgets `reload` shows blank recorders. The shell carries three members to route a view and a size, and the one meant to keep the size fresh is dead. Four tests install `onContentRebuilt` only to capture the replacement view.

**Code-judo.** The tab owns a stable container (the tab item's view) and rebuilds its subviews in place; read the size from `container.bounds`, delete `onContentRebuilt`, `buildSize`, `replaceShortcutsView`, `shortcutsItemIndex`, `windowDidResize`. Make `buildTabView(frame:includingWelcome:)` take the flag as a parameter and delete `forceWelcomeOnce`; fold the hidden-window branch into one `present(selecting:)`. Render recorder labels during build, so `reload` only handles external change. Tests query one stable view.

**Branches that disappear.** The callback, three size writes, the rebuild guard/no-op, the one-shot flag, and `reload`'s label half. **design · high confidence · M**

## S5. The permission warning is a component in three copies, with two trust-flip implementations

**Evidence.** Build blocks: Shortcuts (`:117-137`), Welcome (`SettingsWelcomeTab.swift:67-88`), General (`SettingsGeneralTab.swift:79-105`) — identical sentence, button title, font, compression priority, and `-24` cap. `lastKnownTrusted` plus flip announcement exists in General (`:34-36`, `181-199`) and Shortcuts (`:82-84`, `300-313`); Welcome has the row but no flip announcement (`:272-274`). General posts against the row, Shortcuts against `conflictLabel`. The button title also appears in `PermissionWindowController.swift:132`.

**Reader-load / user-visible risk.** One promise and one inset live in four files; the tabs disagree about whether a trust flip is announced and where. A copy or inset edit drifts one tab, and the tests pin three copies by button title.

**Code-judo.** A `PermissionRow` component owns the copy, button, provider, visibility, and flip announcement (post against itself, as General already does). Each tab adds the row and deletes `lastKnownTrusted` and its refresh body.

**Branches that disappear.** Two flip branches, three build blocks, two copies of the warning string. **design · high confidence · S/M**

## S6. The reset/restore button is a hidden mode; its overwrite promise is unreachable

**Evidence.** `resetShortcuts` chooses restore whenever a backup exists (`SettingsShortcutsTab.swift:710-720`), so `confirmAndReset` is only reached with no backup; its overwrite branch (`:731-734`) and the comment claiming a second reset is warned (`:722-726`) describe a state the button cannot produce. The title is computed at build (`:214-216`) and written directly at `:753` and `:805-806`; `reload` never refreshes it. T11's requested test cannot drive the overwrite promise through `confirmReset` without a new seam.

**Reader-load / user-visible risk.** Dead copy claims a guard that the flow makes unnecessary; a future caller of `confirmAndReset` that skips the button would overwrite the snapshot with the comment's blessing. The footer is the one stateful control `reload` does not refresh, so a backup change outside those two methods leaves "Reset" in front of a restore.

**Code-judo.** Decide the model: either the button is one two-state control and the overwrite branch, comment, and T11's sequence go; or reset-again becomes an explicit second action and the promise stays. Either way derive the title in `refreshFooter()` from `anyResetBackup()` and move both promises to `ShortcutText.resetPromise(hasBackup:)`.

**Branches that disappear.** The direct title writes, the dead promise branch, and the duplicated mode decision. **design · high confidence · S**

## S7. `TopAnchoredStackView`'s doc prescribes the constraint all three call sites call broken

**Evidence.** `TopAnchoredStackView.swift:3-7`: "Pair with: top == contentView.top, bottom >= contentView.bottom." The call sites say the opposite: no bottom constraint, because a bottom pin "stretches the stack to the viewport and sinks the footer" (`SettingsShortcutsTab.swift:226-228`, `SettingsGeneralTab.swift:69-72`, `SettingsWelcomeTab.swift:56`).

**Reader-load / user-visible risk.** The shared component's only documentation teaches the exact bug each tab works around; Welcome points the reader to it by name. The next tab author follows the doc and reintroduces it.

**Code-judo.** State the real contract ("pin leading, trailing, and top only; never bottom") and let the scaffold from S5 encode the four constraints so no tab hand-writes them.

**Branches that disappear.** None at runtime; the trap and its three counter-comments. **mechanical · high confidence · S**

## S8. Dead and duplicated-derivation code in the slice

**Evidence.** `RecorderButton.slot` (`RecorderButton.swift:37-41`) has no caller. `SlotPreviewView.filledCells` (`:43-68`) re-states `TileCell`'s case order in an eight-case switch, while `TileCell.init(column:row:)` (`Layout.swift:33-35`) already treats that order as the coordinate system; the doc claims the picture "cannot disagree" with the engine. `ShortcutSection.layout` (`SettingsShortcutsTab.swift:29-35`) is an optional side-channel for an enum that is either app-actions or a layout, forcing the ternary at `:182`. `announce` (`:684`) has two statements on one line with broken indentation.

**Reader-load risk.** Adding or reordering a `TileCell` silently misdraws the first-run preview; the dead property suggests a row→slot link that no longer exists; the optional makes every consumer re-derive the case split.

**Code-judo.** Delete `slot`; derive `(column, row)` from `TileCell.allCases.firstIndex(of:)` or add `column`/`row` to `TileCell`; model `ShortcutSection` as `.appActions | .layout(LayoutKind)` with a custom raw value preserving the stored strings; fix the line.

**Branches that disappear.** The eight-case mapping, the layout ternary, and the dead accessor. **mechanical · high confidence · S**

## S9. The Welcome guide's copy matrix is assembled in the view

**Evidence.** `refreshShortcutInstructions` (`SettingsWelcomeTab.swift:206-229`, three branches), `topLeftInstructions` (`:233-238`), `refreshBehaviorNote` (`:244-259`, two branches). Tests read strings out of a built hierarchy (`WelcomeInstructionsTests.swift:27-104`).

**Reader-load risk.** The guide is the first-run contract where F9/F10 lived; each disabled/failed/remapped combination adds a branch, and only a built view tells you the output.

**Code-judo.** A pure `WelcomeGuideText.make(topLeft: HotkeyBinding?, failed: Set<HotkeyAction>, expand: …) -> (steps: String, behavior: String)`; the view assigns two strings and the matrix becomes a table test.

**Branches that disappear.** The nested registration/disabled branches and the two helper indirections. **design · medium confidence · S** (do it when Welcome is next touched).

---

## Ranked shortlist — worth fixing this week

1. **S3** — one notice model; closes F32 and removes the last-writer-wins class. S.
2. **S2** — one guarded binding codec; closes the trap and is the first slice of S1. S.
3. **S6** — decide reset-vs-restore; delete the dead overwrite promise, derive the footer, and replace T11 with a reachable pin. S.
4. **S1** — land A6 as `ShortcutPark` + two pure plans; the structural centerpiece. M (start with the plans).
5. **S5** — one `PermissionRow`; deletes duplicated state and copy across three tabs. S/M.

Best M-sized follow-on if the week has room: **S4** — the rebuild protocol and its dead resize hook. It is the largest reader-load cut in the slice, but no current user-visible bug depends on it.
