# Stage 3 - The drag loop decides only; the canvas settles the resize

Status: DONE at `2edfeba` ("Let the drag loop decide and the canvas settle the resize"), master.
Blocked by: stage 2
Blocks: stage 4

## What to build

Releasing a resize edge — or snapping back a short title-bar drag — reasserts the owning canvas, so the
window ends flush in its tile and an app that clamped at its minimum leaves no gap. This is the user-facing
fix. The drag loop stops computing rects and scheduling writes; it emits a decision, and the coordinator
routes it to the canvas.

## Acceptance criteria

- [x] At mouse-up the coordinator reads the dragged window's achieved frame and reasserts its canvas with `.resize`; a title-bar snapback reasserts with `.grid`; a drag past the untile distance still untiles (unchanged).
- [x] The dragged window's tile is asserted like any other occupant; a drag that already ended on the tile issues no writes.
- [x] The drag loop computes no rects and schedules no writes. It emits a resize / snapback / untile decision and keeps only echo suppression, edge detection, and the live splitter commit.
- [x] The tracker's rect math, runloop coalescing, and duplicate no-op-write skip are deleted; the canvas reassert is the only write path for a resize.
- [x] The live splitter path reads the canvas's stored visible frame, not a per-window resolution.
- [x] End-to-end through the fake gateway: mouse-up leaves the neighbour flush; the clamp case leaves no gap and no overlap; refusals still land on the canvas with the existing message; per-display and per-Space splitter isolation holds.
- [x] `swift test` green; mutation table caught, none stale.

## Constraints (settled, do not re-decide)

- The trigger stays the global mouse-up. Binding the commit to the drag's own end is a deliberate follow-up, out of scope.
- Only the dragged window's own clamp is reconciled. A clamped neighbour is a follow-up.
- Drag-out, eviction, reflow, re-house, undo, expand, and layout switching are unchanged.
- The tracker keeps its small echo-bookkeeping methods (echo marking, convergence, forget, last-pushed target): echo bookkeeping is genuinely separate from grid geometry, so it does not move into the pure canvas.

## Gates

Run the stages per `.scratch/resize-reassert/README.md` ("Running one stage in a fresh session"). On
completion, record the commit hash here and in the README stage table.

## What shipped

- `DragTracker.DragDecision` (`.resize(WindowID)` / `.snapback(WindowID)` / `.untile(WindowID)`), emitted
  through the single injected `onDragEnd` callback. `mouseLifted` emits `.resize` per pending canvas; a
  title-bar drag end emits `.snapback` or `.untile`. The tracker keeps echo suppression, edge detection, the
  live splitter commit, drag tracking, and its echo bookkeeping (`markExpected`, `seedBaseline`,
  `convergence`, `forget`, `lastPushedTarget`).
- Deleted from `DragTracker`: `rect(for:)` / `rect(for:slot:)`, `reassertAll`, `schedule` / `scheduleApply`,
  the coalescing state (`pendingRects` / `pendingExclusion` / `applyScheduled`), the `apply` / `onUntile`
  callbacks, and the `frameOf` / `boundsOf` context seams.
- `DragTracker.GridProvider` gains `visibleFrame: (TilingSpaceKey?) -> CGRect`; `processResize` divides the
  dragged edge against the canvas's stored frame.
- `TilingController.handleDragEnd` routes the decision: `.resize` reads the dragged window's achieved frame
  and reasserts `.resize(dragged:achieved:)`; `.snapback` reasserts `.grid`; `.untile` calls the unchanged
  `untileFromDrag`. `publishRects`, `frameForTracker`, and `visibleBounds` are deleted.
- Tests: `DragTrackerTests` retargeted to the decision callback (edges move the splitter under the canvas
  frame; resize / snapback / untile decisions; trailing-tick re-arm); `ControllerGatewayTests` gains the
  flush end-to-end, the no-write clean drag, the refusal message, and the expanded-two-thirds rule;
  `MinimumSizeTests` gains the dragged-window clamp (no gap, no overlap); `SpaceIndependenceTests` gains the
  per-display mouse-up isolation.
- Gates: build clean (zero warnings), 627/627 tests, mutation 63/63 caught, none stale (four new entrants;
  the expanded-occupants entrant relabelled to the two-thirds divider rule it now protects).
