# Stage 3 - The drag loop decides only; the canvas settles the resize

Status: ready-for-agent
Blocked by: stage 2
Blocks: stage 4

## What to build

Releasing a resize edge — or snapping back a short title-bar drag — reasserts the owning canvas, so the
window ends flush in its tile and an app that clamped at its minimum leaves no gap. This is the user-facing
fix. The drag loop stops computing rects and scheduling writes; it emits a decision, and the coordinator
routes it to the canvas.

## Acceptance criteria

- [ ] At mouse-up the coordinator reads the dragged window's achieved frame and reasserts its canvas with `.resize`; a title-bar snapback reasserts with `.grid`; a drag past the untile distance still untiles (unchanged).
- [ ] The dragged window's tile is asserted like any other occupant; a drag that already ended on the tile issues no writes.
- [ ] The drag loop computes no rects and schedules no writes. It emits a resize / snapback / untile decision and keeps only echo suppression, edge detection, and the live splitter commit.
- [ ] The tracker's rect math, runloop coalescing, and duplicate no-op-write skip are deleted; the canvas reassert is the only write path for a resize.
- [ ] The live splitter path reads the canvas's stored visible frame, not a per-window resolution.
- [ ] End-to-end through the fake gateway: mouse-up leaves the neighbour flush; the clamp case leaves no gap and no overlap; refusals still land on the canvas with the existing message; per-display and per-Space splitter isolation holds.
- [ ] `swift test` green; mutation table caught, none stale.

## Constraints (settled, do not re-decide)

- The trigger stays the global mouse-up. Binding the commit to the drag's own end is a deliberate follow-up, out of scope.
- Only the dragged window's own clamp is reconciled. A clamped neighbour is a follow-up.
- Drag-out, eviction, reflow, re-house, undo, expand, and layout switching are unchanged.
- The tracker keeps its small echo-bookkeeping methods (echo marking, convergence, forget, last-pushed target): echo bookkeeping is genuinely separate from grid geometry, so it does not move into the pure canvas.

## Gates

Run the stages per `.scratch/resize-reassert/README.md` ("Running one stage in a fresh session"). On
completion, record the commit hash here and in the README stage table.
