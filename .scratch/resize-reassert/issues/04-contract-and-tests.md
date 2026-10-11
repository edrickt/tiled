# Stage 4 - Contract and test surface

Status: DONE at `302042b` ("Delete the dead publish path and retarget the resize tests"), master.
Blocked by: stage 3
Blocks: none

## What to build

The dead seams are gone and the tests describe the new one. Delete the canvas's old publish path and any
accessor left without a caller; make bounds resolution one spelling; move the resize tests to the seam they
now describe.

## Acceptance criteria

- [ ] The canvas's old publish path and any now-unused accessors are deleted; bounds resolution has one spelling.
- [ ] Canvas tests cover the reassert end-to-end; tracker tests assert the emitted decision, not rects; the minimum-size test asserts no gap after mouse-up.
- [ ] Any test that drove the tracker's rect computation is retargeted to the canvas's plan; no assertion tests past the seam.
- [ ] The mutation table is re-pointed to the moved symbols and gains entrants for the reconcile; full table caught, none STALE/INVALID/TIMEOUT.
- [ ] `swift build` warning-free; `swift test` green.

## Gates

Run the stages per `.scratch/resize-reassert/README.md` ("Running one stage in a fresh session"). On
completion, record the commit hash here and in the README stage table.

## What shipped

- Deleted `TilingSpace.publish(rects:excluding:context:)`, a middle man over `writeRects` called only by
  `reassert` with `excluding: nil`; `reassert` now calls `writeRects` directly.
- Deleted the caller-less accessors `TilingController.writeCanvas(for:fallback:)` and
  `DragTracker.lastPushedTarget(for:)`. Bounds resolution has one spelling: `TilingController.visibleFrame(for:)`
  feeding each canvas's stored `visibleFrame`; no per-window resolver remains.
- Retargeted `testPublishWritesRectsAndReportsPluralRefusals` to
  `testReassertReportsPluralRefusalsOnTheCanvas` (same plural refusal count, driven through the reassert).
  Tracker tests assert the emitted decision and live splitter fractions, never rects; the minimum-size test
  keeps its no-gap-after-mouse-up assertion.
- Added one plan test for the reassert's row-splitter reconcile plus two mutation entrants pinning the
  top/bottom achieved-edge mapping.

## Evidence

- `swift build` clean, zero warnings.
- `swift test`: 628/628.
- `python3 tools/mutation/mutate.py`: 65/65 caught, none STALE/INVALID/TIMEOUT.
- Code-review (Standards + Spec) against `20c6f71`: one Standards judgement call (the new test helper renamed
  to `rowPosition(_:)`); Spec: all acceptance criteria met, no scope creep.

This closes the resize-reassert arc.
