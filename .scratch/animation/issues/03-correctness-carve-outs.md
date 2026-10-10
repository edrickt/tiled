# 03: Correctness carve-outs

**Status:** DONE at `6f95a26` ("Make the correctness carve-outs instant and surface refused
landings"), master.

**Blocked by:** 1 (Animator core + the first glide), done at `96ad5b6`.

## What shipped

- Motion is a declared argument at every write now: `FrameWriter.write(..., animated:)`,
  threaded through `TilingSpace.reassert/publish/writeRects/applyLayout/restore` and out
  through `TilingController.applyAll`. `applyAll` (the display-change and stale-canvas
  reassert path) declares `animated: false`, so every occupant of every visible canvas
  lands on its new slot in one write; splitter resets, splitter restores, and the
  tracker's publish path keep declaring animated. `FrameWriter.writeImmediately` also
  supersedes any in-flight glide for the window before an instant write, so a stale step
  can never overwrite a frame a rollback or a display reassert just snapped.
- Failure and rollback writes declare themselves instant: the swap rollback's
  write-home, the reflow rollback's old-rect rewrite, and both re-house fallback restores
  (a refused re-house write; a refused requester leaving the victim still tiled).
- Refused landings surface: the glide's `land` runs the exact target through the instant
  policy and routes a refused result to a new injected `onLandingFailed`; the
  controller's `landingFailed` rolls the window out exactly like the late silent-ignore
  path (occupancy and record released, the standard `refusalMessage(windowName:)` on the
  window's canvas, `.refused` feedback, and `onChange`). The two late rollbacks share
  `refusePlacement` and `TilingSpace.discard(window:refusing:)`. This route is required
  because a glide ends within a pixel of its target, so the late convergence check would
  read a refused landing as converged and stay silent.
- Boundary semantics kept: a clamped landing (the instant policy's repin) is a success;
  a landing deferred off-Space stands (the tile holds, the canvas goes stale for the
  swipe back); an accepted-but-ignored landing still belongs to the late convergence
  check, exactly as for an instant write.
- Tests: 11 new `AnimationTests` through `TilingSpaceHarness` and the controller
  `ControllerGlide` fixture — display reassert instant (the controller's notification
  path and the canvas path, plus a display change mid-glide superseding the in-flight
  glide), the refused landing rollback (controller: occupancy, wording, feedback,
  onChange; canvas), the swap rollback snap and glide supersession, the half-applied
  reflow rollback snap, both re-house fallback snaps, a silent-ignored glide rolling
  back at verification, and a landing deferred on a hidden canvas not failing. The
  harness's animation default stays off.

## Evidence

- `swift build`: clean, zero warnings.
- `swift test`: 644/644 (was 633; +11 `AnimationTests`).
- `python3 tools/mutation/mutate.py`: 74/74 caught, none STALE/INVALID/TIMEOUT (65
  before; nine new targets: display reassert glides [controller], reassert ignores its
  motion declaration, publish ignores its motion declaration, swap rollback write
  glides, reflow rollback write glides, refused re-house fallback restore glides,
  refused requester's re-house victim restore glides, refused landing not surfaced,
  instant write leaves the glide running; three existing targets re-pointed: swap
  write-home deleted, restore ignores the animator, the landing's no-op opt-out).

## Review findings and resolutions

- Code-review skill run over `08c3cb6...6f95a26`: parallel subagents are unavailable in
  this session, so Standards and Spec ran as separate manual passes (findings below).
- Standards: the two late rollback entry points were about to duplicate the "window
  still holds its slot" guard; extracted `tiledCanvas(of:)`. The meaningless `Harness`
  test-name prefix was dropped. A pre-existing unused `let target` in `AnimationTests`
  (a test-target warning) was removed while the file was open. Judgement call kept:
  `animated: Bool` rather than a two-case enum; it mirrors the animator's existing gate
  and makes the spec's "declare themselves non-animated" visible at each call site. No
  documented standards files exist in the repo.
- Spec: all five checklist paths covered. The refused landing enters the same
  user-visible outcome as today's refused write, with unchanged wording, and the clamp
  repin stays a success (one refusal sentence, one discard, one feedback case). The
  interpretation below is the one judgement call the spec left open.

## Deviations

- "Off-target landing" is read as the consequence of a refused final write, handled at
  the landing, with the clamp repin exempt. An accepted-but-off-target landing (a
  silent ignore) is not reclassified synchronously: a read-back cannot distinguish an
  ignored write from an app-native animation that stage 4 must leave alone to finish on
  target, and the late convergence check already owns that verdict for instant and
  animated writes alike. The new silent-ignore test pins that late rollback under
  animation.
- A refused landing on paths whose instant refusal is not a discard (tracker publish,
  reflow survivor, expand) takes the shared late-refusal shape (release the window,
  standard wording, feedback) rather than replaying that path's write-time rollback,
  which is unreachable once the transaction has settled. This mirrors the existing late
  silent-ignore route, which already applies that shape to every declared write.
- Refused *restore* landings (stage 2's raw pre-tile write) are not routed through this
  outcome: the key pointer scoped stage 3 to the `FrameWriter` landing, and restore
  refusals have their own wording and no occupancy to clean up. A known boundary, not
  stage 4/5 work.
