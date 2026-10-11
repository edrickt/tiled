# Resize reassert — the canvas owns the resize settle

Audit origin: architecture review of 2026-10-11, candidates 1 ("Settle the dragged window into its slot")
and 2 ("Give the canvas its own bounds"), taken together. Design settled by grilling on 2026-10-11.
Vocabulary: `CONTEXT.md` (Visible frame, Reassert, Achieved frame). Decision: `docs/adr/0002-canvas-owns-visible-frame-and-reassert.md`.
This file is the single source of truth for the design and the stage map.

## Problem Statement

Dragging a tiled window's edge to resize it is unreliable: the window does not always end up exactly in its
tile, and a gap can open between it and the neighbour that shares the edge. From the user's side the resize
feels like it "almost" lands — sometimes flush, sometimes a few points off, sometimes leaving a strip of
desktop between two tiles that should touch.

The mechanism is the cause, not any one defect. The canvas never owns its own geometry: every rect is
derived from whichever window's frame happens to be at hand, so two occupants of one canvas can compute
different bounds for the same shared edge. And the settle step deliberately *excludes* the dragged window,
so "the window is in its tile" is assumed, never checked — a far edge the app rounded or clamped is left
uncorrected until something else reasserts the whole layout.

## Solution

The canvas becomes the single owner of its geometry and its settle. A canvas holds one **visible frame** —
the visible frame of its display — and every rect on it derives from that one frame. After a resize the
canvas **reasserts** the whole layout in one operation: it first reconciles any app-clamped edge back to the
dragged window's **achieved frame**, then re-derives and writes every tiled occupant's rect under the one
visible frame, the dragged window included. The dragged window's tile is then an invariant the code asserts
rather than an assumption it hopes holds.

## User Stories

1. As a user dragging a tiled window's edge, I want the window to end up exactly in its tile when I release, so the layout is predictable.
2. As a user dragging a tiled window's edge, I want the neighbour across that edge to sit flush against the window I resized, so there is never a gap or an overlap.
3. As a user dragging a tiled window's edge, I want the neighbour to abut the window's real edge even when the app refused to shrink it below its minimum size, so a clamped app never opens a gap.
4. As a user dragging a tiled window's edge, I want the splitter to end up where the window actually landed, not where my cursor went, so a later resize starts from reality.
5. As a user dragging a tiled window's edge, I want the resize to feel the same in every canvas — quarters, sixths, every display, every Space — so I do not have to learn per-layout quirks.
6. As a user dragging a two-thirds window's edge, I want its hidden one-thirds divider to stay at the midpoint, so the window still reads as two equal thirds.
7. As a user who drags a tiled window's edge on one canvas, I want the tiles on another display or Space to stay untouched, so resizing never crosses canvases.
8. As a user who drags a tiled window's title bar a short distance, I want it to snap back into its tile with the same flush guarantee as an edge resize, so both gestures end the same way.
9. As a user who drags a tiled window's title bar past the untile distance, I want it to leave the layout exactly as it does today, so drag-out is unchanged.
10. As a user with a window expanded over the layout, I want a neighbour's resize to leave the expanded window alone, so expansion still covers the others without being dragged into a slot.
11. As a user whose display changed (unplugged, rearranged, or resolution changed), I want every visible canvas to put itself back on the correct grid, so the layout follows the screen.
12. As a user who swipes back to a Space whose layout was stale, I want that canvas to reassert against the new bounds, so a hidden canvas is correct the moment it is visible.
13. As a user who presses Reset Splitters, I want every window to stay in its slot with the splitters at even splits, so only the sizes change.
14. As a user who presses Restore Previous Splitters, I want the pre-reset splits back, so one press undoes the reset.
15. As a user whose app refuses programmatic resizing, I want the menu to still name the app that refused, so state and screen never silently disagree.
16. As a user who resizes on a canvas that is not the visible Space, I want Tiled to hold the write until the swipe back rather than pull the window onto the visible Space, so a hidden canvas is never disturbed.
17. As a user who undoes a displacement, I want the restore to reassert against the canvas's own bounds, so an undo after a display change lands correctly.
18. As a user, I want an edge-resize that ends exactly on the existing tile to issue no write, so a no-op drag costs nothing and provably changes nothing.
19. As a maintainer, I want the resize settle to be one operation on the canvas, so I change it in one place instead of two.
20. As a maintainer, I want the one non-obvious behaviour — reconciling a clamped edge — to be testable headless, so a regression is caught in the unit suite without AX.
21. As a maintainer, I want the drag loop to decide only, so it no longer owns a second copy of the rect math or a second no-op-write policy.
22. As a maintainer, I want a canvas's bounds resolved once, so no future change can reintroduce a per-window bounds path.

## Implementation Decisions

- **The canvas owns its geometry.** The canvas gains one stored **visible frame** (the display's visible frame). It is resolved and installed when the canvas is established and refreshed only on the events that already trigger a full reassert: display change, swipe back, and splitter reset. It is never resolved per window and never per drag. The canvas's context loses its per-frame bounds provider; every rect computation inside the canvas reads the stored frame instead.
- **One reassert operation, over a pure core.** The canvas's reassert is the single entry point for "the splitters changed": an edge drag's mouse-up, a title-bar snapback, a display change, a swipe back, and a splitter reset. It is split into a **pure plan** (reconcile the grid, map every occupant's slot to a rect) and a **thin effectful wrapper** (store the grid, seed the drag loop's diff baselines, publish through the write policy). The pure plan takes no gateway, no clock, and no scheduler; it is the deep module and the test surface.
- **The input is a small sum type, not a request object.** The reassert source is either `.resize(dragged:achieved:)` or `.grid`. No scope set, no convergence-check knob: those are speculative and have no current caller. A future overlay-handle gesture can add a case; it is not built now.
- **The dragged window is asserted.** The reassert writes every tiled, non-expanded occupant including the dragged window — no exclusion set. When its reconciled rect already equals its frame, the write policy's no-op skip collapses the write, so a clean drag costs nothing.
- **The clamp is reconciled before the rects.** When an app held the dragged window short of the splitter, the window's achieved frame is authoritative: the reassert moves the splitter back to the achieved edge, then maps the rects. Neighbours abut the window itself, never the phantom splitter. The achieved frame is read once, by the coordinator (the one effect the pure core cannot perform), and passed in as a value.
- **The drag loop becomes decide-only.** The tracker stops computing rects and stops scheduling writes. It still detects edges, suppresses echoes, and commits live splitter fractions during the drag — but at a drag's end it emits a decision (resize / snapback / untile) and the coordinator routes it to the owning canvas's reassert. Its rect math, its runloop coalescing, and its duplicate no-op-write skip are deleted.
- **One rule for the two-thirds divider.** The occupant-aware rule for which two-thirds window's hidden divider follows a splitter moves out of the drag loop into the grid as a pure function, so the live path and the reassert share one declaration.
- **The write policy stays the only write path.** Every reassert write goes through the existing write policy (no-op skip, off-Space deferral, echo marking, minimum-size repin, convergence check, refusal counting). The policy takes the canvas's visible frame so the repin is judged against the same frame the target was derived from.
- **The trigger is unchanged.** The commit still fires on the global mouse-up. Committing on the drag's own end instead is a separate, deliberate follow-up.
- **Vocabulary.** Reassert, Visible frame, and Achieved frame are defined in `CONTEXT.md`; the shape decision is `docs/adr/0002`.

## Testing Decisions

A good test here asserts observable outcomes through a seam — a window's frame as the fake gateway sees it, and the canvas's grid — not internal state or private helpers. Behaviour-preserving moves are validated by the existing suite; new behaviour needs new tests at the seam.

**One seam, split in two layers.** The resize reassert is tested at the canvas, which is also where it lives:

- **The pure plan, headless.** Construct a canvas with occupancy, records, a grid, and a visible frame; call the pure reconcile-and-plan; assert the reconciled grid and every target rect. This is where the clamp gap-fix, the reconcile-before-rect ordering, the two-thirds centering, the expanded-skip, and the occupant set are locked down — no gateway, no runloop, in the ~2s suite.
- **The whole canvas through the write policy, with the fake gateway.** Drive the effectful reassert and assert frames and grid, and that refusals still land on the canvas. This absorbs the current `publish` / reassert tests and the minimum-size end-to-end test.
- **The drag loop decides only.** A recording drag-end callback proves the tracker hands off the right window and decision and computes no rects. The existing drag tests move their rect assertions to the canvas tests.

**Existing seams preferred.** The coordinator → canvas → fake-gateway path stays as it is; the minimum-size end-to-end test keeps its shape and gains the "no gap after mouse-up" assertion. The pure plan is the only new seam, and it is the highest one available: it crosses the module's real interface, so tests survive any internal refactor.

**Prior art.** `DragTrackerTests` (drag decisions and echo), `TilingSpaceTests` (canvas operations), `MinimumSizeTests` (the clamped-neighbour end-to-end shape), `ControllerGatewayTests` (coordinator through the fake), `GridLayoutTests` (grid math and the two-thirds divider), and `FakeWindowGateway` (the local stand-in).

**Gate.** `swift build` stays warning-free, the suite stays green, and the mutation table stays caught — re-pointing any mutant whose path or target text moves, and adding entrants for the new reconcile behaviour.

## Out of Scope

- Committing on the drag's own end (a resize transaction bound to the drag lifecycle) instead of the global mouse-up.
- Repairing a *neighbour's* minimum-size clamp in the same pass (a fixed-point over clamped occupants). The dragged window's own clamp is in scope; a clamped neighbour is a follow-up.
- Owned overlay resize handles.
- Any change to drag-out, eviction, reflow, re-house, undo, expand, layout switching, or observation.
- Making the no-op-write policy single is absorbed by this work, not deferred.

## Stages

| # | Ticket | Delivers | Blocked by | Status |
|---|--------|----------|------------|--------|
| 1 | `issues/01-canvas-visible-frame.md` | Canvas owns one visible frame | - | DONE (`ebbb47a`) |
| 2 | `issues/02-pure-reassert-plan.md` | Pure reassert plan + clamp reconcile | 1 | DONE (`6c0c5a4`) |
| 3 | `issues/03-tracker-decides-only.md` | Drag loop decides only; canvas settles the resize | 2 | DONE (`2edfeba`) |
| 4 | `issues/04-contract-and-tests.md` | Dead seams deleted; tests describe the new seam | 3 | ready-for-agent |

## Running one stage in a fresh session

One stage per context window. Start the session with:

```
Read .scratch/resize-reassert/README.md, then implement
.scratch/resize-reassert/issues/03-tracker-decides-only.md (replace with the stage ticket).
```

Then work the ticket (the gates are the `canvas-aggregate` arc's, unchanged):

1. Read this file, the stage ticket, and `CONTEXT.md`; respect `docs/adr/0002`.
2. Build through the `tdd` skill: one red-green slice at a time. Behaviour-preserving moves are validated by the existing suite instead of new tests.
3. Gates, tiered by cost:
   - Every red-green slice: `swift test` -> all green (it compiles too, so warnings surface here).
   - While iterating on the stage's subjects: `python3 tools/mutation/mutate.py --since <stage base>` -> every selected mutant CAUGHT, none STALE.
   - Once before commit: full `python3 tools/mutation/mutate.py` -> the whole table CAUGHT, none STALE.
4. Close with the `code-review` skill (Standards + Spec) against the stage's base commit.
5. Commit on `master` in the repo's style (imperative subject, the why in the body, gate evidence at the end), then update the stage ticket and the table above with the commit hash and status.

## Further Notes

- The visual version of the design is the audit report's candidate 1 and 2 cards (temp path from the 2026-10-11 review; not stored in the repo).
