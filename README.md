<h1 align="center">Tiled</h1>

<p align="center">A native macOS window manager. Tile windows into quarters or sixths from global hotkeys or the menu bar, resize the grid by dragging a shared edge, and undo any layout change from anywhere.</p>

<p align="center">
  <a href="https://github.com/edrickt/tiled/actions/workflows/tests.yml"><img src="https://github.com/edrickt/tiled/actions/workflows/tests.yml/badge.svg" alt="Tests"></a>
  <a href="https://github.com/edrickt/tiled/releases"><img src="https://img.shields.io/github/v/release/edrickt/tiled?sort=semver&color=2b7" alt="Release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey" alt="macOS 13+">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT">
</p>

Focus a window, press a slot shortcut, and it lands there. The menu bar glyph fills in as slots are taken, and one undo puts everything back.

## Features

| Feature | What it does |
|---|---|
| **Two layouts per canvas** | Quarters: a 2×2 grid plus halves. Sixths: a 3×2 grid plus thirds and two-thirds. Both are refinements of one shared 4×2 cell model, so overlap, eviction, and geometry are decided by cell sets, not special cases. |
| **Live shared-edge resizing** | Drag any edge of a tiled window and the splitter moves with it; the neighbors sharing that edge follow. Columns (quarters) and thirds (sixths) resize independently, and so do separate displays and Spaces. |
| **Reversible destruction** | Tiling into an occupied slot evicts the occupant, but one undo (⌃⌥⇧⌘Z, from anywhere) puts everything back, including layout switches that untiled the whole canvas. |
| **Eviction, swap, reflow, re-house** | A lone blocker swaps tiles instead of being evicted. Freed cells merge with an adjacent survivor into a whole slot. An evictee returns to tiling when exactly one slot is free. The rules are strict and unit-tested, not heuristics. |
| **Per-Space, per-display canvases** | A canvas is one display's one Mission Control Space. Each has its own occupancy, splitters, undo history, and notices, so tiling on one desktop never touches another. |
| **Remappable shortcuts** | Click a shortcut in Settings and press a new combo. Conflicts are named, Esc keeps the old binding, ⌫ disables the slot, and each layout has an Enable/Disable all switch that parks your combos instead of losing them. |
| **Honest failure states** | If an app refuses programmatic resizing, the window stays put and the menu names the app. If a shortcut fails to register, the menu says so. State and screen never silently disagree. |
| **No overlay, no chrome** | Tiled is a menu bar app (no Dock icon) that drives windows through the Accessibility API. Nothing is drawn over your windows; there are no owned resize handles to hunt for. |

## Install

Tiled needs **macOS 13 or later** and **Accessibility permission** (System Settings → Privacy & Security → Accessibility). It does not need kernel extensions, a scripting bridge, or a helper daemon.

### From a release

1. Download `Tiled-<version>.zip` from [Releases](https://github.com/edrickt/tiled/releases) and move `Tiled.app` to `/Applications`. Release bundles are universal: Apple Silicon and Intel.
2. Open it once. Releases are ad-hoc signed (there is no Developer ID yet), so Gatekeeper may ask you to confirm: right-click the app and choose **Open**.
3. Tiled opens its Settings window and asks for Accessibility permission. Grant it, then relaunch Tiled.

### From source

```bash
git clone https://github.com/edrickt/tiled.git
cd tiled
./scripts/install-app.sh     # release build, installed to /Applications, launched
```

The script builds first and only then replaces the installed copy, so a failed build never leaves you without the app that is currently tiling your windows.

`make app` builds the bundle at `build/Tiled.app` without installing it; `make app-universal` builds it for both architectures, which is what release bundles ship. Requires a recent Swift toolchain (developed with Swift 6.2, `Package.swift` tools version 5.9).

### Which binary do I want?

| | Release bundle | `swift run` |
|---|---|---|
| Speed | optimized, universal | debug, this Mac only |
| Permission | grant **Tiled** once | grant your terminal once |
| Menu bar name | Tiled | tiled |
| Survives rebuilds | re-grant may be needed (ad-hoc signing) | grant follows the terminal |

Use the bundle for daily driving and `swift run` while developing.

### Accessibility permission

macOS attributes Accessibility requests to the *responsible* process. Two consequences worth knowing:

- **Running the bundled app** grants `Tiled` itself. Tiled's first-run flow opens the settings pane for you.
- **Running from a terminal** (`swift run`) grants your terminal app, because the subprocess inherits its responsibility. Grant Terminal once and `swift run` works from then on.

Ad-hoc signatures change on every rebuild, so macOS may ask you to re-grant after a rebuild. Signing with a stable identity (even a free Apple Development certificate) makes TCC remember the grant.

Uninstalling is `rm -rf /Applications/Tiled.app`. Quitting Tiled leaves your windows where they are; see [docs/install.md](docs/install.md) for the full caveat list.

## Quick start

First launch opens Settings on a **Welcome** tab: focus any window, press the Top Left shortcut (⌥⇧⌘U by default), and the window snaps into place, with a miniature preview showing what Top Left covers. Dismiss the guide and it stays gone; reopen it from menu bar → **Tiled Guide**.

From then on:

1. Focus a window.
2. Press a tile shortcut.
3. The menu bar glyph fills the cells that are occupied on the current canvas.

## Hotkeys

Seventeen slot combos are remappable; four combos are fixed and always available. The full list also lives in the app under **Settings… → Shortcuts**.

### Quarters (hold ⌥⇧⌘)

| Key | Tile | Key | Tile |
|---|---|---|---|
| ⌥⇧⌘U | Top left | ⌥⇧⌘J | Left half |
| ⌥⇧⌘O | Top right | ⌥⇧⌘L | Right half |
| ⌥⇧⌘M | Bottom left | ⌥⇧⌘. | Bottom right |

### Sixths (hold ⌥⇧)

| Key | Tile | Key | Tile |
|---|---|---|---|
| ⌥⇧U | Top left sixth | ⌥⇧J | Left third |
| ⌥⇧I | Top middle sixth | ⌥⇧K | Middle third |
| ⌥⇧O | Top right sixth | ⌥⇧L | Right third |
| ⌥⇧M | Bottom left sixth | ⌥⇧H | Left two-thirds |
| ⌥⇧, | Bottom middle sixth | ⌥⇧; | Right two-thirds |
| ⌥⇧. | Bottom right sixth | | |

### Fixed

| Key | Action |
|---|---|
| ⌥⇧⏎ | Expand the focused window to fill the screen (not fullscreen mode); press again to return to its slot |
| ⌥⇧⌫ | Evict the focused window: untile it and restore its pre-tile frame |
| ⌃⌥⇧⌘, | Open Settings (works even with the menu bar icon hidden) |
| ⌃⌥⇧⌘Z | Undo the last displacement: a layout switch, an eviction, a swap, or a reflow, from anywhere |

The menu names the active layout's slots as single-click equivalents, plus one switch row for the other layout, because switching layouts re-tiles the focused window into it.

## Layouts

Quarters and sixths are mutually exclusive on a canvas, and the menu always offers the switch: the focused window moves into the other layout's top-left, every tiled window on that canvas is untiled, and one undo brings the whole arrangement back.

A full sixths canvas holds up to six windows in the 3×2 grid, and a two-thirds slot sits beside a third without special handling: both are cell sets in the same model. Splitters stay independent per third.

## Tiling rules

The normative rules live in [docs/tiling-rules.md](docs/tiling-rules.md); the ones you will actually meet:

- **One window per tile.** Tiling into an occupied slot evicts the occupant, unless exactly one window blocks it and your window has a tile to give: then the two **swap**, both stay tiled, and focus follows the displaced window.
- **Reflow.** When a tiled window leaves the layout (untile, evict, drag-out, close) or moves, its freed cells merge with an adjacent survivor into a whole slot. Rightmost candidate wins ties. A hole no survivor fits exactly stays empty.
- **Re-house.** An eviction that leaves exactly one whole slot free re-tiles the victim into it instead of untiling it (the middle third making room for the right two-thirds moves into the freed top-left sixth).
- **Expand keeps the slot.** An expanded window covers the layout without releasing its tile; the layout is never erased, and tiling a neighbor into a free tile leaves the expanded window alone.
- **Drag-out.** Dragging a tiled window by its title bar past ~100pt untiles it where you drop it. A shorter drag snaps back into the tile.
- **Layouts are mutually exclusive per canvas.** Requesting a slot in the other layout untiles every tiled window on that canvas and switches it. One undo restores the whole thing, so exploring is safe.

## Live resizing

Drag any edge of a tiled window and the shared splitter follows; the neighbors on the other side resize when you release. Splitters are independent per column (quarters) and per third (sixths), and per canvas, so dragging an edge here never moves a tile there. A two-thirds window resizes as two equal one-thirds, keeping its hidden internal divider centered. **Reset Splitters** in the menu snaps the focused canvas back to even splits.

## Spaces and displays

Every Mission Control Space on every display has its own canvas: occupancy, layout, splitters, undo history, and notices. The menu, the status glyph, and the bulk actions (**Untile All**, **Reset Splitters**) follow the focused window's canvas.

Display changes (unplug, rearrange, resolution) re-assert every visible canvas immediately. Canvas identity follows the monitor's CoreGraphics display number, so reordering screens never moves an arrangement to another display. Hidden Spaces are marked stale instead of being written to, because an off-screen resize can pull a window onto the visible Space; swiping back re-asserts them against the new bounds. Where the window server withholds a Space identifier, Tiled falls back to one canvas per display rather than guessing.

## Settings

- **Welcome** teaches one tiling with a live preview of both layout shapes, not seventeen combos.
- **Shortcuts** is one recorder row per slot. Click a row, press a combo, and it rebinds. A conflict with another slot or with one of Tiled's fixed combos is refused and named; Esc keeps the old binding; ⌫ disables that slot. Each layout section has an Enable/Disable all switch that parks the combos aside and restores them unchanged.
- **General** holds launch-at-login, the menu bar icon toggle (a fixed recovery shortcut opens Settings if you hide the icon), and the guide re-entry.

The status glyph is an occupancy map: each cell fills while a tiled window actually covers it, so the menu bar shows the layout's state, not just its shape. The menu itself lists the active layout's slots, the managed windows under the tiles they hold, and the bulk actions.

## Testing

Four layers, from hermetic to physical:

| Layer | Command | Needs |
|---|---|---|
| Unit suite (551 tests) | `swift test` | nothing: no Accessibility, no run loop, ~2s |
| Mutation audit (44 mutants) | `python3 tools/mutation/mutate.py` | nothing, ~10s per mutant |
| Live end-to-end (39 cases) | `./scripts/run-repro.sh` | a GUI session and Accessibility permission |
| Multi-display suite | `./scripts/run-repro.sh tools/repro/multi-display-suite.swift` | two attached displays |

The unit suite drives the pure engine through `FakeWindowGateway`, with clocks, schedulers, and the display set injected, so behavior is pinned without a window server. The live suite drives a throwaway host app through real clicks, drags, and global hotkeys: quarters and sixths geometry, eviction, swap, re-house, reflow, undo, drag clamping, and window closes, plus `tools/repro/multi-display-checklist.md` for the display changes a suite cannot drive.

The mutation audit answers the question a green suite cannot ask itself: would these tests notice if the code stopped working? Each entry in `tools/mutation/mutants.json` injects a plausible bug into `Sources/tiled` and expects the suite to fail. Survivors are test gaps, and the tool exits non-zero on any survivor, so it can gate a release branch.

CI runs the unit suite, a release build, and the app bundle check on pushes to `master` and on every pull request.

## Architecture

Two halves, one seam:

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

`TilingController` owns decisions and records and never touches Accessibility types; everything about element identity, coordinate conversion, observation, and activation lives behind `WindowGateway`, which is why the engine can be tested hermetically. [docs/architecture.md](docs/architecture.md) maps every module and the invariants it holds.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Hotkeys do nothing | Accessibility permission was revoked by a rebuild; see [docs/install.md](docs/install.md) |
| A shortcut does nothing, the menu warns | Another app registered that global combo; macOS cannot tell Tiled which one. Pick another in Settings → Shortcuts |
| A window will not move | The app refuses programmatic resizing; the menu names it |
| Two managers fight over a keystroke | Quit any other tiling manager (Tiled, Rectangle, …) while testing |
| Windows tile on one Space but not another | Hidden Spaces re-assert when you swipe back; nothing is written off-screen on purpose |

More in [docs/troubleshooting.md](docs/troubleshooting.md).

## Roadmap

- [x] Menu bar app (LSUIElement), Accessibility permission flow
- [x] Quarters and sixths layouts, 21 global hotkeys (17 remappable slots + 4 fixed)
- [x] Pure, unit-tested tiling state with eviction, swap, reflow, and re-house
- [x] Live shared-edge resizing
- [x] Per-Space, per-display canvases
- [x] Drag-out (short drag snaps back, long drag untiles in place)
- [x] Expand without releasing the slot
- [x] Undo across eviction, swap, reflow, and layout switches
- [x] Remappable shortcuts with conflict handling
- [x] Visible failure states (hotkey conflicts, apps refusing resize)
- [x] Display-change re-assertion and closed-window cleanup
- [ ] Owned overlay resize handles
- [ ] Gaps (decided: no gaps for now)

## Contributing

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) for the development loop, the test layers, and what a change is expected to prove. The short version:

```bash
swift test                        # the gate for every change
./scripts/run-repro.sh            # before a release
python3 tools/mutation/mutate.py  # would the tests notice?
```

`CONTEXT.md` is the project's vocabulary: one word per concept, with the words to avoid. The media pipeline lives in `tools/capture/` (see [docs/capture.md](docs/capture.md)); it is kept so the screenshots and GIFs can be regenerated on demand, and none are committed today.

## License

MIT. See [LICENSE](LICENSE).
