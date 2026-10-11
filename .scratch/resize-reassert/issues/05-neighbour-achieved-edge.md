# Stage 5 - Reconcile a neighbour's achieved edge

Status: DONE at `0039d0c` ("Reconcile a neighbour's achieved edge in the resize settle"), master.
Blocked by: stage 4
Blocks: none

## What to build

A neighbour that cannot reach the splitter — because its app rounds or insets a programmatically-written
frame — leaves a gap between tiles. After the resize settle writes the occupants, read each written window's
**achieved frame** back; when a neighbour's achieved edge falls short of the shared splitter, snap that
splitter to the neighbour's achieved edge and run the settle once more, bounded. The tiles abut at the
splitter; any residual that cannot be removed lands at the screen edge, where the existing repin already
applies.

Reported live on 2026-10-11: two Terminal windows in the top-left and bottom-left sixths, sharing the
left-column row splitter. Terminal keeps a window's top edge and rounds its height down to a whole character
row, so the programmatically-written neighbour fell 6pt short of the splitter the dragged window defined,
opening a gap. Stage 2 reconciles the *dragged* window's achieved edge; this stage adds the neighbour.

The regression test is already written and red: `Tests/tiledTests/NeighbourRoundingTests.swift`.
Run it with `swift test --filter NeighbourRoundingTests`.

## Acceptance criteria

- [ ] After the settle, a splitter is reconciled to a neighbour's achieved edge when the neighbour cannot reach it, so stacked (or adjacent) tiles abut — no gap.
- [ ] The corrective pass is bounded (a small constant; the reported case converges in one extra pass) and idempotent: a settle against an app that applies its target exactly, or a second settle, issues no extra writes.
- [ ] The dragged window's own achieved-edge reconcile (stage 2) is unchanged.
- [ ] The pure plan stays pure: the achieved-edge readback and the corrective grid update live in the effectful settle, not in the pure plan.
- [ ] `NeighbourRoundingTests.testStackedSixthsStayFlushWhenTheAppRoundsTheNeighbour` goes green; the existing flush, minimum-size, refusal, and isolation tests stay green.
- [ ] `swift build` clean, zero warnings; `swift test` green; mutation table caught, none stale.

## Constraints (settled, do not re-decide)

- The residual that cannot be removed — an app that row-rounds cannot make both the splitter and a screen edge flush when the screen height is not a whole number of rows — lands at the screen **edge**, never between tiles. Closing the internal gap is the goal.
- Only occupants that were written are read back; a skipped no-op write has no achieved frame to consult beyond its live frame.
- `TilingSpace` stays a pure value type; the readback is one gateway read inside the effectful settle.
- No change to drag-out, eviction, reflow, re-house, undo, expand, layout switching, or observation.

## Gates

Run the stages per `.scratch/resize-reassert/README.md` ("Running one stage in a fresh session"). On
completion, record the commit hash here and in the README stage table.

## What shipped

- `TilingSpace.reassert` reads every *written* occupant's achieved frame back after its write pass and hands
  the pairs to `reconcileAchievedEdges`, which maps a diverged edge to its boundary
  (`GridLayout.boundary(edge:slot:)`) and moves that splitter to the achieved position — the two-thirds
  centering rule included, the same one the resize reconcile uses. If any splitter moved, the layout is
  re-planned under `.grid` and re-written. Only written occupants are read: a skipped no-op write has no new
  achieved frame. An edge on a screen edge has no boundary and is left alone, so the residual a row-rounding
  app cannot remove lands at the screen edge, never between tiles.
- The pass is bounded (`maxAchievedEdgePasses = 2`) and a fixed point: the reported case converges in one
  extra pass, the cap stops two neighbours from oscillating, and a second settle over the settled grid is a
  no-op.
- The pure plan is untouched: `reassertPlan`/`reconciledGrid` take no gateway; the readback lives in the
  effectful `reassert`. `writeRects` now returns a `WritePass` (pairs written plus refusal count) so reflow's
  rollback and the readback share one write loop, and the resize reconcile's edge-to-position switch was
  extracted to `TilingSpace.position(of:in:)` and reused by the corrective reconcile.
- Tests: `NeighbourRoundingTests.testStackedSixthsStayFlushWhenTheAppRoundsTheNeighbour` (the red regression,
  unchanged) plus two canvas-level tests in `ReassertPlanTests` — the splitter follows the neighbour's
  achieved edge and the tiles abut, and a second settle after the corrective pass issues no extra writes.
- Mutation table gains four entrants pinning the corrective reconcile; two existing entrants were re-pointed
  to text that moved (`var plan`, `seedBaselines`), and the two far-edge entrants now target the shared
  `position(of:in:)` switch.

## Evidence

- `swift build` clean, zero warnings.
- `swift test`: 631/631 (three new tests: the regression plus the two canvas tests).
- `python3 tools/mutation/mutate.py`: 69/69 caught, none STALE/INVALID/TIMEOUT.
- Code-review (Standards + Spec) against `a0f640e`: Standards, no hard findings (the duplicated
  edge-to-position switch is now shared; the `(id, target)` tuple clump and the test-side app-model copy are
  accepted judgement calls); Spec, all six acceptance criteria met, no scope creep.

This closes the resize-reassert arc again.
