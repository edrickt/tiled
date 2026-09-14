# Capturing the screenshots and GIFs

Every image in the README is generated from the real app by scripts in
`tools/capture/`. Nothing is hand-drawn, and re-running the pipeline after a UI
change refreshes the assets.

```bash
tools/capture/capture.sh            # every scene, into docs/assets/
tools/capture/capture.sh quarters   # one scene
```

## What the run does

1. **Builds the tools** (`demo-host`, `scene-driver`, `veil`, `mov2gif`,
   `desktop`) and the dev build of Tiled.
2. **Hides your apps** (`veil.swift`) so no unrelated window is in frame, and
   **backs up your desktop picture** with a screenshot of the empty desktop
   before replacing it with a neutral gradient. Both are restored at the end,
   even if the run fails.
3. **Per scene**: relaunches Tiled for an empty canvas, launches one demo
   window per mock app, records the visible frame with `screencapture -V`
   while the driver presses the real global hotkeys, then trims the recording
   and writes a GIF at 1024px / 10fps (`mov2gif`).
4. **For screenshot scenes** (menu, guide, shortcuts) the driver leaves the
   surface open, prints the crop frame the Accessibility API reports, and the
   script captures that rectangle, so crops follow the window.

## Requirements

- A logged-in GUI session with Accessibility permission for the terminal that
  runs the script (System Settings → Privacy & Security → Accessibility).
- A quiet desktop: the script moves the real cursor and relaunches Tiled.
- The installed `/Applications/Tiled.app` must not be running (it owns the
  same global hotkeys), so quit it first; the script does this for you and
  reports it.

## Files

| File | Role |
|---|---|
| `demo-host.swift` | The demo windows: an editor, terminal, notes, file list, browser, and music player, drawn with AppKit so there are no assets to ship. One process per mock app, so Tiled's window list names them like real apps. |
| `scene-driver.swift` | Scripts each scene (focus, hotkey, drag, menu) and records it. Posts real modifier key events, not just flags: synthetic clicks that arrive as ⌥⌘-clicks make macOS hide every other app, which produces very confusing footage. |
| `veil.swift` | Hides every app except the cast, and restores exactly those it hid. |
| `desktop/main.swift` | Renders the neutral backdrop that replaces the machine's own wallpaper during the run. |
| `mov2gif/main.swift` | Extracts frames from the recording with AVFoundation and writes an animated GIF with ImageIO, with `--start/--end/--width/--fps` trimming. |
| `capture.sh` | Orchestrates all of the above and writes `docs/assets/`. |

Scene definitions live at the top of `scene-driver.swift`; each one is a list
of steps, so adding a feature animation means adding a handful of `.focus` /
`.key` / `.dragEdge` lines.

## Notes

- Demo windows are labeled honestly (Editor, Terminal, Notes, Files, Browser,
  Music). They are drawings, not screenshots of other apps.
- The GIFs are cut to the visible frame, so the menu bar is not part of them.
  The menu bar has its own still (`menu.png`), which is where the occupancy
  glyph and the status item read best.
- Recordings and intermediate files land in `build/capture/` and are not
  committed; only `docs/assets/` is.
