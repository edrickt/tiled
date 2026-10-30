# Changelog

All notable changes to Tiled are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Drag-out untile distance halved again: ~25pt of title-bar drag (was
  ~50pt) releases the tile; a shorter drag still snaps back.

## [1.1.0] - 2026-10-30

### Changed

- Every exit from tiling leaves the window floating at the layout's slot
  footprint — quarter size on a Quarters canvas, sixth size on a Sixths
  canvas — instead of snapping back to its pre-tile frame. Manual untile,
  eviction, untile-all, layout switch, and drag-out all resize in place
  (top edge kept, the bottom edge pulled up to the grid's size, repinned inside
  the visible frame), and undo chapters
  store the sized frame. The footprint is always the regular even-split
  size, ignoring any drag-edited splitters. The footprint hangs from the
  window's top edge: the top stays where it was and the bottom edge rises
  to the grid's size.
- New windows open at the cursor display's canvas footprint instead of
  keeping whatever size their app gave them, and stay floating: Tiled
  never auto-tiles.

## [1.0.3] - 2026-10-29

### Changed

- Tiling into a slot blocked by two windows no longer sends both home: they
  mirror to the other side and stay tiled (two right quads move to the two
  left quads when a left half becomes the right half). If the other side
  can't hold them all, or a middle third is in the way, both untangle as
  before.

## [1.0.2] - 2026-10-29

### Fixed

- Dragging a shared edge to expand over a neighbour at its app's minimum
  size no longer snaps the drag back at mouse-up. The floor-clamped
  neighbour keeps its minimum size pinned to the screen edge it already
  held, and the expanding window keeps the edge the drag reached; the two
  overlap, the expanded window in front, until the splitter is dragged
  back past the neighbour's achieved edge. A neighbour that lands a few
  pixels *short* of its target by rounding still pulls the splitter, so
  no gap reopens. (A frame the app answered *larger* than its target is a
  floor clamp; only that case leaves the splitter alone. See ADR 0004.)

## [1.0.1] - 2026-10-29

### Fixed

- An app that never marks a window AX-focused can be tiled again. A
  Chromium/CEF host (Spotify is the measured one) exposes no focused UI
  element, so the system-wide `kAXFocusedApplicationAttribute` read
  answers `.noValue` and every slot key resolved "no focused window":
  the window never moved and no notice named why. The requester now
  falls back to the workspace's frontmost app, whose own
  `kAXFocusedWindowAttribute` read answers for such an app — and only
  when AX named no app, so an answer AX gave is never overridden.
  Verified live on macOS 26 (Spotify 1.3.3, `TILED_DEBUG=1`: the read
  logged err=-25212 with Spotify frontmost and err=0 with Firefox
  frontmost, milliseconds apart; the fallback then tiled Spotify into
  the requested slot).

## [1.0.0] - 2026-10-29

First stable release. No code changes since 0.3.2: the audited 0.3.x
foundation — atomic frame writes, canvas retirement for deleted
Spaces, truthful menus and undo, the warning-free build — is now the
1.0 behavior the README documents, held by the standing gates (959
unit tests, the 149-mutant table, the exhaustive undo replay).

## [0.3.2] - 2026-10-28

### Fixed

- The debug build is warning-free again: a dead `slot` binding in the
  collapse-expansion deferral now reads as the boolean test it is, and
  the cursor-seed calls discard their result explicitly. No behavior
  change.
- Glossary drift swept a second time: prose that said "monitor" for the
  display dimension (status icon, menu grouping, window gateway, README)
  now says "display". Code identifiers are untouched. No behavior change.
- The open self-untile question is pinned hermetically: a new regression
  test proves undo after a focused untile restores the reflowed survivor
  and leaves the untiled window at its pre-tile frame, so the live log's
  missing re-place matches the design instead of a dropped write.
  Whether undo should re-tile there is a product call, parked in the
  ticket with the pinning test cited.

### Added

- `tools/repro/probe-identity.swift` reports the display number and
  Space table a canvas key is built from, for the sleep/wake identity
  hypothesis the audit parked.
- `.gitignore` now covers local tool state (`.headroom/`, `.pi/`).

## [0.3.1] - 2026-10-28

### Fixed

- A refused position write no longer resizes the window in place: the
  frame write pair is all-or-nothing in both directions, so an app that
  refuses the move leaves the window exactly where it was.
- A Mission Control Space deleted while its canvas held windows no longer
  strands them: the canvas is retired, and the window tiles again on the
  Space macOS moved it to instead of deferring forever against a canvas
  that can never be visible.
- The menu no longer shows the same error twice after an action on another
  display, and a window on a display holding both a named and a withheld
  canvas stays under its own display's header, with that header's count.
- A re-house whose fallback restore is also refused now names the app in
  the menu instead of claiming the window went back.
- A mouse-up can no longer lose a drag: a sub-pixel final tick no longer
  cancels an in-flight title-bar drag, and a live drag is decided before
  the edge reassert that used to erase it and reconcile the splitters from
  the dropped frame.
- A stored shortcut value outside the usable range no longer traps when
  Settings opens; it degrades to the factory default.
- Clearing a failing shortcut no longer leaves the old warning on screen,
  and clearing an app action no longer parks its combo where nothing could
  restore it. Slot keys still park for Enable all, and the message names
  that route.
- Undo's notices point at the menu instead of a hardcoded ⌃⌥⇧⌘Z (Undo is
  remappable), an undo re-tiles above the arrangement it restores, and the
  menu never offers "Restore 0 Displaced Windows".
- A closed window's parked restore is dropped instead of failing on the
  swipe back and naming a window the user closed.
- Reset Splitters keeps its one-press contract: while a backup is parked
  the same press restores it instead of overwriting it.
- The Welcome tab announces an Accessibility permission change instead of
  changing layout silently.
- Hotkey bindings opened only for focus reads are released when their app
  quits.
- The README now states the shipped rule for the menu-bar glyph and ⌥⇧\:
  both follow the display under the pointer, while the tiled-window rows
  and the menu's Switch Layout row follow focus.

### Added

- `make exhaustive` runs the exhaustive undo replay (653 boards, 11,931
  chapters) and joins the hand-off gate, which the hermetic cycle never
  ran before.

## [0.3.0] - 2026-10-28

### Added

- Eleven shared ⌥⇧ slot keys (U I O M , . J K L H ;) that mean the
  matching position in whichever layout the canvas is showing, plus ⌥⇧\
  to switch the layout of the display under the pointer — with or without a
  window there — explicitly (the menu's Switch Layout row still follows
  focus). A switch untiles every tiled window there and restores each to
  its pre-tile frame; one undo returns the windows and the previous layout.
  The layout is a stored canvas choice, so an empty canvas keeps it, and a
  key with no slot in the active layout is inert and says where it belongs.
  Tiled now registers 17 hotkeys: 11 slot keys and 6 app actions.
- The Shortcuts tab shows App Actions (6) and Slot Keys (11), with one bulk
  Enable/Disable all for the eleven slot keys.

### Changed

- **Breaking:** quarter-specific hotkey overrides and parked combos are
  retired. The shared keys persist under the sixths slot names, so sixths
  overrides, parks, and reset backups survive untouched; the six old
  quarter storage names (topLeft, topRight, bottomLeft, bottomRight,
  leftHalf, rightHalf) are deleted once at launch. Quarter placements now
  use the same ⌥⇧ modifiers as sixths rather than ⌥⇧⌘, and a slot press no
  longer switches layouts.

### Fixed

- A title-bar drag whose first tick carries a size change the app absorbed
  now moves the window instead of yanking a splitter. The tick is read from
  both edges of each axis, so an absorbed translation stays a move while an
  edge grab with a little opposite-edge drift still resizes.
- Hotkey registrations are retired when the service is released, its
  process-wide hotkey handler is cleared with it, and a reload unregisters
  the old set before registering the edited bindings. Registration,
  disabled actions, failed actions, reload, and teardown are now covered by
  the hermetic suite instead of only a live process.
- A programmatic window jump no longer untiles when an unrelated click
  lands before the move-silence debounce: a far tick decides a drag-out at
  mouse-up only when a recent hand press landed on that window and mouse
  movement kept it live, so a real one-tick hand drag still drops where
  released while a programmatic jump — even a multi-tick one — snaps back. A placement,
  undo, reflow, or expand/collapse write skipped because the window already
  held its target frame now seeds the drag baseline, so a one-tick short
  title-bar drag after it snaps back instead of leaving the window offset.
- The re-house notice names the slot a window finally holds after reflow,
  not the intermediate slot it passed through. Undo now says “last
  displacement” and “Restore N Displaced Windows” instead of describing a
  switch or evictions, modified arrow keys and forward delete render as keycaps
  in the menu and VoiceOver instead of hex, and the Disable-all tooltip says
  the current combos are parked for Enable all to restore.
- The menu's Expand row says “Return to Previous Frame” for an expanded
  untiled window instead of “Expand to Fill Screen”, and still names the slot
  an expanded tiled window returns to. Expanding a window also supersedes an
  edge drag that never reached mouse-up, so the next mouse-up can no longer
  rewrite the splitters or move neighbours from the expanded window's
  screen-sized frame.
- The Welcome guide shows its Accessibility warning and grant button whenever
  the install is untrusted, including the first open after the Settings window
  was built, and hides them when permission arrives while the guide is open.
  It also stops teaching a Top Left or Expand combo that lost global
  registration, naming the menu row instead of a key that does nothing.
- Hiding the menu bar icon names the user's live Settings shortcut as the
  recovery, and only when that shortcut is enabled and registered. A
  disabled or failed Settings action now takes the relaunch-only path
  instead of promising a default combo that does nothing.
- Evict, Untile All, a single window's untile, and Undo announce success
  only when the controller performed the action. An empty undo stack, an
  untiled window, or a refused restore now answers once instead of
  speaking success and then contradicting it; a refusal on a background
  canvas names that display.
- The manage menu follows the focused canvas: with no tiled windows there
  it omits Untile All (never "Untile 0 Windows") and the Reset Splitters
  row, while a parked Restore Previous Splitters receipt stays reachable,
  the window list still names windows on every visible display, and a
  live undo chapter survives Untile All.
- Undo reports a refused restore instead of claiming success, keeps a
  window that cannot be moved back in the slot it visibly holds, and
  counts only the windows that actually landed, and names evictees a
  retained requester blocks. A refused move no longer puts the requester
  in the undo chapter when it never left its slot.
- A swap rolled back after the requester's write was refused now also
  names a failed home write, instead of reporting only the requester's
  refusal while the displaced window stayed in the vacated tile.
- A refused action now names every write it lost instead of letting one
  refusal outrank another: a refused eviction restore is reported beside a
  refused placement, and a refused reflow recovery write is reported beside
  the refused grow that triggered it.
- Corrupt stored shortcut data with negative modifiers is ignored like
  any other unreadable entry instead of trapping when Settings opens or
  a parked section is restored.
- A refused write clears its armed convergence expectation and reseeds
  the drag baseline, so a late check cannot evict a window that never
  moved there and an immediate short drag still snaps back.
- A refused minimum-size clamp repair now cancels its expectation and
  reports the write as refused, so a placement cannot claim success while
  the window still holds the clamped frame.
- Tiling places a window at its exact slot again: the live AX adapter
  writes the AppKit top-left corner instead of the bottom-left origin, so
  a bottom-row tile no longer lands a full window-height below its slot
  with only the title bar left on screen.
- A refused undo re-place or a refused expand keeps the source canvas's
  deferred pre-tile restore alive; only a landed claim discards it.
- Retiling or expanding a window on another Space after it was untiled
  on a hidden Space no longer lets the hidden Space's swipe-back restore
  write the old frame and pull the window off its new slot or expanded
  frame.
- Restore Previous Shortcuts restores a parked snapshot atomically,
  keeps clash-skipped entries for a retry, persists the footer across
  reopens, and leaves registration failures visible beside a partial
  restore result.
- The Shortcuts live region keeps one fixed order — registration
  failures, then a recorder conflict, then an action result — and
  VoiceOver hears an unchanged failure once instead of again on every
  reload or reopen.
- The reset-splitters hotkey restores a parked splitter backup instead of
  overwriting it with the already-reset grid, and the menu and hotkey now
  speak one receipt; a refused reassert is no longer announced as a
  successful reset.
- A mouse-up during an unreadable frame read still reasserts the canvas
  under the stored splitters, and two windows edge-dragging on one canvas
  both reconcile when the button lifts. A released window's memoized
  focus answer no longer outlives the handle.

### Tooling

- The mutation gate can resume from its last run: `--resume` rechecks only
  the mutants it did not catch, and a test or `Package.swift` change now puts
  the whole table in scope instead of selecting nothing. Verdicts merge into
  `build/mutation-results.json`, so the add-tests-to-kill-survivors loop no
  longer pays for the already-caught table.

## [0.2.2] - 2026-10-15

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

[0.3.0]: https://github.com/edrickt/tiled/releases/tag/v0.3.0
[0.2.2]: https://github.com/edrickt/tiled/releases/tag/v0.2.2
[0.2.1]: https://github.com/edrickt/tiled/releases/tag/v0.2.1
[0.2.0]: https://github.com/edrickt/tiled/releases/tag/v0.2.0
[0.1.0]: https://github.com/edrickt/tiled/releases/tag/v0.1.0
