# Stage 4 - Tests and the surface

Status: TODO
Blocked by: stage 3
Blocks: -

## Goal

The canvas's interface becomes the test surface. The hand-copied tests die. The duplicated controller
accessor spellings die. The arc closes with the full mutation gate and a review over the whole arc.

## Scope

In:

- New `TilingSpaceTests` through the canvas interface: fake driver, injected bounds, injected clock.
  Cover placement, eviction, reflow, re-house, undo, expand, splitter reset/restore, release.
- Dissolve `PlanExecutorTests` and the hand-written production copies (`LayoutSwitchTests.apply`,
  `MatrixCrossCheckTests.applyExpected`). `MatrixCrossCheck` becomes a canvas-vs-model replay instead
  of production-logic-in-test.
- Geometry tests move to the injected `ScreenProvider` instead of live `NSScreen` as they are touched
  (`SwapTests.expectedRect`, `ReflowTests.expectedRect`, `ControllerBulkOperationTests`,
  `ControllerGatewayTests`).
- Delete the duplicated accessor spellings (zero-arg / on-screen / in-space) once nothing uses them;
  menus and tests use `canvas(for:)` plus canvas methods.
- Final full mutation run; sweep for dead code the moves left behind; update `CONTEXT.md` if anything
  else drifted.
- `code-review` over the whole arc (fixed point: `26c1db3`).
- Commit and close the arc in the README (status table all DONE).

Out: candidate C ("one outcome, announced once") and the other audit candidates - separate arcs.

## Steps

1. Write `TilingSpaceTests` against the settled interface; one red-green slice per action.
   -> Criterion: every action has coverage through the canvas interface; tests pass.
2. Replace the hand-written copies by driving the canvas interface.
   -> Criterion: the copy sites are gone; suite green; record the count.
3. Collapse the accessor surface; migrate the remaining call sites.
   -> Criterion: no callers of the deleted spellings; build clean; suite green.
4. Full mutation gate; arc-wide review; commit; close the README table.
   -> Criterion: every mutant caught; both review axes reported; commit on `master`; arc marked DONE.

## Evidence to record

- Test count before/after and the list of test files removed.
- Final build/test/mutation output at the closing commit.
- The review's findings and resolutions.
