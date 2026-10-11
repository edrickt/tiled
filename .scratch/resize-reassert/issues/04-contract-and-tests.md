# Stage 4 - Contract and test surface

Status: ready-for-agent
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
