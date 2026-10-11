# Tiled-driven animation — spec

Grilling origin: session of 2026-10-09. Feel spike on branch `prototype/stepped-ax-animation`
(`c410b8d`, verdict: 180ms ease-out). Vocabulary settled in `CONTEXT.md` (`be641b0`):
Tiled-driven animation, app-native animation, retarget, graceful surrender.

This file is the single source of truth for the design and the stage map.

## Where this is

Stages 1-5 are done. `master` at `b613c04` ("Add the "Animate layout changes" settings
toggle"): Tiled-driven animation with retarget, hand takeover, and Reduce Motion; restore
and release glides; display-reassert and failure carve-outs; per-window graceful surrender;
and the live "Animate layout changes" toggle. 655 tests, 84/84 mutants. The arc is closed.

## Problem Statement

Every layout change Tiled makes lands instantly: tiling a window into its slot, evicting or
re-housing the window in the way, growing a survivor into freed cells, undo, the layout switch,
expand/collapse, splitter resets, restoring an untiled window, a short drag snapping back, the
neighbors committing when the mouse button lifts after an edge drag. The jump is abrupt, and when
several windows move at once it is hard to follow where each one went. macOS's own window
movements read as motion; Tiled's read as teleports.

## Solution

Tiled animates every move it initiates: the window glides from its current frame to the target
over 180ms with a cubic ease-out, and all windows in one change glide in parallel. The animation
is decorative — it never changes where a window finally lands, never delays the write policy, and
never fights the hand. Live drag-resizing and display reassert stay instant, a user's drag cancels
an in-flight glide, Reduce Motion snaps, and a Settings toggle ("Animate layout changes", on by
default) turns it off. An app that animates its own resize is left to it (graceful surrender).

## User Stories

1. As a Tiled user, I want a hotkey tiling a window to glide it into its slot, so the change reads
   as motion rather than a jump.
2. As a Tiled user, I want windows displaced by a tiling request (evicted, re-housed, swapped) to
   glide as part of the same change, so I can follow where they went.
3. As a Tiled user, I want a survivor growing into freed cells (reflow) to glide, so the layout
   change stays legible.
4. As a Tiled user, I want undo to glide the chapter's windows back, so undo reads as moving back
   rather than teleporting.
5. As a Tiled user, I want a layout switch to glide every window into its new slot.
6. As a Tiled user, I want expand/collapse to glide, including a collapse that precedes a tiling
   into a blocked slot.
7. As a Tiled user, I want Reset Splitters and Restore Previous Splitters to glide the affected
   windows.
8. As a Tiled user, I want an evicted or untiled window to glide back to its pre-tile frame,
   including on Untile All.
9. As a Tiled user, I want a short title-bar drag (snap-back) to glide back into its tile.
10. As a Tiled user, I want the neighbors' commit after an edge drag to glide when the button
    lifts (the hand has released), consistent with snap-back.
11. As a Tiled user, I want survivors to glide into freed cells when a tiled window closes.
12. As a Tiled user, I want rapid consecutive hotkeys to retarget mid-glide — motion continues
    from the current frame, never queues and never jumps.
13. As a Tiled user, I want to grab a window mid-glide and have my hand win immediately, including
    for windows that just left the layout.
14. As a Tiled user, I want live drag-resizing to stay instant under my cursor; animation must
    never lag or fight the hand.
15. As a Tiled user, I want display-change reassertion to land instantly, so correctness after an
    unplug/rearrange never waits on a glide.
16. As a Tiled user with Reduce Motion enabled, I want every change to snap, always.
17. As a Tiled user, I want a Settings toggle to turn animation off, applying live without a
    restart, as an escape hatch for apps that fight motion.
18. As a Tiled user, I want an app that animates its own resize to be left to it — Tiled stops
    stepping and lets the app's animation finish on target (graceful surrender).
19. As a Tiled user, I want a refused write to surface exactly as today — same notice, same state
    cleanup — with animation never masking a failure.
20. As a Tiled user, I want animation to never change where a window finally lands, so state and
    screen still never silently disagree.
21. As a Tiled user, I want animation under load to drop intermediate steps rather than delay or
    half-finish a move; the final frame always lands.
22. As a Tiled user, I want animations short enough (~180ms) that the UI stays responsive while
    windows glide.

## Implementation Decisions

- **Animator module, controller-owned.** Steps a window's frame current→target: 180ms, cubic
  ease-out, ~60Hz cadence, monotone by construction. Never overshoot/spring: `DragTracker`'s
  escape rule classifies a rising distance-to-target as a user takeover.
- **Injected time.** Clock and scheduler are closure-injected, following the existing
  `DragEndScheduler` / `now` pattern; no new protocol.
- **First step is synchronous.** `play` writes the first step inline and returns its acceptance,
  preserving today's fail-fast refusal path. Remaining steps are scheduled; intermediate steps are
  best-effort and droppable under load; the final target always lands.
- **The landing keeps write-policy semantics.** The final write runs the same classification as
  the instant path — clamp repin included — rather than a raw gateway write.
- **Retarget.** A newer target for the same window supersedes the glide; motion continues from the
  window's current frame. Animations never queue.
- **Hand takeover.** Pure-origin divergence from the last step beyond tolerance cancels the glide
  without a final write (same shape as `DragTracker`'s title-bar classification). For windows that
  left the layout — where echo classification is off — the per-step read-back is the detector.
- **Graceful surrender per window.** If the observed frame lags the schedule (an app animating
  natively), or steps are refused repeatedly, stop stepping and land the final write; other
  windows in the change keep animating. Thresholds live in the animator.
- **Attachment points.** The `FrameWriter` accepted-write path (tile, swap, evict, re-house,
  reflow, layout switch, splitter reset/restore, expand/collapse, drag release, snap-back) and the
  direct `restore(window:)` path (evict, untile, Untile All, undo restores).
- **Carve-outs.** Display reassert writes declare themselves non-animated; failure and rollback
  writes are instant; live drag-resize ticks write nothing today, so only its release paths
  animate.
- **Failure.** End-of-glide not-at-target (and not a clamp) enters the existing refusal/rollback
  path with unchanged wording; rollback writes snap.
- **Settings.** `AppSettings.animateLayoutChanges` (Bool, default `true`) plus a General-tab
  checkbox and a provider closure into the controller; read live per move. Reduce Motion always
  wins over the toggle.

## Testing Decisions

- Good tests assert external behaviour: the sequence of writes logged by `FakeWindowGateway`, the
  target each window lands on, and the user-visible notices — never animator internals.
- Behavioural seam: `TilingSpaceHarness` + `FakeWindowGateway`, with captured scheduler closures
  and a fake clock; tests fire steps manually and assert glides are monotone and land exactly on
  target.
- Carve-out tests assert instant writes: Reduce Motion, display reassert, failure rollback.
- Retarget tests assert continuity (no write to the abandoned target after supersession).
- Surrender tests assert the final write lands after a simulated lagging app.
- Prior art: `DragTrackerTests` (captured scheduler closures fired by hand),
  `ControllerGatewayTests` (`now` advancement), `FrameWriter` tests through the harness.
- Gates: `swift build` warning-free, full suite green, and the mutation table stays green — add
  mutants for the carve-outs, retarget, and surrender; every mutant caught, none stale.

## Out of Scope

- Springs, overshoot, or bounce easing (blocked by the drag-tracker escape rule).
- A per-app blocklist of natively animating apps (surrender is per move).
- Duration slider or configurable easing (fixed at 180ms ease-out).
- Animating display reassert, live drag ticks, or the real cursor.
- Animating Tiled's own UI (menu-bar glyph, Settings windows).
- Cross-canvas coordinated motion.

## Further Notes

- Primary source for the motion heuristics: `prototype/stepped-ax-animation` (`c410b8d`) —
  `SpikeAnimator.swift` carries the validated shape: 60Hz step, cubic ease-out, first-step
  fail-fast, retarget, pure-origin hand detection, lag/refused-streak surrender.
- The spike's simplifications are this spec's work: display reassert and live drag not carved out,
  settings not wired, clamp repin skipped mid-glide, final refusals logged not rolled back.
- Product promise the arc must not break: state and screen never silently disagree.

## Stages

| # | Ticket | Delivers | Blocked by | Status |
|---|---|---|---|---|
| 1 | `issues/01-animator-core.md` | Animator + FrameWriter glide; retarget, hand, Reduce Motion | - | DONE (`96ad5b6`) |
| 2 | `issues/02-restores-and-release.md` | Restore and drag-release paths glide | 1 | DONE (`3241358`) |
| 3 | `issues/03-correctness-carve-outs.md` | Display reassert, failure writes, end-of-glide refusal | 1 | DONE (`6f95a26`) |
| 4 | `issues/04-graceful-surrender.md` | Per-window surrender for natively animating apps | 1 | DONE (`bead32f`) |
| 5 | `issues/05-settings-toggle.md` | "Animate layout changes" toggle, live | 1 | DONE (`b613c04`) |

## Running one stage in a fresh session

One stage per context window. Start the session with:

```
Read .scratch/animation/README.md, then implement
.scratch/animation/issues/01-animator-core.md (replace with the stage ticket).
```

Then work the ticket:

1. Read this file, the stage ticket, and `CONTEXT.md`. The prototype branch
   `prototype/stepped-ax-animation` (`c410b8d`) holds the validated motion heuristics —
   `SpikeAnimator.swift` shows the working shape: 60Hz step, cubic ease-out, first-step
   fail-fast, retarget, pure-origin hand detection, lag/refused-streak surrender.
2. Build through the `tdd` skill: one red-green slice at a time.
3. Gates, tiered by cost - the full mutation table is a once-per-stage gate, not a per-step one:
   - Every red-green slice: `swift test` -> all green (it compiles too, so warnings surface here).
   - While iterating on the stage's subjects: `python3 tools/mutation/mutate.py --since <stage base>`
     (optionally plus a positional filter, e.g. `mutate.py TilingSpace --since <stage base>`) ->
     every selected mutant CAUGHT, none STALE; a stage that touched no mutation source passes.
   - Once before commit: `python3 tools/mutation/mutate.py` -> the full table CAUGHT, none STALE.
4. Close with the `code-review` skill (Standards + Spec) against the stage's base commit.
5. Commit on `master` in the repo's style (imperative subject, the why in the body, gate evidence
   at the end), then update the stage ticket and the table above with the commit hash and status.
