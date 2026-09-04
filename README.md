# tiled

A native macOS window manager. Tile windows into quarters (2×2 plus halves)
or sixths (3×2 grid plus thirds and two-thirds), with global hotkeys or from
the menu bar. Dragging a tiled window's edge resizes it live — neighbors
sharing the edge follow.

## Hotkeys

Tile the focused window. Tiling a window into its own tile is a no-op (it
stays exactly where it is). Every shortcut also exists as a menu item
under **Tile Focused Window** in the menu bar menu.

### Quarters — hold ⌥⇧

| Key   | Tile          |
|-------|---------------|
| ⌥⇧U   | Top left      |
| ⌥⇧O   | Top right     |
| ⌥⇧M   | Bottom left   |
| ⌥⇧.   | Bottom right  |
| ⌥⇧J   | Left half     |
| ⌥⇧L   | Right half    |

### Sixths — hold ⌥⇧⌘

| Key    | Tile               |
|--------|--------------------|
| ⌥⇧⌘U   | Top left sixth     |
| ⌥⇧⌘I   | Top middle sixth   |
| ⌥⇧⌘O   | Top right sixth    |
| ⌥⇧⌘M   | Bottom left sixth  |
| ⌥⇧⌘,   | Bottom middle sixth|
| ⌥⇧⌘.   | Bottom right sixth |
| ⌥⇧⌘J   | Left third         |
| ⌥⇧⌘K   | Middle third       |
| ⌥⇧⌘L   | Right third        |
| ⌥⇧⌘H   | Left two-thirds    |
| ⌥⇧⌘;   | Right two-thirds   |
| ⌃⌥⇧⌘,   | Open Settings (works even with the menu bar icon hidden) |

First launch opens Settings on a Welcome tab: focus any window, press ⌥⇧U
to tile it top-left, and you're going — with a miniature preview showing
what Top Left covers. Dismiss the guide once; reopen it anytime from the menu bar menu → tiled Guide.

The full list lives in the app too: menu bar → **Settings… → Shortcuts**.

Shortcuts are remappable: open the Shortcuts tab, click a shortcut, and
press a new combo. Esc keeps the old one, ⌫ disables that slot.
Disable or re-enable a whole layout at once with the Enable/Disable all
button beside each section header — your combos are parked aside and
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
- When every overlapping window fits into the footprint the requesting window
  vacates, they **swap** instead — nobody is untiled. (Top left → occupied
  bottom right exchanges the two windows; left half → occupied top right
  exchanges the half and the quad.)
- Tiling a window into its own tile does nothing — no restore, no reassert.
- A window re-tiling itself into an overlapping slot just moves (never evicts
  itself) and keeps its original pre-tile frame.
- Use **Untile All** in the menu to restore every tiled window, or open a
  tiled window's submenu to focus it, untile just that window, or tile the
  focused window into its slot.
- Quarters and sixths are mutually exclusive on screen: requesting a slot in
  the other layout untiles every tiled window and switches layouts. The menu
  names the switch and how to undo it ("Switched to Sixths · 3 windows
  untiled. Undo: Restore 3 Evicted Windows") — undo is one step (⌘Z).
  Safe to explore: destruction is always reversible.
- Some apps refuse programmatic resizing. When that happens the window is
  left alone and the menu says which app refused — state and screen never
  silently disagree.

## Live resizing

Drag any edge of a tiled window and the shared grid divider moves with it;
neighbors on the other side follow. Vertical and horizontal dividers are
independent per column (quarters) or per third (sixths), so resizing one
column never moves the other. **Reset Dividers** in the menu snaps all
dividers back to even splits.

## Building & running

Requires a recent Swift toolchain (tested with Swift 6.2).

```bash
swift build          # debug build
swift test           # layout-engine unit tests
./scripts/make-app.sh # release build bundled as build/Tiled.app
```

### Running during development

The easiest dev loop: run the binary from your terminal and grant **Terminal**
(itself) Accessibility permission once — TCC attributes AX requests from
subprocesses to the responsible process:

```bash
swift run
```

For the bundled app (`./scripts/make-app.sh`), grant **Tiled** Accessibility
permission in System Settings. Note: ad-hoc signing changes on every rebuild,
so macOS may ask you to re-grant the permission after rebuilds. For serious
use, sign with a stable identity (even a free Apple ID "Apple Development"
certificate) so TCC remembers the grant.

Quitting tiled leaves your windows where they are.

## Status / roadmap

- [x] Menu bar app (LSUIElement), Accessibility permission flow
- [x] 17 global hotkeys (Carbon RegisterEventHotKey) + clickable menu equivalents
- [x] In-app keyboard-shortcut reference
- [x] Pure, unit-tested tiling state with eviction, swap, and layout-switch rules
- [x] Fixed-rect tiling via the Accessibility API
- [x] Live shared-edge resizing (observe native drag + compensate neighbors)
- [x] Sixths layout (3×2 grid, thirds, two-thirds)
- [x] Visible failure states (hotkey conflicts, apps refusing resize)
- [x] Display-change reassertion + automatic cleanup of closed windows
- [ ] Drag-out-to-untile (drop inside tile = snap back, outside = untile)
- [ ] Owned overlay resize handles
- [x] Remappable shortcuts
- [ ] Gaps? (decided: no gaps for now)
