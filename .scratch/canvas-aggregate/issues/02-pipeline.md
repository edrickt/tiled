# Stage 2 - Move the placement pipeline into TilingSpace

Status: DONE at `27a1562` ("Move the placement pipeline into TilingSpace"), master.
Blocked by: stage 1 (DONE, `26c1db3`)
Blocks: stage 3

## Goal

`plan -> execute -> settle -> reflow` for a placement moves, verbatim, inside `TilingSpace`, behind the
unchanged `TilingController` facade. `PlanExecutor` dissolves into the canvas's private phases. The
placement path returns one `Outcome` instead of an executor `Outcome` plus controller effects.

This is a behaviour-preserving move: the existing 557-test suite is the oracle. No deliberate behaviour
change in this stage.

## Scope

In:

- Fold `CanvasState` into `TilingSpace` (occupancy, undoStack, splitterBackup, notice, error) and move
  the placement pipeline in: plan commit phases (`applyTile` / `applySwap` / `applySwitchLayout` /
  `place` / restore / re-house / snapshot), and the placement half of `settle` + `reflow` + `pushUndo`.
- `TilingController.handle(slot:)` becomes: resolve requester + canvas, call `space.apply(...)`, apply
  the returned coordinator effects (space ownership, `observe`, focus, `onChange`).
- Introduce the placement `Outcome` type: typed result, `focusAfter`, refusal name; `notice`/`error`
  stay readable on the canvas. Keep the existing `onFeedback` mapping at the coordinator for now.
- Delete `PlanExecutor.swift`; `WindowRecord` and `EvictedWindow` move next to `TilingSpace`.

Out:

- Records/grid/expansion ownership (stage 3), accessor cleanup and test migration (stage 4), removing
  `onFeedback` entirely (later), any change to reflow/verification/undo rules.

## Constraints (settled, do not re-decide)

- `TilingSpace` is a struct; the coordinator stores `[TilingSpaceKey: TilingSpace]`.
- During this stage the canvas's methods may still take a context value carrying `records`, `nextID`,
  collaborators, and return updated records; stage 3 removes the threading. The named-methods +
  `Outcome` shape is the destination, so do not grow new multi-return tuples in its place.
- `FrameWriter` stays the only write path. Placements pass `check: .none` (`settle` schedules the plan's
  check); reflow and rollback pushes pass `.rollback`.
- Focus effects stay coordinator-side: the canvas returns `focusAfter`, the controller focuses.
- `TilingState.plan`/`reflow` and `TilePlan` stay pure in `Layout.swift`.

## Steps

1. Introduce `TilingSpace` with `CanvasState`'s fields; move the pipeline phases in without editing the
   logic.
   -> Criterion: `PlanExecutor.swift` deleted; `swift build` clean; the `spaces` dictionary retyped.
2. Rewire `TilingController.handle` to the canvas method; remove the executor property and its wiring.
   -> Criterion: `swift test` 557/557, no test-fixture changes beyond unavoidable type updates.
3. Re-point the mutation table: any mutant whose path or target text moved must be updated, because
   `mutate.py` fails the run on STALE by design. Run the full table.
   -> Criterion: every mutant CAUGHT, none STALE/INVALID/TIMEOUT.
4. Run the `code-review` skill on the diff; fix or reason each finding.
   -> Criterion: both axes reported; commit on `master` with gate evidence in the body; this ticket and
   the README table updated with the commit hash.

## Evidence

- `swift build`: clean, zero warnings.
- `swift test`: 557/557 (delta 0). `PlanExecutorTests` was retargeted to the canvas's `execute`/`undo`
  interface; no fixtures were added or weakened.
- `python3 tools/mutation/mutate.py`: 49/49 caught, none STALE/INVALID/TIMEOUT. Eight mutants were
  re-pointed to `TilingSpace.swift` (path and/or target text), including the degenerate-swap mutant,
  whose replacement now flips `context.isExpanded`.
- `code-review` on both axes against `26c1db3`:
  - Spec: no wrong behaviour found. Two scope creeps are forced by the move and reasoned in the commit:
    the expand/collapse refusal plumbing (the placement pipeline owns its canvas's error while `apply`
    runs) and `DragTracker.rect(for:slot:)` (the canvas holds a grown slot before the coordinator's
    view catches up). `undo` riding along is a stage-3 formalization, required because
    `PlanExecutor.swift` is deleted.
  - Standards (smell baseline; no repo standards files): fixed the duplicated refusal pair (now
    `Refusal`), the duplicated undo-entry construction (now `evictedEntry`), `applyLayout` threading a
    second copy of `records`, `untileAll` hand-trimming the undo stack (now `beginUndoChapter()`),
    inlined the `pushUndo`/`undoDepth` middle-men, shared the three expand/collapse/retile failure arms
    (`expandedWriteFailure`), and refreshed the stale `CanvasState` comment. Reasoned: internal
    `execute` (test seam, stage 4) and the separate `pushRects`/`writeReflow` loops (per-canvas
    coordinator attribution vs canvas-local error).
