# Tiled User Guide

> Full hotkey, tiling, and resizing reference. Back to [README](../README.md).

## Hotkeys

Tile the focused window. Tiling a window into its own tile is a no-op (it
stays exactly where it is). Every slot key in the active layout exists as a
menu item under **Tile Focused Window** in the menu bar menu. The explicit
switch is its own top-level row beside that submenu, and the app actions have
their own top-level menu rows. A slot key never changes the layout: the
layout is a stored canvas choice that sticks even when the canvas empties.

### The eleven slot keys (hold ⌥⇧)

The same physical key means the same position in both layouts; the active
layout decides which slot it selects. Five keys have no Quarters slot and are
inert there (the dashes below); an inert press changes nothing and says which
layout owns the position.

| Key    | Quarters     | Sixths             |
|--------|--------------|--------------------|
| ⌥⇧U   | Top left     | Top left sixth     |
| ⌥⇧I   | —            | Top middle sixth   |
| ⌥⇧O   | Top right    | Top right sixth    |
| ⌥⇧M   | Bottom left  | Bottom left sixth  |
| ⌥⇧,   | —            | Bottom middle sixth |
| ⌥⇧.   | Bottom right | Bottom right sixth |
| ⌥⇧J   | Left half    | Left third         |
| ⌥⇧K   | —            | Middle third       |
| ⌥⇧L   | Right half   | Right third        |
| ⌥⇧H   | —            | Left two-thirds    |
| ⌥⇧;   | —            | Right two-thirds   |

### Switch layout (⌥⇧\)

| Key    | Action |
|--------|--------|
| ⌥⇧\   | Switch the layout of the display under the pointer (the menu's Switch Layout row follows focus instead): untiles every tiled window on that canvas (each keeps its top edge and takes the quarter footprint); one undo restores the windows and the previous layout. On an empty canvas it just switches. |

### App actions

The six app actions are remappable. Expand, Evict, Reset Splitters, and
Switch Layout share the slot keys' ⌥⇧ modifier; Settings and Undo
deliberately take all four modifiers (⌃⌥⇧⌘) so they can't collide with a
slot combo:

| Key    | Action |
|--------|--------|
| ⌥⇧⏎    | Expand the focused window to fill the screen (not fullscreen mode) |
| ⌥⇧⌫    | Evict the focused window: untile it and leave it floating at the quarter footprint |
| ⌥⇧R    | Reset Splitters: snap the focused canvas's splitters back to even splits, keeping every window tiled |
| ⌥⇧\    | Switch the layout of the display under the pointer (see above) |
| ⌃⌥⇧⌘,   | Open Settings (works even with the menu bar icon hidden, as long as this shortcut is enabled and registered; otherwise quit and reopen Tiled) |
| ⌃⌥⇧⌘Z   | Undo the focused canvas's last displacement (a layout switch, an eviction, or a swap — any reflow it caused is undone with it) |

### Expand (⌥⇧⏎)

Press ⌥⇧⏎ again and the window returns to its previous tile, or to its
previous frame if it wasn't tiled. The layout is never erased: a tiled
window keeps its slot while expanded (the expanded window just covers the
others, like focusing does), and tiling a neighbor into a free tile leaves
the expanded window alone.

### Evict (⌥⇧⌫)

Evicting leaves the focused window floating at the quarter
footprint (top edge kept, kept inside the visible frame) and releases
its slot. When a tiling request evicts a window, the victim keeps its
tiling whenever a whole slot fits: if its own slot overlaps the target and
the leftover (its slot minus the target) is exactly one whole slot, it
steps aside into that leftover (the left third asked for its top sixth
steps down into the bottom-left sixth); otherwise, when the request leaves
exactly one whole slot free, the victim re-tiles into that slot (the middle
third making room for the right two-thirds moves into the top-left sixth).
It untangles only when neither fits. The freed cells reflow: a neighboring tile that merges with
them into a whole slot grows into it — evict the bottom-left sixth and
the top-left sixth expands into the left third; free the middle third
and the right third becomes the right two-thirds (the right side wins
when both flanks could grow). The same reflow runs whenever a tiled
window leaves the layout (untile, drag-out, closing the window) or moves
to a free tile, and ⌃⌥⇧⌘Z undoes it together with the event that
caused it. A hole no neighbor can merge into exactly stays empty.

### Reset Splitters (⌥⇧R)

⌥⇧R and the menu row share one action: a reset snaps the focused canvas's
splitters back to even splits and parks the positions from before it; while
that backup is parked the same press (or the same row, then titled **Restore
Previous Splitters**) brings those positions back instead of resetting again.
A drag alone never arms the restore (and a drag after a reset doesn't clear
it). Windows stay in their slots either way; only the sizes change.

First launch opens Settings on a Welcome tab: focus any window and press the
Top Left slot key (⌥⇧U by default), with a miniature preview showing what the
top-left slot covers in both layouts. The guide shows your current binding
and the live switch shortcut; if the slot key is disabled or couldn't be
registered (another app owns the combo), it teaches menu bar → Tile Focused
Window → Top Left instead, and the Expand note names the menu row when that
combo is not live. A slot key never changes the layout: ⌥⇧\ switches it and
untiles every tiled window (undo restores them). Dismiss the guide once;
reopen it anytime from the menu bar menu → Tiled Guide.

The full list lives in the app too: menu bar → **Settings… → Shortcuts**.

Shortcuts are remappable: open the Shortcuts tab, click a shortcut, and
press a new combo. This covers every hotkey Tiled registers — the 11 slot
keys and the 6 app actions (Expand, Evict, Reset Splitters, Switch Layout,
Settings, Undo). Esc keeps the old one, ⌫ disables that action.
Disable or re-enable all eleven slot keys at once with the Enable/Disable
all button beside the Slot Keys section header (app actions disable one at
a time); your combos are parked aside and restored unchanged (re-recording
a disabled shortcut keeps the new combo and drops its park).

If two shortcuts use the same combo, the Shortcuts tab names the conflict
and keeps the old binding until you pick a free one. If a
shortcut fails to register, the menu says so. macOS does not report
another app owning a global shortcut to a non-exclusive registrant (the
key simply goes elsewhere), so Tiled can surface a dead combo but cannot
tell you which app took it.

## Tiling rules

- One window per slot.
- Tiling a window into a slot **evicts** any window occupying an overlapping
  slot. Evicted windows float at the quarter footprint, top edge kept.
  - **Mirror:** with two or more windows in the way, each moves to its own
    slot on the other side instead of untangling, so a left half tiled to the
    right half sends the two right quads to the two left quads, and a left
    two-thirds tiled to the right two-thirds sends the two right corner
    sixths to the two left ones. Windows land on the other side whether or
    not the requester held it. All or nothing: if any home is taken, or a
    middle third or middle sixth is in the way (it mirrors onto itself),
    every window in the way is evicted instead.
  - Two quads occupied on one side + the half key → both quads mirror to the
    other side, or both are evicted when the mirror cannot fit.
  - A half occupied + a quad key on that side → the half window steps aside
    into the other quad on that side when it's free; only then is it evicted.
- **Swap:** a tiled window tiling into a slot blocked by exactly one other
  tiled window swaps with it instead of evicting — unless the blocker's
  slot overlaps the target and its leftover (its slot minus the target) is
  exactly one whole slot, in which case the blocker steps aside into that
  leftover instead (see the re-house rule under Evict). Otherwise the
  blocker moves into the tile the requester vacated (which is disjoint from
  the target in the swap case), and both stay tiled. Focus follows the displaced window
  into the tile it landed in. (With more than one window in the way, or
  from an untiled window, the request evicts as above, and focus stays
  put.) Undo swaps back.
- Undo restores the displaced windows and returns the requester. If an
  app refuses a restore, undo reports that window instead of claiming
  success; a window that cannot be moved back keeps the slot it visibly
  holds, and the notice counts only the windows that landed.
- Tiling a window into its own tile does nothing: no restore, no reassert.
- A window re-tiling itself into an overlapping slot just moves (never evicts
  itself) and keeps its original pre-tile frame.
- **Drag a tiled window by its title bar**: past ~25pt of drag it untiles
  right where you dropped it (the drop's top edge takes the quarter
  footprint); a shorter drag snaps back into its tile. A single far jump
  with no recent hand press on the window (a programmatic move, not a
  hand drag) still snaps back, even if an unrelated click follows.
- Use the untile row in the menu (**Untile 1 Window** / **Untile N
  Windows**, titled by count) to float every tiled window on the focused
  canvas at the quarter footprint, or open a
  tiled window's submenu to focus it, untile just that window, or tile the
  focused window into its slot. The untile row is omitted when the focused
  canvas has no tiled windows; the window list still names windows on every
  visible display.
- Each canvas tiles independently, where a canvas is one display's one
  Mission Control Space. Every Space you reach by swiping up with three
  fingers has its own layout, occupancy, splitters, undo history, and
  notices, and so does every display: the same tile can be occupied in
  several Spaces and on several displays at once. Tiling, switching,
  drag-resizing, and ⌃⌥⇧⌘Z on one canvas never disturb another; Untile
  All and Reset Splitters act on the focused canvas only. (Where the
  window server withholds a Space id, Tiled falls back to one canvas per
  display rather than guessing.)
- The menu-bar glyph follows the display under the pointer, and the
  focused-canvas rows follow the focused window's display and Space; the
  window list still groups every visible display's windows. Swiping the
  pointer's display to another Space (or moving the pointer to another
  display) redraws the glyph (2×2 or 3×2) and its occupancy for the
  canvas that just became visible, even though there was no tiling
  action. Windows parked in hidden Spaces stay tiled and keep their
  history; they simply wait off-menu until you swipe back.
- Quarters and sixths are mutually exclusive per canvas: ⌥⇧\ switches the
  layout of the display under the pointer, untiling every tiled window on
  that canvas at the quarter footprint. One undo returns
  the windows and the previous layout.
  A canvas keeps its layout when the board empties. A slot key never
  switches: a key with no slot in the active layout is inert and says where
  it belongs. The menu names the effect and how to undo it ("Switched to
  Sixths · 3 windows untiled. Undo from the Tiled menu.").
- New windows open at quarter size — top edge kept —
  and stay floating; Tiled never auto-tiles. A window born while the
  mouse button is down (tearing a tab off Firefox) sizes at the drop
  point on mouse-up, so the resize never fights the drag.
- A display change (unplug, rearrange, resolution) re-asserts every visible
  canvas immediately. Canvas identity follows the physical display's
  CoreGraphics display number, so reordering screens never moves a display's
  arrangement to another display. Hidden Spaces are marked stale instead:
  Tiled never writes an off-Space window, because an AX resize can pull it
  onto the visible Space. Swiping back re-asserts that Space against the new
  bounds. A display that disappears keeps its canvas: its last geometry,
  splitters, and undo history survive unplugged, and nothing is written to
  it until it returns and is re-asserted.
- Some apps refuse programmatic resizing. When that happens the window is
  left alone and the menu says which app refused, so state and screen never
  silently disagree.
- Evict, Untile All, a window's untile row, and Undo announce success only
  after the controller performed the action: an empty undo stack, an
  untiled window, or a refused restore answers with exactly one message
  describing what happened (naming the display when the action touched
  another display's canvas).

## Live resizing

Drag any edge of a tiled window and the shared grid splitter's fraction
updates as you drag; the neighbor windows on the other side — and the
dragged window's own tile — are rewritten when the mouse button is
released. The row splitters are independent per column (quarters) or per
third (sixths), so resizing one column's rows never moves the other, and
the same independence holds between displays and Spaces, so dragging an
edge on one canvas never moves tiles on another. A two-thirds window
resizes as two equal one-thirds: the hidden splitter inside it follows
its outer edge, staying at the midpoint. A neighbor pushed narrower (or
shorter) than its app's minimum size simply stops shrinking at that
size, pinned to the screen edge it already held: the window always
stays inside the boundaries of the screen, never sliding off it. Since
the drag is yours and the floor is the app's, the edge you are dragging
keeps the position you gave it and covers over the minimum-size window:
the two overlap, and dragging the splitter back past the neighbor's
achieved edge makes them flush again. (A window that lands a few pixels
*short* of its target by rounding or an inset still owns the splitter,
so no gap opens.) Dragging an edge that coincides with the screen edge
itself (the top edge of a right two-thirds window, say) moves no
splitter — screen edges are fixed — and the edge snaps back to the
screen edge when you release: the drag is free while the button is
down, and the mouse-up re-assert pulls the edge home. A corner that
mixes a screen edge with a real splitter (the top-left corner of a
two-thirds window) resizes the splitter live as usual and keeps the
new splitter position; only the screen edge snaps back.
**Reset Splitters** in the menu and ⌥⇧R share one action: a reset snaps the
focused canvas's splitters back to even splits and parks the pre-reset
positions; while that backup is parked the same row is titled **Restore
Previous Splitters** and both surfaces bring those positions back. That
restore row stays until the backup is used, even if Untile All empties the
canvas. The plain **Reset Splitters** row needs a tiled edge, so it is omitted
when the focused canvas has no tiled windows and no parked backup.

