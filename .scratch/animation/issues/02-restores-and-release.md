# 02: Restores and the release paths

**Status:** DONE at `3241358` ("Glide the restore and release paths"), master.

**Blocked by:** 1 (Animator core + the first glide), done at `96ad5b6`.

## What shipped

- `TilingSpace.restore(window:context:)` glides to the pre-tile frame through the
  `Animator` the context now carries beside the frame writer and tracker: the first step
  is synchronous (a refusal still fails the move exactly like the instant path), and the
  landing is a direct gateway write to the exact pre-tile frame (restores stay
  deliberately exempt from the FrameWriter clamp repin). `animator.isAnimating` gates it,
  so Reduce Motion and the enablement provider are read live per restore; the instant
  branch cancels any in-flight glide for the window, so a snapped release is never
  overwritten by a stale step.
- That covers evict/untile, Untile All, the layout switch, and the undo restores (the
  requester's `restore` and the chapter's retiles, which already glided through
  `applyLayout`). Multi-window restores start their first steps in the same call, so
  Untile All and a layout switch glide every restored window in parallel.
- The glide store is keyed by `WindowHandle` instead of `WindowID`. One window, one
  glide: a released window re-attached under a fresh id (the coordinator allocates a new
  id once the record is gone) now supersedes its old glide instead of racing it.
- Untile All chapters each window's restore target from its record's pre-tile frame
  instead of the post-restore live read, which under animation is only the glide's first
  step. The live read stays as the readability gate: an unreadable frame still builds no
  chapter.
- Drag-out snap-back and the neighbors' mouse-up commit already glided through the shared
  `FrameWriter` path; harness coverage now pins both, including the dragged window
  holding its hand frame while only the neighbor glides.
- Tests: 12 new `AnimationTests` through `TilingSpaceHarness` (write logs, landed
  frames, chapters, notices), plus a controller-wiring test for the untile path and a
  `ControllerGlide` fixture replacing the triplicated step-settling loop. The harness
  routes the tracker's coalesced pushes into `TilingSpace.publish` and exposes a captured
  drag end (`fireDragEnd`); the animation default stays off so the instant-landing suite
  is untouched.

## Evidence

- `swift build`: clean, zero warnings.
- `swift test`: 633/633 (was 621; +12 `AnimationTests`).
- `python3 tools/mutation/mutate.py`: 65/65 caught, none STALE/INVALID/TIMEOUT (58
  before; seven new targets: restore ignores the animator, restore landing never writes,
  restore starts from the target, instant restore leaves the glide running, retarget
  leaves the older glide running, Untile All chapters the mid-glide frame, Untile All
  drops the readability gate; the Animator landing target was re-pointed to the
  handle-keyed store).
- Code-review skill run over `4781080...3241358`: parallel subagents are unavailable in
  this session, so Standards and Spec ran as separate manual passes (findings below).

## Review findings and resolutions

- Standards: the controller step-settling loop was about to be triplicated across
  `AnimationTests`; extracted a `ControllerGlide` fixture (captured steps + clock +
  `settle`) and pointed both controller tests at it. No documented standards files exist
  in the repo (`CODING_STANDARDS.md`/`CONTRIBUTING.md` absent); the baseline smells are
  otherwise clean, and names follow the arc vocabulary (restore, pre-tile frame, glide,
  retarget, supersede).
- Spec: all six ticket checklist paths are covered. Two fixes inside the stage were
  required for the spec's "animation never changes where a window finally lands" promise:
  the handle-keyed glide store (the ticket's supersession requirement, read as "same
  window", not "same id") and the Untile All chapter frames (a post-restore live read
  lands mid-glide and would poison undo). Neither is scope creep: both are the stage's
  own paths keeping their meaning under animation.

## Deviations

- The handle-keyed store touches `Animator` beyond the literal same-id retarget: the
  fresh-id race is the same retarget story across the record boundary, and it has its own
  test (`testReTileAfterRestoreSupersedesTheRestoreGlide`). The same-id supersession the
  ticket names works without it, so this is the one interpretation the orchestrator may
  want to weigh.
- `restore` falls back to the instant write when animation is on but the live frame is
  unreadable: there is no start frame to glide from. This preserves the write exactly as
  before; the corner is untested.
