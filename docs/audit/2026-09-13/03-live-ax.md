# live Accessibility / window-server integration — audit findings

## Summary
I read all five owned files end to end plus the callers and tests that consume them (`AppDelegate`, `TilingController`, `PlanExecutor`, `FakeWindowGateway`, the AX/liveness/registry test files, `README.md`, `CONTEXT.md`). CoreFoundation ownership on the AX/CGS paths is correct as written — no leaks or over-releases found, and observer/runloop-source lifetimes are ordered correctly. The real exposure is not memory: it is *death-decision ownership* (`liveness` retires the element on the first `.dead` verdict, which makes the controller's documented transient-recovery protocol unreachable) and *partial-write residue* (`setFrame` writes position before size and never reverts the position when the size write is permanently refused).

## Findings

### F1 - `liveness(of:)` retires the element on the first `.dead`, so the controller's transient-death recovery can never happen [High | High for the mechanism, Medium that a false `.dead` occurs live | code-defect]
- Location: `Sources/tiled/LiveWindowGateway.swift:176`, `Sources/tiled/LiveWindowGateway.swift:227`, `Sources/tiled/TilingController.swift:126`
- Evidence:
```swift
// LiveWindowGateway.swift:176
guard let element = elements[handle], let pid = pids[handle] else { return .dead }
// LiveWindowGateway.swift:227
if verdict == .dead {
    elements[handle] = nil
    pids[handle] = nil
    changeHandlers[handle] = nil
    destructionHandlers[handle] = nil
    lastFrames[handle] = nil
```
```swift
// TilingController.swift:126-130 (the protocol this defeats)
/// gone from unreachable. Requiring the dead reading to persist
/// across `deathConfirmation` seconds (two prune ticks) lets a
/// transient recover — the machine sleeps before a second tick
/// can run, and on wake the probes answer again — while a really
/// dead window releases its slot on the next tick.
```
- Trigger: one `.dead` verdict from `liveness(of:)` for a live window. That verdict is reachable whenever the window's position probe fails while the app still answers its window list and no listed frame matches `lastFrames[handle]` — the file itself documents both halves as live-observed: "across a lid close/open, window-level probes fail (.invalidUIElement on held refs, .attributeUnsupported on fresh refs) for LIVE windows; the app element keeps answering and still lists them" (`:181-186`), and `AXLivenessTests` quotes "a display-sleep cycle turns `.success` probes into `.attributeUnsupported` for ~4 of 5 windows at t+2s". The geometry half goes stale because `lastFrames` is only refreshed by *reads* (`:165-170`) while writes (`setFrame`) do not touch it, and the system "repositions windows while the lid is closed … every frame shifts and shrinks" (`Tests/tiledTests/LidSleepWakeTests.swift:100-103`). After the first dead verdict, the next tick hits `:176` and returns `.dead` *without any probe*, so the controller always confirms at the second tick (`TilingController.swift:766-780`).
- Impact: the confirmation window degenerates to a fixed one-tick delay; a live window is dropped from management 3–5s after a single erroneous reading, its slot is released, its cells reflow into a survivor, and its `preTileFrame` is lost (when the user re-tiles it, `windowID(for:)` issues a fresh record whose pre-tile frame is captured from the *tile*, so "evict restores the pre-tile frame" is thereafter false for it). `Tests/tiledTests/ControllerGatewayTests.swift:334` asserts exactly the recovery that the live adapter cannot perform (`gateway.probeDead.remove(handle)` then "a recovered probe clears the pending death") — the fake's `liveness` is stateless (`FakeWindowGateway.swift:101-106`), so the suite green-lights a behaviour the production adapter cannot deliver.
- Fix: keep the door open for a recovery — do not retire `elements`/`pids`/handlers in `liveness(of:)`; return the verdict and let `deadSince` own death, or retire only for the non-recoverable causes (`appWindowsError == .invalidUIElement || !processAlive`). If retirement stays, `liveness` must be able to re-probe (e.g. re-derive the handle's element from the app's window list) rather than short-circuit to `.dead` at `:176`.

### F2 - position lands, size is refused: the window is left half-moved, contradicting the "left alone" contract [Medium | High | code-defect]
- Location: `Sources/tiled/LiveWindowGateway.swift:770` (and `:749-753` for the ordering rationale), `Sources/tiled/PlanExecutor.swift` `place` failure path, `README.md:143`
- Evidence:
```swift
// LiveWindowGateway.swift:770-779
let positionResult = AXUIElementSetAttributeValue(
    element, kAXPositionAttribute as CFString, positionValue)
let sizeResult = AXUIElementSetAttributeValue(
    element, kAXSizeAttribute as CFString, sizeValue)
guard positionResult == .success, sizeResult == .success else {
    lastError = positionResult == .success ? sizeResult : positionResult
    return lastError
}
```
- Trigger: an app that accepts `AXPosition` and permanently refuses `AXSize` (fixed-size/constrained windows). `AXWrite.retrying` only retries `.cannotComplete` (`:799-802`), so on a permanent size refusal it breaks on the first attempt; `setFrame` returns `false` with the window already moved to the target top-left. No caller reverts the position: `PlanExecutor.place` rolls back state only (`state.remove(window: id); tracker.forget(id)`) and reports "the app refused to resize it"; `restoreWindow` likewise deletes the record after a refused restore.
- Impact: the requester is *not* left alone — it now sits anchored at the requested tile's top-left at its old size, overlapping other tiles, while `TilingState` believes it is untiled. README:143 promises the opposite: "When that happens the window is left alone and the menu says which app refused, so state and screen never silently disagree." The same partial residue applies to evictee restores and reflow growth, and the menu text ("couldn't be tiled") misdescribes what happened.
- Fix: on a failed write whose position leg succeeded, write the position back (the caller already holds the previous frame — `record.preTileFrame`/`gateway.frame` before the write) before reporting the refusal; or detect it in `setFrame` by re-reading and restoring the previous origin.

### F3 - handles are deduped by `CFEqual` on the AX element, which this same file documents as unreliable for live windows [High | Medium | design-risk]
- Location: `Sources/tiled/LiveWindowGateway.swift:586`, evidence comment at `:60-63`, `Sources/tiled/LiveWindowGateway.swift:626-631`
- Evidence:
```swift
// :60-63
/// Last successfully-read frame per handle: the geometry a death
/// confirmation matches against. Window element identity is useless
/// for that check — after a display teardown a held element stops
/// comparing equal (CFEqual) to the app's fresh reference for the
/// same window (observed on live AX: `listed=no` while the app
/// listed every window) — but the window's frame is stable.
// :585-588
private func handle(for element: AXUIElement, pid: pid_t) -> WindowHandle {
    for (handle, registered) in elements where CFEqual(registered, element) {
        return handle
    }
```
- Trigger: after a display teardown, `focusedWindow()` (`:169-172`) hands `handle(for:pid:)` the app's *fresh* element for a window whose held element no longer `CFEqual`s to it. The registry then issues a second `WindowHandle` for a window that already has a record (`TilingController.windowID(for:)` keys strictly on `WindowHandle` equality, `TilingController.swift:748-759`). The same comparison drives notification routing at `:626-631`.
- Impact: "One window per tile" (README:60) breaks: two records, two occupied slots, both drives writing the same window to two different tiles (last write wins on screen; the menu double-counts the window and offers two rows/untile actions for it), and the older record cannot self-heal — its element still answers `.alive`, so prune keeps it forever. The same identity gap can drop an `AXUIElementDestroyed` notification on the floor (it matches no handle), which is the path README:240 promises "release inside a sub-second budget".
- Fix: dedupe on something that is not the element reference — e.g. keep the owning pid plus the window's stable identity (frame-adjacent or the app's own window list ordering) as a secondary key, or make `handle(for:)` fall back to "same pid, same last-read frame" when the `CFEqual` scan misses. At minimum, treat a `CFEqual` miss for a window whose last-read frame matches an existing handle of the same pid as the same window.

### F4 - a nil Space id turns the "never write an off-Space window" guard off, and that is the mode the fallback exists for [Medium | Medium | design-risk]
- Location: `Sources/tiled/LiveWindowGateway.swift:380-388` (`currentSpaces()` returns `[:]`), `Sources/tiled/TilingController.swift:1642-1644`
- Evidence:
```swift
// TilingController.swift:1642-1644
private func isVisible(_ space: TilingSpaceKey) -> Bool {
    guard let screen = space.screen, let id = space.space else { return true }
    return activeSpaceID(on: screen) == id
}
```
```swift
// LiveWindowGateway.swift:383-387
guard
    let connection = CGS.defaultConnection?(),
    let displays = CGS.copyManagedDisplaySpaces?(connection)?
        .takeRetainedValue() as? [[String: Any]]
else { return [:] }
```
- Trigger: any machine where the private Space table is unavailable or unparsable for a display — the deliberate degrade path when `_CGSDefaultConnection`/`CGSCopyManagedDisplaySpaces` disappear (`:8-11`, `:380`), or a table row whose identifier no longer resolves (`spaces(from:)` skips it, `:404-421`). `activeSpace(on:)` then returns nil for that display, every canvas key becomes the per-display fallback, and `isVisible` answers `true` for every one of them.
- Impact: with Space identity withheld, Tiled writes windows that are parked in hidden Spaces (display reassertion after `didChangeScreenParametersNotification`, `applyAll`), which is exactly what README:139-141 promises never happens ("Tiled never writes an off-Space window, because an AX resize can pull it onto the visible Space"): the observed failure is windows being pulled onto the visible Space. The fallback therefore silently inherits the hazard the known-Space path is built to avoid, and the menu gives no hint (the README's parenthetical only mentions the canvas-count consequence).
- Fix: make `isVisible` require evidence of visibility *or* a known Space id — e.g. on a display with no Space id, skip the blanket `applyAll` reassertion and only write the window acted on; or surface the degraded mode in the menu's status line.

### F5 - per-refresh AX cost is unbounded in the number of messages, and the result is often discarded [Medium | High on the counts, Medium on impact | design-risk]
- Location: `Sources/tiled/LiveWindowGateway.swift:169-172` and `:653-685` (`focusedWindow()`), `:203-206` (`readFrames`), `Sources/tiled/AppDelegate.swift:404-410`
- Evidence:
```swift
// AppDelegate.swift:404-410 — snapshots are computed before the diff decides
let snapshot = menuSnapshot()
let icon = iconSnapshot()
let plan = Self.refreshPlan(
    menuChanged: force || snapshot != lastMenuSnapshot || statusItem?.menu == nil,
    iconChanged: lastIconSnapshot != icon || statusItem?.button?.image == nil,
    menuOpen: menuOpen)
```
```swift
// LiveWindowGateway.swift:205 — two AX messages per listed window
let readFrames = list.compactMap { Self.frame(of: $0) }
```
- Trigger: one `refreshMenu()` (fired per drag tick via `pushRects` → `onChange` at `TilingController.swift:638`, once per second by the permission poll at `AppDelegate.swift:162-171`, on every app activation) resolves the focused window **three** times — `AppDelegate.swift:463` (`hasFocusedWindow`), `:464` (`expandedFocusedSlot` → `TilingController.swift:976`), and `iconSnapshot` → `focusedTilingSpace` → `focusedScreenID` → `TilingController.swift:1672` — which is 3× `AXUIElementCreateSystemWide()` + 6 blocking `AXUIElementCopyAttributeValue` messages, plus the frame read (`:1673`, 2 more messages), plus an `AXIsProcessTrustedWithOptions(nil)` TCC query (`:569`, `:647`); all before the diff that may discard the whole snapshot. A failing liveness probe reads `2 × (windows listed by that app)` more messages on the 5s tick (`:205`).
- Impact: every message is capped at 1s (`:44-51`), but nothing caps the *count*, so a hung or very busy focused app can block the main runloop for many seconds per drag tick and per prune tick — the drag-resize loop and hotkeys share that thread, and the work is duplicated three times over for one logical question ("which window is focused?").
- Fix: resolve the focused window once per refresh pass (pass a snapshot down, or memoize `focusedWindow()` for the duration of one runloop turn / a few tens of ms), and stop reading the app's whole window list when a cheaper confirm is available.

### F6 - the live adapter's own state machine has no test; the lid-cycle transient is only asserted against a fake that cannot fail the same way [Medium | High | test-gap]
- Location: `Tests/tiledTests/ControllerGatewayTests.swift:312-338`, `Tests/tiledTests/FakeWindowGateway.swift:92-106`, `Tests/tiledTests/`
- Evidence: no test file constructs `LiveWindowGateway` (grep for `LiveWindowGateway()` matches only `AppDelegate.swift:5` and `TilingController.swift:196`); the fakes' liveness is a settable set:
```swift
// FakeWindowGateway.swift:101-106
func liveness(of handle: WindowHandle) -> Liveness {
    guard let window = windows[handle] else { return .dead }
    if probeDead.contains(handle) { return .dead }
    ...
```
- Trigger: none needed — this is the coverage statement for F1/F2/F3. Everything that fails in F1–F3 lives between `liveness`'s pure classifier (well tested, `AXLivenessTests`) and the adapter's element/registry bookkeeping (untested), and `setFrame`'s two-write sequence has no test at all (`AXWriteTests` covers only the retry policy). `tools/repro/multi-display-checklist.md` covers unplug/rearrange/resolution/Spaces but has no sleep/lid scenario, so the `deathConfirmation` rationale's trigger is not exercised anywhere.
- Impact: a regression in handle retirement, baseline seeding, or partial-write handling is invisible to the 530-test gate, which the README (Testing section) treats as "the gate for every change".
- Fix: extract the adapter's per-handle bookkeeping (register/retire/baseline/partial-write decision) into a pure value type with the element operations injected, the way `ObservationRegistry`/`liveness`/`appKitFrame` already are, and add the lid-cycle sequence (probe fails → app answers → cached frame stale → probe recovers) to the fake's fidelity surface.

### F7 - the observation registry keys on `CFHash`, so a hash collision permanently skips registration with no signal [Low | Medium | design-risk]
- Location: `Sources/tiled/LiveWindowGateway.swift:281`, `:287-288`, `:895-901`
- Evidence:
```swift
// :281
let key = UInt(CFHash(element))
// :287-288
switch registry.begin(key: key, pid: pid) {
case .skip:
    return
```
- Trigger: two distinct elements whose `CFHash` collides, or a hash that is not element-stable across sessions of registration. `.skip` is returned only on "already registered or in flight" (`:895-901`), and `observe` returns without registering anything, without logging, and without a retry path.
- Impact: precisely the lockout the `ObservationRegistry` doc comment exists to prevent ("a window whose notifications could not be registered stays retryable, instead of losing drag-resize for the rest of the session with nothing on screen to say so", `:320-324`) — reopened by a different route, silently. I cannot construct a concrete colliding pair statically, hence RISK rather than defect.
- Fix: key on a pair the registry can validate (`key` + the owning pid, plus a `CFEqual` check against the element the key was recorded for) instead of a bare hash.

### F8 - `focus(_:)` ignores the activation result and uses the un-branched API, unlike the app-level path [Low | Low | design-risk]
- Location: `Sources/tiled/LiveWindowGateway.swift:548-553`, `Sources/tiled/NSApplication+Activate.swift:10-15`
- Evidence:
```swift
// LiveWindowGateway.swift:548-553
func focus(_ handle: WindowHandle) {
    guard let element = elements[handle], let pid = pids[handle] else { return }
    AXUIElementSetAttributeValue(
        element, kAXMainAttribute as CFString, kCFBooleanTrue)
    NSRunningApplication(processIdentifier: pid)?.activate()
}
```
```swift
// NSApplication+Activate.swift:10-15
if #available(macOS 14.0, *) {
    activate()
} else {
    activate(ignoringOtherApps: true)
}
```
- Trigger: on macOS 14+ cooperative activation can deny a non-user-initiated request; e.g. granting Accessibility in System Settings (frontmost) → Tiled's 1s poll fires `start()` → `showSettings(selecting: .welcome)` (`AppDelegate.swift:153`) → `activateAsFrontmost()`. The menu's "focus this window" rows go through the `NSRunningApplication` call, whose `Bool` result is discarded.
- Impact: a denied activation is invisible in both paths — the window is raised inside its app (kAXMain) while the app stays behind, so the menu row appears to do nothing. I cannot verify the OS's decision statically, hence RISK.
- Fix: check the returned `Bool` from `NSRunningApplication.activate(...)` and fall back to `NSApp.activateAsFrontmost()` + `NSRunningApplication.current.activate` when it reports failure; log the refusal rather than swallowing it.

### F9 - a handle whose frame baseline was never captured can never be judged dead, so the slot never releases [Low | Medium | code-defect]
- Location: `Sources/tiled/LiveWindowGateway.swift:203-211` (the `match` computation), `:699-714` (the classifier's `nil → .unknown`), `:275-280` (baseline seeding)
- Evidence:
```swift
// :203-211
var match: Bool?
if let cached = lastFrames[handle] {
    let readFrames = list.compactMap { Self.frame(of: $0) }
    if readFrames.contains(where: { Self.framesClose($0, cached) }) {
        match = true
    } else if list.isEmpty || readFrames.count == list.count {
        match = false
    }
}
```
- Trigger: a record whose `observe()` baseline seed failed (`if lastFrames[handle] == nil, let frame = Self.frame(of: element)` — the read can fail for a busy app; the `frame(of:)` callers in `spaceKeyForRequester`/`focusedScreenID` can fail the same way) and whose window is then closed by the user. The probe fails, the app answers its window list, `match` stays `nil` (no baseline to compare), and `liveness(probeError:appWindowsError:appWindowMatch:processAlive:)` returns `.unknown` (`:713`) — forever, since nothing ever seeds the baseline for a handle the controller no longer reads a frame for.
- Impact: a ghost record keeps its slot, the status icon keeps it lit, the menu keeps a row for a window that no longer exists, and the 5s prune tick re-probes it indefinitely; the only exits are "Untile All" (whose restore then fails) or quitting the app. `windowDestroyed`'s fast path (`TilingController.swift:1141-1152`) can't help because it requires `.dead` too.
- Fix: never leave a handle without a baseline — seed it inside `handle(for:)` at registration (or retry the seed from the first `changeHandlers` tick), and treat "no baseline" as a reason to re-seed rather than a permanent `nil`.

## Verified-clean areas (what I checked and why it held)

- **CoreFoundation ownership on every AX path.** All AX objects flow through ARC-managed CF types with no manual `CFRelease`/`CFRetain` anywhere in `Sources/tiled` (grep). `AXUIElementCreateApplication` (`:191`, `:513`), `AXUIElementCreateSystemWide` (`:654`), `AXUIElementCopyAttributeValue` (`:177`, `:194`, `:663`, `:677`, `:992`) and `AXValueCreate` (`:965`, `:970`) all follow the importer's Create/Copy rule; the two manual ownership transfers that need it are correct: `CGSCopyManagedDisplaySpaces(...)?.takeRetainedValue()` (`:386`, the CGS symbol is Copy-rule and deliberately typed `Unmanaged<CFArray>?` at `:11`) and `CGDisplayCreateUUIDFromDisplayID(...)?.takeRetainedValue()` (`:466`). `kAXTrustedCheckOptionPrompt.takeUnretainedValue()` (`:575`) is right for a constant. No `Unmanaged`, `passRetained`, `fromOpaque`, `autoreleasepool`, or `__bridge` misuse exists outside `HotkeyService` (not this slice). Long-running-app leak hunt: `elements`/`pids`/`lastFrames`/`changeHandlers`/`destructionHandlers`/`registry`/`observers` each have an explicit removal path (`:227-236`, `:247-253`, `ObservationRegistry.forget` at `:920-928`); no per-poll allocation path exists in the gateway.
- **Observer lifetime and runloop-source ordering.** Both teardown paths remove the source from the main runloop *before* dropping the observer reference — `CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)` then `observers[pid] = nil` (`:250-253`) and the same order in `releaseFocusObserver()` (`:539-543`) — which is the one ordering trap with `AXObserverGetRunLoopSource` (a Get-rule source owned by the observer). Registration is undone with `AXObserverRemoveNotification` before the observer dies (`:536-537`); `AXObserverAddNotification` results are honestly classified (`.notificationAlreadyRegistered` counted as success, `:912-914`).
- **Notification threading.** Every handler that touches controller state runs on the main runloop: per-window and focus observers are attached with `CFRunLoopAddSource(CFRunLoopGetMain(), …, .commonModes)` (`:302-304`, `:526-528`; `.commonModes` also keeps them firing during menu/drag event tracking), the three `NSWorkspace` observers pass `queue: .main` (`:110`, `:119`, `:131`), and the space-change block hops once more to main before invalidating the cache (`:134-137`). No AX state is touched off-thread.
- **Coordinate math.** The y-flip is the standard, correct one and is the only coordinate conversion in the module (`appKitFrame`/`axTopLeft`, `:938-952`), with the primary top edge taken once from `NSScreen.screens.first?.frame.maxY` and an honest `nil` (not a guess) when no screen exists (`:717-731`); AX and AppKit both speak points, so Retina scale needs no factor. Round-trip and top/bottom anchoring are pinned by `Tests/tiledTests/AXConversionTests.swift`.
- **Space-table parsing defensiveness.** Every hostile shape degrades instead of guessing: missing/unparsable `id64` (`:424-431`), unresolvable display identifier (single-display fallback only, `:437-459`), empty/failed private-symbol lookup → `[:]` → documented per-display canvas (`:380-388`). `displayIDs()` handles the `CGGetActiveDisplayList` count-in/out protocol correctly (`:471-482`) and never indexes out of range (`Array(ids.prefix(Int(count)))`).
- **Force unwraps / unchecked operations.** The only `as!` casts are behind `CFGetTypeID` checks (`:667/669`, `:681/684`, `:994/996`) or known-constant tags (`:957-958`, `AXValueType(rawValue: kAXValueCGPointType)!`); no `try!`, no array subscripts, no unchecked arithmetic in the five owned files. `main.swift` is safe despite `NSApplication.delegate` being weak: `delegate` is a top-level `let` (static storage) so it outlives `app.run()`.
- **Space-change cache invalidation** (`:128-137`, `:367-375`) is correct for the hotkey path: the cache is dropped before the handler runs and the 0.1s lifetime only collapses repeated per-row lookups. I also checked that a transient nil Space cannot misroute a *tiled* window, because `spaceKeyForRequester` prefers recorded ownership (`TilingController.swift:718-719`) over the freshly resolved key.

## Residual uncertainty (what static reading cannot decide)

- Whether a false `.dead` (F1) actually occurs on current hardware: it needs probe failure + readable listed frames + a stale cached frame at the same moment. The repo's own live notes say the first two co-occur across a lid cycle; the third depends on whether the app emits a move notification after Tiled's write. This is what a TILED_DEBUG=1 live lid-cycle run would settle.
- Whether `AXUIElement`'s `CFHash` is element-stable and collision-free in practice (F7) — needs a live probe across an app's windows.
- Whether `NSScreen.screens.first` is always the display at the CoreGraphics origin that `CGMainDisplayID()` names (the Space table's "Main" row, `:441`); they agree in every arrangement I can reason about, but mirrored/rotated arrangements and displays above/left of the menu-bar display cannot be confirmed from source.
- Mirrored displays: `CGGetActiveDisplayList` collapses a mirror set, so the Space table row for the mirrored display may not map; the single-display fallback absorbs the common case but the multi-display corner is unverified.
- Whether the deprecated `NSRunningApplication.activate()` overload is what the compiler binds at `:552` (it compiles under the declared macOS 13 deployment target, so it cannot be the macOS 14 `activate()`), and whether the system honors it on macOS 14+ (F8).
- `deinit` removes only the focus observer's runloop source, not the per-pid sources; harmless for the singleton the app installs, but it means any future second `LiveWindowGateway` instance would leave sources on the runloop and would also steal `LiveWindowGateway.active` routing.
- I ran no build, test, or git command (read-only slice, and a mutation run is rewriting `Sources/*.swift` in place). The supervisor should run, after the mutation run finishes: `swift test`; `TILED_DEBUG=1` live lid-close/open and sleep/wake cycles against the repro host app (`scripts/run-repro.sh`, `tools/repro/dead-app-liveness-probe.swift`) to confirm or refute F1; and a fixed-size-window app against `⌥⇧U` to reproduce F2. `tools/repro/multi-display-checklist.md` has no sleep/lid row and needs one.