# Switch layouts

Quarters and sixths are mutually exclusive per canvas, and the layout is a stored canvas choice. `⌥⇧\` switches the focused canvas explicitly: every tiled window there returns to its pre-tile frame, and one undo restores the windows and the previous layout. A slot key never switches; a key with no slot in the active layout is inert and says which layout owns the position.

## Sub-features

- `switch-to-sixths` switches a quarters canvas to sixths with `⌥⇧\`.
- `switch-to-quarters` switches a sixths canvas to quarters with `⌥⇧\`.
- `switch-untiles-all` restores every tiled window on that canvas, not on other canvases, to its pre-tile frame.
- `switch-undo` restores the previous layout and every untiled window as one chapter.
- `switch-empty-canvas` changes the layout, narrates it, and pushes no chapter (nothing to undo).
- `switch-per-canvas` leaves other displays and Spaces on their own layouts.

## How to get to it (user POV)

- Focus a window on the canvas and press `⌥⇧\` (the default Switch Layout combo).
- Menu bar → **Switch to Sixths** or **Switch to Quarters** (top-level, no focused window required).
- The status icon and the menu's layout line follow the stored choice, including on an empty canvas.
- Press `⌃⌥⇧⌘Z` to undo a switch that untiled windows.

## Driving it with run-repro.sh

Preconditions:

- `./.opencode/skills/verify/scripts/doctor.sh` exits 0.
- `/Applications/Tiled.app` is not running.
- One canvas with at least two tiled windows for the untiling proof.

- **Switch untiles and undo restores (live).** Run `./scripts/run-repro.sh`. After S1 tiles four quarters, the suite presses `⌥⇧\`, asserts all four windows sit at their pre-tile frames (`PASS S1c`), presses the global undo, and asserts all four quarter frames are back (`PASS S1d`). It then presses a sixths-only key on the restored quarters canvas and asserts the window did not move (`PASS S1e`), proving the undo restored Quarters.
- **Explicit switch geometry.** Read `PASS S19b switched to sixths: three top sixths at equal thirds`. S19 clears the board first, so it proves the switch's layout change and the sixths geometry, not the untiling side effect.
- **A slot press never switches.** Read `PASS S1b sixths-only key changed neither layout nor occupancy`.
- **Proof.** Tee the run to `build/verification/<timestamp>-layout-switch/suite.log`; keep the `PASS` lines and the final `PASS n FAIL 0` line.
- **Multi-display scope.** `./scripts/run-repro.sh tools/repro/multi-display-suite.swift` checks that one display's writes never move the other display's window. With one display attached, per-canvas layout isolation is unit-tested only.

## Gotchas

- S19 clears the board before switching, so it does not prove that the switch untiles other windows. Use S1c/S1d for that.
- The switch is per canvas (one display's one Space). Other canvases keep their layouts.
- A zero-window switch changes the layout and is not undoable. Pressing undo afterward acts on the newest older chapter, which may restore a different layout and its windows.
- Requesting a slot in the active layout tiles normally; no slot request switches.
- A key with no slot in the active layout (I, comma, K, H, semicolon in Quarters) is inert. The live suite proves I on Quarters; the receipt text is unit-tested.
- The menu notice is unit-tested (`MenuTextTests`); the live suite asserts frames and the layout behavior, not the notice text.
