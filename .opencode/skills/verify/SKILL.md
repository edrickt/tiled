---
name: verify
description: Drive the real Tiled macOS window manager on live windows and prove tiling behavior. Use when a change touches tiling, eviction/swap/reflow, splitter drags, drag-out, layouts, undo, window lifecycle, menus, or multi-display/Space handling, and hermetic tests alone are not proof.
---

# Verify Tiled

Tiled is an LSUIElement menu-bar app that moves other apps' windows through
the Accessibility API. Its user surface is global hotkeys, the menu bar, the
status icon, and the resulting window frames. Verification means putting real
windows on a real screen and reading their AX frames back.

## Launch

Hermetic gate first, from the repo root:

```sh
swift test
```

It runs 833 tests in about 4 seconds with no AX, no window server, and no
runloop. One is an opt-in exhaustive check (`TILED_EXHAUSTIVE=1`); plain
`swift test` skips it. A green unit suite is necessary, not proof of the live adapter.

For live behavior, start through the repo harness, never by pointing a suite
at an instance someone else started:

```sh
./scripts/run-repro.sh                            # full suite (39 cases)
./scripts/run-repro.sh tools/repro/driver.swift   # smaller focused driver
./scripts/run-focus-loop.sh tools/repro/window-lifecycle-repro.swift
```

`run-repro.sh` builds `.build/debug/tiled`, compiles `build/host`, launches
both, and kills exactly the PIDs it started on exit. It refuses to run while
`/Applications/Tiled.app` is running (exit 3): two managers answer one global
hotkey and every case then reads the wrong state. Quit the installed app
first, or use `run-focus-loop.sh`, which kills it and says so.

`run-focus-loop.sh` builds the suite into `build/focus-suite`, launches the
dev app under a PTY with `TILED_DEBUG=1` writing `build/focus-loop-tiled.log`,
opens `build/Host.app` through LaunchServices so the host can become
frontmost, and prints the filtered log after the suite. Ready means you see
`==> Running <suite>`; the four host windows exist after the preceding
3-second sleep.

For a one-off diagnostic, launch the dev app directly and keep its log:

```sh
TILED_DEBUG=1 NSUnbufferedIO=YES .build/debug/tiled > build/tiled-manual.log 2>&1 &
TILED_PID=$!
```

The direct form keeps `$!` as the app's PID, so cleanup can kill exactly it;
the repo harness wraps the app in `script` for a PTY. Use the harness for
anything that drives windows, because it also builds and activates the host.
Never drive an instance you did not start.

## Doctor

Run the read-only preflight before any live run:

```sh
./.opencode/skills/verify/scripts/doctor.sh
```

It checks the GUI session, Accessibility trust for this terminal, whether
`/Applications/Tiled.app` is running, stale dev/host processes, and the
Space table via `swift tools/repro/probe-spaces.swift`. Exit 0 means the
machine is drivable; fix every `FAIL` before driving and treat `WARN` as a
reason the run may be partial.

## Drive

The suites drive the real path: click a host window to focus it, post the
global hotkey with `CGEvent`, and assert AX frames within a small tolerance.
They read window titles `HOSTA`-`HOSTD` and AX frames; do not substitute
internal setters or test-only endpoints for the hotkey.

Run the suite that covers the feature, not the nearest passing one:

- `./scripts/run-repro.sh` - quarters and sixths end to end, 39 cases.
- `./scripts/run-repro.sh tools/repro/driver.swift` - two windows, one
  shared-edge drag.
- `./scripts/run-repro.sh tools/repro/multi-display-suite.swift` - two
  displays; needs both attached.
- `scripts/run-focus-loop.sh tools/repro/window-lifecycle-repro.swift` -
  close vs kill release; `MODE=close-window` for the close leg.
- `scripts/run-focus-loop.sh tools/repro/handle-collision-repro.swift` -
  same-frame same-app window identity.
- `scripts/run-focus-loop.sh tools/repro/screen-edge-snapback-latency.swift`
  - screen-edge mouse-up latency.

Known harness limit: the suites park the host windows at fixed coordinates
tuned for roughly 1512x982. On a narrower display `HOSTC` and `HOSTD` start
partly off-screen and `HOSTB`'s center can sit under `HOSTC`; a focused
driver that clicks that center targets the wrong window, and an eviction
restore can be clamped to the visible frame. Before calling a failure a
regression, read the case's actual and expected frames and record the display
size in the evidence. On a 1120x1050 single-display machine the full suite
scored `PASS 37 FAIL 2` (S11a and S14b); the resize cases S2-S7 and the rest
of the tiling sequence passed.

`tools/repro/dragout-sixth-test.swift` and `tools/repro/evict-drag-test.swift`
read `/tmp/tiled-debug.log`, so launch tiled manually with
`TILED_DEBUG=1 .build/debug/tiled 2>/tmp/tiled-debug.log` and run them with
`swift`, plus the host app. Do not run them through `run-focus-loop.sh`; its
log lands at `build/focus-loop-tiled.log` and the probe would read a stale or
missing file.

When you add a case, put it in the suite that owns the behavior and give it a
label that names the user gesture and the expected end state. Extend
`tools/repro/suite.swift` for quarters/sixths; write a focused
`tools/repro/<name>.swift` when the signal is the menu, status icon, or a
latency rather than a frame.

## Evidence

Write artifacts under `build/verification/<timestamp>-<feature>/` and keep
them after cleanup. `build/` is gitignored. Example:

```sh
mkdir -p "build/verification/$(date +%Y%m%d-%H%M%S)-edge-resize"
```

- Capture the suite transcript with `tee`, including the `PASS <label>` lines
  and the final `PASS n FAIL n` line.
- For a failure, capture the `>>>> FAILED` line, the actual and expected
  frames, and the relevant `build/focus-loop-tiled.log` lines.
- Capture the environment when the result is surprising:
  `swift tools/repro/probe-spaces.swift` (Space and display table) and the
  `doctor.sh` output.
- A screenshot of the final screen (`screencapture -x <path>`) is supporting
  evidence, not proof on its own.
- Exercise the user path, not just the final frame: the hotkey or click, the
  resulting frame, and the side effect that must accompany it (menu row,
  status-icon occupancy, undo notice, log line).
- Report an unreachable path with the attempted command and the unmet
  precondition. Do not report a skipped entry point as verified through a
  different one.

## Cleanup

The harness scripts trap and kill the PIDs they started. After a run,
confirm no dev instance or host survived:

```sh
pgrep -fl '\.build/(debug|release)/tiled' || true
pgrep -x host || true
```

If you launched manually, kill `$TILED_PID` and the host PID by the recorded
PIDs; never kill by process name. If `run-focus-loop.sh` stopped
`/Applications/Tiled.app` and it was running before the run, reopen it with
`open /Applications/Tiled.app` and say that its in-memory layout state was
lost. Do not delete `build/verification/`: the proof outlives the instance.

## Helpers

- `scripts/doctor.sh` - read-only preflight; run
  `./.opencode/skills/verify/scripts/doctor.sh`.
- `features/` - the feature map and one recipe per user-facing feature. Read
  `features/README.md` first, then open the matching feature file.
