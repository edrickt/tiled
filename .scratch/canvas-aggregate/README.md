# Canvas aggregate (TilingSpace) - build arc

Audit origin: architecture review of 2026-10-06, candidate A ("Give the canvas one deep module").
Full report: `architecture-review.html` in this directory. Design settled by grilling on 2026-10-06;
this file is the single source of truth for the design and the stage map.

## Where this is

Stages 1-4 are done. `master` at `60cea51` ("Make the canvas the test surface and collapse the
accessor facade"): one write policy module, one placement pipeline per canvas, per-canvas
records/grid/expansion, the canvas as the test surface, 581 tests, 50/50 mutants. The arc is
closed.

## The design (settled)

- `TilingSpace` is a struct, one per canvas (the coordinator stores `[TilingSpaceKey: TilingSpace]`),
  and it is the behavioural module for that canvas: injected narrow `WindowDriver`
  (`setFrame` / `frame(of:)` / `appName(of:)`), the shared `FrameWriter`, a bounds provider, and a clock.
- It owns occupancy (`TilingState` internals), grid + splitter backup, window records + expansion,
  undo chapters, and notices/errors.
- Every action is a named method returning one `Outcome` (typed result, refusal name, `focusAfter`);
  `notice`/`error` stay readable on the canvas; `Outcome` replaces `onFeedback` from canvas actions.
- The coordinator (`TilingController`) keeps: focus/handle resolution, the handle->id table that creates
  record stubs, screens/bounds, gateway observation, the prune clock and death confirmation, the menu
  snapshot, Space identity, and the canvas table. `spaceOwnership` becomes derived, not stored.
- `PlanExecutor` dissolves into the canvas's private phases; `CanvasState` is absorbed by `TilingSpace`.
- `TilingState.plan`/`reflow` and `TilePlan` stay pure in `Layout.swift`.
- `DragTracker` keeps the drag loop and echo suppression; grid/splitter ownership moves to the canvas and
  the tracker reads through a provider. The legacy shared-grid paths die.
- Framework words: CONTEXT.md vocabulary (canvas, slot, eviction, reflow, re-house, expand, requester).
  Architecture words: module, interface, implementation, depth, seam, adapter, leverage, locality.

Non-negotiable in every stage: `swift build` stays warning-free; the test suite stays green; every
mutation-table target stays live and caught.

## Stages

| # | Ticket | Delivers | Blocked by | Status |
|---|---|---|---|---|
| 1 | `issues/01-framewriter.md` | FrameWriter write policy | - | DONE (`26c1db3`) |
| 2 | `issues/02-pipeline.md` | Pipeline moves into TilingSpace; PlanExecutor dissolves | 1 | DONE (`27a1562`) |
| 3 | `issues/03-state.md` | Canvas owns records/grid/expansion; ownership derived | 2 | DONE (`2524826`) |
| 4 | `issues/04-tests-surface.md` | TilingSpaceTests; duplicated tests and accessors die | 3 | DONE (`60cea51`) |

## Running one stage in a fresh session

One stage per context window. Start the session with:

```
Read .scratch/canvas-aggregate/README.md, then implement
.scratch/canvas-aggregate/issues/02-pipeline.md (replace with the stage ticket).
```

Then work the ticket:

1. Read this file, the stage ticket, and `CONTEXT.md`. The report's candidate A card is the visual
   version of the design.
2. Build through the `tdd` skill: one red-green slice at a time. Behaviour-preserving moves are
   validated by the existing suite instead of new tests.
3. Gates, tiered by cost - the full mutation table is a once-per-stage gate, not a per-step one:
   - Every red-green slice: `swift test` -> all green (it compiles too, so warnings surface here).
   - While iterating on the stage's subjects: `python3 tools/mutation/mutate.py --since <stage base>`
     (optionally plus a positional filter, e.g. `mutate.py TilingSpace --since <stage base>`) ->
     every selected mutant CAUGHT, none STALE; a stage that touched no mutation source passes.
   - Once before commit: `python3 tools/mutation/mutate.py` -> the full table CAUGHT, none STALE.
4. Close with the `code-review` skill (Standards + Spec) against the stage's base commit.
5. Commit on `master` in the repo's style (imperative subject, the why in the body, gate evidence at the
   end), then update the stage ticket and the table above with the commit hash and status.
