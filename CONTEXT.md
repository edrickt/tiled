# Tiled

A native macOS window manager: tile windows into quarters or sixths with global hotkeys or the menu bar, with live drag-resize of shared edges.

## Language

**Slot**:
A named tile a window can occupy (Top Left, Left Third, …), defined by its set of cells.
_Avoid_: tile, zone, region

**Layout**:
One of two mutually exclusive geometries per tiling space: quarters (2×2 plus halves) or sixths (3×2 grid plus thirds and two-thirds). Each display's each Space runs its own, stored on the canvas and kept when the board empties. `⌥⇧\` switches it explicitly: every tiled window on that canvas is restored to its pre-tile frame, and one undo returns the windows and the previous layout. A slot request never switches; a key with no slot in the active layout is inert and names the layout that owns the position. Two layouts never coexist on one canvas.
_Avoid_: mode, grid

**Slot key**:
One of the eleven physical ⌥⇧ keys (U I O M , . J K L H ;) that selects the matching position in the canvas's active layout. The same key means Top Left in both layouts; the mapping from key to slot lives in `SlotGeometry.key`, and `SlotKey.slot(in:)` resolves it. A key with no slot in the active layout is inert. Its persisted identity is the sixths slot's raw value; the six retired quarter names are deleted at launch.
_Avoid_: slot shortcut, layout shortcut, quarter key, sixths key (the key is shared)
_Code_: `SlotKey`, `SlotGeometry.key`

**Space**:
A macOS Mission Control desktop, identified by its window-server id. A window belongs to one Space on one display; Spaces exist independently per display when "Displays have separate Spaces" is on.
_Avoid_: desktop, workspace, virtual desktop

**Tiling space (canvas)**:
One display's one Mission Control Space: its occupancy, layout, splitters, undo chapters, and notices. Tiling acts on the requesting window's canvas; menus aggregate the visible canvases (the manage list groups per display), while the undo, untile-all, and splitter rows and their counts follow the focused canvas. A canvas whose Space id the OS withholds falls back to per-display state, and is treated as visible, not hidden.
_Avoid_: monitor space (prose for the display dimension only), screen (AppKit type), desktop
_Code_: `TilingSpace` (one canvas's occupancy, records, splitters, expansion, visible frame, placement pipeline, and undo chapters), `TilingSpaceKey` (display + Space identity); `TilingController` restores chapters across canvases.

**Canvas directory**:
The one owner of display plus Space identity: the canvas table, stale marks, the last focused canvas, the last display the cursor was seen on, visibility, the withheld-Space fallback, and the single visible-canvas enumeration. A display action resolves the identified canvas when it holds anything, else that display's withheld canvas; the manage list enumerates both so a withheld canvas's windows stay reachable. The status glyph's canvas resolves from the cursor's display; the Switch Layout hotkey acts on the cursor's display too; every other menu row and action resolves from the focused one.
_Avoid_: monitor table, space registry
_Code_: `CanvasDirectory`

**Window register**:
The controller's identity and lifetime bookkeeping for window handles: which id a handle wears, the id allocator, the death-confirmation clock, and any pending convergence check. Ownership stays derived from the canvas records; the register reads through them and keeps no id-to-canvas map.
_Avoid_: handle table, ownership map (the canvas records own canvases)
_Code_: `WindowRegister`

**Receipt**:
The user-visible truth of one app action: whether it performed, the canvas that owns the outcome, the menu's sticky notice, and exactly one spoken sentence. The controller builds it at the action's commit point; the delegate only presents it.
_Avoid_: result, feedback, notification (one channel, not the whole truth)
_Code_: `ActionReceipt`

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
Putting the screen back on the grid after a drag: the canvas reconciles any app-clamped edge back to the dragged window's achieved frame, re-derives every non-expanded tiled occupant's rect under its one visible frame, and writes them — the dragged window included, unlike a resize mid-drag. One reassert covers an edge drag's mouse-up, a title-bar snapback, a display change, a swipe back, and a splitter reset. Expanding supersedes a pending edge drag, and an expanded dragged window's screen-sized frame never reconciles a splitter.
_Avoid_: settle (the placement pipeline's own step), reflow (reflow merges freed cells into a survivor; reassert changes no slot), refresh
_Code_: `TilingSpace.reassert(_:context:)`, over the pure core `TilingSpace.reassertPlan(_:)`

**Achieved frame**:
Where an app actually left the window, which an app's minimum-size floor can hold short of the splitter the cursor moved. The reassert trusts the achieved frame over the splitter, so neighbours abut the window itself and never the splitter it could not reach. A frame that lands *smaller* than its target fell short by rounding or an inset, and its achieved edge wins the splitter, so no gap opens. A frame that lands *larger* than its target is a floor clamp (see Floor clamp): the window keeps its floor and the splitter keeps the position the drag gave it.
_Avoid_: actual frame, clamped frame (a clamp is one cause), intent (the drag loop's pushed target, which is where we aimed, not where the app landed)
_Code_: the dragged window's live frame, read at reassert

**Floor clamp**:
A written frame an app answered larger than its target because the size it was given was below its own minimum: the app keeps the target's origin and grows away from it, so a floor-clamped frame can escape the visible frame, and the write policy repins it to hold the screen edge it already hugged. The window keeps its floor exactly where it stands — its minimum size and the screen edge it held — and the reassert moves no splitter for it: the expanding window keeps the edge the drag reached and covers over the floor-width neighbour, the two overlapping instead of the drag being pulled back by a size the neighbour cannot give up. A later grid reassert re-clamps the neighbour in place, so the overlap is the stable answer, not a transient; dragging the splitter back past the neighbour's achieved edge makes the two flush again.
_Avoid_: minimum-size clamp (the write policy's repin step, one part of this), clamped frame (unqualified: a rounding shortfall is not a floor), pinned window (the frame is pinned, not the window)
_Code_: `FrameWriter.repinnedInsideBounds` (the repin); the grown-axis test in `TilingSpace.reconcileAchievedEdges` (no splitter moves)

**Eviction**:
Untiling a window to make room, restoring its pre-tile frame; what `plan` returns when another window overlaps the requested slot.
_Avoid_: displacement (the undo chapter, not the eviction), removal

**Swap**:
A tiled requester trading tiles with the single window blocking its target: the blocker lands in the tile the requester vacated, nobody is untiled. The vacated tile must be disjoint from the target, or the request falls back to eviction. A blocker whose leftover (its slot minus the target) is exactly one whole free slot never swaps — it steps aside instead (see Re-house), keeping its own strip.
_Avoid_: exchange, trade, tile swap (in prose; the code name is `swap`)

**Reflow**:
Absorbing freed cells: when a tiled window leaves the layout (eviction, untile, drag-out, close) or moves, its freed cells merge with exactly one adjacent survivor into a whole slot, and that survivor grows into it — rightmost candidate wins ties. A hole no survivor merges into exactly stays empty; the requester and expanded windows never grow. One undo chapter covers the event and its reflow together.
_Avoid_: growth, backfill, gap-filling (the code name is `reflow`)

**Re-house**:
Keeping an evictee tiled instead of untangling it. Two rules, step-aside checked first, both exact-or-nil: when the evictee's slot overlaps the requested slot and its leftover — its slot minus the request — is exactly one whole unoccupied slot, the blocker steps aside into that leftover (the left third requested at its top sixth steps down into the bottom-left sixth, the left half into the bottom-left quad, a two-thirds into the third its request leaves clean; the one overlap that is not a containment — a left two-thirds blocking a right two-thirds request — steps aside into the left third); otherwise, when the cells left free after the request form exactly one whole slot, the evicted window re-tiles into that slot (with the bottom-left sixth occupied, the middle third making room for the right two-thirds moves into the free top-left sixth). A region or leftover that is not exactly one slot falls back to untile-and-restore, and expanded windows never re-house — they untangle (see Expand). The step-aside covers tiled requesters too: it wins over a swap, because the blocker keeps its own strip instead of teleporting to the requester's vacated tile, whose cells then reflow to a neighbor or to the re-housed blocker itself. Undo puts the whole chapter back: each moved window returns to the slot it was evicted from, which for a step-aside is its original full slot, and a tiled requester returns to the slot it vacated.
_Avoid_: relocation, re-assignment, re-seat, displacement (the undo chapter, not the move)

**Displacement (undo chapter)**:
The undo model's whole destructive event: the windows it evicted, moved (a re-house or swap), or grew by reflow, plus a requester that left its slot when the event displaced another window. A requester that moves to a free tile with no displacement leaves no chapter. A swap displaces without untiling anyone, so the chapter and its undo copy say "displaced", never "evicted". A chapter stores no layout: undo derives the restored layout from the chapter's slots, so a switch chapter puts back the previous layout with its windows.
_Avoid_: switch (undo covers swaps and evictions too), eviction (one cause and one kind of chapter entry)
_Code_: `TilingSpace.UndoChapter`, `TilingSpace.displacedCount`

**Expand**:
Covering the layout: the ⌥⇧⏎ toggle resizes one window to fill its screen without releasing its slot; a second press retiles it into that slot, or restores its pre-expand frame when it had none. An expanded window never grows (see Reflow) and never re-houses or steps aside (see Re-house); on eviction it untangles.
_Avoid_: maximize, zoom, fullscreen

**Drag-out**:
Untiling by dragging: a title-bar drag past the untile distance releases the slot and leaves the window where dropped: the drop is the placement, never a pre-tile restore. The drop decides the drag (a move-silence debounce is the fallback when the mouse-up is missed). A shorter drag snaps back into the tile. A single far tick is a hand drag only when a recent hand press landed on that window and mouse movement kept it live; an unrelated press elsewhere cannot turn a programmatic move into a drag-out.
_Avoid_: drag-to-untile, fling

**Requester**:
The window asking to be tiled in the current `handle` call; never evicts itself.
A Chromium/CEF host can leave AX with no focused application to name (it
exposes no focused UI element), so a requester AX cannot name is resolved
from the workspace's frontmost app; that fallback never overrides an answer
AX gave.
_Avoid_: focused window (focus is how it's usually found, not what it is)
_Code_: `LiveWindowGateway.focusSource`

**Window handle**:
The controller's opaque reference to a managed window, issued by the window gateway.
_Avoid_: window id (that's the pure-state key), element

**Parked combo**:
A hotkey binding the Shortcuts tab holds so a later action can restore it. Disable all parks the eleven slot keys' current combos and Enable all restores them; app actions disable one at a time. Reset Shortcuts parks one whole pre-reset snapshot instead, and Restore Previous Shortcuts applies it as one state, keeping a clash-skipped entry for a retry. The two namespaces never share a key.
_Avoid_: saved shortcut, stored combo
_Code_: `ShortcutPark` (both namespaces and the footer's two-state answer), `BulkRestorePlan`, `SnapshotRestorePlan`

**Plan execution**:
Committing a decided plan (tile or swap): snapshot, restore, place, rollback, and notice logic. Owned by the tiling space's placement pipeline; the controller keeps focus, pruning, and dispatch. The layout switch is a separate canvas action, not a `TilePlan` branch.
_Code_: `TilingSpace.execute(decision:)`
_Avoid_: placement (which is only the place step), commit

**Expected write**:
One frame the canvas intends to put on a window, taken through the one shared write policy: expected (written), already correct (a no-op skip), refused by the app, or deferred off-Space.
_Avoid_: push, setFrame (the gateway call, one policy outcome), placement (a whole plan)

**Deferral (deferred off-Space write)**:
A write the policy skipped because the window's canvas is on a Mission Control Space the user cannot see; writing blind could pull the window onto the visible Space. A deferral is **never a failure anywhere**: the write's intent stands — a committed slot, a pre-tile restore, an expansion, or a collapse — and reconciles when the Space becomes visible (swipe back), exactly as a deferred reflow does — unless a newer slot request, undo re-place, or expand claims the same window first: retiling or expanding it discards its pre-tile restore on every canvas, so the canvas it left can never write the old frame over the new slot or expanded frame. A deferral is narrated as a deferral ("That Space isn't visible yet"), never as an app refusal. Only a genuine refusal rolls a placement back.
_Code_: `FrameWriter.Result.stands` (the one read every push path shares); `MenuText.deferredOffSpaceAnnouncement()`
_Avoid_: refused, ignored write, hidden-canvas failure, rollback
