# README.md / CONTEXT.md documentation truth + dead code — audit findings

## Summary (<=3 sentences)
Every hotkey in the README matches the registered Carbon bindings exactly (all 17 slot combos plus the 4 fixed combos), and the "530 tests" and "40 cases" numbers both check out to the exact count (530 `func test` methods; 40 PASS/FAIL sites in `tools/repro/suite.swift`). Six doc-gaps remain where README text no longer matches the code it describes (roadmap hotkey count, the "every shortcut is a menu item" promise, the first-run Welcome combo, a quoted menu notice, the live-suite coverage list including drag-out, and CI "every push"), plus one Tiling-rules bullet contradicted by the re-house rule documented two sections earlier. Dead code exists in four places (one fully unreferenced accessor, two unreferenced `AppDelegate` title helpers, one unreferenced `DragTracker` overload, and two properties only tests read); no TODO/FIXME/HACK markers, no commented-out code blocks, and no dangling file references were found.

## Findings

### F1 - "Tiling rules" states a general rule (evicted windows are restored) that the code re-houses around [Low | Confidence High | doc-gap]
- Location: README.md:97 (compare README.md:63, PlanExecutor.swift:314-319, Layout.swift:551)
- Evidence:
  - README.md:96-99: `- Tiling a window into a slot **evicts** any window occupying an overlapping` / `slot. Evicted windows are restored to their pre-tile frames.` / `- Two quads occupied on one side + the half key → both quads are evicted.` / `- A half occupied + a quad key on that side → the half window is evicted.`
  - Code (PlanExecutor.swift:314-319): `if evicted.count == 1, !execution.isExpanded(evicted[0]),` / `let home = state.rehousingHome(evicting: evicted[0], for: slot)` / `{ rehouse = (evicted[0], home) }`
  - README.md:63 documents the exception in another section: `its slot. When a tiling request evicts a window and leaves exactly one whole slot free, the victim re-tiles into that slot instead`
- Trigger: quarters canvas, window B tiled in Top Left, requester A untiled; A requests Left Half. `plan` returns `.tile(evicting: [B])`; `rehousingHome` finds `rightHalf` as the exactly-free slot, so B is moved to Right Half and is never restored to its pre-tile frame.
- Impact: the section titled "Tiling rules" — the place a reader (or a test author) treats as normative — is false for a normal-path request: the victim keeps its tiling instead of being restored. The two worked examples are accurate, which makes the generalisation look verified.
- Fix: replace README.md:97 with the re-house-aware statement (or add "unless it is the lone evictee and exactly one whole slot is left free, in which case it re-tiles — see Evict").

### F2 - Roadmap "17 global hotkeys" undercounts what the app registers (and what the README's own tables document) [Low | Confidence High | doc-gap]
- Location: README.md:266 (compare HotkeyService.swift:51, 71, 91, 99, 216-232)
- Evidence:
  - README.md:266: `- [x] 17 global hotkeys (Carbon RegisterEventHotKey) + clickable menu equivalents`
  - HotkeyService.swift:51 `static let expandHotkeyID: UInt32 = 998`, :71 `evictHotkeyID`, :91 `settingsHotkeyID`, :99 `undoHotkeyID` — each followed by a `RegisterEventHotKey` call in `registerHotkeys()`; then :216-232 `for slot in Slot.allCases { ... RegisterEventHotKey(...) }` over 17 slots.
- Trigger: count registrations — 17 slot combos (6 quarters + 11 sixths, `Slot.allCases`) + 4 fixed combos = 21 registered global hotkeys whenever no slot is disabled. The README's own tables document 21 rows (README.md:14-22 quarters, 25-41 sixths incl. settings/undo at 40-41, 43-49 expand, 56-60 evict).
- Impact: a stated, checkable number that contradicts both the code and the same file; readers auditing the product's surface get the wrong count.
- Fix: README.md:266 → "21 global hotkeys (17 slot combos + fixed expand/evict/settings/undo)".

### F3 - "Every shortcut also exists as a menu item under Tile Focused Window" is false for the inactive layout [Low | Confidence High | doc-gap]
- Location: README.md:11 (compare MenuModel.swift:174-217, AppDelegate.swift:569-587)
- Evidence:
  - README.md:10-12: `stays exactly where it is). Every shortcut also exists as a menu item` / `under **Tile Focused Window** in the menu bar menu.`
  - MenuModel.swift:174-197: `if snapshot.activeLayout == .quarters { ... for slot in SlotPresentation.quartersQuads { tileChildren.append(tileItem(slot, binding)) } ... tileChildren.append(Item(title: "Switch to Sixths (focused window → Top Left Sixth)", ...))`
- Trigger: quarters active; the Tile Focused Window submenu lists the 6 quarters slots plus one *switch* row. The 11 sixths combos (⌥⇧U/I/O/M/,/./J/K/L/H/;) have no row; the switch row does not merely switch — it tiles the focused window into Top Left Sixth (AppDelegate.swift:732 → `controller.handle(slot: .sixthTopLeft)`), which is a destructive layout switch. Symmetrically for sixths active.
- Impact: the documented one-click equivalent for half the shortcuts does not exist; the substitute row has different, destructive semantics. The app's own guide repeats the same overclaim (SettingsWelcomeTab.swift:87 `"Every combo lives under Tile Focused Window in the menu bar menu."`), so both sides need the same wording fix.
- Fix: scope the sentence ("every shortcut in the layout currently in use"), or list the switch row's differing behaviour alongside it.

### F4 - The quoted menu notice does not exist in the code (and the quotation is never closed) [Low | Confidence High | doc-gap]
- Location: README.md:134 (compare PlanExecutor.swift:182-186)
- Evidence:
  - README.md:134-135: `it ("Switched to Sixths · 3 windows untiled. Undo (⌃⌥⇧⌘Z) is one step,` / `from anywhere. Safe to explore: destruction is always reversible.`
  - PlanExecutor.swift:183-186: `outcome.notice =` / `"Switched to \(slot.layout.title) \u{00B7} \(noun) untiled. " +` / `"Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo."`
- Trigger: read the README quote, then switch layouts and read the menu's notice row. The second sentence differs ("Undo … is one step, from anywhere. Safe to explore: destruction is always reversible." vs "Press ⌃⌥⇧⌘Z to undo.").
- Impact: README presents a verbatim user-visible string the product no longer produces; the missing closing `"` also breaks the sentence/bullet structure of that rule.
- Fix: update the quoted notice to the current string (or drop the quotation) and close the parenthesis.

### F5 - First-run guide combo in the README (⌥⇧U) differs from the app's Welcome tab (the ⌥⇧⌘U default) and from the README's own preview claim [Low | Confidence High | doc-gap]
- Location: README.md:76 (compare SettingsWelcomeTab.swift:84-88, HotkeyService.swift:16-18, README.md:28, 76-78)
- Evidence:
  - README.md:76-78: `First launch opens Settings on a Welcome tab: focus any window, press ⌥⇧U` / `to tile it top-left, and you're going, with a miniature preview showing` / `what Top Left covers.`
  - SettingsWelcomeTab.swift:84-87: `let topLeft = hotkeyStore.binding(for: .topLeft).label ?? "\u{2325}\u{21E7}U"` … `"2. Press \(topLeft) to tile it top-left.\n"` — the default `.topLeft` binding is quarters (README.md:17 `| ⌥⇧⌘U   | Top left |`), so the app says ⌥⇧⌘U.
  - README.md:28 lists `⌥⇧U` as `Top left sixth` (sixths layout), while the preview the README points at is the quarters one (SettingsWelcomeTab.swift:109 `SlotPreviewView(highlighted: [.topLeft], …)`; :121 `"Preview: Top Left covers the top-left quarter"`). A fresh canvas starts in sixths (`Layout.swift:459-465 occupantBySlot.keys.first.map(\.layout) ?? .sixths`), so ⌥⇧U lands in the *sixth*, not the quarter the preview shows.
- Trigger: fresh install, follow README.md:76 → the window lands in Top Left Sixth, while the README's "what Top Left covers" preview (quarter) and the app's own step 2 (⌥⇧⌘U) describe something else.
- Impact: the first-run teaching path in the docs sends the user somewhere different from both the app's own instructions and the accompanying picture.
- Fix: make README.md:76 quote the app's own text — the default `.topLeft` binding (⌥⇧⌘U), i.e. "press the Top Left shortcut".

### F6 - Live-suite coverage list claims "drag-out" end to end; suite.swift never drags a title bar past the untile distance [Low | Confidence High | doc-gap]
- Location: README.md:202-206 (compare tools/repro/suite.swift, DragTracker.swift:122)
- Evidence:
  - README.md:202-206: `host` app and drives real clicks, drags, and global hotkeys: 40 cases` / `covering the quarters family end to end (tiling, edge drags with` / `per-column row independence, clamping, screen edges, eviction, swap,` / `re-house, undo, drag-out, closes)`
  - Every drag in suite.swift is an edge drag (`dragEdge(`) or the deliberate programmatic move S11: `suite.swift:536 simulateMove("HOSTA", by: CGSize(width: 60, height: 40))` (60pt + one tick ⇒ below `DragTracker.swift:122 private static let untileDragDistance: CGFloat = 100` and `// S11 - moving a tiled window is inert (v1), grid intact`).
- Trigger: search suite.swift for a title-bar drag with distance > 100pt across ≥2 ticks — there is none (`grep drag` yields only `dragEdge` calls, S7/S11/S19, and the S16-S20 `evict()` hotkey uses).
- Impact: the README credits the live E2E layer with drag-out coverage it doesn't have; drag-out is covered only by the fake-gateway unit tests (DragTrackerTests.swift:433, ControllerGatewayTests.swift:236). Anyone trusting the README's layer split will not re-check drag-out against a real app.
- Fix: drop "drag-out" from README.md:205, or add a title-bar drag case to suite.swift.

### F7 - Verification summary - CI claim broader than the workflow trigger [Low | Confidence High | doc-gap]
- Location: README.md:261 (compare .github/workflows/tests.yml:3-7)
- Evidence:
  - README.md:261: `CI (`.github/workflows/tests.yml`) runs the unit suite on every push and PR.`
  - tests.yml:3-7: `on:` / `  push:` / `    branches: [master]` / `  pull_request:` / `  workflow_dispatch:`
- Trigger: push a branch that is not `master` and has no PR open — no CI run.
- Impact: docs promise gating that only exists for `master` pushes and PRs.
- Fix: "on pushes to master and on every PR", or widen the trigger.

### F8 - `TilingController.focusedTiledWindowsInfo` is unreferenced anywhere in the repo [Info | Confidence High | code-defect (dead code)]
- Location: Sources/tiled/TilingController.swift:1236-1248
- Evidence: `/// Tiled windows on the focused canvas (tile submenu scope).` / `var focusedTiledWindowsInfo: [TiledWindowInfo] {` / `let key = focusedSpaceKey()` … (a repo-wide grep for `focusedTiledWindowsInfo` matches only this declaration; the menu path uses `tiledWindowsInfo` → `allTiledWindowsInfo()` at TilingController.swift:1231-1233 and AppDelegate.swift:450)
- Trigger: none required — the accessor has no caller in `Sources/` or `Tests/`.
- Impact: ~13 lines of orphaned, comment-documented API; the "tile submenu scope" it advertises is not what the submenu uses (MenuModel renders per-window rows plus disabled section headers from `tiledWindowsInfo`).
- Fix: delete it, or wire the tile submenu's scope to it if the per-canvas split is still intended.

### F9 - Two `AppDelegate` title helpers are unreferenced (the menu builds those titles in `MenuModel`) [Info | Confidence High | code-defect (dead code)]
- Location: Sources/tiled/AppDelegate.swift:604-606 and 609-611
- Evidence: `private var undoDisplacementTitle: String {` / `MenuText.undoDisplacementTitle(evictedCount: controller.evictedCount)` / `}` and the same shape for `untileAllTitle`; the live path is MenuModel.swift:266 `title: MenuText.undoDisplacementTitle(evictedCount: snapshot.evictedCount)` and :271 `title: MenuText.untileAllTitle(count: snapshot.tiledWindows.count)`
- Trigger: none — a repo-wide grep for either name matches only the two definitions (plus `MenuText`/`MenuModel` usages of the underlying `MenuText` functions).
- Impact: dead code in the largest file, and a second, drifting source of truth for menu wording next to the one actually rendered (Swift warns on unused local variables, not on unused private computed properties, so it can survive indefinitely).
- Fix: delete both properties.

### F10 - Legacy single-grid `DragTracker.restoreDividers(_:)` has no callers; `resetDividers()` is test-only [Info | Confidence High | code-defect (dead code)]
- Location: Sources/tiled/DragTracker.swift:288-290 (and 271-274)
- Evidence: `func restoreDividers(_ saved: GridLayout) {` / `grid = saved` / `}` sits beside the live per-canvas form at :293 `func restoreDividers(_ saved: GridLayout, for space: TilingSpaceKey)`, which is the one called from TilingController.swift:959 `tracker.restoreDividers(backup, for: space)`. The only caller of the no-arg `resetDividers()` is a test (DragTrackerTests.swift:634); production resets through `tracker.resetDividers(for: space)` (TilingController.swift:936).
- Trigger: none — grep for `restoreDividers` across `Sources/` and `Tests/` returns only the two declarations, one live call site, and the mutant table's per-space strings (tools/mutation/mutants.json:41).
- Impact: leftover surface from the single-canvas→per-canvas splitter migration; the one-arg `grid` fallback remains reachable only when `spaceOf` returns nil, so the no-arg `restoreDividers` is pure baggage that also keeps `grid` looking load-bearing.
- Fix: delete the one-org overload; if `resetDividers()` is only a test convenience, note that the per-space form is the production path.

### F11 - `MenuModel.Item.isHeader` is written but never read in production; `HotkeyBinding.isEnabled` is read only by tests [Info | Confidence High | code-defect (dead code)]
- Location: Sources/tiled/MenuModel.swift:36, Sources/tiled/HotkeyBinding.swift:10
- Evidence: MenuModel.swift:36 `var isHeader = false` (set at :175, :179, :199, :203, :207, :244) — read only at MenuModelTests.swift:156, :179, :322, :339. The renderer ignores it: AppDelegate.swift:573-574 `item.isEnabled = model.isEnabled` / `if let reason = model.disabledReason, !model.isEnabled {`. HotkeyBinding.swift:10 `var isEnabled: Bool { keyCode != nil }` — read only at HotkeyBindingTests.swift:160, :203; the service guards on the binding itself (HotkeyService.swift:216 `guard let keyCode = binding.keyCode else { continue }`).
- Trigger: none — both symbols are unreferenced by `Sources/` outside their own file.
- Impact: `isHeader` promises a header/disabled-row distinction the UI does not implement (headers and disabled rows render identically), so tests pin semantics production doesn't honour; `isEnabled` is a test-only accessor.
- Fix: either use `isHeader` in `makeItem` (e.g. bold + disabled section label) or drop it and assert headers via `isEnabled` in the tests; delete `isEnabled` or use it at the `HotkeyService` guard.

## Verified-clean areas (what I checked and why it held)
- **Hotkey tables vs registered bindings (all 21 combos).** Every README row matches: quarters `⌥⇧U/O/M/./J/L` (README.md:17-22) ⇔ `HotkeyService.swift:7-14` `case .quarters: UInt32(shiftKey | optionKey | cmdKey)` with `:18-33` (`topLeft`→U, `topRight`→O, `bottomLeft`→M, `bottomRight`→Period, `leftHalf`→J, `rightHalf`→L); sixths `⌥⇧U/I/O/M/,/./J/K/L/H/;` (README.md:28-38) ⇔ the same keycode switch (`sixthTopMiddle`→I, `sixthBottomMiddle`→Comma, `sixthsRightTwoThirds`→Semicolon); fixed combos `⌥⇧⏎` (README.md:48 ⇔ HotkeyService.swift:47-56), `⌥⇧⌫` (README.md:60 ⇔ :63-72), `⌃⌥⇧⌘,` (README.md:40 ⇔ :73-82), `⌃⌥⇧⌘Z` (README.md:41 ⇔ :83-94). Routing is table-tested (`route(forHotKeyID:slotByID:)` :108-124, HotkeyServiceTests.swift:90), and every one of the 17 `Slot` cases has a keycode (no `default` arm), so no documented combo can be a dead key while the menu advertises it.
- **"530 tests".** Counted statically per file: exactly 530 `func test` declarations across the 34 test files (`Tests/tiledTests/*.swift`), matching README.md:193. (Largest contributors: GridLayoutTests 53, TilingStateTests 46, ReflowTests 33, ControllerBulkOperationTests 31, DragTrackerTests 28, LayoutSwitchTests 28, ControllerGatewayTests 26, MenuModelTests 24.) I could not *run* the suite (mutation run in flight), so "~2s" and greenness remain unverified — see residual uncertainty.
- **"40 cases" live suite.** tools/repro/suite.swift:34 `verify(...)` call sites, one of which is inside `for i in 1...3` (:578), plus four manual `pass += 1` / `fail += 1` blocks (:503, :539, :551, :651) = exactly 40 PASS/FAIL lines. The stated sixths scope (layout switch, geometry, per-third rows, two-thirds hidden divider — README.md:206-208) matches S19-S20; "Sixths boards stay disjoint" matches the suite's placements.
- **Mutation-tool description (README.md:250-260).** mutate.py:44-47 patches in place and restores via `finally: open(full, "w").write(source)` ("uncommitted work is safe" ✓), :47-57 prints `"~10s each"` per mutated file, STALE detection when the `old` string count ≠ 1, `--list` at :38-41, and :92 `return 1 if survivors else 0`. Three randomly spot-checked mutant `old` strings are present verbatim in the current tree (TilingController.swift:81 `fileprivate static let undoDepth = 5`, TilingController.swift:1642, Layout.swift:551), so the table is not visibly stale.
- **First-run flow promises.** "First launch opens Settings on a Welcome tab" (README.md:76) ⇔ AppDelegate.swift:68-73 (`let firstRun = !settings.didDismissWelcome` → `showSettings(selecting: .welcome)`) with the tab inserted at index 0 by SettingsWindowController.swift:170-176 and selected by identifier at :111-122; "reopen it anytime … → Tiled Guide" ⇔ MenuModel.swift:283 `Item(title: "Tiled Guide", action: .showGuide)` → AppDelegate.swift:710-713; "Esc keeps the old one, ⌫ disables that slot" ⇔ HotkeyRecorderTests.swift:22-46; conflict naming/old-binding retention ⇔ SettingsShortcutsTab.swift:563-567; per-section Enable/Disable all ⇔ :288-331, :350-393.
- **"Quitting Tiled leaves your windows where they are" (README.md:185).** No `applicationWillTerminate` / `applicationShouldTerminate` exists anywhere in `Sources/` (grep for `Terminate` matches only `NSWorkspace.didTerminateApplicationNotification` in LiveWindowGateway.swift:118); both quit rows go straight to `NSApplication.terminate` (AppDelegate.swift:104, MenuModel.swift:285), so nothing rearranges windows on the way out.
- **Evict / reflow / undo / re-house bullets (README.md:62-73)** ⇔ `PlanExecutor` re-house condition (:314-319), `Layout.reflow` (:589-640, rightmost-wins tie-break at :612-627), `Layout.rehousingHome` (:550-559), undo chapter per canvas (`CanvasState.undoStack`, DisplaySpace.swift:73-76). The "~100pt" drag-out rule (README.md:109) ⇔ DragTracker.swift:122 + :431 `guard distance > Self.untileDragDistance, drag.ticks >= 2`.
- **Live-resizing bullets (README.md:157-167)** ⇔ per-column/per-third row splitters (`GridLayout` :211-227), the two-thirds midpoint rule (`twoThirdsSymmetry` :370-385), deferred neighbour push until mouse-up (`mouseLifted` DragTracker.swift:532), and `Reset Splitters`/`Restore Previous Splitters` (MenuModel.swift:274-276, AppDelegate.swift:755-771).
- **Canvas / display bullets (README.md:119-145)** ⇔ `TilingSpaceKey`/`CanvasState` (DisplaySpace.swift:42, :70), `staleSpaces` + `isVisible` (TilingController.swift:148, :1642), per-screen canvas identity via CoreGraphics display number (DisplaySpace.swift:22-24), refusal surfacing into the menu (AppDelegate.swift:625-640 + MenuText.refusedAnnouncement).
- **Roadmap checkboxes.** Spot-checked each `[x]`: `LSUIElement` (scripts/make-app.sh:31), `setActivationPolicy(.accessory)` (main.swift:4), drag-out, remappable shortcuts, per-Space layouts, visible failure states, display-change reassertion, closed-window cleanup ("5s tick plus 3s confirmation" README.md:236 ⇔ TilingController.swift:197-201 `pruneInterval: TimeInterval? = 5.0` / `deathConfirmation: TimeInterval = 3.0`). The two unchecked boxes are accurate: `[ ] Owned overlay resize handles` (zero `overlay` matches in `Sources/`) and `[ ] Gaps?`.
- **File/path references.** Every path named in README.md resolves: `scripts/make-app.sh`, `scripts/run-repro.sh`, `scripts/run-focus-loop.sh`, `tools/repro/{suite,driver,probe-spaces,multi-display-suite,window-lifecycle-repro,destroy-notification-probe}.swift`, `tools/repro/multi-display-checklist.md` (covers unplug/replug, rearrange, Mission Control as claimed), `tools/mutation/{mutate.py,mutants.json}`, `.github/workflows/tests.yml`. The multi-display suite does check the three claimed things (M1 same-slot coexistence, M2/M3 per-monitor moves, M4 splitter isolation) and nothing claimed for it is missing.
- **Test-suite composition.** README's "pure engine through `FakeWindowGateway`, with clocks, schedulers, and the display set injected; only a few live-screen identity checks touch AppKit" holds: DisplayIdentityTests.swift:85 / LiveGatewayMappingTests.swift:56-104 are the AppKit-touching ones; LiveGatewayMappingTests exercises only pure static helpers (`LiveWindowGateway.spaceID(from:)`, `displayID(...)`) — no AX (FakeWindowGateway provides `registerAccessibilityInterest()` at Tests/tiledTests/FakeWindowGateway.swift:25).
- **CONTEXT.md vocabulary vs code identifiers — no drift.** `CanvasState` (DisplaySpace.swift:70), `TilingSpaceKey` (DisplaySpace.swift:42), `GridBoundary` (Layout.swift:139, documented as the splitter's code name), `swap`/`reflow`/`rehousingHome` (Layout.swift:499-559, :589), `WindowHandle` (WindowGateway.swift:10), `PlanExecutor` (PlanExecutor.swift), `TileCell` as the shared 4×2 refinement (Layout.swift:23-32), `untileDragDistance` for Drag-out (:122), `twoThirdsSymmetry` for the hidden divider (:370). The CONTEXT rules I could falsify mechanically (`swap` requires a disjoint vacated tile; reflow is exact-or-empty and rightmost-wins; re-house needs exactly one free whole slot; expansion keeps the slot) all match the code and its tests.
- **Markers and dead markers.** Zero matches for `TODO|FIXME|HACK|XXX|for now` in `Sources/` and `Tests/`; zero lines that are commented-out code (`^\s*// *(let|var|func|if|return|guard|for|while|case|self\.)` in `Sources/` matches only English prose in comments).
- **`.impeccable/critique/`.** Dated, gitignored review artifacts about the Settings surface (`.gitignore:7` ignores `.impeccable/critique/*`, re-including exactly `2026-09-04T16-14-22Z__sources-tiled.md`), referenced by neither README.md nor CONTEXT.md; the one tracked file is a design critique whose P1 item (Enable-all preferring fresh edits over stale parks) matches the current code (SettingsShortcutsTab.swift:362-375), though its interior "355 tests pass" note is now stale against the 530-test suite.

## Residual uncertainty (what static reading cannot decide)
- **Timing and greenness.** No command was run (hard rule 1; a mutation run was rewriting `Sources/*.swift` in place), so "~2s" (README.md:193), the assertion that the 530 tests pass, and the live-suite/multi-display results are unverified here. The 530/40 counts are static counts, not a test-run report.
- **Toolchain claim.** "tested with Swift 6.2" (README.md:174) cannot be checked against the repo: Package.swift:1 is `swift-tools-version:5.9` and CI runs on `macos-14` (tests.yml:13), so nothing in-tree pins the toolchain the numbers came from.
- **Live-adapter latency figures.** "host app: ~3ms; Firefox: ~29ms" (README.md:246) are measurement results; the probe exists but the numbers are unreproducible from a static read.
- **Exhaustiveness of the dead-code sweep.** I checked every symbol I noticed plus targeted greps for plausible leftovers, but I did not do a whole-program reference analysis of the two 1000+ line files (TilingController.swift, LiveWindowGateway.swift); additional unused members could still hide there (and `swift build` warnings would be the cheap way to find them once the tree is quiet).
- **Menu rendering nuance for `isHeader`.** Whether AppKit visually distinguishes the disabled "section header" rows in practice (attributed titles, indentation) cannot be decided from `makeItem` alone; I only verified that no code path reads the flag, so any distinction would have to come from `title`/`isEnabled` alone.
- **The two unchecked roadmap boxes** (`Owned overlay resize handles`, `Gaps?`) are accurate as absences today, but the roadmap's intent is not something the code can confirm.