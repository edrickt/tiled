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

**Status:** DONE (c519fa5)

- [x] Classifier tests pin the absorbed translation (100/50), the
      drifty grab (20/2), the clean grab (20/0), and the opposing-edge
      resize.
- [x] `TickShape` lands; `sizeDelta`, `clearGrab`, `clearTranslation`,
      and `originMovedMoreThanSize` are deleted.
- [x] Router extraction lands; the service handler is cleared on
      teardown; a test drives the resolve-and-hop step without a Carbon
      event.
- [x] Gates in `../README.md` pass (build warnings empty, suite green,
      README count matches); the mutation table is the coordinator's
      final gate, per `AGENTS.md`, and was not run here.

## Comments

Landed in two code units:

- `992bb73` replaced the magnitude ladder with one `TickShape`
  classifier per axis and pinned the four shapes. Against the old
  ladder the absorbed translation (100/50) failed both its splitter and
  drag-decision assertions; the drifty grab (20/2), clean grab (20/0),
  and opposing-edge resize passed, then stayed green under the
  classifier. A search over `Sources/` and `Tests/` confirms the four
  deleted symbols no longer exist. The `[Unreleased]` CHANGELOG names the
  user-visible fix.
- `c519fa5` extracted `CarbonHotkeyEventRouter` (install-once event tap,
  `handleEvent(_:)` parse, `dispatch(hotKeyID:deliver:)` resolve-and-hop)
  and deleted the service's `Context`/`sharedContext`, `handlerInstalled`,
  forwarding handler, and static callback. A hermetic test drives
  `dispatch` without a synthesized Carbon event; service teardown and
  replacement-ownership tests pin F29.

Gates after each unit: `swift build 2>&1 | grep -E "warning:|error:"`
printed nothing; `swift test` passed 858 tests (1 skipped) after unit 1
and 863 tests (1 skipped) after unit 2, with the README counts updated in
the same commits; `./scripts/check-test-count.sh` reported the README
count matches. The full mutation table (`python3
tools/mutation/mutate.py`) is the coordinator's final gate per
`AGENTS.md` and was not run here.

Design decisions: the router stores the owning service's
`ObjectIdentifier` rather than a weak reference, because Swift clears
weak references to an object before its `deinit` body runs, which made
`clearHandler(ifOwner: self)` a no-op. `HotkeyService` accepts an
injected router so tests keep the existing no-op installer seam, while
production shares `CarbonHotkeyEventRouter.shared`. `CONTEXT.md` is
unchanged: the drag, splitter, and reassert definitions did not change
scope.

Residual: F28's Carbon parse itself (`handleEvent`) still needs a live
event or a synthesized one to exercise; the ticket asked only that
resolve-and-hop be hermetic. No wider cleanup from S4–S7 or the
DragTracker minor list was taken.

