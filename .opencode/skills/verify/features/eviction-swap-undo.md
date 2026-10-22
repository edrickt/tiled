# Evict, swap, re-house, and undo

A tiling request aimed at an occupied overlapping slot displaces another window. A lone blocker in a disjoint slot swaps; an evictee whose leftover is exactly one whole slot steps aside; freed cells reflow into a neighbor; undo restores the whole chapter.

## Sub-features

- `evict-one` untiles one blocker and restores its pre-tile frame.
- `evict-double` untiles two quads when a half covers both.
- `swap` trades slots with a single blocker whose old slot is disjoint from the target.
- `rehouse-step-aside` moves a blocker into its own leftover when that leftover is exactly one whole slot.
- `rehouse-free-slot` re-tiles an evictee into the one whole slot the request leaves free.
- `reflow` grows an adjacent survivor into freed cells, rightmost candidate winning ties.
- `undo` returns displaced windows and a tiled requester in one ⌃⌥⇧⌘Z chapter.
- `untile-all` releases every tiled window on the focused canvas from the menu.

## How to get to it (user POV)

- Tile the focused window into a slot another window occupies or overlaps.
- Press ⌃⌥⇧⌘Z to undo the displacement.
- Menu bar → **Untile N Windows** releases every tiled window on the focused canvas.

## Driving it with run-repro.sh

Preconditions:

- `./.opencode/skills/verify/scripts/doctor.sh` exits 0.
- `/Applications/Tiled.app` is not running.
- `HOSTA`-`HOSTD` all exist and start at their parked frames.

- **Single eviction.** Read `PASS S9 B tiled BR, D evicted`; the blocker returns to its pre-tile frame.
- **Double eviction.** Read `PASS S14a C tiled LH; A and B both evicted (double eviction)`.
- **Swap.** Read `PASS S16c swap: A in BL, B in TL, nobody evicted`. The requester lands in the blocker's slot and the blocker takes the vacated tile.
- **Re-house.** Read `PASS S17b re-house: C in LH, A moved to TR, B untouched`. The evictee stays tiled in the leftover slot.
- **Undo.** Read `PASS S18c undo returned A and B to their slots and C to its pre-tile frame`. The suite presses ⌃⌥⇧⌘Z through `pressUndo()`.
- **Proof.** Tee the run to `build/verification/<timestamp>-eviction-undo/suite.log`; keep the `PASS` lines and the final count.

## Gotchas

- Swap needs exactly one blocker and a vacated tile disjoint from the target. With two blockers, or from an untiled window, the request evicts; do not assert a swap in those shapes.
- Re-house step-aside is checked before swap and wins when the blocker's leftover is one whole slot.
- Undo returns a stepped-aside window to its original full slot, not to the slot it stepped into.
- An expanded window never re-houses or steps aside; it untiles. Expand itself has no scripted live case.
- The suite proves frames and undo. The menu's eviction/untile/undo notices are unit-tested (`MenuTextTests`); a live menu-row proof is a separate entry point.
- A refused AX restore cannot be simulated with the host app; that path is unit-tested only. Do not claim a live refusal proof.
- S14b can fail on a display narrower than about 1512: `HOSTC`'s expected pre-tile frame is x=1000, which is off-screen on the 1120-wide test display, and the restore is clamped. Read the expected frame against the screen before calling it an eviction bug.
- `run-focus-loop.sh` stops `/Applications/Tiled.app` if it is running; reopen it after the run and say its in-memory layout state was lost.
