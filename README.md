# Tiled

A native macOS window manager. Tile windows into quarters (2×2 plus halves)
or sixths (3×2 grid plus thirds and two-thirds), with global hotkeys or from
the menu bar. Drag a tiled window's edge to resize it live.

**1.0.3 · macOS 13+ · Apple Silicon + Intel · MIT**

![Tiled demo](docs/assets/tiled-demo.png)

<!-- TODO: capture demo still/GIF at ~1512x982 showing quarters + sixths -->

## Features

- Two layouts per display: quarters and sixths, switched with one key
- Eleven shared slot keys (`⌥⇧` family) that never change the layout
- Live shared-edge resizing with per-column splitters
- Independent canvases per display and per Mission Control Space
- Remappable shortcuts with visible conflict and registration states
- Undo for displacements, plus expand, evict, and splitter reset

## Install

Download `Tiled-<version>.zip` from the
[releases page](https://github.com/edrickt/tiled/releases), move `Tiled.app`
to `/Applications`, then right-click it and choose **Open** on first launch
(the bundle is ad-hoc signed, so Gatekeeper needs that one-time override).
Grant Accessibility permission when Tiled asks and relaunch. Bundles are
universal (Apple Silicon and Intel) and target macOS 13 or later.

Verify the download:

```bash
shasum -a 256 -c Tiled-<version>.zip.sha256
```

## Try it in 30 seconds

1. Focus any window and press `⌥⇧U` — it tiles into the top-left slot.
2. Press `⌥⇧⏎` to expand it, then `⌥⇧⏎` again to drop it back.
3. Press `⌥⇧\` to switch the layout on the display under the pointer,
   then `⌃⌥⇧⌘Z` to undo.
4. Open the menu bar menu for the same actions by click, including
   **Tile Focused Window** and the focused-canvas rows.

## Shortcuts

The full hotkey tables, tiling rules, and live-resizing notes live in
[docs/user-guide.md](docs/user-guide.md).

Source of truth is the app: menu bar → **Settings… → Shortcuts**. All
11 slot keys and 6 app actions (Expand, Evict, Reset Splitters, Switch
Layout, Settings, Undo) are remappable there; the menu names conflicts
and dead combos.

## Building & testing

```bash
swift build            # debug build
make check             # unit suite (1004 tests) and the published count
make app               # release build bundled as build/Tiled.app
```

Details — the `swift run` Accessibility note (grant it to Terminal, not
the app), the live suites, and the mutation gate — are in
[docs/developing.md](docs/developing.md).

## Docs

- [User guide](docs/user-guide.md) — hotkeys, tiling rules, live resizing
- [Developing](docs/developing.md) — build, test, and verification
- [Release steps](docs/release.md) — how a version ships
- [Changelog](CHANGELOG.md) — what changed per version

## Status

Shipped: menu bar app, 17 hotkeys, sixths layout, live resizing,
per-Space canvases, drag-out, remappable shortcuts, undo.
Next: owned overlay resize handles. Decided: no gaps for now.

## License

Tiled is MIT-licensed. See [`LICENSE`](LICENSE).
