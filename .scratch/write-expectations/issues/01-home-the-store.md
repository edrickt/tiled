# Stage 1 - Home the store

Status: DONE at `e495f86` ("Home the write expectation store in WriteExpectations"), master.
Blocked by: -
Blocks: stage 2 (unblocked).

## What ships

- New `Sources/tiled/WriteExpectations.swift`: the expectation store moves out of
  `DragTracker.expectedFrames` with its entry shape (`frame`, `lastDistance`, `date`, `settled`) and
  its constants (`echoTolerance`, `settleWindow`, `staleWrite`, `noOpWriteTolerance`) at today's
  values.
- Operations: `noteExpected(id, frame)` (a frame write); `noteIntent(id, frame)` / `intent(for:)`
  (no write); `classify(id, frame) -> TickVerdict`; `convergence(for:)`; `forget(id)`.
- `TilingController` constructs and holds one instance. `FrameWriter`'s `markExpected` collaborator
  routes to `noteExpected`; its `scheduleCheck` collaborator and the controller's late-verify wiring
  keep today's paths, reading verdicts from the owner.
- `DragTracker` keeps the drag loop, snapback, untile, and `processMove`; `handleChange`'s entry
  branches (`DragTracker.swift:291-353`) become a switch over `classify`'s verdict. The tracker's
  direct store access dies.
- `TilingSpace.untileAll`'s intent priming (`:954-959`) and the tracker's internal priming route
  through `noteIntent`.
- `forget` keeps today's survival split: intent survives, echo entry cleared, pending check
  cancelled (through an injected cancel until stage 2 moves scheduling).

## Design rules (settled)

- Behaviour-preserving: no change to the check set, consequences, copy, or timing. The eight verdict
  outcomes keep their exact semantics - settle-expired, consumed, settling, origin-drift, settle-end,
  escape, stale, converging - and `.live` when no expectation exists. Re-read `handleChange` before
  rewriting it; the origin-drift case (a hand on the title bar during settle) is the subtle one.
- `lastKnownFrames` diffing stays in the tracker (drag state, not expectation state); if the move
  proves otherwise, keep `frameForTracker`'s intent preference (`TilingController.swift:516-520`).
- Tolerance constants move with the store; values frozen.

## Tests

- New `WriteExpectationsTests`: every verdict outcome plus `.live`; intent survival across forget;
  echo entry cleared by forget; pending check cancelled by forget.
- `DragTrackerTests` cases that drive `markExpected` / `convergence` / intent directly
  (`:574-605, :666-667, :771-819`) move to `WriteExpectationsTests`; drag-loop cases stay, built
  through the owner. `FrameWriterTests` keep their five cases with the collaborator re-pointed.
  Replace, don't layer: delete the moved cases from the old file.

## Mutation table

- Re-point the tracker's "stale-write window widened to 3600s" target to its new source text.
- Add "intent cleared by forget" (forget must keep intent).

## Evidence required

- `swift build` clean, zero warnings; `swift test` green; `python3 tools/mutation/mutate.py` all
  CAUGHT, none STALE.
- `code-review` on both axes against `fabb338` (the last code commit before this arc).
- Commit on `master` in the repo's style with gate evidence in the body; update this ticket and the
  README table.

## Evidence

- `swift build`: clean, zero warnings.
- `swift test`: 621/621 (was 608: three cases moved out of `DragTrackerTests`, sixteen added in
  `WriteExpectationsTests`).
- `python3 tools/mutation/mutate.py`: 51/51 caught, none STALE. The stale-write target re-points at
  `WriteExpectations.swift`; "intent cleared by forget" is new; the FrameWriter no-op entry re-points
  at the moved constants; the `rehousingHome` entry, duplicated by the step-aside commit and stale
  at `fabb338`, now names its occurrence.
- `code-review` on both axes against `fabb338`:
  - Spec: no wrong behaviour found. Its only missing item was this status update; two notes accepted
    by design: intent now outlives the echo entry (the settled survival split), and a settled tick
    leaving the radius logs only `settle-end` where the old shared distance block also logged
    `ESCAPE` (state identical; the verdicts are now separate outcomes).
  - Standards (smell baseline; no repo standards files): no hard violations. Judgement calls left as
    designed: the arm-and-baseline pairing at its two write-path call sites (`FrameWriter`'s
    `markExpected` closure and the tracker's own scheduled pushes), `WriteExpectations.close`'s thin
    forward to `framesClose` (the split moved verbatim from `DragTracker`; stage 2 absorbs it), and
    the drag tests' `tile` helper arming only the store (their echo seed seeds the baseline, as
    before).
