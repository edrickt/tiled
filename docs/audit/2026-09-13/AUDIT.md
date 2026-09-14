# Tiled codebase audit

2026-09-13. Repository at commit `8aba9cc` (`master`), 87 tracked files, ~10.5k lines of Swift source plus ~9k lines of tests, no third-party dependencies.

Eight reviewers worked read-only, one per seam, and the lead auditor re-read every High and Medium claim in the source after the mutation run restored it. Per-slice evidence lives in the eight companion reports in this directory; this file is the consolidated result.

## Verdict

No Critical findings. Seven High, eighteen Medium, and roughly thirty Low or Info-level issues. Nothing found blocks use of the app, and none of the High findings is in the geometry engine, the tiling algebra, or the Carbon/AppKit plumbing that most often sinks this class of project.

Two real problem areas stand out.

**Undo is the weakest seam.** The undo path re-enters state directly instead of going through the rules `plan` enforces, so it can produce occupancy the rest of the engine treats as impossible: two windows double-booking cells, or quarters and sixths on one canvas. Three High findings sit here, plus several Medium ones.

**The fake gateway is more forgiving than the real AX adapter, and two High findings live exactly at that boundary.** The fake's liveness is stateless and its writes are all-or-nothing; the live adapter retires a window's element on the first dead reading and can half-apply a write. The 530-test suite and the 44-mutant table both exercise the fake's semantics, which is why they are green.

## Method and ground truth

| Signal | Result |
|---|---|
| `swift build` | clean, zero warnings |
| `swift test` | 530/530 pass, 1.9s |
| Mutation testing (`tools/mutation/mutate.py`) | 44/44 mutants caught, 0 survivors, sources restored |
| Line coverage | 63.6% overall. Engine 90-97% (`Layout` 96.9, `DragTracker` 96.8, `PlanExecutor` 94.9, `TilingController` 89.6). AX adapter 18%, AppKit UI 0-68% (live-suite territory by design) |

The build and test runs are the lead auditor's. The mutation run started before the reviewers and finished while they worked; reviewers were instructed to stay static for that reason. Sources were restored by the tool's `finally` block, the worktree is clean, and every line reference below was re-read afterwards.

Reproduce the gate with `swift test`, `python3 tools/mutation/mutate.py`, and `./scripts/run-repro.sh` (the last needs a GUI session and Accessibility permission).

## High

### H1. Undo double-books cells because `commit` ignores overlap

`PlanExecutor.swift:421` commits a chapter entry straight into its old slot. `TilingState.commit` (`Layout.swift:526-531`) only clears the moving window's own previous slots; it never displaces whoever holds an overlapping one. The controller's pre-loop (`TilingController.swift:1017-1023`) only clears an occupant of the exact same slot.

Trigger: (1) A tiles `topLeft`; (2) B tiles `topLeft`, evicting A and pushing the chapter `[A → topLeft]`; (3) B self-moves to `leftHalf`, which pushes no chapter because nothing was evicted; (4) undo. `occupant(of: .topLeft)` is nil, so nothing is displaced, and A lands back in `topLeft` while B sits at `leftHalf`. Their cells intersect. A reflow-grown survivor covering a chapter's slot does the same.

Impact: the invariant the repo's own tests assert (`LayoutSwitchTests.assertHealthy`, `MatrixCrossCheckTests.assertHealthy`: no cell double-booked) fails at runtime. Windows overlap on screen, the icon and menu over-report occupancy, and the next request evicts windows the user can't see. Fix: displace every overlapping occupant during undo, or give `TilingState` a commit variant that cannot create a double-booking.

### H2. Undoing a layout switch leaves two layouts on one canvas

Same root as H1, different manifestation, and found independently by two reviewers. A switch chapter records slots from the old layout; undo replays them with no layout check anywhere. Because `activeLayout` is derived (`Layout.swift:490-492`, `occupantBySlot.keys.first`), a canvas can hold a quarters slot and a sixths slot at once, and the reported layout becomes dictionary-order arbitrary.

Trigger: A tiles `topLeft` (quarters). B requests `sixthTopLeft`, switching the canvas and pushing the chapter. C tiles `sixthBottomRight` (plain tile, no chapter). Undo untiles B and restores A into `topLeft` while C stays in sixths.

Impact: `README.md:131` says the layouts are mutually exclusive per canvas. The glyph and the menu pick a layout by hash order, and the next cross-layout request mass-untiles the stray window, so a hotkey in what the user believes is the active layout destroys the other arrangement. Fix: record the layout in the chapter and re-establish it on undo, or refuse the undo when the canvas has moved on.

### H3. Transient deaths are unrecoverable in the live adapter, yet a test pins recovery

`liveness(of:)` retires state on the first `.dead` verdict (`LiveWindowGateway.swift:227-236`): it nils `elements`, `pids`, `lastFrames`, and both handler maps. Every later call then hits the guard at `:176` and returns `.dead` without probing anything.

The controller was built for the opposite behavior. `TilingController.swift:126-130` explains that a dead reading must persist across `deathConfirmation` seconds precisely so a lid-sleep transient can recover ("the machine sleeps before a second tick can run, and on wake the probes answer again"), and `pruneDeadWindows` (`:766-780`) implements that window. With the element retired, the second tick always confirms, so the window degenerates to a fixed delay. `ControllerGatewayTests.swift:334` asserts the recovery path, but `FakeWindowGateway.liveness` is a plain set membership test with no retirement, so the suite proves a behavior production cannot deliver.

Impact: a false dead reading during a lid cycle or display teardown drops a live window from management within one to two ticks. Its slot reflows into a survivor and its pre-tile frame is lost, which makes every later "evict restores my frame" claim false for that window. Fix: keep the handle probe-able after a dead verdict and let `deadSince` own confirmation, or retire only on non-recoverable causes (`.invalidUIElement` on the app element, process gone). Then make the fake model retirement too.

### H4. A refused size write leaves the window half-moved, contradicting "left alone"

`setFrame` writes position then size (`LiveWindowGateway.swift:770-772`). If position lands and size is permanently refused, the guard at `:775-779` returns the size error and the window stays at the target's top-left at its old size. The retry policy only retries `.cannotComplete`, so a permanent refusal breaks immediately. No caller reverts the position: `PlanExecutor`'s failure paths roll back state only and report "the app refused to resize it."

Impact: `README.md:143` promises that a refusing app's window is "left alone and the menu says which app refused, so state and screen never silently disagree." Instead the window sits overlapping its neighbors while state believes it was never tiled. The same residue applies to evictee restores and reflow growth. Fix: when the size leg fails after a successful position write, write the previous origin back before reporting the refusal.

### H5. The status menu renders "Layout: Layout: …" in every state

`MenuModel.swift:162-164` builds `"Layout: \(snapshot.layoutTitle) · \(count) tiled"`, but `AppDelegate.swift:458` fills `layoutTitle` with `monitorPresentation`'s `statusLine`, which already begins with `"Layout: "` in the single-monitor case (`AppDelegate.swift:513-517`). With no tiled windows the row reads literally `Layout: Layout: Sixths · 0 tiled · 0 tiled`. With windows it reads `Layout: Built-in Retina Display · Sixths · 1 tiled · 1 tiled`.

Impact: the menu's orientation row is garbled in every state. Tests miss it because `MenuModelTests` feeds a bare `"Quarters"` and `AppDelegateMenuTests` pins `statusLine` in isolation; nothing composes the two. Fix: one owner for the composition, plus a test that feeds `monitorPresentation.statusLine` through `MenuModel.items`.

### H6. Cross-app hotkey conflicts cannot be detected, and the warning blames the wrong party

`HotkeyService.swift:268-274` registers with options `0`, not `kEventHotKeyExclusive`. The SDK contract (verified in the local `CarbonEvents.h`) is that `eventHotKeyExistsErr` is returned only for a hotkey already registered by the current process, or for an exclusive registration colliding with another exclusive one. While another app holds an exclusive registration, Tiled's non-exclusive one is "accepted as normal, but will not receive notification events."

So the README's promise at `:88` ("If a shortcut is already owned by another app, that slot shows a warning") cannot fire for the case it describes. The only reachable cause of `failedSlots` is a duplicate inside Tiled, and `MenuText.swift:43-46` tells the user "other apps own it." The four fixed-combo failure flags have the same problem: the fixed combos register first, so a slot collision always fails the slot, never the fixed combo, making their "quit and reopen Tiled" advice dead text.

Impact: a user who records a combo another app owns gets a silently dead shortcut, and a user with an in-app duplicate is sent to the wrong fix. Fix: reword the warning and the README to name the reachable cause. Real cross-app detection requires `kEventHotKeyExclusive` and is a design decision, not a wording patch.

### H7. Re-house reports success and promises undo when the requester's own placement was refused

In `PlanExecutor.swift` the re-house block at `:336-352` runs regardless of `placeResult.error`, commits the victim into its new slot, and sets the notice "moved to X to make room. Press ⌃⌥⇧⌘Z to undo." The snapshot that would create that chapter is gated two blocks later at `:369` on `placeResult.error == nil`.

Trigger: with the right third, middle third, and bottom-left sixth occupied, focus the right third and request the right two-thirds while its app refuses the write. The re-house write succeeds, so the menu shows both the refusal and the undo promise. `settle` then finds an empty chapter and pushes nothing.

Impact: pressing undo answers "Nothing to undo," or worse, unwinds an unrelated older chapter. The victim's displacement has no receipt. The comment above the block claims "the outcome never lies about what happened"; in this combination it does. Fix: gate the notice on `placeResult.error == nil`, or push the re-house move as its own chapter.

## Medium

### Undo and plan execution

**M1. Re-house misses the documented case where the requester's old cells supply the free slot.** `rehousingHome` (`Layout.swift:550-558`) unions every occupant's cells, including the requester's current slot, though the doc comment and `README.md:64-66` describe the post-request region. With left two-thirds and right sixth occupied, requesting right two-thirds gives `free = ∅`, so the right sixth is untiled even though the left third is exactly free after the move. `reflow` computes the same question differently, which shows the two answers disagree. Fix: pass the vacated slot in and exclude it.

**M2. A refused placement after successful evictions loses the evictees silently.** `applyTile` restores evictees before placing the requester (`PlanExecutor.swift:325-331`). If the placement then fails, the snapshot, reflow, and eviction notice are all gated off (`:369-380`), so the evictees pop out of their tiles with no notice and no undo chapter. Contrast `applySwap`, whose comment states the intended guarantee ("a refusal anywhere leaves every window where it started"). Fix: re-commit the evictees on placement failure, or at minimum narrate the destruction and make it undoable.

**M3. Refusal state is written to the focused canvas, not the canvas that acted.** `lastTileError` and `lastNotice` are computed properties whose setter targets `focusedSpaceKey()` (`TilingController.swift:102-104`). Untiling a window on display 2 from the manage list stores its failure on display 1 (`:913-916`), so the message can be dropped, attributed to the wrong canvas, or left stale. `lastNotice` is never assigned anywhere. Fix: pass the acting canvas into the error setter.

**M4. `untileAll` can leave a placeholder chapter that says "Restore 0 Evicted Windows."** If every `gateway.frame(of:)` read fails during the rebuild (`TilingController.swift:889-902`), every entry is skipped and the empty chapter is rewritten rather than removed, so `canUndoDisplacement` stays true with `evictedCount == 0`. Fix: drop the chapter when the rebuild yields nothing.

### Live adapter and the test seam

**M5. Three of the live suite's 40 cases cannot fail.** S7 compares mirror variables that `(TL,left)` cannot touch (falls to `default: break` in `dragEdge`'s switch, `suite.swift:381-414`). S11a is `col == col` after reading the mirror (`:536-539`). S19d compares `gridRect` mirrors for slots a left-sixth row drag cannot reach (`:646-650`). The behaviors are pinned elsewhere; the diagnostics are fictional. Fix: assert the app's own frames, not the mirror.

**M6. `mutate.py` exits 0 when mutants go STALE, INVALID, or TIMEOUT.** The score filters to CAUGHT/SURVIVED (`mutate.py:92`) and returns 1 only for survivors (`:102`). A mutant whose target line drifted is never run and reports success, which breaks the README's "can gate a release branch" claim. Fix: fail on any non-CAUGHT result.

**M7. The fake cannot express a partial write or observe write counts.** `setFrame` is all-or-nothing and keeps no call log (`FakeWindowGateway.swift:76-88`), so the H4 class is untestable through the seam, and README's "tiling into its own tile does nothing: no restore, no reassert" is asserted only on state, not on writes. `FakeGatewayFidelityTests` has one test and it exercises a hook the fake itself defines. Fix: add a two-phase write mode and a `writes` array, then pin "no-op means zero writes."

**M8. Handles are deduped by `CFEqual` on the AX element, which this same file documents as unreliable after a display teardown.** `handle(for:)` (`LiveWindowGateway.swift:585-588`) issues a second handle for a window whose fresh element no longer compares equal, producing two records and two occupied slots for one window. Fix: add a same-pid, same-last-frame fallback to the identity scan.

### Input, menu, and UI

**M9. An armed recorder survives closing its window or switching tabs, and keeps swallowing keys.** The local key monitor is removed only by `stopRecording`/`cancelSilently` (`RecorderButton.swift:59-71`, `:136-162`); no `viewDidMoveToWindow`, `resignFirstResponder`, or window-close path exists, and the button is retained by the tab. The comment at `:83` claims a focus-reset disarm that does not exist. Keys aimed at a closed window are consumed, and a ⌘-combo can be committed as a global hotkey. Found independently by two reviewers. Fix: disarm when the view leaves the window or the window closes.

**M10. Bulk Enable-all and Restore-Previous-Shortcuts write duplicates through the unchecked store path.** They call `hotkeyStore.set` (`SettingsShortcutsTab.swift:370-377`, `:648-656`) while only `apply` consults the duplicate gate. A slot parked during a bulk disable can then be claimed by an edit in another section, and enable-all stores a combo that loses Carbon registration: the tab shows it enabled, the slot is dead. Fix: route restores through the checked path and move `onHotkeysChange?()` ahead of the rebuild so the tab sees post-registration failure state.

**M11. Slots can be bound to Tiled's own fixed combos.** `duplicates(of:)` (`HotkeyBinding.swift:226-229`) compares slot bindings only, so recording ⌥⇧⏎ onto a slot succeeds, fails to register (fixed combos register first), and the menu blames "another app." Fix: add the four reserved combos to the conflict check.

**M12. "Untile N Windows" counts every canvas but untiles one.** The row uses `snapshot.tiledWindows.count`, built from `allTiledWindowsInfo()` (`AppDelegate.swift:447`, `TilingController.swift:1231-1233`), while `untileAll()` acts on `focusedSpaceKey()` (`:825-831`). With windows on two displays the count exceeds the action and the follow-up notice. Fix: count the focused canvas's windows, or title the row for its scope.

**M13. VoiceOver overstates occupancy.** The status item's description says "N of M slots occupied" using `filledCells`, which counts lit cells, so a half reads as 2 of 4 and a third as 2 of 6 (`StatusIcon.swift:43-49`, `AppDelegate.swift:331-335`). Fix: count distinct occupants, or say "cells covered."

### Multi-canvas and writes

**M14. Expand's frame writes skip the off-Space guard every other write path applies.** `pushRects`, `reflow`, and `raiseOccupants` all defer writes when `isVisible` is false; `writeExpandedFrame` (`TilingController.swift:1494-1497`) does not. If a focused window's owned canvas is not the visible Space, ⌥⇧⏎ writes an off-Space window, the exact hazard `README.md:139-141` exists to prevent. Needs a live check to confirm reachability.

**M15. A window tiled on the nil-Space fallback canvas is unreachable from the menu while keeping its slot and history.** `isVisible` returns true when the Space id is missing (`TilingController.swift:1642-1644`), but `allTiledWindowsInfo` iterates only identified canvases, so the window is absent from the manage list and Untile All, and its undo chapters can never be consumed. Fix: list the fallback canvas, or re-key it once the Space id resolves.

### Performance

**M16. One refresh resolves the focused window three times.** `menuSnapshot` reads `hasFocusedWindow`, `expandedFocusedSlot`, and `iconSnapshot`'s `focusedTilingSpace` separately (`AppDelegate.swift:463-464`, `:404-410`), each a system-wide AX element plus attribute reads, all before the diff that may discard the result. A failing liveness probe also reads two AX messages per window the app lists. Messages are capped at 1s each; the count is not capped. Fix: resolve focus once per refresh pass.

### Build and operations

**M17. `install-app.sh` destroys the installed app before it knows the replacement builds.** It pkills the running instance, `rm -rf`s `/Applications/Tiled.app` (`:22-30`), and only then runs `make-app.sh`. A compile error at that point leaves the user with no app, no running manager, and windows still tiled. The sibling script already builds before deleting. Fix: reorder.

**M18. CI never builds the release configuration or the bundle, and its hygiene is loose.** The only workflow runs `swift build --build-tests` and `swift test` on `macos-14`; `make-app.sh`'s release path, Info.plist, and codesign are never exercised. `actions/checkout@v4` is a mutable tag, no `permissions:` block exists, and the coverage step's `|| true` plus valueless `if` makes a vanished report invisible. Two more Medium-adjacent ops items: `destroy-notification-probe.swift` defaults to pressing a real app's close button or SIGKILLing a pid with no confirmation, and `install-app.sh`'s `pkill` can abort the script under `set -e` in a race.

## Low and Info

| Item | Location | Note |
|---|---|---|
| `UInt32(modifiers)` still traps on a large positive stored `Int` | `HotkeyBinding.swift:195-197` | Guard covers negatives only; same in `parkedBinding` |
| Recorder labels use US-ANSI keycaps | `HotkeyRecorder.swift:62-64` | German user records "Z", app says "Y" |
| Runtime permission revocation is never re-detected | `AppDelegate.swift:131-174` | Hotkey then reports "No focused window" |
| Carbon callback holds an unretained `Context` behind a permanent install flag | `HotkeyService.swift:129`, `:284-290` | Latent use-after-free if a second service exists |
| Observation registry keys on bare `CFHash` | `LiveWindowGateway.swift:281` | A collision silently skips registration forever |
| No baseline frame means a ghost record can never die | `LiveWindowGateway.swift:203-211`, `:275-280` | Slot never releases; only Untile All exits |
| `focus(_:)` ignores the activation result | `LiveWindowGateway.swift:548-553` | Denied activation looks like a dead menu row |
| Eviction notice drops the count for one or two names | `PlanExecutor.swift:482-503` | Two evictees, one named: reports one |
| Drag-out doesn't document its expanded-window exemption | `README.md:109-112` vs `DragTracker.swift:310-311` | Coherent behavior, missing clause |
| Trailing resize tick defers neighbor resize to the next click | `DragTracker.swift:490-497` | Unit-tested deliberately; README says mouse-up |
| Tile rects never integralized | `Layout.swift:413-424` | Needs a live check for seams on odd widths |
| Menu undo row calls every chapter an eviction | `MenuText.swift:9-11` | Says "Evicted" after a swap or switch |
| `showBinding`'s fallback teaches ⌥⇧U for quarters Top Left | `SettingsWelcomeTab.swift:84` | README `:76` repeats it; correct default is ⌥⇧⌘U |
| Permission-warning copy duplicated five times, already drifted | `SettingsGeneralTab.swift:81,188`, `ShortcutsTab:79,239`, `WelcomeTab:66` | "tiled" vs "Tiled" |
| Bulk banner reads pre-toggle registration state | `SettingsShortcutsTab.swift:399-405` | Tab disagrees with menu until reopen |
| `windowDidResize` is dead: no `NSWindowDelegate` conformance | `SettingsWindowController.swift:272` | `shortcutsTab.buildSize` staleness is harmless today |
| `expandedFocusedSlot` creates records as a side effect of a read | `TilingController.swift:975-982` | Unmanaged focused windows accumulate and get probed |
| Failed undo consumes its chapter, contrary to the section comment | `TilingController.swift:791-796` vs `:1002` | Behavior defensible; comment wrong |
| README numbers and quotes have drifted | `README.md:97,134,202-206,261,266,76,166` | 17 vs 21 hotkeys; stale notice quote; "every push"; `build/tiled.app`; extraneous "drag-out" in the live-suite claim; Tiling-rules bullet omits re-house |
| Unit suite depends on live `NSScreen.screens` in six files | `SwapTests:36`, `EvictTests:150`, `ReflowTests:302`, and others | README says "needs nothing"; `screens[index]` could trap with no display |
| Mutation table covers 8 of 25 source files; hotkey reload has no mutant or test | `tools/mutation/mutants.json` | `reload()`/`registerHotkeys()` untested end to end |
| Dead code | `TilingController.swift:1236`, `AppDelegate.swift:604-611`, `DragTracker.swift:288`, `MenuModel.swift:36`, `HotkeyBinding.swift:10` | `focusedTiledWindowsInfo`, two title helpers, single-arg `restoreDividers`, `Item.isHeader`, `isEnabled` |
| CI runner/toolchain unasserted; icon regenerated only when missing | `tests.yml:13`, `make-app.sh:13-18` | arm64 never built; stale icon can ship |
| Login-item registration survives app deletion | `install-app.sh:25`, `SettingsGeneralTab.swift:212` | Low confidence, unverified statically |

## Test suite assessment

The suite earns its reputation. Mutation score is 44/44 with no survivors, the mutators target semantics rather than syntax (undo depth, reflow tie-break, splitter crossing, death confirmation), and `mutate.py` restores sources from memory so it works on a dirty tree. Tests pin literal clamp ranges, cell sets, keycode tables, and a vacuity guard on the random sweep. `MatrixCrossCheckTests` replays the pure model against the real controller across all configurations. Timing is injected; the only real-time waits carry large margins.

The gaps are specific. Three live cases are dead (M5), the mutation tool can green-light unrun mutants (M6), and the fake's expressiveness stops short of partial writes and write counts (M7), which is precisely where the two live-adapter Highs live. The fake's fidelity elsewhere is deliberate and documented: refusals, silent ignores, clamping, unreadable frames, transient probes, busy tri-state, destroyed-versus-changed notifications, z-order, Space tables, focus semantics. That is a better fake than most projects have; it just models a kinder adapter than the one in `LiveWindowGateway.swift`.

Coverage being 18% in the AX adapter is not a defect by itself, since the live harness is the intended gate there. It matters because the adapter's *bookkeeping* (retirement, baselines, partial writes) is neither unit-tested nor visible to the live suite's assertions.

## Fix order

Batch 1, correctness in the engine and adapter. H1, H2, H7, then M1, M2, M4, M3. These share one theme (undo and failure-path gating) and should land with regressions: an undo-after-later-tile test, an undo-after-new-layout test, a refused-placement-with-rehouse test. Add M7's fake capabilities first so the new tests can express the failures.

Batch 2, the live adapter boundary. H3, H4, then M8, M14, M15. These need the lid-cycle and fixed-size-window live checks from the live-ax report before and after the change; the crash-repro instruments already exist.

Batch 3, user-visible surfaces. H5 and H6 are one-line fixes with outsized visibility. Then M9, M10, M11, M12, M13, M16. M16 pairs naturally with a memoized focus resolution while touching `menuSnapshot`.

Batch 4, gates. M17 reorders `install-app.sh`; M18 adds a release build and pins the action; M5 and M6 repair the live suite and mutation tool so they can be cited as evidence again.

Batch 5, documentation and dead code. The README corrections are cheap and load-bearing, because several findings are promises the docs made on the code's behalf. Delete the unreferenced symbols while in there.

## What holds up

The parts most likely to be wrong in a window manager are right. Cell geometry derives from a single `SlotGeometry` declaration, so cells, overlap, and rects cannot disagree; flushness between neighbors comes from one shared expression on both sides. Reflow's "one merge per pass" is provable from `freed ⊆ grown.cells`. The plan algebra matches CONTEXT.md rule for rule, including swap's disjointness condition and the requester-never-evicts-itself rule. Drag decisions (100pt threshold, two-tick requirement, snap-back versus drop, echo suppression, expand exemption) are internally consistent.

CoreFoundation ownership on every AX path is correct, with no manual `CFRelease` and the two `takeRetainedValue` calls in the right places. Observer teardown removes the runloop source before dropping the observer. Every controller closure captures weakly, every non-Cocoa entry point hops to main, and focus is treated as a request rather than a guarantee. The shell scripts use `set -euo pipefail`, quote every expansion, create no temp files, and scope their kills. No secrets, no committed build products beyond the intended icon.

The documentation is unusually honest: all 21 documented hotkeys match the registered bindings, the 530-test and 40-case counts are exact, and CONTEXT.md's vocabulary matches the code with no drift.

## Limits of this audit

Everything here is static reading plus the lead's build, test, mutation, and coverage runs. Four items need hardware or a GUI session to confirm or refute: H3's lid-cycle trigger, H4's fixed-size-app refusal, H6's environment-dependent conflict behavior, and the engine's pixel-seam risk. The multi-display and Mission Control corners are covered by a manual checklist that was not executed. Reviewers could not run the app, so UI findings rest on source reading; the live recorder symptoms (M9) depend on AppKit event ordering that only runtime shows. The mutation run overlapped the review window, but sources were restored before the lead's verification pass, and every High and Medium line reference was re-read after that.

## Companion reports

1. `01-engine.md`: pure geometry, tiling algebra, drag tracker
2. `02-controller.md`: controller state machine and plan execution
3. `03-live-ax.md`: AX, window server, Spaces, displays
4. `04-app-shell.md`: app lifecycle, hotkeys, permissions, settings persistence
5. `05-settings-ui.md`: menu model, settings surfaces, previews
6. `06-tests.md`: test quality, fake fidelity, mutation coverage
7. `07-security-ops.md`: scripts, packaging, CI, secrets
8. `08-docs-claims.md`: README/CONTEXT truth, dead code
