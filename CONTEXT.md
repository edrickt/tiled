# Tiled

A native macOS window manager: tile windows into quarters or sixths with global hotkeys or the menu bar, with live drag-resize of shared edges.

## Language

**Slot**:
A named tile a window can occupy (Top Left, Left Third, …), defined by its set of cells.
_Avoid_: tile, zone, region

**Layout**:
One of two mutually exclusive geometries per monitor: quarters (2×2 plus halves) or sixths (3×2 grid plus thirds and two-thirds). Each display runs its own.
_Avoid_: mode, grid

**Monitor space**:
One display's independent tiling state: its occupancy, layout, splitters, undo chapters, and notices. Tiling acts on the requesting window's monitor; menus aggregate (the manage list groups per display).
_Avoid_: screen (AppKit type), desktop

**Cell**:
An atomic unit of the shared 4×2 refinement both layouts are built from; overlap is cell-set intersection.
_Avoid_: sub-tile, block

**Splitter**:
A movable divider between tiles whose fraction the drag-resize loop updates; screen edges are fixed, not splitters.
_Avoid_: divider, separator, boundary (the code name is GridBoundary)

**Growth**:
The no-gap follow-up to an uncontended move: cells a move vacates merge with exactly one adjacent slot into a whole slot, and that neighbor grows into them - exact-or-empty, the same rule as eviction's reflow. Two left sixths, top moving to the middle third: the bottom sixth becomes the left third.
_Avoid_: expand (the ⌥⇧⏎ toggle), fill

**Eviction**:
Untiling a window to make room, restoring its pre-tile frame; what `plan` returns when a swap can't fit.
_Avoid_: displacement, removal

**Expand**:
Covering the layout: the ⌥⇧⏎ toggle resizes one window to fill its screen without releasing its slot; a second press retiles it. The tracker ignores expanded windows.
_Avoid_: maximize, zoom, fullscreen

**Drag-out**:
Untiling by dragging: a title-bar drag past the untile distance releases the slot and leaves the window where dropped - the drop is the placement, never a pre-tile restore. A shorter drag snaps back into the tile.
_Avoid_: drag-to-untile, fling

**Swap**:
Exchanging places: overlapping windows move into the footprint the requester vacates, nobody untiled. When that footprint has no room, every other window reflows into the cells the tile leaves behind instead - covering them exactly, so nobody is untiled and no empty space remains. A swap is all-or-nothing: any refused write calls off the whole exchange, every window back to its pre-swap frame.
_Avoid_: exchange, switch (which means layout switch)

**Requester**:
The window asking to be tiled in the current `handle` call; never evicts itself.
_Avoid_: focused window (focus is how it's usually found, not what it is)

**Window handle**:
The controller's opaque reference to a managed window, issued by the window gateway.
_Avoid_: window id (that's the pure-state key), element

**Plan execution**:
Committing a decided plan (tile, swap, or switch): snapshot, restore, place, rollback, and notice logic. Owned by the plan executor; the controller keeps focus, pruning, and dispatch.
_Avoid_: placement (which is only the place step), commit
