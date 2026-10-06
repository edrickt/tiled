# Stage 1 - FrameWriter (DONE)

Status: DONE at `26c1db3` ("Unify frame writes behind the FrameWriter policy module"), master.
Blocked by: -
Blocks: stage 2.

## What shipped

- `Sources/tiled/FrameWriter.swift`: one write policy - no-op skip, off-Space deferral, echo marking,
  and a required convergence-check classification. `write(id, handle:, to:, on:, check:) -> Result`
  with `Result` = `.written` / `.skippedNoOp` / `.deferredOffSpace` / `.refused` and `Check` =
  `.rollback` / `.none`.
- `TilingController` builds one shared instance (lazy, `[weak self]` collaborators) and injects it:
  `pushRects` (`check: .rollback`), `writeExpandedFrame` (`check: .none`), `PlanExecutor.applyLayout`
  (`check: .none`; `settle` still schedules the plan-level verification).
- `PlanExecutor` takes the writer by init; `PlanExecutorTests` builds one wired to its own tracker.
- One intentional behaviour change: a no-op expand issues no write, pinned by
  `ExpandToggleTests.testExpandOfAnAlreadyExpandedWindowIssuesNoWrite`.
- `testTileOnAHiddenCanvasDefersTheWriteAndRollsBack` pins `applyLayout`'s deferral branch.
- `FrameWriterTests` cover all four results plus the echo -> write -> check ordering.
- Mutation table grew from 44 to 49 entries; the five new mutants target the module.

## Evidence

- `swift build`: clean, zero warnings.
- `swift test`: 557/557.
- `python3 tools/mutation/mutate.py`: 49/49 caught.
- Established by the code-review skill on both axes; findings fixed at the time (see the commit body).

## Notes for later stages

- `.none` means the caller owns verification: placements schedule per plan in `settle`; expansion has no
  rollback path yet and says so at the call site.
- The fabricated no-canvas scope is named `TilingSpaceKey.displayless`.
- `TilingController.writeCanvas(for:fallback:)` is the one spelling of canvas precedence.
- The tracker's queue-time no-op pre-skip stays as queue hygiene; the write-time policy is the writer's.
- When the canvas aggregate lands, the same writer instance should be the canvas's only write path.
