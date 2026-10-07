# Multi-display live checklist

Run this before a release on a machine with two attached displays. The
automated suite covers what can be driven from one process with AX frame
mutations; the steps below cover physical display changes and Mission
Control actions that need a person at the machine.

## Setup

1. Attach two displays, arranged so both are visible. Label them for
   yourself — **built-in** and **external** — and keep the labels through
   scenario 2's rearrangement: every step and failure report refers to
   them.
2. Run the automated suite first:
   ```bash
   ./scripts/run-repro.sh tools/repro/multi-display-suite.swift
   ```
   The suite requires at least two screens. It launches `tiled` and the
   host app itself, tiles the same sixth slot on both displays, moves one
   window on one display, drags a shared splitter, and fails if the other
   display's window moves. **It kills both apps when it exits** (the trap
   in the script), so nothing is left running for the manual pass.
3. Relaunch both apps yourself for the manual scenarios, with debug
   logging on — the failure reports below ask for it:
   ```bash
   TILED_DEBUG=1 .build/debug/tiled &
   build/host &
   ```
   Quit any installed `/Applications/Tiled.app` first: the suite refuses
   to run while it does, because two managers answering one global
   hotkey make every case lie.

## Manual scenarios

### 1. Same slot, independent canvases

- Tile `HOSTA` into Top Left Sixth (⌥⇧U) on the built-in display.
- Tile `HOSTB` into Top Left Sixth (⌥⇧U) on the external display.
- Expected: both windows land in their own display's top-left sixth; the
  status icon follows the focused display.
- Failure symptom: a tile lands on the wrong display, or the glyph shows
  the other display's occupancy.

### 2. Primary-display / arrangement change

- In System Settings > Displays, drag the white menu-bar bar to the other
  display (or rearrange the displays).
- Expected: each display keeps the arrangement it had; windows do not swap
  between displays. The menu group order follows the new screen order.
- Failure symptom: a canvas's windows jump to the other monitor, or undo
  history/layout follows the wrong display.

### 3. Unplug and replug

- While both displays are tiled, disable one in System Settings or unplug it.
- Expected: the remaining display's windows do not move; the app writes
  nothing to the removed display's canvas while no display shows it (its
  rows leave the menu). macOS itself may relocate windows off the removed
  display — that is not a failure; what must hold is that Tiled never
  writes in the dark.
- Re-attach/re-enable the display.
- Expected: the returned display's canvas is reasserted against its bounds;
  its splitter positions and undo history survive.
- Failure symptom: the removed canvas is written while no display shows it,
  or return loses/re-homes its state.

### 4. Resolution and scaled mode

- Change the resolution or scaled-mode option on one display.
- Expected: that display's canvas reasserts against its new visible frame;
  the other display does not move.
- Failure symptom: the changed display keeps the old frame, or the other
  display's tiles move with it.
- Swipe to a hidden Mission Control Space on that display, change resolution
  while it is hidden, then swipe back.
- Expected: the hidden canvas is not written until shown, then reasserts.
- Failure symptom: the hidden canvas is written while hidden, or comes back
  with a stale frame.

### 5. Mission Control Spaces

- Ensure "Displays have separate Spaces" is on.
- Tile a window on Space A of the built-in display, then swipe that display
  to Space B.
- Tile a different window on Space B.
- Expected: Space A's arrangement stays parked; Space B starts empty and
  gets its own layout/splitters/undo. The external display is untouched
  throughout.
- Swipe back and confirm Space A's arrangement returns.
- Failure symptom: Space B inherits Space A's arrangement, or the external
  display's tiles change.

### 6. Shared Space across two displays

- In System Settings > Displays, turn "Displays have separate Spaces" off
  (one Space now spans both displays).
- Tile a window on each display.
- Expected: the canvases stay per-display even inside the shared Space:
  each display's tiles, splitters, and undo history remain its own, and
  tiling on one never moves the other.
- Turn the setting back on afterwards.
- Failure symptom: one display's tiling lands on (or re-homes) the other.

### 7. Lid close and clamshell

- With the external display tiled, close the laptop's lid, then reopen it
  (with and without the built-in display staying active, if your Mac
  supports clamshell).
- Expected: the surviving canvases reassert against the restored bounds;
  splitter positions and undo history survive; live windows are not pruned
  as dead during the blur (the death-confirmation window exists so a
  momentary AX silence cannot do that).
- Failure symptom: a live window is pruned (its menu rows vanish and never
  return), or a reopened canvas keeps the pre-sleep frame.

### 8. Focus and menu scoping

- Focus a tiled window on the built-in display, then on the external one.
- Expected: the status glyph shows that display's layout and occupancy.
- Drag a splitter first (so a splitter backup exists), then use **Reset
  Splitters**. It is titled **Restore Previous Splitters** whenever a
  backup exists — same control; after a reset it reads **Reset Splitters**
  again.
- Use the untile row (**Untile 1 Window** / **Untile N Windows** — titled
  by count) **last**: it lives in the manage section, which disappears
  once its canvas has nothing tiled, taking Reset Splitters with it.
- Expected: only the focused display's canvas is affected.
- Failure symptom: the other display's splitters move, or its windows
  untile.

## Reporting a failure

Capture:

- the two displays' arrangements and resolutions (and which was
  built-in/external at the time),
- the step that failed,
- `TILED_DEBUG=1` output from the app (step 3 launches it with the flag),
- whether the window frame, menu row grouping, or undo history was wrong.
