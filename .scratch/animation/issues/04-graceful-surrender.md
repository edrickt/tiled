# 04: Graceful surrender

**Status:** DONE at `bead32f` ("Add graceful surrender for natively animating apps"), master.

**Blocked by:** 1 (Animator core + the first glide), done at `96ad5b6`.

## What shipped

- Lag detection: `Animator.tick` compares the observed frame's per-edge distance to the
  target against the frame the last step asked for (`glide.lastWritten`), and counts
  consecutive lagging steps on `glide.lagStreak`; at `lagStreakLimit` (3) the glide
  surrenders. The baseline is deliberately `lastWritten`, not the current expected step
  from the prototype's heuristic (see Deviations).
- Refused-step detection: a rejected step write increments `glide.refusedStreak` (reset by
  the first accepted step); at `refusedStreakLimit` (3) the glide surrenders. A refused
  write leaves `lastWritten` where it was, so the two detectors cannot collide: a refusing
  window never reads as lagging.
- Surrender: one helper removes the glide and calls the same `land` closure the natural
  end-of-glide runs, so the exact target goes through the instant write policy (clamp
  repin included), a refused landing reaches the stage-3 rollback via
  `onLandingFailed`, and the declared convergence check keeps its meaning (it was
  scheduled at write time, before the glide). Other glides are untouched: surrender is
  per window. The glide holds the streaks and dies with the surrender, so the decision
  is per move — the next move glides again, no per-app memory.
- Thresholds live as private `Animator` constants beside `handTolerance`:
  `lagTolerance = 60` (per-edge sum), `lagStreakLimit = 3`, `refusedStreakLimit = 3`.
- Hand precedence kept: the hand check runs first, so a pure-origin divergence from the
  last step still cancels without landing (a frozen or ignored write is the late
  convergence check's case); an app-native animation moves edges, fails the size-held
  test, and reaches the lag detector instead. The rejected pure-move simulation in the
  multi-window test originally proved this by tripping the hand path.
- Tests: 5 new `AnimationTests` through `TilingSpaceHarness` — a damped app surrenders
  early and its last request is the exact target; three refused steps surrender and the
  landing applies; the surrender is per window while the layout switch's other glide
  keeps stepping and lands; a tracking app runs the full schedule and never lands the
  target early; a surrendered landing that is refused runs the standard rollback
  (occupancy released, record dropped, standard wording). The harness's animation default
  stays off and no harness change was needed.

## Evidence

- `swift build`: clean, zero warnings.
- `swift test`: 649/649 (was 644; +5 `AnimationTests`).
- `python3 tools/mutation/mutate.py`: 78/78 caught, none STALE/INVALID/TIMEOUT (74
  before; four new targets: lag tolerance widened, lag streak limit widened,
  refused-step streak limit widened, surrender drops the glide without the policy
  landing). The Animator subset (10 mutants) was run first while iterating; the full
  table was re-run unchanged. No existing target needed re-pointing.

## Review findings and resolutions

- Code-review skill run over `7c97b22...bead32f` (working tree reviewed before the commit):
  parallel subagents are unavailable in this session, so Standards and Spec ran as
  separate manual passes (findings below).
- Standards: no documented standards files exist in the repo (`CODING_STANDARDS.md` /
  `CONTRIBUTING.md` / `AGENTS.md` absent; `docs/` holds only the UI plan). One baseline
  smell, a judgement call: the `simulateLaggingApp` test helper carried an unused
  `damping` parameter (Speculative Generality) — inlined to a local constant. The
  surrender path reuses `land()` rather than duplicating the policy, so no duplication
  was introduced. A pre-existing unused-result warning in
  `testRefusedReflowSnapsTheHalfMovedSurvivorBack` (present at the base commit) was left
  alone as unrelated.
- Spec: all five ticket checklist items are covered by tests, and every spec requirement
  is met: thresholds private to the animator, streaks on the glide state, per-window
  independence, and the surrendered landing behaving exactly like any other landing by
  construction (it is the same closure). No scope creep: the Settings toggle, the
  carve-outs, and the harness default are untouched.

## Deviations

- The lag baseline is `lastWritten` rather than the prototype's `expected` step. The
  prototype's comparison (`distance(observed, target) > distance(expected, target) + 60`)
  fires on any tracking window whose move is large: every tick reads the observed frame
  before writing the step, so a tracking window is one step behind the schedule by
  construction (verified experimentally — the committed tracking test fails under that
  baseline and passes under `lastWritten`). The ticket's "a window tracking its schedule
  does not surrender" pins which baseline is correct.
- The lag test asserts the surrender's final *request* stream is the exact target, not
  the app's applied frame: the simulated app is mid-native-animation by definition, so
  it cannot apply the target in the surrender write. The refusal test pins the applied
  landing (the app accepts the final write, and the frame lands exactly), and the
  policy path is shared with stage 3's tested `land` closure.
- Retarget resetting the streak has no test: a fresh `play` builds a fresh `Glide`, so
  "per move" is structural. The multi-window test is the nearest behavioural pin.
