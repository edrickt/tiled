# Tiled

A native macOS window manager: tile windows into quarters or sixths with global hotkeys or the menu bar, with live drag-resize of shared edges.

## Language

**Slot**:
A named tile a window can occupy (Top Left, Left Third, …), defined by its set of cells.
_Avoid_: tile, zone, region

**Layout**:
One of two mutually exclusive geometries per tiling space: quarters (2×2 plus halves) or sixths (3×2 grid plus thirds and two-thirds). Each display's each Space runs its own. A request in the other layout switches the space's layout, untileing every other tiled window (the requester takes its slot), rather than coexisting.
_Avoid_: mode, grid

**Space**:
A macOS Mission Control desktop, identified by its window-server id. A window belongs to one Space on one display; Spaces exist independently per display when "Displays have separate Spaces" is on.
_Avoid_: desktop, workspace, virtual desktop

**Tiling space (canvas)**:
One display's one Mission Control Space: its occupancy, layout, splitters, undo chapters, and notices. Tiling acts on the requesting window's canvas; menus aggregate the visible canvases (the manage list groups per display). A canvas whose Space id the OS withholds falls back to per-display state, and is treated as visible, not hidden.
_Avoid_: monitor space (prose for the display dimension only), screen (AppKit type), desktop
_Code_: `TilingSpace` (one canvas's occupancy, records, splitters, expansion, visible frame, placement pipeline, and undo chapters), `TilingSpaceKey` (display + Space identity); `TilingController` restores chapters across canvases and owns the success/refusal narration.

**Cell**:
An atomic unit of the shared 4×2 refinement both layouts are built from; overlap is cell-set intersection.
_Avoid_: sub-tile, block

**Splitter**:
A movable divider between tiles whose fraction the drag-resize loop updates; screen edges are fixed, not splitters. Dragging an edge that sits on a screen edge moves no splitter, yet the mouse-up still reasserts: the screen edge snaps back to the visible frame — free mid-drag, snapped back on release.
_Avoid_: divider, separator, boundary (the code name is GridBoundary)

**Visible frame**:
The one display geometry a canvas tiles against: the visible frame of the display that canvas lives on, menu bar and Dock excluded. The canvas owns it, resolved once when the canvas is established and refreshed on a display change, a swipe back, and a splitter reset; an absent display's canvas keeps the frame it had until the display returns. Every rect on the canvas derives from this one frame, so two occupants can never disagree about where their shared edge is.
_Avoid_: screen bounds, monitor frame, working area (one step of the screen-resolution chain, not the canvas's stored geometry)
_Code_: `TilingSpace.visibleFrame` (replaces the per-window `Context.boundsOf`)

**Reassert**:
Putting the screen back on the grid after a drag: the canvas reconciles any app-clamped edge back to the dragged window's achieved frame, re-derives every non-expanded tiled occupant's rect under its one visible frame, and writes them — the dragged window included, unlike a resize mid-drag. One reassert covers an edge drag's mouse-up, a title-bar snapback, a display change, a swipe back, and a splitter reset.
_Avoid_: settle (the placement pipeline's own step), reflow (reflow merges freed cells into a survivor; reassert changes no slot), refresh
_Code_: `TilingSpace.reassert(_:context:)`, over the pure core `TilingSpace.reassertPlan(_:)`

**Achieved frame**:
Where an app actually left the window, which an app's minimum-size floor can hold short of the splitter the cursor moved. The reassert trusts the achieved frame over the splitter, so neighbours abut the window itself and never the splitter it could not reach.
_Avoid_: actual frame, clamped frame (a clamp is one cause), intent (the drag loop's pushed target, which is where we aimed, not where the app landed)
_Code_: the dragged window's live frame, read at reassert

**Eviction**:
Untiling a window to make room, restoring its pre-tile frame; what `plan` returns when another window overlaps the requested slot.
_Avoid_: displacement, removal

**Swap**:
A tiled requester trading tiles with the single window blocking its target: the blocker lands in the tile the requester vacated, nobody is untiled. The vacated tile must be disjoint from the target, or the request falls back to eviction. A blocker whose leftover (its slot minus the target) is exactly one whole free slot never swaps — it steps aside instead (see Re-house), keeping its own strip.
_Avoid_: exchange, trade, tile swap (in prose; the code name is `swap`)

**Reflow**:
Absorbing freed cells: when a tiled window leaves the layout (eviction, untile, drag-out, close) or moves, its freed cells merge with exactly one adjacent survivor into a whole slot, and that survivor grows into it — rightmost candidate wins ties. A hole no survivor merges into exactly stays empty; the requester and expanded windows never grow. One undo chapter covers the event and its reflow together.
_Avoid_: growth, backfill, gap-filling (the code name is `reflow`)

**Re-house**:
Keeping an evictee tiled instead of untangling it. Two rules, step-aside checked first, both exact-or-nil: when the evictee's slot overlaps the requested slot and its leftover — its slot minus the request — is exactly one whole unoccupied slot, the blocker steps aside into that leftover (the left third requested at its top sixth steps down into the bottom-left sixth, the left half into the bottom-left quad, a two-thirds into the third its request leaves clean; the one overlap that is not a containment — a left two-thirds blocking a right two-thirds request — steps aside into the left third); otherwise, when the cells left free after the request form exactly one whole slot, the evicted window re-tiles into that slot (with the bottom-left sixth occupied, the middle third making room for the right two-thirds moves into the free top-left sixth). A region or leftover that is not exactly one slot falls back to untile-and-restore, and expanded windows never re-house — they untangle (see Expand). The step-aside covers tiled requesters too: it wins over a swap, because the blocker keeps its own strip instead of teleporting to the requester's vacated tile, whose cells then reflow to a neighbor or to the re-housed blocker itself. Undo puts the whole chapter back: each moved window returns to the slot it was evicted from, which for a step-aside is its original full slot, and a tiled requester returns to the slot it vacated.
_Avoid_: relocation, re-assignment, re-seat, displacement (an eviction untiles; a re-house moves, and never the reverse)

**Expand**:
Covering the layout: the ⌥⇧⏎ toggle resizes one window to fill its screen without releasing its slot; a second press retiles it. An expanded window never grows (see Reflow) and never re-houses or steps aside (see Re-house); on eviction it untangles.
_Avoid_: maximize, zoom, fullscreen

**Drag-out**:
Untiling by dragging: a title-bar drag past the untile distance releases the slot and leaves the window where dropped: the drop is the placement, never a pre-tile restore. The drop decides the drag (a move-silence debounce is the fallback when the mouse-up is missed). A shorter drag snaps back into the tile.
_Avoid_: drag-to-untile, fling

**Requester**:
The window asking to be tiled in the current `handle` call; never evicts itself.
_Avoid_: focused window (focus is how it's usually found, not what it is)

**Window handle**:
The controller's opaque reference to a managed window, issued by the window gateway.
_Avoid_: window id (that's the pure-state key), element

**Plan execution**:
Committing a decided plan (tile, swap, or switch): snapshot, restore, place, rollback, and notice logic. Owned by the tiling space's placement pipeline; the controller keeps focus, pruning, and dispatch.
_Code_: `TilingSpace.execute(decision:)`
_Avoid_: placement (which is only the place step), commit

**Expected write**:
One frame the canvas intends to put on a window, taken through the one shared write policy: expected (written), already correct (a no-op skip), refused by the app, or deferred off-Space.
_Avoid_: push, setFrame (the gateway call, one policy outcome), placement (a whole plan)

**Deferral (deferred off-Space write)**:
A write the policy skipped because the window's canvas is on a Mission Control Space the user cannot see; writing blind could pull the window onto the visible Space. A deferral is **never a failure anywhere**: the write's intent stands — a committed slot, a pre-tile restore, an expansion, or a collapse — and reconciles when the Space becomes visible (swipe back), exactly as a deferred reflow does — and it is narrated as a deferral ("That Space isn't visible yet"), never as an app refusal. Only a genuine refusal rolls a placement back.
_Code_: `FrameWriter.Result.stands` (the one read every push path shares); `MenuText.deferredOffSpaceAnnouncement()`
_Avoid_: refused, ignored write, hidden-canvas failure, rollback
