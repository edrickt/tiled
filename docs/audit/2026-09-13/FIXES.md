# Audit fixes

2026-09-13. Status of the 7 High and 18 Medium findings from `AUDIT.md`. Every fix has a regression test except where noted (live-AX-only policy that cannot execute without Accessibility, or ops files). Test suite went from 530 to 550 tests, all green; mutation table re-run after the changes.

## High

**H1. Undo double-books cells.** `undoLastDisplacement` now displaces every current occupant whose slot overlaps a chapter entry's slot, not just an exact-slot occupant (`TilingController.swift`, undo pre-loop). `Layout.commit` stays permissive because plan execution removes occupants first. Tests: `testUndoDisplacesAnOverlappingWindowInsteadOfDoubleBookingCells` (asserts no cell is double-booked, the overlapping window is restored to its pre-tile frame, and the requester is released).

**H2. Undo of a layout switch left two layouts on one canvas.** The same pre-loop now also displaces occupants whose slot belongs to the layout being restored into, so undo re-establishes the chapter's layout. Test: `testUndoOfLayoutSwitchDisplacesTheOtherLayoutsOccupants` (asserts `activeLayout` is the restored one and the abandoned layout's window yielded).

**H3. Transient deaths were unrecoverable.** `liveness(of:)` no longer retires the element, handlers, and baseline on the first `.dead` verdict; it returns the verdict and lets the controller's `deathConfirmation` window own death. Cleanup moved to a new `WindowGateway.release(_:)`, implemented by the live adapter (element, pid, handlers, baseline, observation key, shared observer when the pid's last handle goes) and called by the controller only on confirmed death or an OS destroy report. A window that may return through undo keeps its element. Tests: `testTransientDeadReadingRecoversBeforeTheConfirmationWindow`, `testConfirmedDeathReleasesTheHandleButUntileDoesNot`, `testDestroyNotificationReleasesTheHandle`; the fake gained a `releaseCalls` log.

**H4. A refused size write left the window half-moved.** `LiveWindowGateway.setFrame` records the window's origin before writing, tracks whether a position write landed across retries, and writes the origin back when the pair fails (`AXWrite.needsPositionRestore` is the pure policy). Test: `testPartialWritePolicyRestoresTheLandedOrigin`; the fake gained `refuseSizeWrites` plus a write log so the partial-write shape is expressible at all.

**H5. "Layout: Layout: …".** `MenuModel` renders `snapshot.layoutTitle` verbatim; `AppDelegate`'s status line already carries the prefix and count. `MenuModelTests` updated; the composition is now the delegate's alone.

**H6. Cross-app hotkey conflicts cannot be detected.** The README, the menu warning, and the summary row no longer claim another app is detected or blamed. The wording now says a combo failed to register and names the one attribution that is possible ("another Tiled shortcut or a system shortcut"). `MenuTextTests` updated. Real cross-app detection would require `kEventHotKeyExclusive` and is left as a separate design decision.

**H7. Re-house promised an undo with no chapter.** The re-house move now runs only when the requester's placement landed cleanly; when it did not, the victim is restored to its pre-tile frame like any evictee. The eviction chapter and notice are pushed whenever restores succeeded, even if the requester was refused, so the destruction is narrated and undoable. Test: `testRefusedPlacementWithReHouseDoesNotMoveTheVictim`.

## Medium

**M1. Re-house used the pre-request free region.** `rehousingHome` takes the requester's vacated slot and excludes it from the occupied set (`Layout.swift`); `PlanExecutor` passes it, and `MatrixCrossCheckTests`' pure model does too. Test: `testReHouseUsesTheRegionTheRequestActuallyLeavesFree`.

**M2. Refused placement after evictions was silent.** The snapshot/notice push is now gated only on restore success; the requester joins the chapter only when it landed. Test: `testRefusedPlacementAfterEvictionsKeepsTheDestructionUndoable`.

**M3. Refusals landed on the focused canvas.** New `setTileError(_:on:)` and `reportRestoreFailures(_:on:)`; `pushRects` counts failures per canvas and every call site passes the canvas that acted. `lastNotice`/`lastTileError` are read-only views now. Test: `testRefusalLandsOnTheActingCanvasNotTheFocusedOne`.

**M4. Empty untile-all chapter.** A chapter that could not be rebuilt from live frames is popped and its notice drops the undo offer. Test: `testUntileAllDropsAChapterItCouldNotRebuild`.

**M5. Three live-suite cases could not fail.** S7 now verifies the app's frames against the pre-drag splitters after the re-assert (the mirror-only check is gone); S11a verifies the app's frame snapped back after the re-assert; S19d compares the actual middle and right sixth frames before and after the row drag. Case count stays 40.

**M6. `mutate.py` exited 0 on unrun mutants.** STALE, INVALID, and TIMEOUT results now print in a dedicated block and fail the run. Verified by the post-fix mutation run below.

**M7. The fake could not express partial writes or write counts.** `FakeWindowGateway` gained `refuseSizeWrites` (origin moves, call fails), a `writes` log, and `clearWrites()`. Tests: `testPartialSizeRefusalLeavesNoCommittedState`, `testRetilingOwnSlotIssuesNoFrameWrite`.

**M8. `CFEqual` identity gaps.** `handle(for:pid:)` falls back to same-pid, same-last-frame matching and adopts the app's fresh element, so a window that stops comparing equal does not get a second handle and destroy notifications route again.

**M9. Armed recorder survived close and tab switches.** `RecorderButton` disarms when it leaves its window and observes `NSWindow.willCloseNotification`; observer removal happens in `deinit`. The stale `resignFirstResponder` comment was corrected.

**M10. Bulk restores bypassed the duplicate gate.** Enable-all goes through `HotkeyStore.apply`, keeps the park when the combo was claimed elsewhere, and reports the clash; `onHotkeysChange` (registration) now runs before the rebuild so the fresh rows read post-registration state. Reset-restore skips fixed combos and does the same. Test: `testEnableAllKeepsDisabledWhenTheParkedComboWasClaimed`.

**M11. Slots could take Tiled's own fixed combos.** `HotkeyStore.apply` refuses the four reserved combos with a new `.reserved(name:)` result; the recorder and bulk paths report it. Test: `testApplyRejectsFixedShortcutCombos`.

**M12. "Untile N Windows" counted every canvas.** `Snapshot.untileCount` comes from `focusedTiledWindowsInfo` (the accessor was dead code before), and the row uses it. Test: `testUntileAllTitleCountsTheFocusedCanvasOnly`.

**M13. VoiceOver overstated occupancy.** `StatusIcon.Snapshot.occupiedSlots` counts distinct windows, and `StatusIcon.accessibilityDescription` is the single spoken-line builder. Test: `testAccessibilityDescriptionCountsWindowsNotCells`.

**M14. Expand skipped the off-Space guard.** `writeExpandedFrame` defers an off-Space write like every other path, leaving the expansion out of state. Test: `testExpandDefersAnOffSpaceWindowInsteadOfWritingIt`.

**M15. Withheld-Space canvases became unreachable.** `actionSpaceKey(for:)` resolves the focused canvas to the display's nil-Space canvas while the identified one holds nothing; `allTiledWindowsInfo` lists withheld canvases; `activeSpaceKeys` reasserts them. Tests: `testWindowTiledWhileTheSpaceWasWithheldStaysReachable`, `testUndoReachesChaptersPushedWhileTheSpaceWasWithheld`.

**M16. One refresh resolved the focused window three times.** `LiveWindowGateway.focusedWindow()` memoizes for 50 ms; the focus observer clears it. No unit test (AX-only), but the menu build now performs one resolution instead of three.

**M17. `install-app.sh` deleted the installed app before building.** Build moved first, `pkill` calls are `|| true`-guarded, and the header says why.

**M18. CI never built the release bundle, and ops hygiene.** Workflow: `permissions: contents: read`, a concurrency group, `actions/checkout` pinned to the v4.2.2 commit, a release build step, an app-bundle step (`make-app.sh` + `codesign --verify` + `plutil -lint`), and a coverage step that logs the instrumented run and warns instead of hiding a missing profile. `destroy-notification-probe.swift` now requires an explicit `close|kill` mode and prints the target app before acting.

## Verification

| Evidence | Result |
|---|---|
| `swift build` | clean, no warnings |
| `swift test` | 550/550 pass |
| `python3 tools/mutation/mutate.py` | re-run after the changes; see `build/mutation-results.json` |
| `bash -n scripts/*.sh`, `swiftc -parse tools/repro/*.swift` | clean |
| `git diff --stat` | 26 files, +694/−159 |

## Still open from the audit (Low / Info)

The Low and Info table in `AUDIT.md` is untouched: US-ANSI keycap labels, runtime permission revocation, the unretained Carbon context, `CFHash` registry keys without an element check, no-baseline ghost windows, activation result ignored in `focus`, eviction-notice naming for one-of-two, drag-out documentation gaps, trailing-tick resize deferral, un-integralized tile rects, undo-row wording, Welcome fallback combo, duplicated permission copy, bulk banner timing (now mostly fixed by the ordering change), the dead `windowDidResize`, `expandedFocusedSlot` record side effect, failed-undo comment, remaining README drift, NSScreen-dependent unit tests, mutation-table breadth, and dead code (`isHeader`, single-arg `restoreDividers` — `focusedTiledWindowsInfo` and the `AppDelegate` title helpers are now referenced or still dead as noted).

Live checks still needed for H3's lid-cycle trigger, H4's fixed-size-app refusal, and the engine's pixel-seam question. The live repro suite and mutation run are the pre-release gates; the live suite was not executed here (no GUI session).
