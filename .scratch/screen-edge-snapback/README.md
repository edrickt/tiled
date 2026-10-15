# Screen-edge snap-back (rubber band)

Grilled and decided 2026-10-15; parked in favor of the documentation-accuracy
pass running the same day. Everything below was verified against the code at
`ab6ce65`.

Shipped 2026-10-15: the fix below landed as designed — `processResize` now
marks the canvas pending on any edge movement (the field is `pendingReasserts`),
the red test is `testScreenEdgeDragEmitsResizeOnMouseUp`, README/CONTEXT.md/
CHANGELOG describe the shipped behavior, and 678 tests are green.

## The behavior (agreed spec)

Screen edges are rubber bands:

1. **Mid-drag**: dragging a slot edge that coincides with a screen edge
   changes nothing — the edge follows the cursor freely (today's behavior),
   no clamping, no preview, no untile trigger.
2. **On release**: the screen edge snaps back (instant, one AX write) to the
   canvas's visible-frame edge, for all four screen edges and corners
   uniformly. No animation (an AX write cannot be animated; a spring would
   need timer-stepped writes — rejected for now, revisit only if the instant
   restore feels jarring).
3. **Corner drags** mixing a movable splitter edge with a screen edge: the
   splitter resizes live as today, and the screen edge snaps back on
   release (this case already works — the splitter update marks the drag
   pending, so mouse-up emits a decision).

## Root cause (the bug)

`DragTracker.processResize`
(`Sources/tiled/DragTracker.swift:504-539` at `ab6ce65`) marks the drag
pending (`pendingResizeApplies[space] = id`) only inside `if changed`, and
`changed` only becomes true when a **movable splitter** was updated. A pure
screen-edge drag hits the `boundary == nil` guard (line 521) and `continue`s
before anything is marked — so `mouseLifted` (lines 563-573) emits **no
decision**, no reassert runs, and the edge stays wherever the user released
it. The reassert machinery that would restore the edge already exists and
already handles fixed edges correctly
(`TilingSpace.reassert(.resize(dragged:achieved:))` skips them in splitter
reconciliation and re-derives the window's rect from its slot); it is simply
never invoked.

Confirmed live by the user: the top edge of the right two-thirds stays
dragged away after release.

## Fix (test-first)

- **Red**: a `DragTrackerTests` case — a tick that moves only a screen edge
  (no boundary), then `mouseLifted()`, must emit `.resize(id)` (today it
  emits nothing). This path is currently untested.
- **Green**: in `processResize`, mark the drag pending whenever any edge
  moved, even when no splitter updated (a separate "any edge moved" flag or
  equivalent minimal change).
- **Verify**: the 31 existing tracker tests, the reassert-plan tests, and
  the corner-drag cases stay green.
- **Docs**: once shipped, update the screen-edge paragraph in README's
  "Live resizing" section and the Splitter entry in `CONTEXT.md` (both
  currently describe the as-built gap and say so).
