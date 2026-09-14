# Install

Tiled is a menu bar app. It needs **macOS 13 or later** and **Accessibility
permission**, and nothing else: no kernel extension, no helper daemon, no
scripting bridge.

## From a release

1. Download `Tiled-<version>.zip` from [Releases](https://github.com/edrickt/tiled/releases).
2. Move `Tiled.app` to `/Applications`.
3. Open it once. Releases are ad-hoc signed (there is no Developer ID yet), so
   Gatekeeper may refuse the first launch; right-click the app and choose
   **Open**, then confirm.
4. Grant Accessibility permission when Tiled asks, then relaunch it.

## From source

```bash
git clone https://github.com/edrickt/tiled.git
cd tiled
./scripts/install-app.sh    # builds, installs to /Applications, launches
```

The script builds first and replaces the installed copy only after the build
succeeds, so a compile error cannot leave you without the app that is currently
tiling your windows. It also quits a running instance before replacing it.

Prefer not to install? `./scripts/make-app.sh` builds the bundle at
`build/Tiled.app`, and `swift run` runs the dev build from the terminal.

## Accessibility permission

Tiled drives windows through the Accessibility API, which macOS gates behind a
per-app permission. System Settings → **Privacy & Security → Accessibility**.

macOS attributes the request to the *responsible* process, which matters for
two different development setups:

- **Bundled app** (`build/Tiled.app`, `/Applications/Tiled.app`): grant
  **Tiled**. The first-run flow opens the settings pane for you.
- **`swift run` / plain binary**: grant your **terminal app**. The subprocess
  inherits the terminal's responsibility, so one grant covers every run from
  that terminal.

Ad-hoc signatures change on every rebuild, so a rebuild can make macOS treat
the app as a new program and forget the grant: System Settings may show Tiled
enabled while the app still reports no permission. Toggle it off and on again,
or sign with a stable identity (even a free Apple Development certificate) and
the grant sticks.

The app never writes to an off-screen Space. If a tiled window lives on a
hidden Space, its canvas is marked stale and re-asserted when you swipe back.

## Quitting and uninstalling

- **Quit** from the menu bar. Tiled leaves every window where it is; there is
  no termination handler that rearranges anything.
- **Launch at login** is a checkbox in Settings → General.
- **Uninstall**: quit Tiled, then `rm -rf /Applications/Tiled.app`. Tiled
  stores two preferences (`dev.tiled.app`: `hideMenuBarIcon` and
  `didDismissWelcome`); launch-at-login is registered through `SMAppService`
  and is removed with the app. `defaults delete dev.tiled.app` gets rid of the
  rest if you want a clean slate.

## Running alongside other window managers

Do not. Two managers registering the same global hotkeys produce a machine
where one keystroke moves two windows, and the one that is not moving windows
still holds the state it thinks is true. Quit other tiling managers (Rectangle,
Magnet, yabai's hotkey daemon, Tiled itself from another build) while using
Tiled or while running its live test suites.
