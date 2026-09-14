# Troubleshooting

Symptom first, then the cause that actually produces it. If none of these fit,
open an issue with your macOS version, how Tiled was installed, and the menu
rows that look wrong.

## Nothing happens when I press a shortcut

**Accessibility permission is not in effect.** Tiled tiles through the
Accessibility API; without the permission it cannot see or move windows, and
the menu shows `Waiting for Accessibility permission…`.

- Bundled app: System Settings → Privacy & Security → Accessibility → enable
  **Tiled**.
- `swift run`: enable your **terminal app** instead; the subprocess inherits
  the terminal's responsibility.
- After a rebuild, macOS can treat the ad-hoc-signed binary as a new program
  while System Settings still shows the old switch on. Toggle it off and on, or
  sign with a stable identity so the grant survives rebuilds.

## The menu warns that a shortcut failed to register

**Something already owns that global combo.** macOS does not report another
app's non-exclusive registration to Tiled, so Tiled can tell you the combo is
dead but not who took it. Open Settings → Shortcuts, click the row, and pick a
different combo. Disabled slots register nothing and never warn.

## One key fires two window managers

**Two managers are running.** Tiled, Rectangle, Magnet, and friends all
register global hotkeys; the winner is whichever registered first, and the
loser still holds the state it believes. Quit the other manager (or the other
Tiled build) before using Tiled and before running any live suite.

## A window snaps back, or the menu names an app that refused

**The app refuses programmatic resizing.** Some apps (and some windows inside
otherwise fine apps) reject AX frame writes. Tiled leaves the window where it
is, does not record the placement, and names the app in the menu. Nothing is
lost; tile another window, or resize that one by hand and press the shortcut
again.

## Windows tile on one Space and not another

**Canvases are per Space.** Each Mission Control Space keeps its own layout,
occupancy, and history. Windows on a hidden Space stay tiled but are not written
to while off-screen (an off-screen resize can pull a window onto the visible
Space); they re-assert against current bounds when you swipe back. If it never
re-asserts, note whether the Space identifier is available on your setup:
where the window server withholds it, Tiled falls back to one canvas per
display, and per-Space independence is not promised in that mode.

## A window I closed stays in the layout

Closing a window normally releases its slot within milliseconds through the
Accessibility destroy notification. If the whole app was killed (no
notification left to send), the slot is released by a 5s prune tick plus a 3s
confirmation, so a slow read is expected. If a slot never releases, please
report the app: the fallback depends on that app answering window-list queries,
and a failure there is a real bug worth seeing.

## Dragging a window untiled it, and I wanted it tiled

**Drag-out is deliberate.** A title-bar drag past ~100pt releases the slot and
leaves the window where you dropped it; a shorter drag snaps back. If you moved
a tiled window with a keyboard shortcut or another manager and it snapped back,
that is the same rule: a single far jump without a drag shape is treated as a
programmatic move, not a hand drag.

## The status glyph does not match the layout

The icon is an occupancy map, not a layout badge: each cell fills while a tiled
window *actually covers* it. A half window fills two cells; a two-thirds fills
four; an empty slot stays hollow. If it disagrees with the screen, the menu is
reporting a window whose write was refused, which is the state you want to see
rather than a silent mismatch.

## Live suites fail everywhere

**Accessibility permission, or a second manager.** `./scripts/run-repro.sh`
refuses to start if an installed Tiled is running (it owns the same hotkeys);
quit it first. Then confirm your terminal has Accessibility permission; if
every case fails, that is the cause, not the engine.

## `swift test` fails on a fresh clone

**Almost every test is hermetic**, so a failure is usually a real failure. The
exception is the handful of screen-identity tests (`DisplayIdentityTests`,
`LiveGatewayMappingTests`): they read `NSScreen` to pin how a live display maps
to a canvas key, so a headless session or an unusual display arrangement can
fail them for reasons that are not about the engine. `swift build -c release`
and `./scripts/make-app.sh` are the other two build-time checks CI runs; if one
of those fails, the message names the file.

## Reporting something not listed here

Useful evidence, in order: the exact menu rows (especially `⚠ …` warnings, the
status line, and any row naming an app that refused), the macOS version, how
Tiled was installed (release bundle, `/Applications` from source, or
`swift run`), and the shortest sequence that shows the problem. State both what
Tiled believes and what the screen shows; the interesting bugs are the ones
where those two disagree.
