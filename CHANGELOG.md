# Changelog

All notable changes to Tiled are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Detaching a tab from a tiled Firefox window no longer untiles the
  original window when the new window is tiled. Firefox opens the
  detached window at (within a point of) the source window's frame, and
  the live adapter's element-churn fallback adopted any same-app window
  answering at a held window's last-read frame — so the newcomer
  inherited the tiled window's handle, the canvas read it as the tiled
  window moving, the original silently lost its slot, and the menu
  stopped counting it. Adoption by frame now also requires the held
  element to be provably stale (the app's fresh window list no longer
  contains it, or it no longer answers its own probe) — the state a
  display-teardown churn leaves behind — so a live window that merely
  shares the frame always keeps its handle. (`tools/repro/handle-collision-repro.swift`)

## [0.2.1] - 2026-10-15

### Changed

- Drag-out untile distance halved: ~50pt of title-bar drag (was ~100pt)
  releases the slot and leaves the window where dropped.

### Fixed

- Dragging an edge that sits on a screen edge snaps back on release: the
  drag moved no splitter, so the mouse-up re-asserted nothing and the edge
  stayed wherever it was released. Any edge movement now marks the canvas
  pending, and the release re-assert returns the fixed edge to the visible
  frame; a settle write the app's own live-resize session overrides (its
  final frame lands just after the write and is not refused) is re-issued
  once. In a corner drag mixing a screen edge with a real splitter, the
  splitter's new position is kept and only the screen edge snaps back.
- Dragging a tiled window by its title bar no longer expands the tile: apps
  that silently absorb the placement write (rounding to their own grid)
  made the first drag tick carry a slightly different size than the target,
  which the tracker misread as an edge drag and yanked a splitter by the
  full origin drag distance. Ticks now classify by what a hand can do:
  windows do not resize during a title drag, so any size change beyond the
  absorption-noise bound is an edge grab, and everything else tracks as a
  move.
- A fast drag out of a tile no longer snaps back: a fling coalesces in
  Accessibility to a single far tick, which the drag-end's two-tick rule
  read as a programmatic jump. A drag decided at the physical mouse-up is
  a hand gesture by definition (the button was down; programmatic jumps do
  not click) and untiles past the distance.
- Dragging a tiled window out of its tile (including out of its Space) now
  untiles at the drop: the title-bar drag ends at mouse-up like an edge drag,
  instead of waiting out the 0.5s move-silence debounce that left the slot
  marked occupied and the neighbours un-reflowed for a second or more.
- Tiling a right-third window into the left third no longer leaves the right
  third empty: the left two-thirds window it displaced re-housed into the
  middle third and now also absorbs the requester's vacated right third,
  ending up as the right two-thirds.

## [0.2.0] - 2026-10-11

### Added

- Reset Splitters global hotkey (⌥⇧R): snap the focused canvas's splitters
  back to even splits with every window kept in its slot, then press it again
  to restore the previous positions.
- App Actions section in the Shortcuts tab: Expand, Evict, Reset Splitters,
  Settings, and Undo are now remappable, disable-able, and parkable like the
  slots, bringing the total to 22 remappable hotkeys. Customized combos render
  in the status menu and the Welcome guide instead of being hardcoded.
- Re-house step-aside: a single blocker whose slot contains the requested tile
  now steps aside into its leftover strip instead of being untiled (the left
  third asked for its top sixth slides down into the bottom-left sixth). The
  rule covers tiled requesters, wins over swap, and is one undo away.

### Changed

- A canvas's placement pipeline, window records, expansion, and splitters now
  live in one deep module per canvas (`TilingSpace`); menus and tests read that
  single per-canvas surface instead of re-deriving state.
- All frame writes go through one `FrameWriter` policy module (no-op skip,
  off-Space deferral, echo marking, and the late convergence check in one
  place).

### Fixed

- A neighbor pushed below its app's minimum size now stops at the screen edge
  instead of growing off it: a clamped AX frame write is repinned at the bounds
  edge its target held.
- Documentation audit corrections across the README and CONTEXT.md (swap and
  step-aside wording, hotkey and test counts, and menu text).

### Tooling

- The mutation gate runs mutants in parallel copy-sandboxes (~3 minutes for
  the full 50-mutant table, down from ~15) and gains `--since <ref>` to score
  only the mutants a change can affect.
- 613 hermetic unit tests, up from 551 at 0.1.0.

## [0.1.0] - 2026-09-13

First release.

### Added

- Menu bar app (`LSUIElement`, no Dock icon) with a live occupancy glyph:
  each icon cell fills while a tiled window covers it.
- Quarters layout: top/bottom left and right quads, left and right halves.
- Sixths layout: six corner cells, three thirds, two two-thirds.
- 21 global hotkeys registered through Carbon: 17 remappable slot combos
  (6 quarters + 11 sixths) plus fixed Expand (⌥⇧⏎), Evict (⌥⇧⌫),
  Settings (⌃⌥⇧⌘,), and Undo (⌃⌥⇧⌘Z).
- Pure tiling engine over an atomic 4×2 cell model: overlap is cell-set
  intersection, so eviction, swap, reflow, and re-house are one rule set
  rather than per-layout special cases.
- Eviction with swap: a lone blocker trades tiles with the requester
  instead of being untiled.
- Reflow: freed cells merge with an adjacent survivor into a whole slot,
  rightmost candidate winning ties.
- Re-house: an eviction that leaves exactly one whole slot free re-tiles
  the victim into it.
- One undo chapter per canvas covering layout switches, evictions, swaps,
  reflows, and their combinations, reachable from anywhere with ⌃⌥⇧⌘Z.
- Expand toggle that covers the layout without releasing the slot.
- Drag-out: a title-bar drag past ~100pt untiles in place; a shorter drag
  snaps back.
- Live shared-edge resizing with per-column (quarters) and per-third
  (sixths) splitter independence, and a hidden divider kept centred on a
  two-thirds window.
- Per-Space, per-display canvases keyed on the window server's Space
  identifier and the monitor's CoreGraphics display number, with a
  per-display fallback where the Space identifier is withheld.
- Display-change re-assertion for visible canvases; hidden Spaces are
  marked stale and re-asserted on return.
- Remappable shortcuts with conflict detection, reserved-combo refusal,
  per-layout Enable/Disable all with parked combos, and a recorder row per
  slot.
- First-run Welcome tab demonstrating one tiling with a live slot preview,
  and a Tiled Guide reachable from the menu bar at any time.
- Honest failure states: an app that refuses a programmatic resize is named
  in the menu, and a global hotkey that fails to register is reported.
- 551-test hermetic unit suite over the pure engine through
  `FakeWindowGateway`, a 44-mutant audit table, a 39-case live end-to-end
  suite, and a multi-display suite with a manual checklist.
- CI on pushes to `master` and pull requests: unit suite, release build,
  app bundle verification, and a coverage summary.
- Universal release bundles (Apple Silicon and Intel), built and checksummed
  by the release workflow on a `v*` tag.

[0.2.1]: https://github.com/edrickt/tiled/releases/tag/v0.2.1
[0.2.0]: https://github.com/edrickt/tiled/releases/tag/v0.2.0
[0.1.0]: https://github.com/edrickt/tiled/releases/tag/v0.1.0
