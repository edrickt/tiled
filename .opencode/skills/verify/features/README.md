# Tiled verification map

This directory is the maintained source for verifying Tiled's user-facing behavior on live windows. Read this index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- A logged-in GUI session on the machine's console. The live suites post real mouse and keyboard events and cannot run over SSH or in CI.
- Accessibility permission for the terminal that runs opencode. `doctor.sh` checks it.
- `/Applications/Tiled.app` is not running. `run-repro.sh` refuses while it is; `run-focus-loop.sh` stops it and loses its in-memory layout state.
- The checkout builds: `swift test` passes (833 tests at the time of writing, one opt-in check skipped).
- A display at least about 1512x982, or a run that checks frames before trusting a focus click. The suite parks windows at fixed coordinates: on a 1120x1050 display `HOSTC` and `HOSTD` start partly off-screen and `HOSTB`'s center sits under `HOSTC`.
- Start every live run through `./scripts/run-repro.sh` or `./scripts/run-focus-loop.sh`. Never drive an instance you did not start.

## Driving conventions

- The harness builds `.build/debug/tiled` and compiles `build/host` from `tools/repro/host-app.swift`.
- Host windows are titled `HOSTA` through `HOSTD`. All four must exist; a missing one turns some cases into silent no-ops.
- Drive with real global hotkeys and real mouse events (`CGEvent`), then read AX frames. Do not call internal setters or test-only endpoints.
- Assert frames within 2 pt (`suite.swift`) or 3 pt (`multi-display-suite.swift`).
- Check the side effect the user sees, not only the frame: menu rows, status-icon occupancy, undo notice, `TILED_DEBUG` log lines.
- Keep artifacts under `build/verification/<timestamp>-<feature>/`; `build/` is gitignored and cleanup never removes it.

## Proof and skip reporting

- Record the feature ID, entry point, command, and the `PASS`/`FAIL` lines with every artifact.
- A passing unit test is not live proof of the adapter.
- Report an unreachable path with the attempted command and the unmet precondition. Never report a skipped entry point as verified through a different path.
- When a Space or display precondition is absent (one Space, one display), say so; the suite degrades silently.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph of user-visible behavior, then exactly four H2s in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with <harness>`, `Gotchas`.

## Features

- [Tile into slots](./tile-slots.md) covers quarter and sixth slots, one window per slot, and same-slot no-ops.
- [Resize shared edges](./edge-resize.md) covers splitter drags, per-column and per-third independence, clamping, and screen edges.
- [Evict, swap, re-house, and undo](./eviction-swap-undo.md) covers occupancy conflicts and the undo chapter.
- [Drag out](./drag-out.md) covers long-drag untiling at the drop and short-drag snapback.
- [Switch layouts](./layout-switch.md) covers quarters-to-sixths switching and the undo of its untiling.

## Also covered by focused probes

These have live probes but no full feature recipe yet; use the command named in the probe's header and report the path you actually drove.

- `tools/repro/window-lifecycle-repro.swift` - a closed window releases its slot sub-second; a killed app releases on the prune cadence and empties the status icon.
- `tools/repro/handle-collision-repro.swift` - a same-app window opening on a tiled window's exact frame must not inherit its handle.
- `tools/repro/screen-edge-snapback-latency.swift` - a screen-edge drag snaps back within 0.75 seconds of mouse-up.
