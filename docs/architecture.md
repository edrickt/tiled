# Architecture

Tiled is two halves and one seam: a pure tiling engine that decides, and an
AppKit/Accessibility app that executes. Everything that can be decided without
a window server is decided without one, which is why 551 tests run in about two
seconds on a machine with no GUI session.

```
   AppKit / Carbon                 pure Swift
 ┌──────────────────────┐      ┌──────────────────────┐
 │ AppDelegate          │      │ Layout  GridLayout   │
 │ MenuModel            │      │ TilingState          │
 │ SettingsWindow…      │      │  (slots, cells,      │
 │ StatusIcon  Hotkeys  │      │   eviction, swap,    │
 └──────────┬───────────┘      │   reflow, re-house)  │
            │                  └──────────┬───────────┘
      ┌─────┴─────────────────────────────┘
      │
 ┌────┴─────────────────┐
 │ TilingController     │
 │ PlanExecutor         │
 │ DragTracker          │
 └────┬─────────────────┘
      │  WindowGateway (protocol)
 ┌────┴─────────────┐     ┌──────────────────┐
 │ LiveWindowGateway│     │ FakeWindowGateway│
 │ (AX, production) │     │ (tests)          │
 └──────────────────┘     └──────────────────┘
```

## Modules

### The engine (no AppKit, no Accessibility)

| File | Owns |
|---|---|
| `Layout.swift` | `Slot`, `Layout`, `TileCell`, `GridLayout` splitter state, and the pure plan: overlap, eviction sets, swap eligibility, `reflow`, `rehousingHome`. |
| `DisplaySpace.swift` | `ScreenID`, `TilingSpaceKey` (display + Space identity), `CanvasState` (one canvas's occupancy, layout, splitters, undo chapters), and the per-canvas store. |
| `WindowGateway.swift` | The `WindowGateway` protocol and `WindowHandle`: the only vocabulary the controller has for windows. |
| `DragTracker.swift` | The live drag-resize loop (observe native drag, compensate neighbors), per canvas. |
| `HotkeyBinding.swift` | A remappable binding: Carbon modifiers plus a virtual keycode, with `keyCode == nil` meaning *disabled*. |
| `MenuModel.swift`, `MenuText.swift` | A platform-free description of the status menu and its user-visible strings, so the structure contracts (warning precedence, grouping, empty states, undo visibility) are testable without building `NSMenu`. |
| `StatusIcon.swift` | The mapping from tiling state to the menu bar glyph's filled cells. |

### The seam

`TilingController` glues the pure engine to real windows and never touches
Accessibility types directly. All element identity, coordinate conversion,
observation, and activation live behind `WindowGateway`
(`Sources/tiled/LiveWindowGateway.swift` in production,
`Tests/tiledTests/FakeWindowGateway.swift` in tests). The fake is not a stub:
it can express partial write refusals, write counts, and destroy notifications,
so the controller's failure paths are exercised, not just its happy path.

Two modules carry work out of the controller's decision path:

- `PlanExecutor` commits a decided plan: snapshot, restore, place, rollback,
  notices, undo chapters.
- `DragTracker` owns the resize loop, so a mouse drag never re-enters the
  controller's placement logic.

### The app shell

`AppDelegate` builds the menu and owns the app lifecycle; `SettingsWindowController`
is a thin shell around three tab modules (`SettingsWelcomeTab`,
`SettingsGeneralTab`, `SettingsShortcutsTab`); `PermissionWindowController`
explains the Accessibility request before macOS asks; `HotkeyService` registers
Carbon hotkeys and routes them to the engine.

## Invariants

These are asserted in tests and are the cheapest way to tell whether a change
belongs:

1. **One window per cell.** No two tiled windows on a canvas may share a cell.
   Every commit path (tile, swap, reflow, undo) is expected to displace
   occupants first, and the undo pre-loop is tested explicitly against
   double-booking.
2. **Destruction is undoable.** Any action that untiles a window or switches a
   canvas's layout pushes exactly one chapter, and the chapter's undo
   re-establishes both the windows and the layout.
3. **State and screen agree, or the menu says so.** A window whose frame write
   is refused is never recorded as tiled; the refusal is reported on the canvas
   that acted, not on whichever canvas happens to be focused.
4. **Off-screen Spaces are never written.** A stale canvas is re-asserted when
   it becomes visible; an AX resize on an off-Space window can pull it onto the
   visible Space, so the safe move is to defer.
5. **The engine never reads the clock or the screen.** Time, displays, and
   gateways are injected; `Layout.swift` and `DisplaySpace.swift` stay pure.

## Testing

| Layer | Command | What it protects |
|---|---|---|
| Unit (551 tests) | `swift test` | The engine's rules and the controller's failure paths, through `FakeWindowGateway` with injected clocks, schedulers, and displays. |
| Mutation (44 mutants) | `python3 tools/mutation/mutate.py` | Whether the unit suite would notice if a rule stopped working; survivors are test gaps and fail the run. |
| Live end-to-end (39 cases) | `./scripts/run-repro.sh` | The real AX adapter: geometry, eviction, swap, re-house, reflow, undo, drags, closes, and the status glyph's occupancy. |
| Multi-display | `./scripts/run-repro.sh tools/repro/multi-display-suite.swift` | Same-slot coexistence across displays, per-monitor moves, splitter isolation. |

The live suites move the real cursor and need Accessibility permission for the
running terminal, which is why they are not in CI. CI runs the unit suite, a
release build, and an app-bundle check (`codesign --verify`, `plutil -lint`) on
pushes to `master` and on pull requests.

The mutation table is the answer to "the suite is green, is it *watching*?".
Each entry is a plausible bug (an off-by-one in a tie-break, a dropped guard, a
skipped rollback) written as a literal string replacement, and the tool reports
STALE when a mutant's anchor no longer exists, so a refactor cannot silently
retire a test.

## Capture tooling

Screenshots and GIFs are produced by scripts in `tools/capture/`: a demo window
host, a scene driver that presses the same global hotkeys a person would,
`screencapture` for video, and a `mov2gif` converter. No media is committed at
the moment; the pipeline is kept so it can be regenerated on demand. See
[capture.md](capture.md).
