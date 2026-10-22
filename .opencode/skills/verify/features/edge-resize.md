# Resize shared edges

Dragging a tiled window's edge moves the shared splitter. The dragged window's tile and the neighbor across the edge are rewritten when the mouse button is released. Rows are independent per column in quarters and per third in sixths; screen edges never move a splitter and snap back on release.

## Sub-features

- `resize-column` drags a vertical shared edge and moves only that column's splitter.
- `resize-row` drags a horizontal shared edge and moves only that column's or third's row splitter.
- `resize-corner` drags a corner that mixes two real splitters.
- `resize-clamp` stops a neighbor at its app minimum and pins it to the screen edge it held.
- `resize-screen-edge` leaves a screen-edge drag free mid-drag and snaps it home on mouse-up.
- `resize-hidden-divider` keeps a two-thirds window's hidden divider centered.
- `reset-splitters` snaps the focused canvas back to even splits (⌥⇧R or the menu row).

## How to get to it (user POV)

- Drag any edge of a tiled window (not its title bar).
- Press ⌥⇧R to reset the focused canvas's splitters.
- Menu bar → **Reset Splitters**, then **Restore Previous Splitters** after a reset.

## Driving it with run-repro.sh

Preconditions:

- `./.opencode/skills/verify/scripts/doctor.sh` exits 0.
- `/Applications/Tiled.app` is not running.
- For per-column and per-third isolation, no other window overlaps the dragged edge.

- **Focused drag (wide displays only).** Run `./scripts/run-repro.sh tools/repro/driver.swift`. It tiles `HOSTA` top-left and `HOSTB` bottom-left, drags `HOSTB`'s top edge up 120 pt, and prints the before/after frames plus an `EXPECT` line. On a display narrower than about 1512, its fixed `HOSTB` center can sit under `HOSTC` and the drag lands on the wrong window; on the 1120-wide test display it did. Prefer the full suite there.
- **Full resize family.** Run `./scripts/run-repro.sh` and read `PASS S2` (column), `PASS S3` (row), `PASS S4` (column from the other side), `PASS S5` (corner), `PASS S6a` (clamp), and `PASS S7` (screen edges did not move splitters). These passed on a 1120x1050 single-display machine.
- **Per-third independence.** Read `PASS S19c left sixth resized, middle and right sixths unmoved` and `PASS S19d per-third row independence: other thirds held`.
- **Two-thirds hidden divider.** Read `PASS S20b two-thirds resized, right third followed` and `PASS S20c middle third lands on the re-centered hidden divider`.
- **Screen-edge latency.** Run `scripts/run-focus-loop.sh tools/repro/screen-edge-snapback-latency.swift`. It tiles `HOSTA` into the right two-thirds, corner-drags both fixed screen edges, and requires the AX frame back within 0.75 seconds of mouse-up.
- **Proof.** Tee the transcript to `build/verification/<timestamp>-edge-resize/`; for the focus loop, keep `build/focus-loop-tiled.log` or a copy of the filtered log.

## Gotchas

- AX coordinates use a top-left origin; AppKit uses bottom-left. The suite converts with `axRect`; compare AX frames to AX frames.
- Drags are posted as many ticks. A single far jump without a recent hand press is treated as a programmatic move, not a drag.
- Neighbor writes happen on mouse-up, not continuously. Sample after the suite's settle delay (about 1.2 s); sampling immediately reads the pre-release board.
- A screen edge is free while the button is down and snaps back on release. A mid-drag screenshot showing the window off the screen edge is expected.
- Reset Splitters has no scripted live case. To prove it, press ⌥⇧R on a resized canvas and read the frames and the menu row; say that you drove it by hand, not through the suite.
- `run-focus-loop.sh` stops `/Applications/Tiled.app` if it is running. Reopen it after the run and say its in-memory layout state was lost.
