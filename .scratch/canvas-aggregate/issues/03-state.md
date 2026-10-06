# Stage 3 - The canvas owns its state

Status: DONE at `2524826` ("Move per-canvas state into TilingSpace"), master.
Blocked by: stage 2 (DONE, `27a1562`)
Blocks: stage 4

## What shipped

- `TilingSpace` owns the per-canvas state: window records (`records`), expansion (`expanded`), and
  splitter fractions (`grid`), on top of the occupancy, undo chapters, `splitterBackup`, notice, and
  error it already held. The placement `Context` no longer threads records/nextID/isExpanded/spaceOf;
  it carries only collaborators (gateway, frame writer, tracker, bounds, canvas key, id allocator, log).
- The coordinator keeps the handle->id table (`windowIDs`) plus `nextID`; it resolves the id and the
  canvas hands the window over (`attach`, which creates the stub). `spaceOf(window:)` is derived by
  scanning canvases for the record; `spaceOwnership`, the coordinator's `expanded` map, and its
  `records` registry are gone.
- `DragTracker` stores no grids. It takes a `GridProvider` (read/write closures) at construction; the
  coordinator wires it to `spaces[key]?.grid` (nil key -> `.displayless`). The legacy shared `grid`,
  `setGrid(_:for:)`, both `resetDividers` spellings, and both `restoreDividers` spellings are deleted;
  splitter reset/restore are canvas actions (`splitterBackup` + `grid`).
- The non-placement actions moved in and return one `Outcome`: `untile`, `evict`, `expandToggle`
  (plus internal `collapseExpanded`), `resetSplitters`, `restoreSplitters`, `release` (the prune
  leave), `reassert`, `publish(rects:excluding:)`, plus `untileAll`, the drag-out leave
  (`untileFromDrag`), and `discard` for the silent-ignore rollback. `Outcome.Result` grew
  `.nothingToEvict` and `.expandRefused`; `Outcome.requester` died with stored ownership.
- Prune stays coordinator-side (timer, `deadSince`, liveness probes) and calls `canvas.release(window)`
  on confirmation: the untile leave without a frame write (forget + reflow + chapter).
- `TilingState.plan`/`reflow` and `TilePlan` stay pure. The expanded exclusion is the canvas's internal
  rule now: `ReflowTests.testExpandedExclusionIsTheCallersJob` died, coverage pinned by the existing
  canvas-level `testExpandedSurvivorNeverGrows`.
- `CONTEXT.md` canvas `_Code_` line now reads "occupancy, records, splitters, expansion, and placement
  pipeline".
- Mutation table: five targets re-pointed (path/text), one new mutant pins the placement write's canvas
  key (the regression the review caught).

## Evidence

- `swift build`: clean, zero warnings.
- `swift test`: 556/556 (delta -1: two tests died by design, one added).
  - Died: `DragTrackerTests.testResetDividersRestoresDefaults` (the tracker no longer owns splitters),
    `ReflowTests.testExpandedExclusionIsTheCallersJob` (expanded exclusion is internal).
  - Added: `SpaceIndependenceTests.testTileOnAHiddenSpaceDefersTheWriteAndRollsBack` (red before the
    review fix, green after).
  - Retargeted fixtures: `PlanExecutorTests` (records/expansion on the canvas, new `Context`),
    `DragTrackerTests` (provider-backed splitter storage).
- `python3 tools/mutation/mutate.py`: 50/50 caught, none STALE/INVALID/TIMEOUT.
- The tracker's provider interface (before -> after):
  - before: `private(set) var grid: GridLayout`, `private var grids: [TilingSpaceKey: GridLayout]`,
    `grid(for:)`, `setGrid(_:for:)`, `resetDividers()` / `resetDividers(for:)`,
    `restoreDividers(_:)` / `restoreDividers(_:for:)`.
  - after: `struct GridProvider { var grid: (TilingSpaceKey?) -> GridLayout; var setGrid: (GridLayout, TilingSpaceKey?) -> Void }`,
    injected at init; the tracker keeps no grid state, and `grid(for:)` reads the provider.
- `code-review` on both axes against `75dfe34`:
  - Standards: fixed the duplicated leave tails (one `leave`), the repeated load/store canvas pattern
    (`mutateSpace` at every site), the duplicated refusal -> feedback mapping (`announce`), the
    `currentID` and tracker `store` middle men; `discard` lost its unused `Outcome`; `applyLayout` lost
    its dead `on:` default. Top-level docs refreshed.
  - Spec: found and fixed one real defect: placement writes had dropped their canvas key, scoping every
    tile/swap/re-house write to `.displayless` and disarming the off-Space deferral; pinned by the new
    red-then-green test and a new mutant. Two spec lines are reasoned deviations: `reflow` keeps an
    `excluding:` parameter because its only caller is `settle` inside the canvas (the expanded half is
    internal), and `undo` returns `UndoOutcome` because one chapter spans canvases, so its narration
    cannot ride the per-action `Outcome`.
