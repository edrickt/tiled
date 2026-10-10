# 01: Animator core + the first glide

**Status:** DONE at `96ad5b6` ("Add Tiled-driven animation: 180ms ease-out glides"), master.

**Blocked by:** None.

## What shipped

- New `Animator` (`Sources/tiled/Animator.swift`): one glide per window, 180ms cubic
  ease-out at ~60Hz, injected `now`/`scheduleStep` closures in the existing
  `DragEndScheduler` style, injected enablement and Reduce Motion providers read live per
  move. The first step is synchronous, so a refusal comes back as `.refused` and the plan
  rollback and notice are unchanged. Intermediate steps are best-effort; the landing runs
  the exact target back through the write policy with the no-op shortcut opted out, so the
  screen ends exactly on target and the clamp repin and declared convergence check keep
  their meaning.
- `FrameWriter` consults the animator on every accepted write path (tile, swap, reflow,
  layout switch, splitter reset/restore, expand/collapse, tracker publish). The landing
  re-enters the same policy rather than a raw gateway write; the declared check is
  scheduled when responsibility is taken, so a hand-cancelled glide cannot dodge the
  silent-ignore verification.
- Retarget: a newer target cancels the in-flight glide and resumes from the window's
  current frame; animations never queue. Hand takeover: pure-origin divergence beyond the
  shared divergence metric cancels without landing. Reduce Motion always wins over the
  enablement provider.
- Controller owns the animator; `scheduleStep`, `animationEnabled`, and `reduceMotion` are
  injected at init; the app enables animation by default. The harness gains a fake clock,
  captured step fires with cancellers, and `step()` / `settleAnimations()`, defaulting
  animation off so the existing instant-landing suite is untouched.
- `DragTracker.frameDistance` is now the one shared per-edge divergence metric the tracker's
  escape rule and the animator's hand detection both read.

## Evidence

- `swift build`: clean, zero warnings.
- `swift test`: 621/621 (was 613; +8 `AnimationTests`).
- `python3 tools/mutation/mutate.py`: 58/58 caught, none STALE/INVALID/TIMEOUT (50 before;
  eight new targets cover retarget continuity, first-step refusal, the ease curve, hand
  takeover, Reduce Motion, landing, the policy landing, and the landing's no-op opt-out; a
  pre-existing stale `rehousingHome` target was disambiguated).

## Review findings and resolutions

- Standards: dead `Glide.id` removed; the duplicated per-edge metric collapsed onto
  `DragTracker.frameDistance`. The hand-classification parallel with `DragTracker` stays a
  commented single-source note, exactly as the spec names it ("same shape as DragTracker's
  title-bar classification").
- Spec: the first revision wrote the target raw at the final tick and let the policy
  landing classify it, which the no-op shortcut could skip in the unclamped case; changed
  so the last tick calls the policy landing directly (raw write dropped) and the no-op
  shortcut is opted out at landing, with two mutants pinning it.

## Deviations

- The `FrameWriter` seam already animates the release paths that share it (drag-out
  snap-back, mouse-up neighbor commit) and expand/collapse/splitter reset, since stage 1
  changed the shared policy path. Stage 2 narrows to the direct `restore(window:)` path
  and its nuances. Until then, a restore fired mid-glide does not supersede the glide; the
  restore stage owns that.
- The controller's `animationEnabled` provider defaults off so headless and test rigs are
  deterministic; `AppDelegate` passes `{ true }` for the product default, which stage 5
  replaces with the persisted Settings toggle.
