# Tiling rules

These are the normative rules. Every one of them is pinned by a unit test, and
the vocabulary is [CONTEXT.md](../CONTEXT.md)'s: *slot*, *cell*, *canvas*,
*eviction*, *swap*, *reflow*, *re-house*, *requester*.

## Geometry

A canvas runs one of two layouts, both built from the same atomic 4×2 **cell**
refinement:

- **Quarters**: top left, top right, bottom left, bottom right (one cell each),
  left half, right half (two cells each).
- **Sixths**: six corner cells (one cell each), left/middle/right thirds (two
  cells each), left/right two-thirds (four cells each).

Overlap is cell-set intersection. Two slots overlap when they share at least
one cell, which is what makes the eviction algebra identical in both layouts
instead of two sets of special cases.

## Tiling a window

1. **Own tile.** Tiling a window into the tile it already occupies is a no-op:
   no restore, no re-assert, no state change.
2. **Free slot.** The window takes the slot.
3. **Blocked slot, one blocker, requester is tiled.** *Swap*: the blocker moves
   into the tile the requester just vacated, and both stay tiled. Focus follows
   the displaced window. The swap requires the vacated tile to be disjoint from
   the target; otherwise the request falls back to eviction.
4. **Blocked slot otherwise.** *Eviction*: every window in an overlapping slot
   is untiled and restored to its pre-tile frame, then the requester takes the
   slot. Two quads occupied on one side plus the half key evicts both quads; an
   occupied half plus a quad key on that side evicts the half.
5. **Re-house.** If an eviction leaves exactly one whole slot free and the
   victim is the only one, the victim re-tiles into that slot instead of being
   restored (the middle third making room for the right two-thirds moves into
   the freed top-left sixth). A region that is not exactly one slot falls back
   to untile-and-restore. The undo chapter returns the victim to the slot it
   was evicted from.
6. **Reflow.** When a tiled window leaves the layout (untile, evict, drag-out,
   or close) or moves to another slot, its freed cells merge with exactly one
   adjacent survivor into a whole slot, and that survivor grows into it.
   Rightmost candidate wins ties. A hole no survivor merges into exactly stays
   empty; the requester and expanded windows never grow.
7. **Refusal.** An app can refuse a programmatic resize. The window is left
   alone, its slot is not committed, and the menu names the app. If the
   placement that was supposed to follow an eviction is refused, the evicted
   windows keep their undo chapter and their restore is narrated anyway.

A window re-tiling itself into an overlapping slot just moves; it never evicts
itself, and it keeps its original pre-tile frame for a later untile.

## Leaving the layout

- **Untile** (menu, per window or all): restore the window's pre-tile frame and
  release its slot, then reflow.
- **Evict** (⌥⇧⌫): same, driven by the focused window.
- **Drag-out**: a title-bar drag past ~100pt (across at least two drag ticks)
  untiles the window where you dropped it; the drop *is* the placement, never a
  pre-tile restore. A shorter drag snaps the window back into its tile. A
  single far jump with no drag shape (a programmatic move) always snaps back.
- **Close**: a destroyed window releases its slot through `AXUIElementDestroyed`
  (typical latency a few milliseconds) or, for a process that died without
  notifying, a 5s prune tick plus a 3s confirmation window.

## Expand

⌥⇧⏎ resizes the focused window to fill its screen without fullscreen mode. The
slot is kept: the expanded window covers the layout, it does not consume it.
Tiling a neighbor into a free tile leaves the expanded window alone, and
pressing ⌥⇧⏎ again returns the window to its slot (or to its previous frame if
it was never tiled). The layout is never erased by expanding.

## Layouts are exclusive per canvas

Requesting a slot in the layout that is not active untiles every tiled window
on that canvas and switches the canvas. The menu names the switch and the undo
("Switched to Sixths · 3 windows untiled. Press ⌃⌥⇧⌘Z to undo."). One undo step
restores the layout and every untiled window, from anywhere.

## Undo

⌃⌥⇧⌘Z pops one chapter from the focused canvas's history: a layout switch, an
eviction, a swap, a reflow, or a combination of them produced by one action.
Undoing displaces whatever currently overlaps the restored slots, so two
windows can never share a cell, and it re-establishes the chapter's layout when
the chapter crossed a switch. History is bounded per canvas (five chapters).

## Splitters and resizing

- Dragging an edge of a tiled window moves the shared splitter; the neighbors
  on the other side resize on mouse-up.
- Quarters have independent per-column horizontal splitters and one vertical
  splitter; sixths have independent per-third splitters. Resizing one column or
  third never moves another.
- A two-thirds window resizes as two equal one-thirds: its hidden internal
  divider stays centred on the window's midpoint.
- Splitters are per canvas, so a drag on one display or Space never moves tiles
  on another. **Reset Splitters** restores even splits for the focused canvas;
  **Restore Previous Splitters** appears after a reset.
- Screen edges are fixed boundaries, not splitters.

## Canvases

A canvas is one display's one Mission Control Space. Windows parked on a hidden
Space stay tiled and keep their history; they are not written to while
off-screen (an AX resize can pull a window onto the visible Space), and they
are re-asserted against current bounds when you swipe back. Canvas identity
follows the monitor's CoreGraphics display number, so reordering screens in
System Settings never moves one monitor's arrangement to another. Where the
window server withholds a Space identifier, the canvas falls back to one per
display rather than guessing.
