# Test-suite quality and mutation coverage - audit findings

## Summary
The unit suite is unusually rigorous for its size: injectable clock/scheduler/screen seams, literal pins for every clamp/cell/hotkey table, a pure-plan-vs-real-controller cross-check, and 44/44 mutants caught (`build/mutation-results.json`, `build/mutation-full2.log`) — I found no Critical or High defect in the tests. The gaps are concentrated in three places: three of the live suite's 40 cases are structurally incapable of failing (S7, S11a, S19d), `mutate.py` exits 0 when its mutants go STALE/TIMEOUT, and the fake gateway cannot express or observe write-level facts (partial writes, write counts), so nothing pins "a no-op request issues no write" or the display half of the canvas-ownership rule. Verdict: **OK with notes** — nothing here blocks a merge, but F1/F2/F3 should be fixed before the mutation table or the live suite is cited as release evidence again.

## Findings

### F1 - Three of the live suite's 40 cases cannot fail [Medium | High | test-gap]
- Location: `tools/repro/suite.swift:499-505` (S7), `tools/repro/suite.swift:536-541` (S11a), `tools/repro/suite.swift:646-653` (S19d)
- Evidence:
```swift
// S7 (499-505): both drags fall into dragEdge's `default: break`, so col/row
let colSaved = col, rowLSaved = rowL, rowRSaved = rowR
dragEdge("HOSTA", "left", 40)
dragEdge("HOSTB", "bottom", -40)
if col == colSaved && rowL == rowLSaved && rowR == rowRSaved {
// S11a (536-539): colMoved is read AFTER simulateMove, nothing between
simulateMove("HOSTA", by: CGSize(width: 60, height: 40))
let colMoved = col, rowLMoved = rowL, rowRMoved = rowR
if col == colMoved && rowL == rowLMoved && rowR == rowRMoved {
// S19d (646-650): dragEdge("HOSTA","bottom") can only touch sixthsRowL
let midsBefore = gridRect("sixthTopMiddle"), rightBefore = gridRect("sixthTopRight")
dragEdge("HOSTA", "bottom", -60)
if close(midAfter, midsBefore) && close(gridRect("sixthTopRight"), rightBefore) {
```
- Trigger: run `./scripts/run-repro.sh`. `verify()` is the only thing that reads the app's windows; these three cases only re-compare the suite's own mirror variables (`col`, `rowL`, `rowR`, `gridRect`) to values the mirror itself cannot change for those (slot, edge) pairs (`dragEdge`'s switch at `suite.swift:381-414` has no case for `(TL,left)` / `(BL,bottom)`, and only `sixthsRowL` for `(sixthTopLeft,bottom)`). S11a is literally `col == col`.
- Impact: the README claim "40 cases covering ... screen edges ... per-third row independence" (`README.md:202-207`) overstates the gate: 3 of the 40 pass/fail contributions are unconditional. The behaviours they name are pinned elsewhere (screen-edge inertness: `GridLayoutTests`, `DragTrackerTests`; title-bar inertness: `DragTrackerTests:232`; per-third independence: S19c's `verify` at `suite.swift:648`), so detection power is not lost — only the diagnostic value of the two claims is fictional.
- Fix: make each case read the app: for S7/S11a assert the dragged window's own frame is still its mirror rect after the inert drag (`verify("S7b ...")` style) instead of comparing the mirror to itself; for S19d assert the *app's* middle/right sixth frames against `gridRect` before and after the drag (i.e. fold it into S19c's `verify`). Invariant pinned: "a screen-edge drag and a title-bar move leave every splitter and every window frame unchanged."

### F2 - `mutate.py` reports success when mutants are STALE, TIMEOUT, or INVALID [Medium | High | code-defect]
- Location: `tools/mutation/mutate.py:66-70`, `:79`, `:83`, `:92-95`, `:102`
- Evidence:
```python
        if source.count(old) != 1:
            status = f"STALE(find x{source.count(old)})"       # 66-67
            results.append(dict(path=path, label=label, status=status))
            continue
...
    scored = [r for r in results if r["status"] in ("CAUGHT", "SURVIVED")]   # 92
    print(f"\nMutation score: {caught}/{len(scored)} valid mutants caught")   # 95
    return 1 if survivors else 0                                             # 102
```
- Trigger: edit a line any mutant targets (reformat, rename a symbol, move code) so its `old` snippet no longer occurs exactly once, then run `python3 tools/mutation/mutate.py`. It prints `STALE(find x0)`, scores `0/0 valid mutants caught`, and exits **0**. Same for `TIMEOUT` (`:83`) and `INVALID(compile)` (`:79`).
- Impact: the README sells this as a release gate — "It exits non-zero on any survivor, so it can gate a release branch" (`README.md:257-258`). An un-run mutant is not a survivor, so a whole class of "the suite was never asked this question" outcomes passes the gate silently; a mutant that hangs the suite is reported as success. The per-mutant lines are printed, but the score line and the exit code both say green.
- Fix: treat every non-`CAUGHT`/non-`SURVIVED` result as a failure: `return 1 if any(r["status"] != "CAUGHT" for r in results) else 0`, and include STALE/INVALID/TIMEOUT counts in the score line. Invariant pinned: "every mutant is either run-and-caught or the tool fails."

### F3 - The fake cannot express a partial write, so no test pins what a half-applied `setFrame` does [Medium | High | test-gap]
- Location: `Tests/tiledTests/FakeWindowGateway.swift:76-88` vs `Sources/tiled/LiveWindowGateway.swift:766-780`
- Evidence:
```swift
    func setFrame(_ handle: WindowHandle, to frame: CGRect) -> Bool {
        guard var window = windows[handle], window.alive else { return false }
        if silentIgnore.contains(handle) { return true }
        if window.refuseNextWrites > 0 { ...; return false }     // all-or-nothing
        window.frame = writtenFrame(handle, frame)
// Live, the same call is two writes that can part-apply:
        // so a retry after a partial application (position landed, size hit
        // a busy app) just rewrites both, never a half-moved window.    (766-767)
            let positionResult = AXUIElementSetAttributeValue(... kAXPosition ...)  // 770
            let sizeResult = AXUIElementSetAttributeValue(... kAXSize ...)          // 772
            guard positionResult == .success, sizeResult == .success else {
                lastError = positionResult == .success ? sizeResult : positionResult // 777
                return lastError
```
- Trigger: an app that accepts `kAXPosition` and rejects `kAXSize` (a fixed-size/refusing app). Live: the window moves, `setFrame` returns `false`. Fake: the possibility is not representable — `writtenFrame` runs only on the success path, `refuseNextWrites` changes nothing. `FakeGatewayFidelityTests` contains exactly one test (`:31`), and it exercises `writtenFrame` (a hook the fake itself defines), not a live-vs-fake divergence; its own class comment promises "Each pins the contract the fake's convenient defaults used to shield" (plural, but there is one).
- Impact: the entire class "state rolled back, window actually (half-)moved" — the exact shape the README says must never happen silently ("state and screen never silently disagree", `README.md:161-163`) — is untestable via the seam. Rollback correctness for a partially applied write (does the executor restore the requester? the evictee? the re-pushed neighbor?) is asserted only for writes that never landed.
- Fix: give the fake the live adapter's two-phase shape, e.g. `var partialWrite: (WindowHandle, CGRect) -> CGRect?` that applies an origin-only frame and returns `false`, then pin: an app that refuses the size write still ends with the requester's pre-tile frame restored and its slot released/labelled refused. Invariant pinned: "a refused `setFrame` leaves the window either untouched or fully restored, never half-moved with state committed."

### F4 - No test pins the display half of the canvas-ownership rule [Low | Medium | test-gap]
- Location: `Sources/tiled/TilingController.swift:71-75`, `:1599-1606`; closest tests `Tests/tiledTests/PerMonitorTests.swift:386`, `Tests/tiledTests/LidSleepWakeTests.swift:120`
- Evidence:
```swift
    /// Window -> owning tiling canvas. Set when a window tiles (and when
    /// undo reissues ids); cleared on forget. A tiled window never
    /// migrates mid-session: its canvas wins over geometry, so dragging
    /// it across displays keeps its slot until untiled.
    private var spaceOwnership: [WindowID: TilingSpaceKey] = [:]
```
- Trigger: `spaceOf(window:)` returning a canvas resolved from the window's current frame instead of `spaceOwnership[id]`, for the display dimension. Every cross-display move in the suite is either on the two canvases' own displays (`PerMonitorTests:386` `testEvictionNeverCrossesMonitors`, `:260`) or asserted only for occupancy, not ownership (`LidSleepWakeTests:137-138` moves a window onto the external display, then asserts only `occupant(of: .topLeft, on: builtIn.id)`).
- Impact: a regression that adopts a tiled window into the canvas of the display it was dragged onto (or that lets a reflow/push resolve the wrong canvas) survives the whole unit suite. The Space half of the same rule *is* pinned (`SpaceIndependenceTests:296` would fail, since a geometry-resolved canvas would make the off-Space write visible).
- Fix: add to `PerMonitorTests` — tile on the left display, `gateway.simulateChange(handle, to: <frame on the right display>)`, then assert `controller.state(on: leftID).slot(of: id) == .topLeft` and that the right canvas's occupancy is unchanged; a mutant that resolves ownership from geometry then dies. Invariant pinned: "a window belongs to one canvas; its owning canvas wins over its geometry."

### F5 - `testScreenChangeReassertsLayout` passes whether or not the re-assert happens [Low | High | test-gap]
- Location: `Tests/tiledTests/ControllerBulkOperationTests.swift:648-672`
- Evidence:
```swift
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        wait(for: [reasserted], timeout: 1.0)
        XCTAssertEqual(
            gateway.frame(of: a), expectedRect(.topLeft, for: a),
            "windows stay on-grid after a display change")
```
- Trigger: delete the controller's screen observer. The test's screens are the host's real `NSScreen.screens` (unchanged by the test; the controller at `:22` is built without `screens:`), and `expectedRect` (`:47-52`) recomputes the very rect the placement already wrote with the same `controller.grid`, so the assertion holds for a controller with no display-change handling at all.
- Impact: a dead case, not a hole — the invariant is genuinely pinned one file over by `LidSleepWakeTests:92` (`testTilesSurviveLidCloseWithSystemRescale` first silently moves the window off-grid, so only a display-change write can restore it).
- Fix: inject a mutable screen provider (`LidSleepWakeTests`/`SpaceIndependenceTests` pattern), change the resolution, post, and assert the frame moved to the rect under the new visible frame — or delete this test as a duplicate. Invariant pinned: "a display change re-asserts a visible canvas immediately."

### F6 - The fake's documented "activation ignored" mode has no test [Low | High | test-gap]
- Location: `Tests/tiledTests/FakeWindowGateway.swift:34-35` (declaration), `:147-150` (only use); no assignment anywhere in `Tests/`
- Evidence:
```swift
    /// Whether `focus` makes `focusedWindow` return the focused handle.
    /// The real adapter only requests activation: the system may ignore
    /// it, and the next focus query answers with whatever actually has
    /// focus. Off, focus requests are recorded but the environment keeps
    /// its own focus (the fidelity mode for that divergence).
    var focusChangesFocused = true
```
- Trigger: an app that ignores `NSRunningApplication.activate()`. `TilingController.settle` fires `gateway.focus(record.handle)` unconditionally after a swap (`TilingController.swift:433-437`) and never reads back; `SwapTests` asserts only `gateway.focusCalls`. Nothing sets `focusChangesFocused = false`, so the divergence the fake was built for is unexercised.
- Impact: the untested real-world path is "swap completes, activation is ignored, so the next hotkey tiles the previously focused window". That may be the intended best-effort behaviour, but no test states it (e.g. no notice/feedback, no read-back).
- Fix: one test with `gateway.focusChangesFocused = false` around a swap, asserting the documented outcome (requester/displaced slots correct, focus stays where the environment kept it, and the next `handle(slot:)` acts on the requester that `focusedWindow()` reports). Invariant pinned: "focus is a request; layout correctness never depends on it landing."

### F7 - "no AX, no runloop / needs nothing" overstates the unit suite's hermeticity [Low | Medium | doc-gap]
- Location: `README.md:193`, `:198-199`; `Tests/tiledTests/SwapTests.swift:36-38`, `EvictTests.swift:150-152`, `ReflowTests.swift:302-304`, `ControllerBulkOperationTests.swift:49-51`, `ExpandToggleTests.swift:29-31`, `ControllerGatewayTests.swift:175-177` (plus controllers without `screens:` at `SwapTests:16`, `EvictTests:20`, `ReflowTests:21`, `ControllerBulkOperationTests:22`, `ExpandToggleTests:21`, `MatrixCrossCheckTests:102`)
- Evidence:
```swift
        let screens = NSScreen.screens
        let index = TilingController.owningScreenIndex(frames: screens.map(\.frame), for: frame) ?? 0
        return controller.grid.rect(for: slot, in: screens[index].visibleFrame)
```
- Trigger: `swift test` on a host whose screen set differs from the developer's, or reports nothing. The expectations are self-consistent (same rule, same screens), so they hold on a single-display host; but six files depend on a live display, and the `?? 0` + `screens[index]` pattern traps (`Index out of range`) if `NSScreen.screens` is empty. `DisplayIdentityTests:86-93` shows the guarded style (`XCTSkip` when no screen).
- Impact: README's "Unit suite ... Needs: nothing" / "only a few live-screen identity checks touch AppKit" is contradicted; the suite is not runnable blind. (Bounded: the display math itself is pinned display-independently by `ScreenOwnershipTests` and `GridLayoutTests`.)
- Fix: either inject a one-screen provider in those six files, or reword the README rows to "needs a logged-in GUI session (live screen set)" and note the headless limitation. Invariant pinned: "the unit suite's expectations are independent of the host's display set."

### F8 - Mutation table breadth: 8 of 25 source files, nothing in the hotkey layer [Low | Medium | test-gap]
- Location: `tools/mutation/mutants.json` (44 entries); `Sources/tiled/HotkeyService.swift:193-199` (`reload`), `Sources/tiled/AppDelegate.swift:677`
- Evidence:
```swift
    /// Unregisters everything and registers from the store again.
    /// Called after the user edits bindings in Settings; failedSlots is
    /// recomputed, so newly freed (or newly conflicted) slots surface in
    /// the menu without a relaunch.
    func reload() {
```
- Trigger: a mutant in `reload()`/`registerHotkeys()` (e.g. skipping `UnregisterEventHotKey`, or registering the default binding instead of `store.binding(for: slot)`). `HotkeyServiceTests` covers only constants and the pure `route` table; `grep` finds no test referencing `reload()` or `registerHotkeys()`; `FeedbackAndRecorderTests` stops at the store, and the live suite never remaps a shortcut. So the README's "Shortcuts are remappable ... press a new combo" (`README.md:96-98`) is pinned only up to the store, never to registration.
- Impact: no mutant for the app's primary input path, and none for `AppSettings` persistence, `MenuModel`/`MenuText`, or `StatusIcon` (their behaviour is well tested, so this is table breadth rather than a suite hole — the hotkey re-registration is the one that is both untested and unmutated).
- Fix: extract the registration result into the existing pure-style seam (`route(forHotKeyID:slotByID:)` is the precedent) so a test can assert "reload() re-registers exactly the store's enabled bindings and clears `failedSlots`/`hotKeyRefs` first", then add the matching mutant. Invariant pinned: "a remapped binding is what Carbon ends up holding."

### F9 - First-run Welcome / hidden-icon recovery presentation is untested [Low | High | test-gap]
- Location: `Sources/tiled/AppDelegate.swift:66-78`, `Sources/tiled/SettingsWindowController.swift:170`; `Tests/tiledTests/AppSettingsTests.swift:33-54` covers only the persisted flag
- Evidence:
```swift
        let firstRun = !settings.didDismissWelcome
        if firstRun {
            if gateway.isTrusted { showSettings(selecting: .welcome) }
        } else if settings.hideMenuBarIcon {
            // Hidden-icon recovery: with no status item there is no other
            ...
```
- Trigger: any regression in the launch decision table (Welcome on first run, Welcome after the permission wait at `:153`, Settings when the icon is hidden, nothing otherwise). `AppDelegate` already extracts `refreshPlan`/`menuWiring` as pure functions and tests them (`AppDelegateMenuTests`), so the omission is inconsistent rather than impossible.
- Impact: README's onboarding/recovery promises (`README.md:85-88`, `:60-63`) rest on an untested branch table; a new user's first launch, or a user who hid the icon, would fail silently.
- Fix: extract `launchPresentation(trusted:hideIcon:didDismissWelcome:afterPermissionWait:) -> Presentation` and assert the truth table, as `refreshPlan` is asserted at `AppDelegateMenuTests:127-158`. Invariant pinned: "exactly one launch path presents Welcome, and the hidden-icon launch always presents Settings."

### F10 - The fake records no writes, so no test can observe write counts or order [Low | High | test-gap]
- Location: `Tests/tiledTests/FakeWindowGateway.swift:76-88` (no call log; contrast `raiseCalls:48`, `focusCalls:44`); claim at `README.md:106`
- Evidence: `setFrame` mutates `windows[handle]` and returns `Bool`; there is no `writes`/`setFrameCalls` array anywhere in the file, so assertions can only see the *resulting* frame.
- Trigger: README rule "Tiling a window into its own tile does nothing: no restore, no reassert." `testRetileOwnSlotIsNoop` (`ControllerGatewayTests.swift:73-82`) asserts only state and `lastTileError`, so an implementation that re-wrote the tile rect on every same-slot hotkey press stays green. The neighbouring footgun is documented in `DragTracker` ("marking them expected would leave an echo entry that never converges..."): a spurious write is a *dangerous* class of change, not just noise.
- Impact: "no reassert" and the drag loop's spare-write avoidance are unverifiable through the seam (the tracker-level skip *is* pinned, `DragTrackerTests:743`), so the mutation table can never probe counts/ordering — the shape most real AX regressions take.
- Fix: add `private(set) var writes: [(handle: WindowHandle, frame: CGRect)] = []` appended in `setFrame`, assert emptiness in `testRetileOwnSlotIsNoop`, and assert one write per placed window in `PlanExecutorTests.testTilePlacesAndWritesFrame`; then a mutant that duplicates or drops a write becomes killable. Invariant pinned: "a no-op request issues zero AX writes; a placement issues exactly one per window it moves."

## Verified-clean areas (what I checked and why it held)
- **Fake fidelity surface** (`FakeWindowGateway.swift` vs `LiveWindowGateway.swift` + `WindowGateway.swift`): refusals (`refuseNextWrites` ← `AXWrite.retrying`), silent success (`silentIgnore` ← an app ignoring writes while returning success), clamped/rounded application (`writtenFrame` ← "a real app can clamp or round"), unreadable frames (`hideFrames` ← the lid-close read failure), transient dead probes (`probeDead` ← `.invalidUIElement` on live windows), busy/unknown (`busy` ← the tri-state liveness), per-window destroyed-vs-changed delivery (`simulateDestroyed`/`simulateChange` ← the live adapter's two handler dicts), z-order (`raise`/`zOrder` ← `kAXRaiseAction`), Space table (`activeSpaces` ← `activeSpace(on:)`), focus request semantics — all real behaviours, most with consumers; only the last two shapes are under-tested (F6).
- **Hermetic timing**: no `Thread.sleep`/`usleep` and no wall-clock deadline in the unit suite; `DragTracker.Context.now`, `TilingController(now:deathConfirmation:pruneInterval:scheduleDragEnd:scheduleVerify:)` are injected in `DragTrackerTests:36-60`, `ControllerGatewayTests:35-52`, `LidSleepWakeTests:32-45`; drag-ends and convergence checks are fired manually. The only real-time elements are main-queue hops awaited with 1.0 s timeouts and one 0.3 s `asyncAfter` against a 0.05 s prune timer (`ControllerBulkOperationTests:626-645`) — a 6-tick margin, not a race.
- **Notification-driven tests**: `SpaceIndependenceTests:324-346` can only pass if the screen-parameter notification block runs before the next statement (it needs `staleSpaces` to be marked), which shows the `.main`-queue delivery these tests rely on is effectively synchronous here; `ControllerBulkOperationTests:648` also waits on its own observer, so neither is order-flaky.
- **Anti-tautology work done deliberately**: literal clamp pins with the reasoning spelled out (`GridLayoutTests:1114-1126`), literal cell-set and hotkey tables (`TilingStateTests:161-192`, `:343-384`), an independent containment check that "the mirroring cannot fake" (`ExpandToggleTests:44-55`), a vacuity guard on the random sweep (`GridLayoutTests:1126`), and an explicit refusal to assert cross-layout pixel agreement where the design does not promise it (`GridLayoutTests:1138-1150`).
- **Duplicate-logic risk addressed**: `TilingStateTests.drive` and `MatrixCrossCheckTests.applyExpected` do re-implement the controller's apply order, but `MatrixCrossCheckTests` exists precisely to replay both against the real `TilingController.handle` over all configs × slots for fresh and tiled requesters, plus a per-step "no cell double-booked / single layout" invariant.
- **README "Tiling rules" and "Live resizing" mapping**: I walked every bullet/vocabulary rule in `README.md:100-176` and `CONTEXT.md` (one window per tile; eviction incl. both documented shapes; swap incl. the disjoint-vacated-tile requirement, focus follow, undo swaps back; own-tile no-op; self-move keeping the pre-tile frame; drag-out ~100 pt / snap-back / single far jump inert; Untile All and the per-window submenu; per-canvas independence incl. hidden Spaces, mixed layouts, per-canvas undo and splitters; display-change re-assertion and stale marking; refused resizes named in the menu; per-column/per-third splitter independence; two-thirds hidden divider centring; Reset Splitters). Each has a pinning test, except the three items reported as F3/F4/F10 and the first-run UI in F9.
- **Mutation status quo**: `build/mutation-results.json` is 44/44 `CAUGHT` with no STALE/INVALID/TIMEOUT, consistent with `build/mutation-full2.log:92` ("Mutation score: 44/44 valid mutants caught"); I re-verified by reading that the `old` snippets of the mutated code are still present in `Sources/tiled` (`undoDepth = 5` at `TilingController.swift:81`, `staleWrite: 3`, `untileDragDistance: 100`, `sixthsColumnClamp = 0.1...0.9`, `caseInsensitiveCompare`, `guard timestamp… >= deathConfirmation`, `registeredKeys.filter`, the `commit` release loop), so the table is not stale as of this read and the sources are in their pristine state.
- **Live-suite count**: exactly 40 pass/fail cases (`grep` finds 34 `verify(` call sites, one inside the 3-iteration S15 loop, plus 4 manual `pass += 1` blocks) — the README figure checks out; 3 of those 40 are F1.

## Residual uncertainty (what static reading cannot decide)
- I could not run `swift test`, `python3 tools/mutation/mutate.py`, or `./scripts/run-repro.sh` (HARD RULE 1: a mutation run rewriting `Sources/*.swift` in place is in flight, so any result would be untrustworthy). Everything above is static; the green-suite and 44/44 numbers are read from `build/*.log` and `build/mutation-results.json`, not reproduced.
- The headless crash in F7 (`screens[index]` with an empty `NSScreen.screens`) is a RISK: I can construct the trap from the code but cannot run it to confirm that `swift test` can reach a display-less session.
- F4's "survives the suite" claim rests on my reading of the two files that could host such a test (all cross-display traffic there stays on each window's own display, or asserts only occupancy) plus a repo-wide grep for `ownership`; it is an absence claim, not a demonstrated survivor.
- Live/AX-only code (observer registration and routing, `framesClose`-based death confirmation against a real app, write ordering in the real adapter, the ~3 ms `AXUIElementDestroyed` latency the README cites) is exercised only by the live harnesses, which I cannot drive; my statements about them rest on the adapter's own comments and the pure functions it delegates to.
- I did not count XCTest methods, so the README's "530 tests" claim is taken on trust (the 40-case live claim is the one I verified).