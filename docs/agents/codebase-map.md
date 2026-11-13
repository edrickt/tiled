# tiled codebase map

Verified against `e5bb550` (2026-11-12). Native macOS window manager: a SwiftPM executable (`main.swift` -> `AppDelegate`) that tiles windows into quarters or sixths with global hotkeys; the abstraction to learn first is the canvas (`TilingSpace`), one display's one Mission Control Space, driven by `TilingController` through the `WindowGateway` seam.

Maintenance: after adding, moving, or deleting a source file, update the File index and bump `Verified against` to the commit you checked.

## Orientation

- The app is menu-bar only (`.accessory`, no Dock icon), AppKit plus Carbon hotkeys plus the Accessibility API; no third-party dependencies.
- Entry point: `Sources/tiled/main.swift` (7 lines) creates `AppDelegate`; `applicationDidFinishLaunching` builds the launch plan, controller, hotkey service, menu bar, settings, and permission gate.
- Core abstractions: `TilingSpace` owns one canvas's occupancy, records, layout, splitters, undo chapters, notices, and placement pipeline; `TilingController` routes each action to the owning canvas and applies the returned outcome; `CanvasDirectory` is the only display plus Space resolver.
- OS seam: `WindowGateway` is the single interface to the window server; `LiveWindowGateway` is the only AX adapter. Everything else is platform-clean or AppKit presentation.
- Domain terms: `CONTEXT.md` is the glossary of record (its `_Avoid_` lists bind); `docs/adr/` explains the load-bearing decisions; `CODING_STANDARDS.md` is the review bar.
- Build shape: Swift 6.2 toolchain, `Package.swift` tools 5.9, macOS 13+, single target plus one test target; no Xcode project.
- Generated output: only `build/` (app bundle, `build/test.log`, live artifacts) and `.build/` (SwiftPM).
- The README publishes the unit-test count that `make check` enforces; change the count in `README.md` when tests change.

## Layers

| Layer | Path | Owns | Read when |
|---|---|---|---|
| App shell | `Sources/tiled/main.swift`, `Sources/tiled/AppDelegate.swift` | launch, permission gate, status-item host, settings and receipt presentation | lifecycle, launch, menu-bar wiring |
| Coordinator | `Sources/tiled/TilingController.swift` | event and action routing, canvas resolution, applying outcomes, pruning, focus and cursor observation | any user-visible action behavior |
| Canvas engine | `Sources/tiled/TilingSpace.swift`, `Sources/tiled/Layout.swift` | occupancy, tiling state, placement and reflow, write passes, undo chapters, splitters | tiling, layout, undo, reflow logic |
| OS seam | `Sources/tiled/WindowGateway.swift`, `Sources/tiled/LiveWindowGateway.swift` | handle identity, AX frames, observation, liveness, Spaces | anything touching the window server |
| Identity bookkeeping | `Sources/tiled/CanvasDirectory.swift`, `Sources/tiled/WindowRegister.swift`, `Sources/tiled/DisplaySpace.swift` | canvas table, stale marks, handle ids, death clock, display plus Space keys | display, Space, or handle bugs |
| Hotkeys | `Sources/tiled/HotkeyAction.swift`, `HotkeyBinding.swift`, `HotkeyService.swift`, `HotkeyActionRouter.swift`, `CarbonHotkeyEventRouter.swift`, `HotkeyRecorder.swift`, `ShortcutPark.swift` | Carbon registration, action routing, persisted bindings, recorder parsing, parked combos | remapping, registration, conflicts |
| Menu and status | `Sources/tiled/MenuModel.swift`, `MenuReads.swift`, `MenuText.swift`, `MenuBarPresenter.swift`, `StatusIcon.swift`, `StatusIconRenderer.swift` | menu structure, scoped reads, strings, NSMenu construction, glyph | menu rows, wording, glyph |
| Settings UI | `Sources/tiled/SettingsWindowController.swift`, `SettingsWelcomeTab.swift`, `SettingsGeneralTab.swift`, `SettingsShortcutsTab.swift`, `RecorderButton.swift`, `SlotPreviewView.swift` | settings shell, three tabs, recorder button, slot preview | settings or shortcut-editor changes |

## Where things live

| Concern | Files |
|---|---|
| Tiling one window into a slot | `Sources/tiled/TilingController.swift:19` (routing), `Sources/tiled/TilingSpace.swift:42` (placement pipeline) |
| Slot and layout geometry | `Sources/tiled/Layout.swift:11` (`LayoutKind`), `Sources/tiled/Layout.swift:85` (`Slot`), `Sources/tiled/Layout.swift:64` (`SlotGeometry`), `Sources/tiled/Layout.swift:284` (`GridLayout`), `Sources/tiled/Layout.swift:617` (`TilingState`) |
| Physical slot keys | `Sources/tiled/SlotKey.swift:17` |
| Window writes and AX | `Sources/tiled/WindowGateway.swift:32` (seam), `Sources/tiled/LiveWindowGateway.swift:204` (adapter), `Sources/tiled/FrameWriter.swift:8` (write policy) |
| Window handle identity | `Sources/tiled/WindowGateway.swift:10` (`WindowHandle`), `Sources/tiled/WindowRegister.swift:13` |
| Canvas and display resolution | `Sources/tiled/CanvasDirectory.swift:16`, `Sources/tiled/DisplaySpace.swift:13` (`ScreenID`), `Sources/tiled/DisplaySpace.swift:75` (`TilingSpaceKey`) |
| Drag-resize and splitters | `Sources/tiled/DragTracker.swift:51`, `Sources/tiled/Layout.swift` (`TileEdge`, `GridBoundary`, `TilingState` splitters), `Sources/tiled/TilingSpace.swift` (`reflow`, `writeRects`) |
| Undo of displacements | `Sources/tiled/TilingSpace.swift` (`beginUndoChapter`, `pushUndo`, `restore`), `Sources/tiled/TilingController.swift` (`restoreChapter`) |
| Expand toggle | `Sources/tiled/ExpandToggleState.swift:7`, `Sources/tiled/TilingSpace.swift` (`expandToggle`) |
| Global hotkey registration | `Sources/tiled/HotkeyService.swift:74`, `Sources/tiled/CarbonHotkeyEventRouter.swift:16` |
| Hotkey routing and actions | `Sources/tiled/HotkeyAction.swift:11`, `Sources/tiled/HotkeyActionRouter.swift:17` |
| Binding persistence and defaults | `Sources/tiled/HotkeyBinding.swift:6`, `Sources/tiled/HotkeyBinding.swift:195` (`HotkeyStore`), `Sources/tiled/ShortcutPark.swift:74` |
| Menu structure, reads, strings | `Sources/tiled/MenuModel.swift:6`, `Sources/tiled/MenuReads.swift:13`, `Sources/tiled/MenuText.swift:5` |
| Status item and glyph | `Sources/tiled/MenuBarPresenter.swift:21`, `Sources/tiled/StatusIcon.swift:13`, `Sources/tiled/StatusIconRenderer.swift:7` |
| Settings window and tabs | `Sources/tiled/SettingsWindowController.swift:7`, `Sources/tiled/SettingsShortcutsTab.swift:45`, `Sources/tiled/SettingsGeneralTab.swift:42`, `Sources/tiled/SettingsWelcomeTab.swift:7` |
| Shortcut recorder UI | `Sources/tiled/RecorderButton.swift:11`, `Sources/tiled/HotkeyRecorder.swift:12`, `Sources/tiled/SlotPreviewView.swift:11` |
| Launch and permission flow | `Sources/tiled/AppDelegate.swift:3`, `Sources/tiled/AppLaunchPlan.swift:5`, `Sources/tiled/PermissionWindowController.swift:12` |
| Receipts and notices | `Sources/tiled/ActionReceipt.swift:8`, `Sources/tiled/NoticePresentation.swift:6`, `Sources/tiled/ShortcutNotice.swift:10` |
| App settings defaults | `Sources/tiled/AppSettings.swift:5` |
| Focus memo and activation helper | `Sources/tiled/FocusMemo.swift:9`, `Sources/tiled/NSApplication+Activate.swift` |

## Task recipes

**Add or change a tiling slot.** Read `Sources/tiled/Layout.swift` (slot cells and rect math) and `Sources/tiled/TilingSpace.swift` (placement, reflow, undo). Change the engine, not the coordinator. Test with `swift test --filter GridLayoutTests` and `swift test --filter TilingSpaceTests`, then `make check`.

**Add a global hotkey action.** Read `Sources/tiled/HotkeyAction.swift` (identity and defaults), `Sources/tiled/HotkeyActionRouter.swift` (exhaustive route table), `Sources/tiled/AppDelegate.swift` (live forwarding), and `Sources/tiled/SettingsShortcutsTab.swift` (row). Change the action identity, router, performer, and defaults together. Test with `swift test --filter HotkeyActionRouterTests`, then `make check`.

**Change a menu row or user-facing wording.** Read `Sources/tiled/MenuModel.swift` (structure), `Sources/tiled/MenuReads.swift` (state), `Sources/tiled/MenuText.swift` (strings), `Sources/tiled/MenuBarPresenter.swift` (NSMenu). Test with `swift test --filter MenuModelTests`, `swift test --filter MenuTextTests`, `swift test --filter MenuBarCharacterizationTests`, then `make check`.

**Change AX or window-write behavior.** Read `Sources/tiled/WindowGateway.swift` (contract), `Sources/tiled/FrameWriter.swift` (write policy), `Sources/tiled/LiveWindowGateway.swift` (adapter). Test hermetically with `swift test --filter LiveGatewayWiringTests` and `swift test --filter AXWriteTests`; the real adapter runs only via `scripts/run-repro.sh` before a release.

**Fix a drag or resize bug.** Read `Sources/tiled/DragTracker.swift` (gesture decision and echo suppression), `Sources/tiled/TilingSpace.swift` (`reflow`, `writeRects`), and the drag callbacks in `Sources/tiled/TilingController.swift`. Test with `swift test --filter DragTrackerTests`, `swift test --filter ReflowTests`, `swift test --filter SplitterBackupDragTests`, then `make check`.

**Change undo behavior.** Read the undo chapter and restore functions in `Sources/tiled/TilingSpace.swift` and `restoreChapter` in `Sources/tiled/TilingController.swift`. Test with `swift test --filter UndoIntegrityTests`; run `make exhaustive` before hand-off.

**Change the settings window or shortcut editor.** Read `Sources/tiled/SettingsWindowController.swift` (shell and tab ownership) plus the one tab file, and `Sources/tiled/RecorderButton.swift` plus `Sources/tiled/SlotPreviewView.swift` for the editor controls. Test with `swift test --filter SettingsShortcutsRebuildTests`, then `make check`.

**Run the pre-release verification layers.** Read `docs/developing.md` first, then run `scripts/doctor.sh`, `scripts/run-repro.sh` (needs a GUI session and Accessibility), `make exhaustive`, and `make mutation`.

## Tests

Suites live in `Tests/tiledTests/` (80 files, 1175 tests at this commit). The hermetic suite needs no AX grant, no display, and no runloop; it drives the engine through `FakeWindowGateway.swift`, `TilingSpaceHarness.swift`, and `ControllerHarness.swift`, with `LiveGatewayFakes.swift` covering the live adapter's hermetic seam.

| Layer | Suites |
|---|---|
| Canvas engine | `TilingSpaceTests`, `TilingStateTests`, `GridLayoutTests`, `MatrixCrossCheckTests`, `ReflowTests`, `UndoIntegrityTests`, `ExpandToggleTests` |
| Coordinator | `ControllerGatewayTests`, `ControllerBulkOperationTests`, `CanvasDirectoryTests`, `CanvasSurfaceTests`, `WindowRegisterTests`, `WindowBirthTests`, `ReassertPlanTests` |
| AX seam | `AXLivenessTests`, `AXWriteTests`, `AXConversionTests`, `AXFocusFallbackTests`, `LiveGatewayWiringTests`, `LiveGatewayMappingTests`, `FakeGatewayFidelityTests`, `HandleIdentityTests`, `ObservationRegistryTests`, `FrameWriterTests` |
| Hotkeys and settings | `HotkeyServiceTests`, `HotkeyBindingTests`, `HotkeyRecorderTests`, `ShortcutParkTests`, `Shortcuts*Tests`, `SettingsShortcutsRebuildTests`, `RecorderButton*Tests` |
| Menu and status | `MenuModelTests`, `MenuReadsTests`, `MenuTextTests`, `MenuBarCharacterizationTests`, `StatusIconTests`, `SlotPreviewRenderingTests` |
| Displays and Spaces | `DisplayIdentityTests`, `PerMonitorTests`, `ScreenOwnershipTests`, `SpaceIndependenceTests`, `LidSleepWakeTests` |

- One suite: `swift test --filter <Suite>`. Full transcript: `make test`. Gate for every change: `make check`, which runs the suite through `scripts/test.sh` and compares the count with `README.md` through `scripts/check-test-count.sh`.
- Skipped during a normal change: `make exhaustive` (undo replay; `ExhaustiveUndoTests` skips unless `TILED_EXHAUSTIVE=1` is set), `make mutation` (minutes), `make repro` / `scripts/run-repro.sh` and `scripts/run-focus-loop.sh` (real cursor, real windows, TCC grant), and the `tools/repro/*.swift` drivers. `swift test --filter DisplayIdentityTests` skips when no display is attached.
- No fixture or golden directories; scenarios are built in code by the harnesses above.

## Don't read

- `build/`, `.build/`: compiled output, `build/test.log`, live-run artifacts. Read the log only when a run is red.
- `docs/release-notes/`: 22 frozen per-release files; open one only when a task is about that release.
- `CHANGELOG.md`: version history; use only when asked what changed between versions.
- `.scratch/`: untracked local issue tracker and specs; read only a spec or ticket a task names.
- `docs/superpowers/`: untracked agent plans and specs; historical, not product truth.
- `.audit/`: untracked audit dumps (`.tsv`, `.todo.md`); historical.
- `usage` (1.5 MB PNG), `docs/assets/`, `docs/tiled_demo_live_suite.gif`: binary media.
- `tools/repro/*.swift`, `scripts/run-focus-loop.sh`: live-only drivers; `swift test` does not run them.
- `.headroom/`, `.pi/`, `.worktrees/`, `todo.md`: local tool state or scratch notes.
- `docs/adr/`: read the single ADR for the area you touch, not the directory front to back.

## Gotchas

- A canvas is one display's one Mission Control Space (`TilingSpace`), not a drawing surface or folder. `CanvasDirectory` resolves it; `TilingSpace` is a value type, so mutate it only through `withCanvas` / `modifyCanvas`.
- `LiveWindowGateway.swift` is the only file importing `ApplicationServices`. Put window-server behavior behind `WindowGateway`; do not add AX types to the controller or canvas.
- Every frame write goes through `FrameWriter` (no-op skip, off-Space deferral with stale mark, echo suppression, convergence check). It is the only caller of `gateway.setFrame`.
- `make check` fails when the suite count and the README's published count disagree. Update the count in `README.md` when tests change.
- `ExhaustiveUndoTests` silently skips without `TILED_EXHAUSTIVE=1`; `make exhaustive` is the only gate that sets it.
- Layout is stored per canvas (`TilingState.layout`) and changes only through the explicit switch (ADR-0003); a slot request with no slot in the active layout is inert.
- Live-suite case counts and timing notes in `docs/developing.md` drift by version; trust the command output, not the prose. The hermetic suite runs in about 5s, `make check` in about 8s on a warm build.
- There is no Xcode project (`*.xcodeproj` is gitignored); the package is the build definition.

## File index

`Sources/tiled/` (42 files, flat target):

- `ActionReceipt.swift`: one action's user-visible verdict, canvas, notice, and spoken line.
- `AppDelegate.swift`: AppKit lifecycle: launch plan, hotkey service, menu bar, settings and permission windows, action selectors.
- `AppLaunchPlan.swift`: pure launch decision: start now or wait for permission, which settings window opens.
- `AppSettings.swift`: UserDefaults-backed app settings (hidden icon, welcome dismissed).
- `CanvasDirectory.swift`: canvas table, display plus Space resolution, visibility, stale marks, cursor and focus canvas.
- `CarbonHotkeyEventRouter.swift`: process-wide Carbon event handler; parses the hotkey id and hops to the main queue.
- `DisplaySpace.swift`: `ScreenID`, `SpaceID`, `TilingSpaceKey`, and `ScreenInfo` identity types.
- `DragTracker.swift`: live drag-resize loop: echo suppression, edge and splitter detection, drag-end decision.
- `ExpandToggleState.swift`: what the focused window's expand toggle means right now.
- `FocusMemo.swift`: short-lived focused-window memo for one menu pass.
- `FrameWriter.swift`: the one frame-write policy: skip, defer off-Space, echo, converge.
- `HotkeyAction.swift`: hotkey action identity (slot keys plus app actions) and conflict helpers.
- `HotkeyActionRouter.swift`: exhaustive action-to-performer routing plus the live `AppHotkeyPerformer`.
- `HotkeyBinding.swift`: binding value, stored form, labels, and `HotkeyStore` persistence and defaults.
- `HotkeyRecorder.swift`: keypress to binding, clear, or cancel interpretation for the recorder.
- `HotkeyService.swift`: global-hotkey registration lifecycle over an injected registrar; Carbon adapter.
- `Layout.swift`: `LayoutKind`, `Slot`, cell and edge geometry, `GridLayout` rect math, `TilingState`.
- `LiveWindowGateway.swift`: AX adapter: element registry, observers, liveness, writes, Spaces, window creation.
- `MenuBarPresenter.swift`: status item and NSMenu: snapshot diffing, menu construction, show and hide.
- `MenuModel.swift`: platform-free menu structure and item actions.
- `MenuReads.swift`: one scoped read of the state the menu describes.
- `MenuText.swift`: user-visible menu and receipt strings and their composition rules.
- `NSApplication+Activate.swift`: frontmost activation helper for macOS 14 versus older systems.
- `NoticePresentation.swift`: sticky menu notice bound to focus and generation; present, clear, overlay.
- `PermissionWindowController.swift`: launch Accessibility explainer window.
- `RecorderButton.swift`: one shortcut recorder button: arm, capture, label states.
- `SettingsGeneralTab.swift`: General tab: launch-at-login presentation and rows.
- `SettingsShortcutsTab.swift`: Shortcuts tab: sections, rows, bulk enable and disable, reset, conflicts.
- `SettingsWelcomeTab.swift`: first-run Welcome tab: one demonstration, trust and failure guidance.
- `SettingsWindowController.swift`: settings shell: three tabs, selection, rebuild, initial focus.
- `ShortcutNotice.swift`: Shortcuts tab's single live-region notice with fixed precedence.
- `ShortcutPark.swift`: parked combos and reset backups in UserDefaults; bulk restore plans.
- `SlotKey.swift`: the eleven physical slot keys, their keycodes, and the persisted storage namespace.
- `SlotPreviewView.swift`: miniature slot-preview grid drawn from the same cells as the layout.
- `StatusIcon.swift`: pure occupancy-to-glyph-cell mapping and snapshot.
- `StatusIconRenderer.swift`: draws a status snapshot as the menu-bar template image.
- `TilingController.swift`: coordinator: event and action routing, canvas resolution, outcomes, pruning, observation.
- `TilingSpace.swift`: one canvas: records, occupancy, splitters, undo, placement and reflow pipeline, notices.
- `TopAnchoredStackView.swift`: flipped stack for settings scroll views.
- `WindowGateway.swift`: the `WindowGateway` seam plus `WindowHandle` and `Liveness`.
- `WindowRegister.swift`: handle ids, id allocator, death clock, pending convergence checks.
- `main.swift`: app entry: accessory activation policy, delegate, run loop.
