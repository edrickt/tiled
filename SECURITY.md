# Security

## What Tiled can do

Tiled requests **Accessibility permission**, which is broad: it can read every
window's title, position, and size, post synthetic input, and move and resize
other apps' windows. That is the entire mechanism by which a window manager
works, and it is worth being explicit about what Tiled does with it.

- **No network.** Tiled has no networking code, no update checker, no
  telemetry, and no crash reporter.
- **No persistence of your windows.** Frames are kept in memory for the current
  session so a window can be restored when it is untiled; nothing is written to
  disk, and quitting leaves every window where it is.
- **Two preferences**, in `dev.tiled.app`: `hideMenuBarIcon` and
  `didDismissWelcome`. Launch-at-login is registered through `SMAppService`,
  which is visible and removable in System Settings → General → Login Items.
- **No bundled binaries, no helper daemons, no privileged components.** The
  app is one executable.
- **Reads private window-server symbols** (`SkyLight`/CoreGraphics) through
  `dlsym` to identify Mission Control Spaces, with a documented fallback to
  per-display tiling when those symbols are unavailable. It uses them to read
  Space identity, not to write anything off-screen.

## Reporting a vulnerability

Email **edrick.tamayo@zoho.com** with the details rather than opening a public
issue for anything exploitable. Please include the macOS version and the build
(commit hash or release version). Expect an acknowledgement within a few days.

Because Tiled lives on the Accessibility boundary, the reports that matter most
are: a way to make Tiled move or focus a window it was not asked to move, a
code path that writes to an off-screen Space, or a way for a third party to
influence Tiled's decisions (for example through a crafted window title or
application name) beyond what the menu displays.
