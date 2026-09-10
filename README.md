# Tiled

A native macOS window manager. Tile windows into quarters (2×2 plus halves)
or sixths (3×2 grid plus thirds and two-thirds), with global hotkeys or from
the menu bar. Dragging a tiled window's edge resizes it live; the
neighbors sharing the edge resize when the mouse button is released.

## Hotkeys

Tile the focused window. Tiling a window into its own tile is a no-op (it
stays exactly where it is). Every shortcut also exists as a menu item
under **Tile Focused Window** in the menu bar menu.

### Quarters (hold ⌥⇧⌘)

| Key    | Tile          |
|--------|---------------|
| ⌥⇧⌘U   | Top left      |
| ⌥⇧⌘O   | Top right     |
| ⌥⇧⌘M   | Bottom left   |
| ⌥⇧⌘.   | Bottom right  |
| ⌥⇧⌘J   | Left half     |
| ⌥⇧⌘L   | Right half    |

### Sixths (hold ⌥⇧)

| Key   | Tile               |
|-------|--------------------|
| ⌥⇧U   | Top left sixth     |
| ⌥⇧I   | Top middle sixth   |
| ⌥⇧O   | Top right sixth    |
| ⌥⇧M   | Bottom left sixth  |
| ⌥⇧,   | Bottom middle sixth|
| ⌥⇧.   | Bottom right sixth |
| ⌥⇧J   | Left third         |
| ⌥⇧K   | Middle third       |
| ⌥⇧L   | Right third        |
| ⌥⇧H   | Left two-thirds    |
| ⌥⇧;   | Right two-thirds   |
| ⌃⌥⇧⌘,   | Open Settings (works even with the menu bar icon hidden) |
| ⌃⌥⇧⌘Z   | Undo the last displacement (a layout switch, an eviction, a swap, or a reflow, from anywhere) |

### Expand (⌥⇧⏎)

| Key  | Action                                                        |
|------|---------------------------------------------------------------|
| ⌥⇧⏎  | Expand the focused window to fill the screen (not fullscreen mode) |

Press ⌥⇧⏎ again and the window returns to its previous tile, or to its
previous frame if it wasn't tiled. The layout is never erased: a tiled
window keeps its slot while expanded (the expanded window just covers the
others, like focusing does), and tiling a neighbor into a free tile leaves
the expanded window alone. This shortcut is fixed; the slot shortcuts
below are the remappable ones.

### Evict (⌥⇧⌫)

| Key  | Action                                                        |
|------|---------------------------------------------------------------|
| ⌥⇧⌫  | Evict the focused window: untile it and restore its pre-tile frame  |

Evicting restores the focused window to its pre-tile frame and releases
its slot. When a tiling request evicts a window and leaves exactly one
whole slot free, the victim re-tiles into that slot instead (the middle
third making room for the right two-thirds moves into the top-left sixth)
and only untangles when no single slot fits. The freed cells reflow: a neighboring tile that merges with
them into a whole slot grows into it — evict the bottom-left sixth and
the top-left sixth expands into the left third; free the middle third
and the right third becomes the right two-thirds (the right side wins
when both flanks could grow). The same reflow runs whenever a tiled
window leaves the layout (untile, drag-out, closing the window) or moves
to a free tile, and ⌃⌥⇧⌘Z undoes it together with the event that
caused it. A hole no neighbor can merge into exactly stays empty.
Like Expand, this shortcut is fixed.

First launch opens Settings on a Welcome tab: focus any window, press ⌥⇧U
to tile it top-left, and you're going, with a miniature preview showing
what Top Left covers. Dismiss the guide once; reopen it anytime from the menu bar menu → Tiled Guide.

The full list lives in the app too: menu bar → **Settings… → Shortcuts**.

Shortcuts are remappable: open the Shortcuts tab, click a shortcut, and
press a new combo. Esc keeps the old one, ⌫ disables that slot.
Disable or re-enable a whole layout at once with the Enable/Disable all
button beside each section header; your combos are parked aside and
restored unchanged.

If a shortcut is already owned by another app, that slot shows a warning in
the menu instead of silently doing nothing. If two tiled slots use the same
combo, the Shortcuts tab names the conflict and keeps the old binding until
you pick a free one.

## Tiling rules

- One window per tile.
- Tiling a window into a slot **evicts** any window occupying an overlapping
  slot. Evicted windows are restored to their pre-tile frames.
  - Two quads occupied on one side + the half key → both quads are evicted.
  - A half occupied + a quad key on that side → the half window is evicted.
- **Swap:** a tiled window tiling into a slot blocked by exactly one other
  tiled window swaps with it instead of evicting: the blocker moves into the
  tile the requester vacated, and both stay tiled. Focus follows the
  displaced window into the tile it landed in. (With more than one window in
  the way, or from an untiled window, the request evicts as above, and focus
  stays put.) Undo swaps back.
- Tiling a window into its own tile does nothing: no restore, no reassert.
- A window re-tiling itself into an overlapping slot just moves (never evicts
  itself) and keeps its original pre-tile frame.
- **Drag a tiled window by its title bar**: past ~100pt of drag it untiles
  right where you dropped it (the drop is the placement; no pre-tile
  restore); a shorter drag snaps back into its tile. A single far jump
  (a programmatic move, not a hand drag) always snaps back.
- Use **Untile All** in the menu to restore every tiled window, or open a
  tiled window's submenu to focus it, untile just that window, or tile the
  focused window into its slot.
- Each canvas tiles independently, where a canvas is one display's one
  Mission Control Space. Every Space you reach by swiping up with three
  fingers has its own layout, occupancy, splitters, undo history, and
  notices, and so does every display: the same tile can be occupied in
  several Spaces and on several displays at once. Tiling, switching,
  drag-resizing, and ⌃⌥⇧⌘Z on one canvas never disturb another; Untile
  All and Reset Splitters act on the focused canvas only. (Where the
  window server withholds a Space id, Tiled falls back to one canvas per
  display rather than guessing.)
- The menu-bar glyph and the menu's rows follow the focused window's
  display and Space. Swiping to another Space (or focusing a window on
  another display) redraws the glyph (2×2 or 3×2) and its occupancy for
  the canvas that just became visible, even though there was no tiling
  action. Windows parked in hidden Spaces stay tiled and keep their
  history; they simply wait off-menu until you swipe back.
- Quarters and sixths are mutually exclusive per canvas: requesting a slot
  in the other layout untiles every tiled window on that canvas and
  switches that canvas's layout. The menu names the switch and how to undo
  it ("Switched to Sixths · 3 windows untiled. Undo (⌃⌥⇧⌘Z) is one step,
  from anywhere. Safe to explore: destruction is always reversible.
- A display change (unplug, rearrange, resolution) re-asserts every visible
  canvas immediately. Canvas identity follows the physical monitor's
  CoreGraphics display number, so reordering screens never moves a monitor's
  arrangement to another display. Hidden Spaces are marked stale instead:
  Tiled never writes an off-Space window, because an AX resize can pull it
  onto the visible Space. Swiping back re-asserts that Space against the new
  bounds.
- Some apps refuse programmatic resizing. When that happens the window is
  left alone and the menu says which app refused, so state and screen never
  silently disagree.

## Live resizing

Drag any edge of a tiled window and the shared grid splitter moves with it;
neighbors on the other side follow. Vertical and horizontal splitters are
independent per column (quarters) or per third (sixths), so resizing one
column never moves the other, and the same independence holds between
monitors and Spaces, so dragging an edge on one canvas never moves tiles on
another. A two-thirds window resizes as two equal one-thirds: the hidden
splitter inside it follows its outer edge, staying at the midpoint.
**Reset Splitters** in the menu snaps the focused canvas's splitters back
to even splits.

## Building & running

Requires a recent Swift toolchain (tested with Swift 6.2).

```bash
swift build          # debug build
swift test           # layout-engine unit tests
./scripts/make-app.sh # release build bundled as build/tiled.app
```

### Running during development

The easiest dev loop: run the binary from your terminal and grant **Terminal**
(itself) Accessibility permission once, because TCC attributes AX requests from
subprocesses to the responsible process:

```bash
swift run
```

For the bundled app (`./scripts/make-app.sh`), grant **Tiled** Accessibility
permission in System Settings. Note: ad-hoc signing changes on every rebuild,
so macOS may ask you to re-grant the permission after rebuilds. For serious
use, sign with a stable identity (even a free Apple ID "Apple Development"
certificate) so TCC remembers the grant.

Quitting Tiled leaves your windows where they are.

## Testing

Three layers, from hermetic to physical:

| Layer | Command | Needs |
|-------|---------|-------|
| Unit suite (507 tests) | `swift test` | nothing; ~2s, no AX, no runloop |
| Coverage report | `swift test --enable-code-coverage` then `xcrun llvm-cov report ...` | nothing |
| Live end-to-end | `./scripts/run-repro.sh` | GUI session + Accessibility permission |
| Test-quality audit | `python3 tools/mutation/mutate.py` | nothing; ~10s per mutant |

The unit suite drives the pure engine through `FakeWindowGateway`, with
clocks, schedulers, and the display set injected; only a few live-screen
identity checks touch AppKit. The live adapter (`LiveWindowGateway`) is
exercised by `scripts/run-repro.sh`, which launches the app plus a throwaway
`host` app and drives real clicks, drags, and global hotkeys. The multi-display
suite checks same-slot coexistence, per-monitor moves, and splitter isolation
on two attached displays; unplug/replug, rearrange, and Mission Control
validation stays in the accompanying manual checklist. Run these before a
release; they cannot run in CI (they move the real cursor and need a TCC grant).

```
swift test                              # the gate for every change
./scripts/run-repro.sh                  # pre-release live check
./scripts/run-repro.sh tools/repro/multi-display-suite.swift  # two displays
./scripts/run-repro.sh tools/repro/driver.swift   # smaller focused driver
python3 tools/mutation/mutate.py        # verify the suite still catches bugs
python3 tools/mutation/mutate.py --list # show the injected-bug table
```

See `tools/repro/multi-display-checklist.md` for the physical display-change
checks the suite cannot drive.

`tools/mutation` answers the question a green suite cannot ask itself:
would these tests notice if the code stopped working? Each entry in
`tools/mutation/mutants.json` is a plausible bug injected into `Sources/tiled`;
a mutant that survives is a test gap. It exits non-zero on any survivor, so
it can gate a release branch. Sources are restored from memory after each
run, so uncommitted work is safe.

CI (`.github/workflows/tests.yml`) runs the unit suite on every push and PR.

## Status / roadmap

- [x] Menu bar app (LSUIElement), Accessibility permission flow
- [x] 17 global hotkeys (Carbon RegisterEventHotKey) + clickable menu equivalents
- [x] In-app keyboard-shortcut reference
- [x] Pure, unit-tested tiling state with eviction and layout-switch rules
- [x] Fixed-rect tiling via the Accessibility API
- [x] Live shared-edge resizing (observe native drag + compensate neighbors)
- [x] Sixths layout (3×2 grid, thirds, two-thirds)
- [x] Visible failure states (hotkey conflicts, apps refusing resize)
- [x] Display-change reassertion + automatic cleanup of closed windows
- [x] Per-Space layouts (Mission Control desktops independent per display)
- [x] Drag-out (short drag snaps back, long drag untiles in place)
- [ ] Owned overlay resize handles
- [x] Remappable shortcuts
- [ ] Gaps? (decided: no gaps for now)
