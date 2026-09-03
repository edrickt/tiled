# tiled

A native macOS window manager. Tile windows into a 2×2 grid of quadrants plus
full-screen halves, with hotkeys. Dynamic shared-edge resizing is the flagship
feature on the roadmap.

## Hotkeys

| Key   | Tile          |
|-------|---------------|
| ⌥⇧U   | Top left      |
| ⌥⇧O   | Top right     |
| ⌥⇧M   | Bottom left   |
| ⌥⇧.   | Bottom right  |
| ⌥⇧J   | Left half     |
| ⌥⇧L   | Right half    |

Pressing a slot's key again untiles the focused window (restores its
pre-tile frame).

## Tiling rules

- One window per tile.
- Tiling a window into a slot **evicts** any window occupying an overlapping
  slot. Evicted windows are restored to their pre-tile frames.
  - Two quads occupied on one side + the half key → both quads are evicted.
  - A half occupied + a quad key on that side → the half window is evicted.
- A window re-tiling itself into an overlapping slot just moves (never evicts
  itself) and keeps its original pre-tile frame.
- Tiles are fixed rects for now (no gaps); dynamic shared-edge resizing comes later.

## Building & running

Requires Swift 6 / Xcode toolchain.

```bash
swift build          # debug build
swift test           # layout-engine unit tests
./scripts/make-app.sh # release build bundled as build/Tiled.app
```

### Running during development

The easiest dev loop: run the binary from your terminal and grant **Terminal**
(itself) Accessibility permission once — TCC attributes AX requests from
subprocesses to the responsible process:

```bash
swift run
```

For the bundled app (`./scripts/make-app.sh`), grant **Tiled** Accessibility
permission in System Settings. Note: ad-hoc signing changes on every rebuild,
so macOS may ask you to re-grant the permission after rebuilds. For serious
use, sign with a stable identity (even a free Apple ID "Apple Development"
certificate) so TCC remembers the grant.

## Status / roadmap

- [x] Menu bar app (LSUIElement), Accessibility permission flow
- [x] Six global hotkeys (Carbon RegisterEventHotKey)
- [x] Pure, unit-tested tiling state with the decided eviction rules
- [x] Fixed-rect tiling via the Accessibility API
- [ ] AXObserver-driven cleanup (window closed / app quit) — currently lazy pruning
- [ ] Drag-out-to-untile (drop inside tile = snap back, outside = untile)
- [ ] Dynamic shared-edge resizing (the flagship): binary split tree with
      ratios, observe-native-drag + compensate, then owned overlay resize handles
- [ ] Gaps? (decided: no gaps for now)
