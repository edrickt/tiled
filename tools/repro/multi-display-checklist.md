# Multi-display live checklist

Run this before a release on a machine with two attached displays. The
automated suite covers what can be driven from one process with AX frame
mutations; the steps below cover physical display changes and Mission
Control actions that need a person at the machine.

## Setup

1. Attach two displays, arranged so both are visible.
2. Launch `tiled` and run:
   ```bash
   ./scripts/run-repro.sh tools/repro/multi-display-suite.swift
   ```
   The suite requires at least two screens. It tiles the same sixth slot on
   both displays, moves one window on one display, drags a shared splitter,
   and fails if the other display's window moves.
3. Keep the host app running for the manual steps below.

## Manual scenarios

### 1. Same slot, independent canvases

- Tile `HOSTA` into Top Left on display 1.
- Tile `HOSTB` into Top Left on display 2.
- Expected: both windows land in their own display's Top Left; the status
  icon follows the focused display.

### 2. Primary-display / arrangement change

- In System Settings > Displays, drag the white menu-bar bar to the other
  display (or rearrange the displays).
- Expected: each display keeps the arrangement it had; windows do not swap
  between displays. The menu group order follows the new screen order.
- Failure symptom: a canvas's windows jump to the other monitor, or undo
  history/layout follows the wrong display.

### 3. Unplug and replug

- While both displays are tiled, disable one in System Settings or unplug it.
- Expected: the remaining display's windows do not move; the removed
  display's windows stay where they were, and its rows leave the menu.
- Re-attach/re-enable the display.
- Expected: the returned display's canvas is reasserted against its bounds;
  its splitter positions and undo history survive.
- Failure symptom: the removed canvas is written while no display shows it,
  or return loses/re-homes its state.

### 4. Resolution and scaled mode

- Change the resolution or scaled-mode option on one display.
- Expected: that display's canvas reasserts against its new visible frame;
  the other display does not move.
- Swipe to a hidden Mission Control Space on that display, change resolution
  while it is hidden, then swipe back.
- Expected: the hidden canvas is not written until shown, then reasserts.

### 5. Mission Control Spaces

- Ensure "Displays have separate Spaces" is on.
- Tile a window on Space A of display 1, then swipe display 1 to Space B.
- Tile a different window on Space B.
- Expected: Space A's arrangement stays parked; Space B starts empty and
  gets its own layout/splitters/undo. Display 2 is untouched throughout.
- Swipe back and confirm Space A's arrangement returns.

### 6. Focus and menu scoping

- Focus a tiled window on display 1, then on display 2.
- Expected: the status glyph shows that display's layout and occupancy.
- Use **Untile All** and **Reset Splitters**.
- Expected: only the focused display's canvas is affected.

## Reporting a failure

Capture:

- the two displays' arrangements and resolutions,
- the step that failed,
- `TILED_DEBUG=1` output from the app,
- whether the window frame, menu row grouping, or undo history was wrong.
