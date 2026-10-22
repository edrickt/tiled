# Drag out

Dragging a tiled window by its title bar past roughly 50 pt untiles it where you drop it. A shorter drag snaps back into its slot. A single far jump with no recent hand press is a programmatic move, not a drag-out, and still snaps back.

## Sub-features

- `dragout-untile` releases the slot and leaves the window at the drop, never at its pre-tile frame.
- `dragout-short-snapback` returns a short title-bar drag to the tile.
- `dragout-programmatic-snapback` snaps back a far move that had no hand press.
- `dragout-sixth` performs the long drag from a sixth slot.

## How to get to it (user POV)

- Drag a tiled window's title bar more than about 50 pt and release.
- Drag it less and release; it returns to its slot.

## Driving it with the drag-out probe

Preconditions:

- Quit `/Applications/Tiled.app`; two managers fight over the same hotkeys.
- Accessibility permission for this terminal (`doctor.sh`).
- A quiet desktop; the probe moves the real cursor.

Launch the dev app manually so its debug log lands where the probe reads it:

```sh
swift build
mkdir -p build
swiftc -o build/host tools/repro/host-app.swift -framework AppKit
TILED_DEBUG=1 NSUnbufferedIO=YES .build/debug/tiled > /tmp/tiled-debug.log 2>&1 &
TILED_PID=$!
build/host &
HOST_PID=$!
sleep 3
```

- **Long drag from a sixth.** Run `swift tools/repro/dragout-sixth-test.swift`. It tiles `HOSTA` into the top-left sixth and runs five drag variants (straight, fast fling, mid-drag pause, slow crawl, drag right after tiling). Each prints `VERDICT [<variant> r<n>]: GREEN` or `RED`. GREEN means the drop was honored and no splitter was yanked during the title drag.
- **Short-drag snapback.** Run `./scripts/run-repro.sh` and read `PASS S11a title-bar move did not move splitters; A snapped back`.
- **Proof.** Tee the probe to `build/verification/<timestamp>-drag-out/probe.log`; keep the `VERDICT` lines and the log tail for any RED.
- **Cleanup.** Kill the recorded PIDs: `kill "$TILED_PID" "$HOST_PID"`. Confirm with `pgrep -fl '\.build/(debug|release)/tiled'` and `pgrep -x host`.

## Gotchas

- The full suite does not cover long-drag untiling; only `dragout-sixth-test.swift` does. Do not report S11a as proof of drag-out.
- `dragout-sixth-test.swift` reads `/tmp/tiled-debug.log`. `run-focus-loop.sh` writes `build/focus-loop-tiled.log`, so running the probe through that script makes it read a stale or missing log.
- Latched ⌥⇧ turns a title drag into something else. The probe posts Option/Shift key-ups before every drag; a manual run should do the same.
- The drop decides the drag. A move-silence debounce is only the fallback when the mouse-up is missed.
- A fast fling can coalesce drag ticks; the probe repeats that variant to expose the race.
- A programmatic AX move is not a hand drag even if an unrelated click follows. Do not turn one into a drag-out by clicking first.
