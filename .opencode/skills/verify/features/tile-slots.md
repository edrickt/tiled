# Tile into slots

Tiling puts the focused window into a named slot: a quarter or a sixth. One window per slot, and tiling a window into the slot it already holds does nothing. Every slot has a global hotkey and a menu row.

## Sub-features

- `tile-quarters` puts the focused window into TL, TR, BL, BR, left half, or right half (⌥⇧⌘U/O/M/./J/L).
- `tile-sixths` puts it into a sixth, third, or two-thirds slot (⌥⇧U/I/O/M/,/./J/K/L/H/;).
- `tile-own-slot` re-pressing the window's own slot leaves it exactly where it is.
- `tile-retile` moves a tiled window to another slot without untiling it.
- `tile-menu` exposes every active-layout slot under **Tile Focused Window** in the menu bar.

## How to get to it (user POV)

- Focus any window and press a slot hotkey.
- Menu bar → **Tile Focused Window** → the slot name.
- First launch: the Welcome tab shows the Top Left shortcut with a miniature preview; press it on any focused window.

## Driving it with run-repro.sh

Preconditions:

- `./.opencode/skills/verify/scripts/doctor.sh` exits 0.
- `/Applications/Tiled.app` is not running.
- A quiet desktop: the suite clicks the centers of the host windows.

- **Four quarters.** Run `./scripts/run-repro.sh`. The suite parks `HOSTA`-`HOSTD`, focuses each by clicking its center, presses the quarter hotkey, and checks every frame. Expect `PASS S1 tile four quarters`.
- **Retile.** Read `PASS S13 retiled TL+BL+TR with current splitters`; the case moves already-tiled windows between slots.
- **Same-slot no-op.** Read `PASS S10a A still tiled LH after same-tile re-press`. Re-pressing a window's own slot must not restore, re-assert, or move it.
- **Sixth geometry.** Read `PASS S19b switched to sixths: three top sixths at equal thirds`. This case also crosses the layout boundary; see the layout-switch recipe for that part.
- **Proof.** Tee the run to `build/verification/<timestamp>-tile-slots/suite.log` and keep the `PASS` lines plus the final `PASS n FAIL 0` line.

## Gotchas

- The suite focuses a window by clicking its center. A covering window swallows that click, and the hotkey tiles the wrong window. Keep the desktop quiet and the host frontmost.
- A missing `HOSTA`-`HOSTD` window turns its scenarios into silent no-ops. Confirm all four exist before trusting a pass.
- Tiling into an occupied overlapping slot is eviction or swap, not a failed tile; use the eviction recipe to prove that path.
- A window already in its slot stays put; do not expect a reassert or a new pre-tile frame.
- The menu rows are the same actions but the suite proves the hotkey path. A menu-row proof is a separate entry point; do not report it as covered by the hotkey run.
