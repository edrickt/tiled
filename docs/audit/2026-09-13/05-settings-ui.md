# Menu bar model and settings UI - audit findings

## Summary (≤3 sentences)
I read all nine owned files plus the AppDelegate/HotkeyService/HotkeyBinding/TilingController seams they depend on, and found one always-visible text defect (the menu's status row composes "Layout:" twice), three medium behavior/UX defects, and four low-severity label/doc/test gaps. The recorder's park/duplicate/label promise from the README holds in code, the preview draws from the same `Slot.cells` source as the engine and its 3-column fold is geometrically exact, and I found no unbounded constraint ambiguity or retain cycle. Verdict: **BLOCK** on F1 (the status menu's orientation row is garbled in every state); everything else is OK with notes.

## Findings

### F1 - The status menu's "Layout:" row composes the same status line twice [High | High | code-defect]
- Location: Sources/tiled/MenuModel.swift:162-164, Sources/tiled/AppDelegate.swift:458 and 513-517
- Evidence:
```swift
            items.append(Item(
                title: "Layout: \(snapshot.layoutTitle) · \(snapshot.tiledWindows.count) tiled",
                isEnabled: false))
```
```swift
            layoutTitle: presentation.statusLine,          // AppDelegate.swift:458
...
        if sections.isEmpty {
            statusLine = "Layout: \(layoutForScreen(nil).title) · \(rows.count) tiled"
        } else {
            statusLine = sections.map(\.title).joined(separator: " + ")
        }
```
- Trigger: open the status menu in any trusted state. `MenuModel` wraps `layoutTitle` in `"Layout: … · N tiled"`, but `AppDelegate` fills `layoutTitle` with a string that is already a whole status line. With no tiled windows (the flat branch) the row reads **"Layout: Layout: Sixths · 0 tiled · 0 tiled"**; with one window on a named display it reads **"Layout: Built-in Retina Display · Sixths · 1 tiled · 1 tiled"**.
- Impact: the menu's orientation row — the one row that states layout and count — is visibly garbled in every state, and the count is printed twice. It is missed by tests because `MenuModelTests.swift:15/141` feed a bare `"Quarters"` and `AppDelegateMenuTests.swift:66` pins `monitorPresentation.statusLine` in isolation; nothing composes the two.
- Fix: give the composition to one owner. Smallest: `layoutTitle: controller.activeLayout.title` at AppDelegate.swift:458 (MenuModel already appends prefix and count) — but note the intent at AppDelegate.swift:510-512 to show the per-display line, so the alternative is MenuModel rendering `snapshot.layoutTitle` verbatim and dropping its own `"Layout: … · N tiled"` suffix. Either way add one test that feeds `monitorPresentation.statusLine` through `MenuModel.items`.

### F2 - "Untile N Windows" counts every canvas but untiles only the focused canvas [Medium | High | code-defect]
- Location: Sources/tiled/MenuModel.swift:270-272, Sources/tiled/AppDelegate.swift:447+465, Sources/tiled/TilingController.swift:825-831, 1231-1233, 859-861
- Evidence:
```swift
                items.append(Item(
                    title: MenuText.untileAllTitle(count: snapshot.tiledWindows.count),
                    action: .untileAll))
```
```swift
    var tiledWindowsInfo: [TiledWindowInfo] {
        allTiledWindowsInfo()      // every visible canvas (TilingController.swift:1231-1233)
    }
...
    func untileAll() {
        pruneDeadWindows()
        untileAll(in: focusedSpaceKey())   // one canvas only (TilingController.swift:825-830)
```
- Trigger: tile 2 windows on display 1 and 1 on display 2, then open the menu with display 1 focused: the row reads "Untile 3 Windows". Click it: only display 1's 2 windows are restored, and the notice that replaces it in the same menu says `"Untiled 2 windows."` (TilingController.swift:859-861).
- Impact: the bulk row's count contradicts its own action and the resulting notice, on the exact multi-display path the README (README.md:113-122) says is focused-canvas-scoped ("Untile All and Reset Splitters act on the focused canvas only").
- Fix: count the acted-on set (`controller.focusedTiledWindowsInfo.count`) or title the row for its scope ("Untile 2 Windows on This Display").

### F3 - A slot can be bound to Tiled's own fixed combo; nothing detects it and the warning blames another app [Medium | Medium | code-defect]
- Location: Sources/tiled/HotkeyBinding.swift:226-229, Sources/tiled/HotkeyService.swift:209/223/237/251 vs 263-279, Sources/tiled/SettingsShortcutsTab.swift:544-556, Sources/tiled/MenuText.swift:47-53
- Evidence:
```swift
    func duplicates(of candidate: HotkeyBinding, ignoring ignored: Slot) -> [Slot] {
        guard candidate.keyCode != nil else { return [] }
        return Slot.allCases.filter { $0 != ignored && binding(for: $0) == candidate }
    }
```
```swift
        for slot in Slot.allCases {           // AFTER evict/expand/settings/undo registered (lines 209-260)
            ...
                failedSlots.append(slot)      // HotkeyService.swift:263-278
```
- Trigger: with the recorder armed, press ⌥⇧⏎ (or ⌥⇧⌫, ⌃⌥⇧⌘Z, ⌃⌥⇧⌘, — all accepted, since `HotkeyRecorder.outcome` needs only one modifier). `HotkeyStore.apply` finds no slot conflict, stores it, `hotkeys.reload()` re-registers the fixed combos first, and the slot's registration loses.
- Impact: the slot is dead and the tab/menu report "**⌥⇧⏎ is already used by another app**; “Top Left” has no hotkey." — a false owner (it is Tiled's own Expand). The duplicate detector is slot-vs-slot only; the reserved fixed combos are invisible to it.
- Fix: include the four fixed bindings in the duplicate check (a small reserved table next to `HotkeyService.expandBinding`) and word the conflict as "Tiled's own Expand shortcut", or refuse them in the recorder. Add a `HotkeyStore` test for slot-vs-fixed.
- Confidence note: the code facts are certain; the exact Carbon behaviour (registration of a duplicate combo inside one process failing rather than double-dispatching) needs a live check.

### F4 - An armed recorder is never disarmed by a mouse click or by closing the window, so its key monitor keeps swallowing keys [Medium | Medium | code-defect]
- Location: Sources/tiled/RecorderButton.swift:57-71, 134-139; Sources/tiled/SettingsShortcutsTab.swift:498-517; Sources/tiled/SettingsWindowController.swift:100-113 and 91; Sources/tiled/HotkeyRecorder.swift:41-53
- Evidence:
```swift
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.routeRecordedEvent(event)
        }
```
```swift
        for (slot, button) in recorderButtons where button.isRecording && button !== sender {
            button.showBinding(hotkeyStore.binding(for: slot))     // only a *recorder* click disarms another
        }
```
- Trigger: click the Top Left recorder (armed, title "Press shortcut…"), then with the mouse switch to the General tab, or just close the Settings window (`isReleasedWhenClosed = false`, SettingsWindowController.swift:91, and `recorderButtons` still holds the button, so the monitor is never removed). The tab's only disarm paths are `reload()` (called from `show()`), a recorder click, or Tab/Esc/⌫/a decisive combo (`HotkeyRecorder.shouldPassThrough` passes only *unmodified* navigation keys).
- Impact: with the recorder armed and its view off-screen, every non-pass-through keyDown in the app is consumed — ⌘Q, ⌘W and ⌘, do nothing (the monitor runs before menu key equivalents), and a decisive combo such as ⌥⇧⌘T silently rewrites the hidden slot's binding with no visible feedback beyond a conflict line nobody can see. The comment at RecorderButton.swift:83 claims "the button disarms via resignFirstResponder's focus reset"; no such override exists.
- Fix: disarm on `resignFirstResponder`/`viewDidMoveToWindow`(nil window)/`NSWindow.didResignKey`/close (or have `SettingsWindowController` disarm on close), and consider passing ⌘-modified keys through while armed.
- Confidence note: that the monitor swallows plain app keyDowns is certain from the code; that it also intercepts menu key equivalents is the AppKit behavior I could not execute here.

### F5 - The status icon's VoiceOver description reports lit cells as occupied slots [Medium | High | code-defect]
- Location: Sources/tiled/StatusIcon.swift:43-49, Sources/tiled/AppDelegate.swift:331-335
- Evidence:
```swift
    static func filledCells(
        layout: LayoutKind, occupants: [Slot: WindowID]
    ) -> [Slot] {
        cells(for: layout).filter { cell in
            occupants.keys.contains { $0.overlaps(cell) }
        }
```
```swift
        let total = StatusIcon.cells(for: snapshot.layout).count
        return "Tiled \(snapshot.layout.title) layout, "
            + "\(snapshot.filled.count) of \(total) slots occupied"
```
- Trigger: tile a single window into Left Half (`StatusIconTests.swift:50-55` proves `filledCells` returns two cells) and read the status item. VoiceOver announces "Tiled Quarters layout, **2 of 4 slots occupied**"; one Left Third in sixths reports "2 of 6 slots occupied".
- Impact: the spoken occupancy overstates reality for halves, thirds and two-thirds — i.e. for most slots a user can occupy — and the description itself has no test (it is a private function in AppDelegate).
- Fix: count distinct occupants (`Set(occupants.values).count`, exposed on the snapshot) or reword to "…, 2 of 4 cells covered".

### F6 - The undo row calls every chapter an eviction [Low | High | code-defect]
- Location: Sources/tiled/MenuText.swift:9-11, Sources/tiled/MenuModel.swift:265-268, Sources/tiled/TilingController.swift:84-87
- Evidence:
```swift
    static func undoDisplacementTitle(evictedCount: Int) -> String {
        evictedCount == 1
            ? "Restore 1 Evicted Window" : "Restore \(evictedCount) Evicted Windows"
    }
```
```swift
    var evictedCount: Int { focusedCanvas().undoStack.last?.snapshot.count ?? 0 }
```
- Trigger: perform a swap (nobody is evicted, two entries are snapshotted — PlanExecutor.swift:226-275), or a layout switch (windows are *untiled*, not evicted — TilingController.swift:851-861), or a drag-out whose chapter is a reflow — then open the menu.
- Impact: the row says "Restore 2 Evicted Windows" after a swap and "Restore 3 Evicted Windows" after a switch, contradicting CONTEXT.md's distinction between Eviction, Swap, Reflow and Untile; the README calls the same key "Undo the last displacement".
- Fix: neutral wording ("Undo Last Displacement (2 windows)" / "Restore 2 Windows") in `MenuText.undoDisplacementTitle`.

### F7 - The first-run text (README and the Welcome tab's fallback) teaches ⌥⇧U for quarters Top Left [Low | High | doc-gap]
- Location: README.md:76, Sources/tiled/SettingsWelcomeTab.swift:84
- Evidence:
```swift
        let topLeft = hotkeyStore.binding(for: .topLeft).label ?? "\u{2325}\u{21E7}U"
        ...  "2. Press \(topLeft) to tile it top-left.\n" ...
```
- Trigger: README.md:76 ("press ⌥⇧U to tile it top-left") is wrong against the README's own tables (⌥⇧U is *Top left sixth*; quarters Top Left is ⌥⇧⌘U). In the app the same wrong combo is the fallback whenever Top Left is disabled (⌫ / Disable all): reopen the guide from the menu and step 2 says "Press ⌥⇧U to tile it top-left".
- Impact: following the documented first-run instruction tiles the top-left *sixth*, which on a quarters canvas is a layout switch that untiles every window (reversible, but exactly the surprise the guide exists to prevent).
- Fix: use the quarters default (`HotkeyStore.defaultBinding(for: .topLeft).label`) as the fallback, or omit the combo when the slot is disabled; correct README.md:76.

### F8 - The permission-warning copy is duplicated five times across the three tabs [Low | High | code-defect]
- Location: Sources/tiled/SettingsGeneralTab.swift:81 and 188-189, Sources/tiled/SettingsShortcutsTab.swift:79 and 239-240, Sources/tiled/SettingsWelcomeTab.swift:66
- Evidence:
```swift
        let warningText = NSTextField(wrappingLabelWithString:
            "Tiled can't see or move windows: Accessibility permission is off.")
```
```swift
                        ? "Accessibility permission granted; tiled can see and move windows now."
```
- Trigger: any later edit to one copy; the copies have already drifted — the grant announcement lowercases the product name ("tiled can see…") while the label and every other string says "Tiled".
- Impact: three tabs can teach three different sentences for the same state, and the VoiceOver announcement can differ from the visible label; these strings sit outside `MenuText`, the module the codebase uses for exactly this purpose.
- Fix: hoist both strings (warning + granted announcement) into `MenuText` or a new `SettingsText` and use them from all three tabs.

### F9 - Bulk enable/disable computes its conflict banner from the pre-toggle registration state [Low | Medium | code-defect]
- Location: Sources/tiled/SettingsShortcutsTab.swift:399-405 (disable branch; 396-402 for the enable branch), 216-227, 170-179
- Evidence:
```swift
            // The bulk button that triggered this lives in the old view.
            rebuildContent(restoringFocusTo: "bulk-\(layout.rawValue)")
        }
        onHotkeysChange?()      // re-registration happens after the rebuild+reload
```
- Trigger: a slot whose global hotkey lost registration (another app owns it) shows its warning in the tab; click "Disable all 11" (sixths). `rebuildContent` → `reload()` → `surfaceHotkeyFailures()` reads `failedSlotsProvider` *before* `onHotkeysChange?()` triggers `hotkeys.reload()`, so the banner for now-disabled slots stays on screen; the symmetric direction (enabling a section whose restored combo is taken) shows no banner until the next `show()`.
- Impact: the tab contradicts the status menu (which is refreshed after re-registration) about the same state, and the README's "that slot shows a warning" promise is stale in one of the two surfaces.
- Fix: call `onHotkeysChange?()` before `rebuildContent(...)`, or re-run `surfaceHotkeyFailures()` after it.

## Verified-clean areas (what I checked and why it held)
- **Menu structure vs README** (MenuModel.swift:169-288): the tile submenu's active-layout-only groups (`Quarters · Quads`/`Halves`, `Sixths · Corners`/`Thirds`/`Two-Thirds`), the single honest switch row with `disabledReason` + `setAccessibilityHelp`, expand/evict rows carrying the fixed combo, the manage rows' three-action submenus, the pluralized undo/untile rows, the splitter backup toggle, the untrusted block with "Open System Settings", and the always-last app section all exist as documented (README.md:20-95, 113-160) and are pinned per-case in `MenuModelTests`. `autoenablesItems = false` (AppDelegate.swift:427) means every `isEnabled` is honoured.
- **The "keeps the old binding" promise** (README.md:88-91): `HotkeyStore.apply` refuses duplicates without writing (HotkeyBinding.swift:217-222) and `finishRecording`'s `.duplicate` branch re-shows the stored binding and names the owners (SettingsShortcutsTab.swift:560-570); `⌫` parks the previous combo first (524-543) so the clear is reversible.
- **Bulk park/restore algebra** (SettingsShortcutsTab.swift:360-405): disable parks each enabled combo, enable restores parks and clears them, a post-disable edit wins over a stale park and is reported, defaults fill slots with no park — matching `FeedbackAndRecorderTests` (203-320) and the tooltips' wording. Reset uses separate `resetBackupHotkey.*` keys, so it cannot corrupt a section park.
- **Preview draws from the engine's single geometry source** (SlotPreviewView.swift:52-63 over `slot.cells`, derived from `SlotGeometry` in Layout.swift:59-83): a slot cannot disagree with its picture, and the 3-column fold (`col>=3 ? 2 : min(col,1)`) is geometrically exact given the strips' widths in Layout.swift:29-34 (strip 0 = [0,1/3), strips 1+2 = [1/3,2/3), strip 3 = [2/3,1]) — the quarters 4-column display lands the same slot boundaries on the same halves the engine uses at the default `columnSplit`.
- **Preview orientation**: `SlotPreviewView` does not override `isFlipped` (default false), and `draw` inverts the row index (`1 - row`, line 99) exactly so an unflipped bottom-up context still paints row 0 at the top — self-consistent.
- **Auto Layout**: the scroll pattern (flipped `TopAnchoredStackView` as document view, leading/trailing/top pins and a deliberate missing bottom pin, per the comments at GeneralTab.swift:60-66) plus the wrapping-label compression resistance and one explicit trailing cap per label row give every row a determinate width and intrinsic height; I found no constraint pair that can conflict, and 400×300 minimum window vs. 24pt insets leaves ~350pt for the longest row ("Disable all 11", "Bottom Right Sixth").
- **Accessibility of the controls**: recorder label/value/`recording` state (RecorderButton.swift:34-36, 47-55, 61-66; tested), disclosure header exposing `collapsed`/`expanded` as its value (SettingsShortcutsTab.swift:316-318), bulk buttons naming their scope, Welcome previews exposed as images with a label (SettingsWelcomeTab.swift:119-124), disabled switch rows carrying both tooltip and accessibility help (AppDelegate.swift:568-575), and focus restored to the control that triggered a rebuild (SettingsShortcutsTab.swift:428-433).
- **Lifecycle/retain cycles/main thread**: one controller instance reused for every open (AppDelegate.swift:697-717), `show()` reloads values and re-probes trust, `isReleasedWhenClosed = false` + `setFrameAutosaveName` for reopen-in-place, the permission poll refreshing an already-open window (SettingsWindowController.swift:263-268), every stored closure capturing `[weak self]`/`[weak sender]`, the key monitor removed in `deinit`/`stopRecording`, and feedback hopping to the main queue (AppDelegate.swift:41-43).
- **Fixed combos register first** (HotkeyService.swift:209-260 before 263) — the ordering itself is deliberate and correct; F3 is about the missing self-conflict detection, not the order.
- **README's focused-canvas claims**: `Untile All` and `Reset Splitters`/`Restore Previous Splitters` do resolve the focused canvas (`focusedSpaceKey()`), matching README.md:122 and:156; the mislabel in F2 is in the row's count only.

## Residual uncertainty (what static reading cannot decide)
- **Mutation run in flight**: `tools/mutation/mutants.json` lists one mutant in my slice ("bulk labels not refreshed after a recorder commit", SettingsShortcutsTab) and one in AppDelegate (the `refreshPlan` expression). Both sites read as the *original* text right now (`refreshBulkButtons()` is present at SettingsShortcutsTab.swift:575 and `refreshPlan` returns `iconChanged, menuChanged`), and nothing I cite is a mutant target — but no result here can be re-confirmed by a build while that run is rewriting sources.
- **AppKit behaviours I cannot execute**: (a) whether a local keyDown monitor really intercepts menu key equivalents (F4's ⌘Q/⌘W symptom); (b) `SettingsWindowController.windowDidResize` (SettingsWindowController.swift:272-276) has neither `@objc` nor any `NSWindowDelegate` conformance in the target, so under Swift 4+ `@objc` inference AppKit cannot call it — I could not confirm whether that method is dead (its stated purpose, keeping `shortcutsTab.buildSize` current, is also harmless because the rebuilt root view carries `.width/.height` autoresizing and NSTabView re-frames item views); (c) whether Carbon rejects a duplicate `RegisterEventHotKey` inside one process (F3's mechanism, not its existence).
- **Untested surfaces**: `SettingsWindowController`, `WelcomeTab`, `SlotPreviewView` and `TopAnchoredStackView` have no tests at all (grep of Tests/), `GeneralTab`/`ShortcutsTab` only via the permission-row and recorder/bulk tests, and `statusIconDescription` is private. That is why F1 (a pure composition seam) and F5 (spelling) survived 530 green tests.
- **GUI-only claims I could not verify**: that the Welcome previews read as "Top Left covers the top-left quarter" at 160×100, and the dark-mode legibility notes in SlotPreviewView/WelcomeTab comments (they are reasoned, not measured here).