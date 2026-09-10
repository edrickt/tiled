# Tiled

A native macOS window manager: tile windows into quarters or sixths with global hotkeys or the menu bar, with live drag-resize of shared edges.

## Language

**Slot**:
A named tile a window can occupy (Top Left, Left Third, …), defined by its set of cells.
_Avoid_: tile, zone, region

**Layout**:
One of two mutually exclusive geometries per tiling space: quarters (2×2 plus halves) or sixths (3×2 grid plus thirds and two-thirds). Each display's each Space runs its own.
_Avoid_: mode, grid

**Space**:
A macOS Mission Control desktop (the thing a three-finger swipe up moves between), identified by its window-server id. A window belongs to one Space on one display; Spaces exist independently per display when "Displays have separate Spaces" is on.
_Avoid_: desktop, workspace, virtual desktop

**Tiling space (canvas)**:
One display's one Mission Control Space: its occupancy, layout, splitters, undo chapters, and notices. Tiling acts on the requesting window's canvas; menus aggregate the visible canvases (the manage list groups per display). A canvas whose Space id the OS withholds falls back to per-display state.
_Avoid_: monitor space (prose for the display dimension only), screen (AppKit type), desktop
_Code_: `CanvasState` (one canvas's state), `TilingSpaceKey` (display + Space identity)

**Cell**:
An atomic unit of the shared 4×2 refinement both layouts are built from; overlap is cell-set intersection.
_Avoid_: sub-tile, block

**Splitter**:
A movable divider between tiles whose fraction the drag-resize loop updates; screen edges are fixed, not splitters.
_Avoid_: divider, separator, boundary (the code name is GridBoundary)

**Eviction**:
Untiling a window to make room, restoring its pre-tile frame; what `plan` returns when another window overlaps the requested slot.
_Avoid_: displacement, removal

**Swap**:
A tiled requester trading tiles with the single window blocking its target: the blocker lands in the tile the requester vacated, nobody is untiled. The vacated tile must be disjoint from the target, or the request falls back to eviction.
_Avoid_: exchange, trade, tile swap (in prose; the code name is `swap`)

**Reflow**:
Absorbing freed cells: when a tiled window leaves the layout (eviction, untile, drag-out, close) or moves, its freed cells merge with exactly one adjacent survivor into a whole slot, and that survivor grows into it — rightmost candidate wins ties. A hole no survivor merges into exactly stays empty; the requester and expanded windows never grow. One undo chapter covers the event and its reflow together.
_Avoid_: growth, backfill, gap-filling (the code name is `reflow`)

**Re-house**:
Keeping an evictee tiled: when an eviction leaves exactly one whole slot free, the evicted window re-tiles into it (the middle third making room for the right two-thirds moves into the free top-left sixth) instead of being untiled; a region that is not exactly one slot falls back to untile-and-restore. Its undo entry returns it to the slot it was evicted from.
_Avoid_: relocation, re-assignment, re-seat

**Expand**:
Covering the layout: the ⌥⇧⏎ toggle resizes one window to fill its screen without releasing its slot; a second press retiles it.
_Avoid_: maximize, zoom, fullscreen

**Drag-out**:
Untiling by dragging: a title-bar drag past the untile distance releases the slot and leaves the window where dropped: the drop is the placement, never a pre-tile restore. A shorter drag snaps back into the tile.
_Avoid_: drag-to-untile, fling

**Requester**:
The window asking to be tiled in the current `handle` call; never evicts itself.
_Avoid_: focused window (focus is how it's usually found, not what it is)

**Window handle**:
The controller's opaque reference to a managed window, issued by the window gateway.
_Avoid_: window id (that's the pure-state key), element

**Plan execution**:
Committing a decided plan (tile or switch): snapshot, restore, place, rollback, and notice logic. Owned by the plan executor; the controller keeps focus, pruning, and dispatch.
_Avoid_: placement (which is only the place step), commit
