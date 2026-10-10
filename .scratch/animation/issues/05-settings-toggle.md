# 05: Settings toggle

**Status:** DONE at `b613c04` ("Add the "Animate layout changes" settings toggle"), master.

**Blocked by:** 1 (Animator core + the first glide), done at `96ad5b6`.

## What shipped

- `AppSettings.animateLayoutChanges`: Bool, default true. The getter reads the key's
  presence explicitly (`object(forKey:) == nil ? true : bool(forKey:)`) because
  `UserDefaults.bool` returns false for a missing key, so existing installs upgrade into
  animation rather than out of it; the setter persists under `animateLayoutChanges`, so
  the choice survives relaunch.
- General tab: an "Animate layout changes" checkbox above the guide divider, wired like
  the hide-icon checkbox (target/action, initial state from `loadValues`). The action
  writes the setting and nothing else: the controller reads the provider per move, so no
  controller or menu refresh is needed, and the flip applies to the next move.
- `AppDelegate`: the controller's `animationEnabled` provider is now
  `{ [weak self] in self?.settings.animateLayoutChanges ?? true }`, replacing the
  hardcoded `{ true }`; Reduce Motion still wins in `Animator.isAnimating`
  (`isEnabled() && !reduceMotion()`). The controller's init default stays `{ false }` and
  the harness default stays off, so the pre-existing instant-landing suite is unchanged.
- Tests: 2 `AppSettingsTests` (default on with the key absent; persistence off and back on
  through the same suite, read by fresh instances); 2 `SettingsAnimationToggleTests`
  (the checkbox reflects the stored setting through `loadValues`; `performClick` flips the
  control, writes the setting, and the value persists for a "next launch"); 2
  `AnimationTests` through the real controller with an isolated `AppSettings` — default-on
  glides, off snaps the very next move, on glides again; and Reduce Motion snapping over
  the on toggle and over the off toggle, with a control glide proving the path is alive
  and a live Reduce Motion flip back to gliding.

## Evidence

- `swift build`: clean, zero warnings.
- `swift test`: 655/655 (was 649; +6: two `AppSettingsTests`, two
  `SettingsAnimationToggleTests`, two `AnimationTests`).
- `python3 tools/mutation/mutate.py`: 84/84 caught, none STALE/INVALID/TIMEOUT (78
  before; six new targets: the default-on presence read, the persistence setter
  inversion, the checkbox's `loadValues` state and action write inversion, the
  controller's live provider hardcoded on, and the Reduce Motion precedence inversion).
  No existing target needed re-pointing. The new settings mutants ran first via
  `mutate.py animation` while iterating: one draft replacement (`{ _ in true }` for a
  zero-argument `() -> Bool`) compiled as INVALID and was fixed to `{ true }` before the
  full run.

## Review findings and resolutions

- Code-review skill run over the working tree against base `1e1ac1a` (tracked diff plus
  the new untracked test file) before the commit: the skill's parallel subagents are
  unavailable in this session, so Standards and Spec ran as separate manual passes.
- Standards: no documented standards files exist in the repo (`CODING_STANDARDS.md` /
  `CONTRIBUTING.md` / `AGENTS.md` absent; `docs/` holds only the UI plan), so the review
  used `CONTEXT.md` vocabulary plus the smell baseline. No hard violations. One judgement
  call, accepted without change: the new test file repeats the existing `findButton`
  recursion as `findCheckbox` and repeats the controller-construction boilerplate its
  siblings use; both match the file-local test style, and shared test helpers have no
  precedent here.
- Spec: every Settings implementation decision and ticket checkbox is covered — default
  true with the presence read, persistence across launches, live off/on, the provider
  closure read per move, and Reduce Motion winning in both toggle positions (with control
  legs asserting the glide path is alive, so a snap cannot pass because animation is
  dead). No scope creep: the animator, carve-outs, surrender, and harness default are
  untouched. One residual gap, accepted: the delegate's own provider closure has no
  direct test seam (`AppDelegate` owns a live gateway); the controller/settings seam it
  composes is tested in both toggle positions, and the wiring is a two-line closure
  verified by inspection.

## Deviations

- None from the ticket. The tooltip's Reduce Motion sentence is additive UI copy, kept
  because the precedence is otherwise invisible in Settings; no behavior rides on it.
- The "toggle off + Reduce Motion on" leg of the precedence test cannot distinguish
  precedence from the toggle being off (both snap); the distinguishing legs are
  toggle-on + Reduce Motion and the control glide. The redundant leg is kept because the
  ticket names both positions.
- Process note: the controller-level settings test had no red phase — it pins the
  composition of already-built pieces (`AppSettings` plus the existing live provider) at
  the seam the delegate wires. The property slice and the checkbox slice carried the
  red-green loop for the new behavior.
