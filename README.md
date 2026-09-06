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
| ⌃⌥⇧⌘Z   | Undo the last displacement — layout switch or eviction (works from anywhere) |

### Expand — ⌥⇧⏎

| Key  | Action                                                        |
|------|---------------------------------------------------------------|
| ⌥⇧⏎  | Expand the focused window to fill the screen (not fullscreen mode) |

Press ⌥⇧⏎ again and the window returns to its previous tile — or its
previous frame, if it wasn't tiled. The layout is never erased: a tiled
window keeps its slot while expanded (the expanded window just covers the
others, like focusing does), and tiling a neighbor into a free tile leaves
the expanded window alone. This shortcut is fixed — the slot shortcuts
below are the remappable ones.

### Evict — ⌥⇧⌫

| Key  | Action                                                        |
|------|---------------------------------------------------------------|
| ⌥⇧⌫  | Evict the focused window: untile it and let its column-mates expand |

Evicting restores the focused window to its pre-tile frame and grows the
adjacent survivor into the freed space when the two form exactly one slot
together — vertically or horizontally. Evict Top Left with Bottom Left
tiled and Bottom Left becomes Left Half; evict the left third with the
middle third tiled and the middle third becomes the left two-thirds.
Windows that merge into no exact slot never move, and a gap nobody can
fill exactly stays a gap. Like Expand, this shortcut is fixed.

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
- **Drag a tiled window by its title bar**: past ~100pt of drag it untiles
  right where you dropped it (the drop is the placement — no pre-tile
  restore); a shorter drag snaps back into its tile. A single far jump
  (a programmatic move, not a hand drag) always snaps back.
- Each monitor tiles independently: every display runs its own layout,
  occupancy, splitters, and undo history. Tiling, switching, swapping,
  drag-resizing, and ⌃⌥⇧⌘Z on one monitor never disturb the other —
  the same tile can even be occupied on both at once. The menu groups
  tiled windows per display; Untile All and Reset Splitters act on the
  focused monitor only.
- Quarters and sixths are mutually exclusive per monitor: requesting a slot in
  the other layout untiles every tiled window on that monitor and switches layouts. The menu
  names the switch and how to undo it ("Switched to Sixths · 3 windows
  untiled. Undo (⌃⌥⇧⌘Z) is one step, from anywhere. Safe to explore:
  destruction is always reversible.
- Some apps refuse programmatic resizing. When that happens the window is
  left alone and the menu says which app refused — state and screen never
  silently disagree.

## Live resizing

Drag any edge of a tiled window and the shared grid splitter moves with it;
neighbors on the other side follow. Vertical and horizontal splitters are
independent per column (quarters) or per third (sixths), so resizing one
column never moves the other — and independent per monitor, so dragging
an edge on one display never moves tiles on another. **Reset Splitters**
in the menu snaps the focused monitor's splitters back to even splits.

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
- [x] Drag-out (short drag snaps back, long drag untiles in place)
- [ ] Owned overlay resize handles
- [x] Remappable shortcuts
- [ ] Gaps? (decided: no gaps for now)
