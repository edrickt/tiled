# app shell, hotkey service, settings persistence, permissions — audit findings

## Summary (≤3 sentences)
I read all eight owned files plus the parking/restore logic they own, the SDK header that defines the Carbon hot-key contract, and every test file that pins them. The strongest finding is structural: `RegisterEventHotKey` with options `0` can never fail because another app owns a combo (SDK-documented), so the README's "that slot shows a warning" promise and the "other apps own it" warning text are unreachable/wrong-party — the only reachable cause of `failedSlots` is an in-app duplicate. The bulk Enable-all / Restore-Previous-Shortcuts paths do write in-app duplicates (bypassing the store's duplicate gate), and an armed recorder outlives its closed window with its key-swallowing monitor still installed.

## Findings

### F1 — Cross-app hotkey-conflict detection cannot fire; warnings blame the wrong party [High | High | doc-gap]
- Location: `Sources/tiled/HotkeyService.swift:268-274` (registration), `Sources/tiled/MenuText.swift:43-46,60-65` (wording), `README.md:88-90` (promise)
- Evidence:
```swift
            let status = RegisterEventHotKey(
                keyCode,
                binding.modifiers,
                EventHotKeyID(signature: Self.signature, id: slot.hotkeyID),
                GetApplicationEventTarget(),
                0,
                &ref)
```
  The `inOptions` argument is `0` — i.e. *not* `kEventHotKeyExclusive`. The SDK contract is explicit: `…/HIToolbox.framework/Versions/A/Headers/CarbonEvents.h:15435-15437` "The same hot key can, however, be registered by multiple applications. This means that multiple applications can potentially be notified when a particular hot key is requested." and `…/Headers/CarbonEventsCore.h:144-152` "`eventHotKeyExistsErr` … Returned from RegisterEventHotKey when an attempt is made to register a hotkey that is already registered **in the current process**. (Note that it is not an error to register the same hotkey in multiple processes.)". `README.md:88` promises "If a shortcut is already owned by another app, that slot shows a warning in the menu instead of silently doing nothing", and the menu row reads `"⚠ 1 shortcut problem: other apps own it"` (`MenuText.swift:45`).
- Trigger: two concrete reachable cases, neither of which produces a warning: (a) another app registered the combo with `kEventHotKeyExclusive` — `CarbonEvents.h:15414-15417` says Tiled's non-exclusive registration is *accepted* ("non-exclusive registrations are accepted as normal, but will not receive notification events"); (b) a system symbolic hot key (Mission Control/Spotlight class combos, e.g. recording ⌘Space or ⌃← onto a slot) — the WindowServer consumes the key, `RegisterEventHotKey` returns `noErr`. In both cases `failedSlots` stays empty and the menu never shows the advertised warning.
- Impact: the advertised failure state is unreachable, so the user silently loses the shortcut; and in the only case that *does* populate `failedSlots` — an in-app duplicate — the message tells them another *app* owns the combo, sending them to the wrong fix. The four fixed-combo flags (`settingsHotkeyFailed`, `expandHotkeyFailed`, `evictHotkeyFailed`, `undoHotkeyFailed`, `HotkeyService.swift:208-261`) are unreachable for the same reason, since the fixed combos are registered *before* the slots and same-process collisions therefore always fail the *slot*, never the fixed combo: their "quit and reopen Tiled" advice is dead text.
- Fix: minimal, wording-level — make `MenuText.hotkeyFailureWarning`/`warningSummaryTitle` name the only reachable cause ("another Tiled shortcut already uses this combo") and drop the cross-app detection claim from `README.md:88-90`; if genuine cross-app detection is wanted it requires `kEventHotKeyExclusive` (which changes behavior for other registrants) and is a design decision, not a wording fix.

### F2 — Bulk Enable-all / Restore-Previous-Shortcuts store duplicates without the duplicate gate → a hotkey silently dead, tab shows it enabled and names no conflict [Medium | High | code-defect]
- Location: `Sources/tiled/SettingsShortcutsTab.swift:370-377` and `:648-656`; gate bypassed is `Sources/tiled/HotkeyBinding.swift:217-228`
- Evidence:
```swift
                    } else {
                        hotkeyStore.set(parked, for: slot)
                        clearParkedBinding(for: slot)
                    }
                } else if current.keyCode == nil {
                    hotkeyStore.set(HotkeyStore.defaultBinding(for: slot), for: slot)
                }
```
  `set` is the unchecked writer; only `apply` consults `duplicates(of:ignoring:)` (`HotkeyBinding.swift:217-224`). `restoreResetBackup` has the same shape at `:651` (`hotkeyStore.set(backup, for: slot)`).
- Trigger: (1) Quarters → "Disable all 6" (parks Top Left = ⌥⇧⌘U, stores it disabled); (2) record ⌥⇧⌘U onto Top Left *Sixth* — `apply` sees Top Left as disabled and accepts it; (3) Quarters → "Enable all 6" → `set(parked, for: .topLeft)` writes ⌥⇧⌘U although `sixthTopLeft` already holds it. Registration then runs in `Slot.allCases` order (`Layout.swift:67-70`: `topLeft` = id 1 before `sixthTopLeft` = id 7), so the second call gets `eventHotKeyExistsErr` per the header quoted in F1, `failedSlots.append(slot)` runs (`HotkeyService.swift:278`), and Top Left Sixth has **no hotkey**. The identical sequence works through Reset Shortcuts → "Restore Previous Shortcuts" (`:648-656`).
- Impact: the Shortcuts tab shows all six restored combos as live (labels come from the store, `SettingsShortcutsTab.swift:171-173`) while one of them is dead, and the promised "the Shortcuts tab names the conflict" (`README.md:90`) does not happen: `rebuildContent` → `reload()` → `surfaceHotkeyFailures()` (`:177,216`) runs *before* `onHotkeysChange?()` (`:400`) which is what re-registers (`AppDelegate.swift:676-681`), so the tab probes the pre-toggle `failedSlots` and stays silent until the window is reopened. Only the status menu's summary row reveals it. The store's invariant ("no two slots share a combo") is also broken for every later reader.
- Fix: route the restore writes through the same check — e.g. have the store expose an `apply`-like path that rejects a clash with a *non-parked* slot and reports it through the existing `keptEdits`/`showConflict` channel, and move the `onHotkeysChange?()` call ahead of `rebuildContent` so the tab's probe sees the post-registration `failedSlots`.

### F3 — An armed recorder survives its window closing: the keyDown monitor stays installed and armed [Medium | High | code-defect]
- Location: `Sources/tiled/RecorderButton.swift:59-71`, `:134-141`, `:158-162`
- Evidence:
```swift
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.routeRecordedEvent(event)
        }
```
  The monitor is removed only by `stopMonitoring()`, called from `stopRecording()`/`cancelSilently()`; `stopRecording()` is reached from `showBinding`, `beginRecording`, or a decisive event (`:49,58,93`). `grep` over `Sources/tiled` for `windowWillClose|viewDidMoveToWindow|window.delegate` returns **zero** hits, so nothing disarms on close, and the button is never deallocated while the controller lives (`SettingsWindowController` holds the tab; the window is `isReleasedWhenClosed = false`).
- Trigger: click a recorder (armed: `title = "Press shortcut…"`, `isRecording = true`), then click the window's red close button instead of pressing Esc/⌫. Tiled stays the active app (accessory app, no other window). Every subsequent keyDown is now routed to `routeRecordedEvent`, which swallows every non-decisive key (`:95 return nil`) and commits on the first combo with ⌥⌃⇧⌘ (e.g. ⌘Q while the user expects to quit).
- Impact: keystrokes aimed at the (now closed) Settings window are consumed with no visible surface explaining why; a committed combo is stored *and* re-registered globally (`AppDelegate.swift:676-681`), so a stray ⌘Q press can become a global hot key that hijacks Cmd-Q in every app. Reopening Settings happens to clean it up (`show()` → `reload()` → `showBinding` → `stopRecording`), but nothing announces that the record was aborted.
- Fix: disarm when the recorder leaves the window — override `viewDidMoveToWindow` (`window == nil` → `cancelSilently()`) or call a `disarmAll()` from a `windowWillClose` delegate hook, reusing the existing `onSilentCancel` announcement.

### F4 — The Carbon handler holds an unretained `Context` behind a permanent one-shot install flag, with no teardown [Low | High | design-risk]
- Location: `Sources/tiled/HotkeyService.swift:129,284-290`, `:183-187`
- Evidence:
```swift
    private static func installEventHandler(with context: Context) {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        let userData = Unmanaged.passUnretained(context).toOpaque()
```
  `context` is strongly held only by the `HotkeyService` instance (`private let context = Context()`, `:128`), and the class has no `deinit` unregistering its refs or removing the handler. Registered hot keys outlive the registering object (the system only reclaims them at process exit — `CarbonEvents.h:15498-15502`).
- Trigger: none in the current build (the single service is created in `start()`, `AppDelegate.swift:138`, and `hotkeys` is never reassigned), so this is flagged as a RISK, not a present defect. A second `HotkeyService` (a future re-init, or a test constructing one) would route the *new* registrations into the *first* Context's handlers (`handlerInstalled` short-circuits install), and once the first instance is released, the next press dereferences freed memory via `Unmanaged.fromOpaque(userData!).takeUnretainedValue()`.
- Impact: latent use-after-free / silently dead hotkey routing; the failure mode is a crash on a keypress rather than a diagnosable error.
- Fix: own the callback lifetime explicitly — make the install flag per-service (or store the `EventHandlerRef` returned by `InstallEventHandler`), and add `deinit { unregister all; RemoveEventHandler }`.

### F5 — `UInt32(modifiers)` still traps on a large positive Int; the guard only covers negatives [Low | High | code-defect]
- Location: `Sources/tiled/HotkeyBinding.swift:195-197`
- Evidence:
```swift
        guard modifiers >= 0 else { return Self.defaultBinding(for: slot) }
        return HotkeyBinding(
            modifiers: UInt32(modifiers), keyCode: code >= 0 ? UInt32(code) : nil)
```
  The comment above states the intent exactly: a corrupt `modifiers` "must not reach UInt32 (a trap)". `Int` from a plist can be any 64-bit positive value, and Swift's exact-value `UInt32.init(_: Int)` traps on overflow.
- Trigger: `hotkey.topLeft.modifiers` set to a positive integer > `UInt32.max` (hand-edited plist / `defaults write` on an integer node) — e.g. 4294967296. The store is read during launch (`HotkeyService.registerHotkeys` → `store.binding(for:)`, `:263`) and by the menu/`activeWarnings` path, so the app crashes while building its first menu instead of degrading to defaults. `HotkeyBindingTests` covers the negative case only (`testStoredNegativeModifiersFallsBackToDefaults`); `parkedBinding` in `SettingsShortcutsTab.swift:459-464` has the same unchecked conversion.
- Impact: crash on a corrupt-preference path that the code and its tests claim is handled.
- Fix: `guard let m = UInt32(exactly: modifiers) else { return Self.defaultBinding(for: slot) }` (and the same in `parkedBinding`).

### F6 — Permission polling is one-way: runtime revocation is never re-detected, and the app misreports the cause [Low | High | design-risk]
- Location: `Sources/tiled/AppDelegate.swift:131-133`, `:162-174`, `:52-64`
- Evidence:
```swift
    private func start(afterPermissionWait: Bool = false) {
        permissionTimer?.invalidate()
        permissionTimer = nil
```
  `pollForPermission()` is only invoked from the untrusted launch branch (`:63`) and is killed by the first successful `start()`. Nothing re-probes afterwards; `permissionStateDidChange()` is likewise only called from `start()` (`:158`).
- Trigger: grant Accessibility, let the poll stop, then revoke Tiled's Accessibility permission in System Settings and press ⌥⇧U. The hotkeys are still registered (nothing unregisters them), `gateway.focusedWindow()` returns nil, so `TilingController.requesterAndCanvas` emits `.noFocusedWindow` (`TilingController.swift:335-338`) and the user hears "No focused window: click a window first." (`MenuText.swift:107`) — the wrong diagnosis. The status menu does recover on its next rebuild (`MenuSnapshot.isTrusted` probes TCC fresh), and the Settings windows only refresh on `show()`; the launch explainer never returns.
- Impact: a revoked permission looks like a focus bug for a user whose icon is hidden, and a revoke→regrant cycle additionally leaves the focus observer untouched (`LiveWindowGateway.retargetFocusObserver` early-returns on the same pid, `:502`).
- Fix: keep a low-frequency trust poll running after the first grant and route a *flip to untrusted* through one explicit path (notice + Settings permission row refresh), reusing `permissionStateDidChange()`.

### F7 — The store's conflict model excludes the four reserved combos, so a dead combo can be stored and shown as live [Low | High | code-defect]
- Location: `Sources/tiled/HotkeyBinding.swift:226-228` vs `Sources/tiled/HotkeyService.swift:39-72`
- Evidence:
```swift
    func duplicates(of candidate: HotkeyBinding, ignoring ignored: Slot) -> [Slot] {
        guard candidate.keyCode != nil else { return [] }
        return Slot.allCases.filter { $0 != ignored && binding(for: $0) == candidate }
```
  Only slot bindings are compared; `expandBinding` (⌥⇧⏎), `evictBinding` (⌥⇧⌫), `settingsModifiers/KeyCode` (⌃⌥⇧⌘,) and `undoModifiers/KeyCode` (⌃⌥⇧⌘Z) are invisible to the check.
- Trigger: arm any slot's recorder and press ⌥⇧⏎ (an easy slip: Return with ⌥⇧ held, or a deliberate attempt to get expand onto a slot). `apply` finds no duplicate and stores it; registration of the fixed combos happens first (`:208-261`), so the slot's own registration fails with `eventHotKeyExistsErr` and the slot ends up in `failedSlots`.
- Impact: the slot is persisted with a combo that can never fire while the tab renders it as its live shortcut; unlike F2 the recorder does disclose it immediately (`finishRecording` probes `failedSlotsProvider` after re-registration, `:544-552`), which is why this is Low.
- Fix: extend the duplicate check to a reserved set (`HotkeyService.expandBinding`/`evictBinding` plus the two all-modifier combos) so the recorder rejects them with the normal conflict message instead of storing an unusable binding.

### F8 — Recorded combos are labelled with US-ANSI keycaps, not the user's layout [Low | High | doc-gap]
- Location: `Sources/tiled/HotkeyRecorder.swift:62-64`, `Sources/tiled/HotkeyBinding.swift:28-77`
- Evidence:
```swift
        guard !modifierKeyCodes.contains(keyCode) else { return nil }
        return .binding(HotkeyBinding(
            modifiers: carbonModifiers, keyCode: UInt32(keyCode)))
```
  The stored code is the physical/virtual keycode; the label is a static table of `kVK_ANSI_*` → letter (`case kVK_ANSI_U: "U"`).
- Trigger: on a QWERTZ/AZERTY layout, record a combo using a key that moves between layouts (German "Z" is at the ANSI_Y position, French "A" at the ANSI_Q position). The hotkey itself works (Carbon matches keycode+modifiers, which is the correct behavior), but the recorder, the Shortcuts tab, the menu titles and the announcements all render the US letter: the user records "⇧⌥Z" and the app says "⇧⌥Y".
- Impact: the label contradicts the keycap on every non-US layout, in the surface whose entire job is telling the user which combo is bound.
- Fix: derive the label from the current keyboard layout (`UCKeyTranslate` / `TISCopyCurrentKeyboardLayoutInputSource`) and fall back to the current table, or state the US-ANSI labeling limitation in the README's Shortcuts section.

## Verified-clean areas (what I checked and why it held)
- **Launch/lifecycle wiring (`main.swift`)**: `let delegate = AppDelegate()` is a top-level global (static storage), so `NSApplication`'s weak delegate cannot be dropped before `app.run()`; `.accessory` matches `LSUIElement` in `scripts/make-app.sh:31`, and the app menu added in `setupMainMenu` gives ⌘Q/⌘W/⌘, their key equivalents while Settings has focus.
- **Quit behavior**: `grep` for `applicationWillTerminate|applicationShouldTerminate` over the repo returns no hits, and the only `untileAll` call site is the status-menu action — so README's "Quitting Tiled leaves your windows where they are" holds; no unregister is needed at exit (`CarbonEvents.h:15498-15502`).
- **Register/Unregister pairing**: `reload()` unregisters every stored ref before re-registering (`HotkeyService.swift:194-199`), disabled slots register nothing (`:265 guard let keyCode = binding.keyCode else { continue }`), and every successful registration is appended to `hotKeyRefs`; reserved ids 996–999 cannot collide with slot ids 1…17 (`HotkeyServiceTests` pins the ranges and `route`).
- **Store defaults, ordering, corruption, disable semantics**: an absent/partial/garbage entry falls back to the factory default, `keyCode < 0` is the disabled encoding, `duplicates` never matches a disabled or the same slot, and `apply` leaves the store untouched on rejection — all pinned in `HotkeyBindingTests` (round-trip, `-1`, negative modifiers, string, partial).
- **Recorder semantics**: bare ⎋ cancels, bare ⌫/forward-delete clears, ⌥⎋/⌃⌫ are legitimate bindings, modifier-only keyDowns (54/55/58/61/59/62/56/60/63), caps lock, auto-repeat and non-keyDown events are ignored, and navigation keys pass through — `HotkeyRecorderTests` covers each; `routeRecordedEvent` disarms before invoking the completion so a decisive key fires exactly once (`RecorderButtonRoutingTests`).
- **Recording vs. live registration**: every committing outcome calls `onHotkeysChange?()` (`.clear` `:543`, `.binding applied` `:549`; `.cancel`/`.duplicate` correctly change nothing), and the shell's handler reloads and force-refreshes the menu, so a recording cannot leave the hotkeys unregistered.
- **Retain cycles / target-action**: every injected closure in `AppDelegate` uses `[weak self]` (`:41-48,139-146,669-690`); the `NSMenu.delegate` back-reference is weak and the status item is nil-guarded in both directions (`setupStatusItem`/`setIconHidden`); `RecorderButton`'s monitor closure captures `[weak self]` and is removed in `deinit`/`stopMonitoring`.
- **Threading**: the only non-Cocoa entry point (the Carbon callback) hops to the main queue before touching handlers (`HotkeyService.swift:296-308`); the permission poll, workspace observers and AX observers are all main-queue, so no AppKit call in this slice happens off the main thread.
- **Permission explainer**: single-button ask with a self-closing promise, `prompt: false` TCC registration so Tiled appears in the pane without a system dialog (`LiveWindowGateway.swift:571-577`), and a live re-querying trust probe (`:647-648`) so the 1 Hz poll can actually observe the grant — all pinned by `PermissionWindowTests` / `SettingsPermissionButtonTests`.
- **`AppSettings`**: two boolean keys, no schema version needed, isolated-suite tests cover persistence and the "reopen does not clear the dismissal flag" contract.
- **Status-icon/menu refresh decision**: `refreshPlan` is pure and ordered correctly (icon redraw never rides the menu diff; an open menu defers both) and is pinned by `AppDelegateMenuTests`.

## Residual uncertainty (what static reading cannot decide)
- **Recorder vs. live hotkeys while armed**: I could not establish statically whether a swallowed keyDown (local monitor returning `nil`) also prevents the Carbon hot-key dispatch and the `NSApp.mainMenu` key equivalents from firing, since that depends on where `NSEvent` local monitors sit relative to the Carbon dispatcher inside `NSApplication.sendEvent`. If the Carbon path ran first, recording a combo that is currently registered for *another* slot would also tile a window before the duplicate is rejected.
- **F1's runtime trigger set**: which of the user's other apps register their shortcuts with `kEventHotKeyExclusive`, and whether WindowServer symbolic hot keys pre-empt apps silently, are environment facts; the finding rests on the header's documented contract for non-exclusive registration.
- **F3's delivery premise**: whether a closed Settings window leaves Tiled receiving keyDown events (no key window) is an AppKit runtime behavior; the *monitor remaining installed and armed* is certain regardless, which is the part the fix addresses.
- **TCC revoke→regrant**: whether live `AXObserver`s survive a revocation (relevant to F6's impact beyond the poll) cannot be decided by reading source.
- **Cross-slice note (outside my files, verified only by grep)**: `SettingsWindowController.windowDidResize` (`:230-234`) is an `NSWindowDelegate` method but no `window.delegate` assignment exists anywhere in `Sources/tiled` (grep: zero hits), so `shortcutsTab.buildSize` may stay stale across a live resize — worth handing to the settings-window reviewer rather than my slice.
- **Mutation-run interference**: `tools/mutation/mutate.py` rewrites `Sources/tiled` in place and restores from memory. The two of my files listed in `mutants.json` (`AppDelegate.swift` `refreshPlan`; `SettingsShortcutsTab.swift` `refreshBulkButtons`) read in their unmutated form, so I believe my snapshots are the real sources, but this is not provable from inside the session.