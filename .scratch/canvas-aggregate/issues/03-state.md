# Stage 3 - The canvas owns its state

Status: TODO
Blocked by: stage 2
Blocks: stage 4

## Goal

Per-canvas state stops being threaded from the coordinator. `TilingSpace` owns window records for the
windows it manages (tiled, or expanded-but-untiled), the grid + splitter backup, and expansion.
`spaceOwnership` is derived, not stored. `DragTracker` reads the grid through a provider and the legacy
shared-grid twins die.

## Scope

In:

- Records move into the canvas. The coordinator keeps the handle->id table, creates the record stub,
  and hands the window to the canvas. `spaceOf(window:)` becomes a derived lookup over canvases.
- `expanded` moves into the canvas; reflow/plan exclusions become the canvas's internal rule, not
  caller-passed `excluding:` sets (`ReflowTests.testExpandedExclusionIsTheCallersJob` inverts or dies).
- Grid + `splitterBackup` become canvas fields. `DragTracker` takes a `GridProvider` for its session;
  delete the tracker's legacy shared `grid` and the dead no-space twins (`resetDividers()`, the
  single-arg `restoreDividers`).
- Prune stays coordinator-side (timer, `deadSince`, liveness probes); on confirmation it calls
  `canvas.release(window)`, which performs the leave (forget + reflow + chapter), the same as untile.
- `Outcome` grows the non-placement actions, each a named method returning one `Outcome`:
  `untile`, `evict`, `expandToggle`, `undo`, `resetSplitters`, `restoreSplitters`, `release`,
  `reassert`, and `publish(rects:excluding:)` for the tracker's coalesced pushes (routed through the
  shared `FrameWriter`).
- Update `CONTEXT.md`: the canvas's `_Code_` line (`CanvasState` -> `TilingSpace`).
- Re-point the mutation table for every target the move invalidated.

Out: accessor-surface cleanup and test-file migration (stage 4). Echo bookkeeping stays in `DragTracker`
until something forces it out; do not couple it to this stage.

## Constraints

- One red-green slice per action moved; behaviour preserved unless the design says otherwise.
- The coordinator's public read surface (`state`, `grid`, `state(in:)`, ...) stays working until
  stage 4, even if it now forwards.
- Same gates: build clean, suite green, every mutant live and caught.

## Steps

1. Move records + expansion ownership into the canvas; derive `spaceOf`.
   -> Criterion: no `records` or `expanded` storage left in the coordinator (handle->id table and record
   stub excepted); suite green.
2. Move grid + backup into the canvas; give the tracker a `GridProvider`; delete the legacy twins.
   -> Criterion: `DragTracker` stores no grids; no dead no-space API; suite green.
3. Move the remaining actions in, one slice each, all returning `Outcome`.
   -> Criterion: coordinator methods are thin routing; suite green.
4. Update `CONTEXT.md` code names; re-point the mutation table; run the full gate.
   -> Criterion: build clean, suite green, every mutant caught, CONTEXT.md matches the code.
5. `code-review` both axes; commit; update this ticket and the README table.
   -> Criterion: findings resolved or reasoned; commit on `master` with gate evidence; statuses updated.

## Evidence to record

- Per-step suite results and the final build/test/mutation output.
- The tracker's new provider interface (before/after signature).
- Any test that had to change and why.
