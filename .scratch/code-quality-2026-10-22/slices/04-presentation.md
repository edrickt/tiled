# Slice 04 — Presentation: AppDelegate, MenuModel, MenuText, StatusIcon, main

Read-only maintainability pass over the status-menu / status-icon shell.
No builds or tests were run. Evidence is current-tree `file:line`.

## Cross-check of open findings

| ID | Status | Current evidence |
|---|---|---|
| F30 dead `undoDisplacementTitle` / `untileAllTitle` | **STILL PRESENT** | `Sources/tiled/AppDelegate.swift:749-759`; repo-wide grep finds no caller. The live titles are `Sources/tiled/MenuModel.swift:281-298`. The dead `untileAllTitle` still counts `controller.tiledWindowsInfo` (all canvases), the exact F6 mismatch. |
| F31 splitter actions outside the receipt path | **STILL PRESENT** | `Sources/tiled/AppDelegate.swift:888-906` announces fixed sentences; `Sources/tiled/TilingController.swift:857-898` returns `Void`/`Bool` and discards the `Outcome`; `Sources/tiled/HotkeyActionRouter.swift:72-74` resets silently. Worse than asymmetry: `TilingSpace.resetSplitters` overwrites `splitterBackup` (`TilingSpace.swift:1487-1492`), so the global reset while a backup is parked destroys the user's previous drag positions. |
| A5 one action receipt | **STILL PRESENT (narrowed)** | Evict/untile-all/undo/untile(window) return `ActionReceipt` (`TilingController.swift:815, 936, 1404, 1449`) and `present(_:)` consumes it (`AppDelegate.swift:925-937`). But slot/expand actions still use the separate `Feedback` channel (`TilingController.swift:155-170` -> `AppDelegate.swift:965-995`), splitter actions bypass receipts (F31), and `menuSnapshot` recombines `receipt.notice` with canvas error/notice through four parallel fields (`AppDelegate.swift:30-41, 593-608`). The receipt is not yet the single user-visible truth. |
| F27 README adapter-seam wording | Skipped | Out of slice. |

## Findings

### P1. The menu bar has no owner: AppDelegate is lifecycle, presenter, and renderer in one 1076-line file

**Evidence.** `AppDelegate.swift:1-1076` mixes launch/permission (`:59-218`), status item (`:222-229, 443-452`), icon drawing (`:289-418`), refresh policy (`:454-518`), snapshot assembly (`:530-666`), menu wiring (`:668-747`), settings/hotkey wiring (`:781-837`), action selectors (`:845-1033`), and the menu delegate (`:1036-1075`). The pure presentation helpers (`monitorPresentation` `:617-666`, `menuNotice` `:593-608`, `menuWiring` `:671-710`, `refreshPass` `:280-287`, `refreshPlan` `:470-475`) are statics on the delegate; the AppKit status-icon renderer (`statusIcon` `:289-349`, `IconCorner` `:353-355`, `cellPath` `:364-412`) sits beside launch code. `setupStatusItem` resolves focus twice: `iconSnapshot()` (`:225` -> `:241-246`) and `menu()` (`:228` -> `:506-510` -> `menuSnapshot()` `:535-537`), so the setup path does not honour the one-canvas invariant the refresh path documents (`:248-287`).

**Reader-load / risk.** Tracing permission flow or hotkey lifecycle means scrolling past 400 lines of `NSBezierPath` and menu copy. Every new menu field edits the launch file. The setup path can build the glyph and menu from two independent focus resolutions, unlike `refreshMenu` and `menuNeedsUpdate`, which the tests pin.

**Code-judo.** Extract a `MenuBarPresenter` owning one `MenuBarSnapshot { menu: MenuModel.Snapshot; icon: StatusIcon.Snapshot }`, the last-snapshot diff, `menuOpen`, `RefreshPlan`, NSMenu construction, and status-item show/hide. Extract `StatusIconRenderer` (snapshot in, `NSImage` out). AppDelegate keeps launch, permission poll, settings/hotkey lifecycle, action selectors, and receipt presentation. The presenter asks the controller for `hasFocusedWindow`, not the AX gateway.

**Branches that disappear.** `menu()` vs `menu(from:)` (`:506-518`), `menuSnapshot()` vs `menuSnapshot(space:)` (`:535-542`), `iconSnapshot()` vs `iconSnapshot(space:)` (`:241-256`), static `refreshPass` (`:280`) and `refreshPlan` (`:470`), and `statusIconDescription` (`:416-418`). The setup path can no longer take two focus resolutions.

**Mechanical / design:** design. **Confidence:** high. **Effort:** L.

### P2. `activeWarnings` breaks the one-pass rule and `hasHotkeyWarnings` restates `!warnings.isEmpty`

**Evidence.** `menuSnapshot(space:)` receives one canvas key (`AppDelegate.swift:542`) but `activeWarnings` re-resolves focus for `tileError` (`:546, 768-777`), so layout title/notice can describe the passed canvas while the error row describes the focused one. `hasFocusedWindow` queries AX at `:574`; `focusedExpandState` queries it again inside the controller (`TilingController.swift:902-907`). `hasHotkeyWarnings` (`:841-843`) recomputes `!(hotkeys?.failedActions ?? []).isEmpty` even though `warnings.hotkeyWarnings` was just built from the same array (`:769-774`). In `MenuModel.swift:153-164`, `if !snapshot.warnings.isEmpty` and `if snapshot.hasHotkeyWarnings` are the same condition.

**Reader-load / risk.** A future warning kind, or a caller passing a non-focused key, produces two canvases' truth in one snapshot. Today the duplicate is benign only because both reads happen to resolve the same focus. The reader must trace two warning sources to know whether a row and its "Open Shortcuts…" door agree.

**Code-judo.** Build one `MenuReads` value from `space` (canvas, hotkey warnings, rows, `hasFocusedWindow`, trust), then derive the snapshot purely. Delete `Snapshot.hasHotkeyWarnings`, derive it from `warnings`, and merge the two adjacent `MenuModel` branches into one. Expose `hasFocusedWindow` from the controller so the presenter performs no AX query.

**Mechanical / design:** design. **Confidence:** high. **Effort:** S/M.

### P3. The snapshot claims to be everything the menu reads, but excludes hotkey labels — `force:` is the tell

**Evidence.** `MenuModel.Snapshot` is documented as "Everything the menu structure reads" (`MenuModel.swift:49-53`), yet `MenuModel.items` takes a live binding closure (`:127-129`) and reads labels at `:231, 235, 289, 306, 325, 341`. `AppDelegate` patches the resulting diff hole with `refreshMenu(force: true)` on every binding edit (`AppDelegate.swift:477, 496-503, 814-820`), and the comment admits it: "Binding labels live in menu titles but not in the snapshot, so a label-only change would diff clean."

**Reader-load / risk.** Snapshot equality is a lie; the force flag bypasses the diff for every future change on that path. A remap that reaches the store without `onHotkeysChange` leaves stale combos in menu titles, and nothing in the type system prevents it.

**Code-judo.** Put the label map (or the fully composed `[MenuModel.Item]`) inside `MenuBarSnapshot`, so `MenuModel.items(snapshot:)` needs no closure. Delete `force:` and its one call site. The diff becomes the single rebuild decision.

**Mechanical / design:** design. **Confidence:** high. **Effort:** M.

### P4. Splitter actions are the last hand-built outcome (F31), and the hotkey route loses the backup

**Evidence.** `AppDelegate.swift:888-906` announces `"Splitters restored…"` / `"Splitters reset…"` without consulting the controller; `TilingController.resetDividers()` discards the reassert outcome (`:857-874`), even though a refused write sets `canvas.error` (`TilingSpace.swift:1192-1194`). `restoreSplitters()` returns `Bool` but not the canvas verdict (`TilingController.swift:880-898`). The restore sentence exists twice (`AppDelegate.swift:894` and `TilingSpace.swift:1504`). The hotkey route calls only `resetDividers()` (`HotkeyActionRouter.swift:72-74`), unlike the menu, which restores when a backup exists (`AppDelegate.swift:891-897`).

**User-visible risk.** The menu says "Splitters reset" while `canvas.error` names a refused window; the hotkey is silent; pressing the reset hotkey with a parked backup overwrites it with the already-reset grid, so "Restore Previous Splitters" no longer restores the user's positions.

**Code-judo.** Return an `ActionReceipt` from reset and restore, built by the same `receipt(...)` helper as the other four actions (`TilingController.swift:1629-1639`), with sentences in `MenuText`. Route menu and hotkey through `present(_:)`. Make both routes share the restore-if-backup rule, or expose reset and restore as distinct actions so reset can never clobber a parked backup.

**Mechanical / design:** design. **Confidence:** high. **Effort:** M.

### P5. Two outcome channels and four parallel receipt fields (A5)

**Evidence.** Slot and expand actions report through `Feedback` (`TilingController.swift:155-170`) and `signalFeedback` rebuilds announcements in the delegate (`AppDelegate.swift:965-995`), including re-reading `controller.canvas(...).error` at `:979, 985`. Receipt state is four fields: `lastActionReceipt`, `lastReceiptFocusedSpace`, `lastReceiptGeneration`, `actionGeneration` (`:30-41`), cleared field-by-field on focus (`:66-72`) and recombined in `menuNotice` (`:593-608`). `announce`'s fallback branch (`:946-958`) is unreachable in production: `statusItem?.button ?? settingsController?.window ?? NSApp` is never nil after `main.swift:3`, so every `fallback:` argument and the canvas re-reads that feed it are dead.

**Reader-load / risk.** A new action can speak through one channel and set a menu notice through another. The clear-on-focus rule must remember three fields; the comment at `:66-68` names the stale-notice failure that a forgotten field would resurrect.

**Code-judo.** Make every action return `ActionReceipt` (slot/expand can return synchronously; announcement nil for silent success), delete `Feedback` and `signalFeedback`, and reduce `announce` to one argument. Replace the receipt triple with a `NoticePresentation` value that owns `present/clear/overlay`, held by the presenter (P1).

**Mechanical / design:** design. **Confidence:** high on the duplication and dead fallback; medium on receipt-izing every slot path. **Effort:** M.

### P6. Dead title helpers and one-caller wrappers (F30)

**Evidence.** `AppDelegate.swift:749-759` defines `undoDisplacementTitle` and `untileAllTitle`; neither has a caller. `statusIconDescription` (`:416-418`) is a one-line passthrough; `hasHotkeyWarnings` (`:841-843`) is a one-caller recomputation (P2); `menu()` and `menuSnapshot()` are one-caller indirections (P1).

**Reader-load / risk.** A reader cannot tell the live title path from the dead one, and re-wiring the dead `untileAllTitle` would reintroduce the cross-canvas "Untile 0 Windows" bug. Dead code also keeps the pre-ticket-06 count alive as a false precedent.

**Code-judo.** Delete both computed vars and the passthrough now; the other wrappers disappear with P1/P2. The snapshot path (`MenuModel.swift:287-298` + `AppDelegate.swift:577-582`) already owns both titles.

**Mechanical / design:** mechanical. **Confidence:** high. **Effort:** S.

## Verified clean

- `main.swift` and `NSApplication+Activate.swift` are minimal and correct.
- `StatusIcon`'s pure mapping (`StatusIcon.swift:36-91`) is well shaped; only its AppKit renderer is misfiled in AppDelegate (P1).
- `MenuText` value formatting and `MenuModel`'s structural contracts are clean and well pinned; the defects above are duplication and ownership, not string logic.
- The focused-canvas counts added for F6 (`AppDelegate.swift:577-582`) and the receipt consumption for F7 (`:925-937`) are live and correct on their four actions.

## Ranked shortlist (fix this week)

1. **P4** — splitter receipt + hotkey backup overwrite. Real user-visible wrong success and loss of custom splitter positions; smallest high-value fix.
2. **P1** — extract `MenuBarPresenter` / `StatusIconRenderer`, delivered as P2 then P3 first so the snapshot value is honest before it moves.
3. **P3** — put hotkey labels in the snapshot and delete `force:`. Small, makes the "single presentation model" claim true.
4. **P2** — one `MenuReads` pass, delete `hasHotkeyWarnings`, expose `hasFocusedWindow` from the controller. Small correctness/reader-load win.
5. **P5** — collapse the receipt/Feedback split and the four-field overlay into `ActionReceipt` + `NoticePresentation`; fold in P6's dead-title deletion as the free first commit.
