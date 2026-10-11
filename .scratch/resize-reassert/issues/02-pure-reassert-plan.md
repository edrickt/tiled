# Stage 2 - The pure reassert plan and the clamp reconcile

Status: ready-for-agent
Blocked by: stage 1
Blocks: stage 3

## What to build

The canvas can put itself back on the grid in one operation, over a **pure plan**, and reconcile an
app-clamped edge back to the dragged window's **achieved frame** before it maps any rect. The plan is the
deep module: a pure function of occupancy, grid, visible frame, and a reassert source, returning the
reconciled grid and every target rect. A thin effectful wrapper stores the grid, seeds the drag loop's diff
baselines, and publishes through the write policy.

Delivers the headless-testable half of the resize fix: the clamp gap becomes a value assertion.

## Acceptance criteria

- [ ] A pure plan maps (occupancy, grid, visible frame, source) to a reconciled grid plus every tiled occupant's target rect. It takes no gateway, no clock, no scheduler.
- [ ] Source `.resize(dragged:achieved:)` reconciles the splitter back to the achieved edge before mapping rects; source `.grid` leaves the splitters alone (display change, swipe back, reset, snapback).
- [ ] The effectful reassert stores the reconciled grid, seeds diff baselines (including for windows whose write is skipped or deferred), and publishes every in-scope occupant through the write policy — the dragged window included, expanded windows skipped.
- [ ] The occupant-aware two-thirds divider rule is one pure grid function, shared by the live splitter path and the plan.
- [ ] Headless tests: the clamp gap closes (splitter back to the achieved edge, neighbour flush); reconcile precedes rect mapping; two-thirds centering; expanded-skip; a second identical reassert writes nothing.
- [ ] `swift build` clean; `swift test` green.

## Constraints (settled, do not re-decide)

- Input is the small sum type `.resize` / `.grid`; no scope set and no convergence-check knob. Do not add a case with no caller — a future overlay-handle gesture adds one, not now.
- The achieved frame is read by the coordinator (the one effect the pure core cannot perform) and passed in as a value.
- The write policy stays the only write path; it takes the canvas's visible frame so a clamped write is repinned against the same frame its target was derived from.
- The canvas's existing reassert (used by display change, reset, restore) becomes this operation. The tracker's separate push path may still call the canvas's publish until stage 3.

## Gates

Run the stages per `.scratch/resize-reassert/README.md` ("Running one stage in a fresh session"). On
completion, record the commit hash here and in the README stage table.
