# Slice 03 — input and launch: DragTracker, hotkeys, AppLaunchPlan

Scope: `DragTracker`, `HotkeyService`, `HotkeyBinding`, `HotkeyAction`,
`HotkeyActionRouter`, `HotkeyRecorder`, `AppLaunchPlan`; `AppDelegate` only
where it wires them. Base `47dea76`; read-only (no build, tests, or live run).
Prior reports: `.scratch/quality-audit/report.md` and `-followup/report.md`.
Slices 02/04 already own the splitter-receipt and dead-title findings.

## Open-finding cross-check

| ID | Status | Current evidence |
|---|---|---|
| F23 absorption past the translation margin | **STILL PRESENT** | The size gate returns before any shape test (`DragTracker.swift:499-504`); the residual is still documented at `:496-498`; `translationMargin` is 8 at `:190`. |
| F24 one pending reassert per canvas | **STILL PRESENT** | `pendingReasserts: [TilingSpaceKey?: WindowID]` (`:151`) is overwritten per canvas (`:667`); the drain reads only the values (`:712-725`). |
| F28 Carbon callback body runs only live | **STILL PRESENT** | Callback parse/resolve/hop at `HotkeyService.swift:280-298`; the installer is stubbed in every registration test (`HotkeyRegistrationTests.swift:26-31`). |
| F29 shared handler outlives service teardown | **STILL PRESENT** | Handler lives on `sharedContext` (`HotkeyService.swift:170-203`); deinit retires only registrations (`:222-240`); no clear path. `AppDelegate.swift:180` captures weakly, so the worst case is a dropped fire. |
| T4 / ticket 16 one hotkey route | **FIXED** | `actionByID` derives from `HotkeyAction.allCases` (`HotkeyService.swift:163-164`); `route` reads it (`:166-168`); the callback consumes it (`:293`). No second table exists. |

## Drag-state model verdict

The pending-reassert container is the wrong shape: its canvas key is never read,
so the map only suppresses a second window's pending reconcile (F24). A
`Set<WindowID>` is smaller and correct (S1).

The echo/drag maps (`lastKnownFrames`, `expectedFrames`, `settleOverrides`,
`drags`) are **not** worth merging this week. Their lifetimes deliberately
differ: `markExpected` drops a stale drag but keeps a settle override;
`seedBaseline` seeds without arming an echo. A `WindowRecord` would move field
access around without deleting branches. The echo half is A1's `ExpectedWrites`
module (slice 02); the local wins are the Minor list.

## Findings

### S1. The pending reassert is a canvas-keyed map that only ever needs a window set
**Evidence.** `pendingReasserts: [TilingSpaceKey?: WindowID]` (`DragTracker.swift:151`); every edge movement overwrites the canvas's entry (`:661-668`); `mouseLifted` drains `pending.values` and never reads the canvas (`:712-725`); `clearPendingReassert` filters by value (`:284-286`); `forget` (`:340-345`) and `markExpected` (`:265-270`) do not clear pending entries.
**Cost.** The key advertises a per-canvas invariant the drain does not use. Two windows on one canvas overwrite each other, so the first window's achieved-frame clamp is never reconciled (F24). Stale entries survive both a forget and a superseding write.
**Code-judo.** Make it `Set<WindowID>`: insert on movement, drain in sorted order, `remove` in `clearPendingReassert`, `forget`, and `markExpected` (a landed write ends the gesture as it already ends a drag). The canvas key type disappears. Pin two windows' trailing ticks on one canvas.
**mechanical** · confidence **high** · effort **S**

### S2. The process-wide Carbon event router is static state inside a per-service object
**Evidence.** `Context`/`sharedContext` (`HotkeyService.swift:170-172,187-188`), `handlerInstalled` (`:188`), the forwarding `handler` (`:200-203`), install from service init (`:212-217,266-278`), the callback (`:280-298`), and deinit retiring registrations only (`:222-240`). `AppDelegate.swift:176-184` owns the handler.
**Cost.** A replaceable service is fused to a process-wide handler. Nothing enforces or clears the ownership the comment claims, which is F29. The callback's parse, route, and main hop sit behind a stubbed installer, so they are unobservable, which is F28. A reader must reason about `userData` lifetime to trust either.
**Code-judo.** Extract `CarbonHotkeyEventRouter` (own file): `static let shared`, install-once `init`, `var handler`, `handleEvent(_:)` for the parse, and `dispatch(hotKeyID:deliver:)` for resolve-and-hop. `HotkeyService` keeps registration and calls `router.clearHandler(ifOwner: self)` on deinit; delete `Context`, `handlerInstalled`, the forwarding property, and the static callback. Tests drive `dispatch` hermetically and may synthesize an event for the parse.
**design** · confidence **high** · effort **M**

### S3. Tick classification is a magnitude-ordered if-ladder; F23 is its precedence bug
**Evidence.** Size-dominance returns first (`DragTracker.swift:499-504`), then `clearGrab` (`:513-516`), `clearTranslation` with an absolute 8pt similarity bound (`:518-521`), `originMovedMoreThanSize` (`:528-530,540-544`), and a final resize (`:534-535`). `edgeMoveThreshold` 1 and `translationMargin` 8 (`:186-190`) carry both the shape and noise policy.
**Cost.** The core move-vs-resize decision is a five-branch truth table encoded by statement order. The residual at `:496-498` is the size gate winning over translation shape, so absorption larger than the margin yanks a splitter on the first hand tick (F23). Reordering alone is unsafe: a genuine grab with 2pt opposite-edge drift (20/2 travel) would then read as a move.
**Code-judo.** One pure `TickShape` classifier per axis, using a noise bound and a dominance ratio: one edge over noise and the opposite within it = grab; both over noise in opposite directions or with one edge dominating = resize; both comparable and same direction = translation. Aggregate any grab/resize to resize, else any translation to move. Delete `sizeDelta`, `clearGrab`, `clearTranslation`, and `originMovedMoreThanSize`. Pin the absorbed translation (100/50), the drifty grab (20/2), the clean grab (20/0), and the opposing-edge resize.
**design** · confidence **medium-high** · effort **M**

### S4. A hotkey takes a protocol, a router, and a performer to reach one switch
**Evidence.** `HotkeyActionPerformer` has six methods (`HotkeyActionRouter.swift:4-11`); `dispatch` switches to one (`:16-29`); `AppHotkeyPerformer` implements six one-line forwards (`:34-74`); `AppDelegate.swift:13-17,180-183` constructs both; the route test needs a six-method fake (`HotkeyActionRouterTests.swift:11-29`).
**Cost.** "What does ⌥⇧R do?" takes handler → router → protocol → performer → controller: four hops across three files. The protocol exists only to fake the switch; a new action edits the protocol, router arm, performer, and fake.
**Code-judo.** One closure-backed `HotkeyActionRouter` (tile/expand/evict/settings/undo/reset closures) with the same switch. `AppDelegate` builds it from the controller/delegate; delete the protocol and `AppHotkeyPerformer`. Tests use recording closures; live forwarding is now the closures themselves.
**mechanical** · confidence **medium-high** · effort **S**

### S5. `HotkeyAction.allCases` is the totality witness, but it is hand-maintained
**Evidence.** The list is declared by hand (`HotkeyAction.swift:21-25`); registration iterates it (`HotkeyService.swift:245`); `actionByID` derives from it (`:163-164`); the Shortcuts tab iterates it (`SettingsShortcutsTab.swift:178,747,765`); the uniqueness test only checks the list it was handed (`HotkeyServiceTests.swift:22-27`).
**Cost.** A new case forces every exhaustive switch to compile, but omission from `allCases` compiles cleanly and silently removes the action from registration, the menu, Settings, and the route map. The comment at `HotkeyService.swift:158-162` claims an action cannot be in one map and absent from another; membership is the hole.
**Code-judo.** Nested `enum AppAction: CaseIterable` for the five app cases; `appActions = AppAction.allCases.map(HotkeyAction.init)`; the `init` switch is exhaustive, so membership is compiler-checked. The hand list disappears.
**mechanical** · confidence **high** · effort **S**

### S6. Factory default keymaps live in the Carbon service, split across three owners
**Evidence.** Slot defaults are an extension in `HotkeyService.swift:65-95`; app ids and five modifier/keyCode/binding triples are at `:106-156`; `HotkeyAction.defaultBinding` switches to them (`HotkeyAction.swift:61-70`); slots detour through `HotkeyStore.defaultBinding` (`HotkeyBinding.swift:190-197`), which persistence reads (`:199-213`).
**Cost.** "What is Expand's default combo?" crosses model → store → service. Ten modifier/keyCode constants exist only to build five bindings and serve as test oracles; slot key policy sits in the registration adapter, and a new action's default has no single home.
**Code-judo.** One `HotkeyDefaults` table beside the binding model (or `HotkeyBinding.default(for:)`); `HotkeyAction.defaultBinding` reads it; `HotkeyService` keeps only Carbon ids and registration. Delete the redundant constants and assert the binding/label.
**design** · confidence **medium-high** · effort **S**

### S7. The recorder splits one key policy across two functions, with `nil` meaning two things
**Evidence.** `shouldPassThrough` (`HotkeyRecorder.swift:36-48`) and `outcome` (`:50-65`) each switch on keycodes; `RecorderButton.routeRecordedEvent` calls both and reads `outcome == nil` as "swallow and stay armed" only after the pass-through check (`RecorderButton.swift:118-134`). The modifier set is raw keycodes 54-63 (`HotkeyRecorder.swift:21-27`).
**Cost.** To know whether a key is swallowed, a reader must run both functions and know the order; `nil` means "keep recording" in one context and would mean "pass through" in another. Navigation-key knowledge is split across two lists.
**Code-judo.** One `Decision` enum (`.passThrough`, `.keepRecording`, `.clear`, `.cancel`, `.binding`) from one `decision(for:)`; `RecorderButton` switches once; name the modifier keycodes with Carbon constants.
**mechanical** · confidence **medium-high** · effort **S**

## Minor, same files

- `clearDrag` precedes every `processResize` call (`DragTracker.swift:501,524,534`); put the invariant at `processResize`'s entry (`:621`).
- The settle-override detection is written twice with the same log and `.snapback` (`:364-374`, `:453-466`); one helper.
- `handPressPoint` + `handPressAt` are one optional `HandPress` (`:139-140,558-561,689-701,713-714`).
- The tracker's legacy nil-canvas mode (`spaceOf` default nil `:89`, optional keys `:49-55`, `occupiedSlots` fallback `:674-679`) is unreachable in production (`TilingController.swift:59-60`); make the key non-optional (the `occupants()` half is slice 02's minor).
- `grid(for:)` (`DragTracker.swift:103-105`) is a one-caller accessor over `gridProvider.grid` (only use `:652`); inline it.
- `HotkeyService.route` (`:166-168`) is a one-line read; keep it only as the extracted router's named entry point (S2).

## AppLaunchPlan verdict

No structural finding. `showsWelcome`/`showsSettings` are two Bools, but `make` is the only initializer and all eight input rows are pinned; a sum type would rename the two `if`s, not delete them. `AppStartCompletion` is a second moment in the flow, not a second state machine. The shared `!didDismissWelcome` predicate is too small to justify a state type.

## Ranked shortlist this week

1. **S1** — per-window pending set; closes F24 and deletes a key that was never read.
2. **S2** — extract `CarbonHotkeyEventRouter`; closes F28 and F29 together.
3. **S3** — one `TickShape` classifier; closes F23 by rule instead of bounding the residual. Land with the absorption tests.
4. **S5** — nested `CaseIterable` app actions; makes the "cannot vanish from a layer" claim true.
5. **S4** — collapse router/protocol/performer; fold into the S2 hotkey commit.

S6/S7 are cheap follow-ups in the same hotkey files; the Minor list can ride any `DragTracker` commit.

## Verified solid

- `DragTracker` decides only: no rect math, no writes, one `DragDecision` enum, one coordinator switch (`TilingController.swift:1156-1168`). Echo suppression, convergence, and hand-press gating are pinned.
- The registrar seam is clean: `OSStatus` plus an opaque token, with disabled-skip/failure/reload/teardown hermetic (`HotkeyService.swift:21-63,242-264`).
- `actionByID` is one derived mapping consumed by production and tests; T4 is genuinely fixed.
- `HotkeyStore`'s duplicate gate, disabled encoding, and park/restore rules are well pinned; `HotkeyBinding.label` covers arrows (F16 fixed).
- `AppLaunchPlan` is pure and total; its truth table and `execute` test are literal.
