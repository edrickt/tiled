# Switch layouts

Quarters and sixths are mutually exclusive per canvas. Requesting a slot in the other layout untiles every other tiled window on that canvas and switches it; the requester lands in its slot, and one undo restores the switch and its untiling together.

## Sub-features

- `switch-to-sixths` requests a sixth while the canvas is in quarters.
- `switch-to-quarters` requests a quarter while the canvas is in sixths.
- `switch-untiles-others` untiles every other tiled window on that canvas, not on other canvases.
- `switch-undo` restores the switch and every untiled window as one chapter.
- `switch-edge-trigger` switches on the first sixth of a two-thirds drag gesture, the edge trigger that fires before mouse-up (unit-tested).

## How to get to it (user POV)

- With a canvas in quarters, press any sixths slot hotkey (or the reverse).
- Menu bar → **Tile Focused Window**: the other layout's slots appear after the switch.
- Press ⌃⌥⇧⌘Z to undo the switch.

## Driving it with run-repro.sh

Preconditions:

- `./.opencode/skills/verify/scripts/doctor.sh` exits 0.
- `/Applications/Tiled.app` is not running.
- One canvas with at least two tiled windows if you want to observe the untiling side effect.

- **Switch and sixth geometry.** Run `./scripts/run-repro.sh`. The suite clears the board, then tiles `HOSTA`-`HOSTC` with sixth hotkeys on a quarters canvas. Read `PASS S19a board cleared before the layout switch` and `PASS S19b switched to sixths: three top sixths at equal thirds`.
- **Proof.** Tee the run to `build/verification/<timestamp>-layout-switch/suite.log`; keep the `PASS` lines and the final count.
- **Untiling side effect (by hand).** The suite clears the board first, so S19 proves geometry, not the untiling. Tile two windows in quarters, press one sixths hotkey, and read both frames plus the menu notice ("Switched to Sixths · N windows untiled"). Then press ⌃⌥⇧⌘Z and read both restored frames. Report this as a hand-driven path.
- **Multi-display scope.** `./scripts/run-repro.sh tools/repro/multi-display-suite.swift` uses sixths hotkeys and checks that one display's slot writes never move the other display's window.

## Gotchas

- S19 clears the board before switching, so it does not prove that the switch untiles other windows. Do not report it as proof of `switch-untiles-others`.
- No scripted live case presses undo after a layout switch. `switch-undo` is unit-tested only; a live proof must drive ⌃⌥⇧⌘Z by hand and check the frames.
- The switch is per canvas (one display's one Space). Other canvases keep their layouts; S19 exercises only the focused canvas.
- Requesting a slot in the active layout does not switch; it tiles normally.
- Two displays are required for the multi-display suite; with one attached, that run cannot cover per-monitor isolation.
- The menu's switch notice is unit-tested (`MenuTextTests`); the live suite asserts frames, not the notice text.
