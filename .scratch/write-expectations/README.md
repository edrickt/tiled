# WriteExpectations (one owner for a write's expectation) - build arc

Audit origin: architecture review of 2026-10-08, candidate A1 ("Give a write's expectation one owner,
from arm to verdict"). Full report: `architecture-review.html` in this directory. Design settled by
grilling on 2026-10-08; this file is the single source of truth for the design and the stage map.

## Where this is

Both stages are DONE and the arc is closed at `281614c` ("Dissolve FrameWriter into
WriteExpectations"). `WriteExpectations` owns a frame push's whole life: the shared write policy, the
armed expectation, the tick verdicts, the late check with its supersede/forget rules, the consequence
tokens, and intent; `FrameWriter`, the `Check` flag, `Outcome.verify`, and the controller-side
scheduling are gone. 629 tests green, 54/54 mutants caught. Stage 1 was `e495f86`; when the arc was
written, `master` at `fabb338` held 608 tests green and 50/50 mutants. `CONTEXT.md` carries the term
**Expected write** (`_Code_: WriteExpectations`).

## The design (settled)

- One module, `WriteExpectations`, constructed and held by the controller, injected into the canvas
  write path and the tracker's tick handling. It owns the whole life of a frame push: arm before the
  gateway call, tick classification, the late convergence verdict, the consequence, and intent.
- `FrameWriter` dissolves into it: `write(id, handle:, to:, on:, consequence:) -> Result` is the only
  birth of an expected write. The no-op skip, off-Space deferral, and refusal classification move in
  unchanged; call sites state only where the window goes.
- Checks are unconditional per performed write: every accepted write leaves exactly one outstanding
  check; a newer write for the same window supersedes; forget cancels. The `.none`/`.rollback` flag,
  `Outcome.verify`, `verificationWindows`, and the controller's plan-side scheduling all die.
- Consequences are semantic tokens, not check flags:
  - **slot-commit** (placements, reflow, reassert, publish): a silent ignore releases the window and
    announces the standard refusal - today's `verifyConvergence` body.
  - **cover-toggle** (expand, collapse, retile): a silent ignore reverts the `expanded` record to its
    pre-write value (clear for expand, restore for collapse/retile) and announces; no frame write.
- The owner fires the consequence through an injected port; the body stays with the controller/canvas.
- Intent is first class: `noteIntent(id, frame)` / `intent(for:)`. `forget` keeps intent, clears the
  echo entry, cancels the pending check. `untileAll`'s priming and the tracker's internal priming
  route through it.
- `DragTracker` consumes one `classify(id, frame) -> verdict` per tick - the verdict names today's
  eight branch outcomes, `.live` when no expectation - and keeps only drag semantics (snapback,
  untile, processMove).
- Scope boundary: gateway-direct restores (`TilingSpace.restore(window:)`) stay the best-effort exit
  path, outside the owner.
- Widening accepted: every write through the owner is watched, including `.switchLayout` placements
  and undo retiles that the hand-maintained list misses.
- Frozen: all copy, refusal routing, timing constants (`echoTolerance`, `settleWindow`, `staleWrite`,
  `noOpWriteTolerance`, verify delay), undo semantics, off-Space deferral, no-op skip, drag-loop
  behaviour. Sole intended behaviour changes: the widening and expansion's late handling.

## Stages

| # | Ticket | Delivers | Blocked by | Status |
|---|---|---|---|---|
| 1 | `issues/01-home-the-store.md` | `WriteExpectations` holds the store; tracker consumes; FrameWriter arms through it | - | DONE (`e495f86`) |
| 2 | `issues/02-one-write-one-life.md` | FrameWriter dissolves; unconditional deduped checks; both consequence tokens; the widening; arc closes | 1 | DONE (`281614c`) |

## Running one stage in a fresh session

One stage per context window. Start the session with:

```
Read .scratch/write-expectations/README.md, then implement
.scratch/write-expectations/issues/01-home-the-store.md (replace with the stage ticket).
```

Then work the ticket:

1. Read this file, the stage ticket, and `CONTEXT.md`. Domain words: canvas, slot, eviction, reflow,
   re-house, expand, requester, expected write. Architecture words: module, interface, implementation,
   depth, seam, adapter, leverage, locality.
2. Build through the `tdd` skill where behaviour changes; behaviour-preserving moves are validated by
   the existing suite instead of new tests.
3. Gates after every working step:
   - `swift build 2>&1 | grep -E "warning:|error:"` -> empty
   - `swift test` -> all green
   - `python3 tools/mutation/mutate.py` -> every mutant CAUGHT, none STALE
4. Close with the `code-review` skill (Standards + Spec) against the stage's base commit (stage 1:
   `fabb338`; stage 2: stage 1's commit).
5. Commit on `master` in the repo's style (imperative subject, the why in the body, gate evidence at
   the end), then update the stage ticket and the table above with the commit hash and status.

Non-negotiable in every stage: `swift build` stays warning-free; the test suite stays green; every
mutation-table target stays live and caught.

## Out of scope

- Gateway-direct restores stay as they are; a silently ignored restore is its own future ticket.
- Candidates A2-A7 and defects 6-8 from the review report remain unclaimed.
