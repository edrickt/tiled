# Stage 2 - One write, one life

Status: TODO
Blocked by: stage 1.
Blocks: - (closes the arc).

## What ships

- `Sources/tiled/FrameWriter.swift` dissolves into `WriteExpectations`:
  - `write(id, handle:, to:, on:, consequence:) -> Result` becomes the only write path. The policy
    moves in unchanged: off-Space deferral first, no-op skip through the close-to-target tolerance,
    arm before `setFrame`, refusal classification. Call sites state only where the window goes, plus
    what a silent ignore means.
  - The check is armed internally and unconditionally: every accepted write leaves exactly one
    outstanding check; a newer write for the same window supersedes (cancels) the older; forget
    cancels. `TilingController.pendingVerifications` / `cancelVerification` (`:419-437`) move into
    the owner.
- Deletions: the `Check` enum and `check:` parameters; `TilingSpace.Outcome.verify`;
  `TilingSpace.verificationWindows` (`:289-295`); the controller's plan-side scheduling (`:391`,
  `:423-432`) and its comments. `settle` stops computing verification windows.
- Consequence ports - the owner fires, the body stays where the state is:
  - **slot-commit** (placements via `applyLayout`, reflow/reassert/publish via `writeRects`):
    today's `verifyConvergence` body (`TilingController.swift:445-469`) moves behind the port -
    resolve the name before the record goes, discard on the window's own canvas, set the refusal
    message only when the canvas has none, post `.refused` feedback, `onChange`.
  - **cover-toggle** (expand/collapse/retile via `writeExpandedFrame`): on a silent ignore, revert
    the `expanded` record to its pre-write value - clear for expand; restore the `saved` value for
    collapse/retile - and surface the same message and refusal feedback the immediate path uses.
    The revert writes no frames.
- The widening lands here: every write through the owner is watched, including `.switchLayout`
  placements and undo retiles the hand-maintained list missed.

## Design rules (settled)

- Frozen: all copy, refusal routing, timing constants, undo semantics, off-Space deferral, no-op
  skip, drag-loop behaviour. The only behaviour changes are the widening and expansion's late
  handling.
- `TilingSpace.restore(window:)` stays gateway-direct: the exit path is out of scope by design.
- Tokens are semantic, not a check flag: call sites never say *whether* to verify, only *what a
  silent ignore means*.

## Tests

- `FrameWriterTests` folds into `WriteExpectationsTests`: the four policy cases survive re-pointed;
  the `.none`-check case dies with the flag. Keep the arm -> write -> schedule ordering contract
  observable through the interface.
- `ControllerGatewayTests:582-671` late-verify re-points through the port: assert discard + message +
  feedback + `onChange`.
- `TilingSpaceTests`: hidden-canvas deferral and expansion cases re-point through the owner's write.
- New coverage: supersede (a newer write cancels the older check; the older silence must not roll
  back); the widening (silent-ignored `.switchLayout` placement and undo retile roll back);
  cover-toggle reverts in both directions, with no frame movement by the revert; the token route
  itself.
- Replace, don't layer.

## Mutation table

- Re-point the five `FrameWriter` entries to `WriteExpectations.swift` against their new source
  text: no-op pushed anyway; off-Space defer never taken; check never armed (was "rollback check
  inverted"); refusal reported as success; echo expectation not armed.
- Add: "supersede dropped"; "expand silent ignore skips the revert"; "collapse silent ignore skips
  the revert".
- Gate: every mutant CAUGHT, none STALE.

## Evidence required

- `swift build` clean, zero warnings; `swift test` green; `python3 tools/mutation/mutate.py` all
  CAUGHT, none STALE.
- `code-review` on both axes against stage 1's commit.
- Commit on `master` in the repo's style with gate evidence in the body; update this ticket and the
  README table; the arc closes.
