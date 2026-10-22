# 05: Input seams — tick classifier and Carbon router

**What to build:** one pure `TickShape` classifier per axis (noise bound
plus a dominance ratio) replacing the five-branch magnitude ladder in
`DragTracker`; one `CarbonHotkeyEventRouter` with a `dispatch(hotKeyID:
deliver:)` entry point, install-once init, and a handler the service
clears on teardown.

**Why:** F23 is the size gate winning over the translation shape, so a
first tick that absorbs more than the 8pt margin yanks a splitter;
reordering alone regresses a drifty grab. The Carbon callback's parse,
route, and main hop sit behind a stubbed installer (F28), and the
process-wide handler outlives service teardown (F29).

**Findings:** `../report.md` "Still open 5"; `../slices/03-input-launch.md`
S2, S3; F23/F28/F29 in `../../quality-audit-followup/report.md`.

**Status:** TODO

- [ ] Classifier tests pin the absorbed translation (100/50), the
      drifty grab (20/2), the clean grab (20/0), and the opposing-edge
      resize.
- [ ] `TickShape` lands; `sizeDelta`, `clearGrab`, `clearTranslation`,
      and `originMovedMoreThanSize` are deleted.
- [ ] Router extraction lands; the service handler is cleared on
      teardown; a test drives the resolve-and-hop step without a Carbon
      event.
- [ ] Gates in `../README.md` all pass.
