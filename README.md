# Tiled

A native macOS window manager. Tile windows into quarters (2×2 plus halves)
or sixths (3×2 grid plus thirds and two-thirds), with global hotkeys or from
the menu bar. Dragging a tiled window's edge resizes it live; the
neighbors sharing the edge resize when the mouse button is released.

## Hotkeys

Tile the focused window. Tiling a window into its own tile is a no-op (it
stays exactly where it is). Every slot key in the active layout exists as a
menu item under **Tile Focused Window** in the menu bar menu. The explicit
switch is its own top-level row beside that submenu, and the app actions have
their own top-level menu rows. A slot key never changes the layout: the
layout is a stored canvas choice that sticks even when the canvas empties.

### The eleven slot keys (hold ⌥⇧)

The same physical key means the same position in both layouts; the active
layout decides which slot it selects. Five keys have no Quarters slot and are
inert there (the dashes below); an inert press changes nothing and says which
layout owns the position.

| Key    | Quarters     | Sixths             |
|--------|--------------|--------------------|
| ⌥⇧U   | Top left     | Top left sixth     |
| ⌥⇧I   | —            | Top middle sixth   |
| ⌥⇧O   | Top right    | Top right sixth    |
| ⌥⇧M   | Bottom left  | Bottom left sixth  |
| ⌥⇧,   | —            | Bottom middle sixth |
| ⌥⇧.   | Bottom right | Bottom right sixth |
| ⌥⇧J   | Left half    | Left third         |
| ⌥⇧K   | —            | Middle third       |
| ⌥⇧L   | Right half   | Right third        |
| ⌥⇧H   | —            | Left two-thirds    |
| ⌥⇧;   | —            | Right two-thirds   |

### Switch layout (⌥⇧\)

| Key    | Action |
|--------|--------|
| ⌥⇧\   | Switch the layout of the display under the pointer (the menu's Switch Layout row follows focus instead): untiles every tiled window on that canvas (each returns to its pre-tile frame); one undo restores the windows and the previous layout. On an empty canvas it just switches. |

### App actions

The six app actions are remappable. Expand, Evict, Reset Splitters, and
Switch Layout share the slot keys' ⌥⇧ modifier; Settings and Undo
deliberately take all four modifiers (⌃⌥⇧⌘) so they can't collide with a
slot combo:

| Key    | Action |
|--------|--------|
| ⌥⇧⏎    | Expand the focused window to fill the screen (not fullscreen mode) |
| ⌥⇧⌫    | Evict the focused window: untile it and restore its pre-tile frame |
| ⌥⇧R    | Reset Splitters: snap the focused canvas's splitters back to even splits, keeping every window tiled |
| ⌥⇧\    | Switch the layout of the display under the pointer (see above) |
| ⌃⌥⇧⌘,   | Open Settings (works even with the menu bar icon hidden, as long as this shortcut is enabled and registered; otherwise quit and reopen Tiled) |
| ⌃⌥⇧⌘Z   | Undo the focused canvas's last displacement (a layout switch, an eviction, or a swap — any reflow it caused is undone with it) |

### Expand (⌥⇧⏎)

Press ⌥⇧⏎ again and the window returns to its previous tile, or to its
previous frame if it wasn't tiled. The layout is never erased: a tiled
window keeps its slot while expanded (the expanded window just covers the
others, like focusing does), and tiling a neighbor into a free tile leaves
the expanded window alone.

### Evict (⌥⇧⌫)

Evicting restores the focused window to its pre-tile frame and releases
its slot. When a tiling request evicts a window, the victim keeps its
tiling whenever a whole slot fits: if its own slot overlaps the target and
the leftover (its slot minus the target) is exactly one whole slot, it
steps aside into that leftover (the left third asked for its top sixth
steps down into the bottom-left sixth); otherwise, when the request leaves
exactly one whole slot free, the victim re-tiles into that slot (the middle
third making room for the right two-thirds moves into the top-left sixth).
It untangles only when neither fits. The freed cells reflow: a neighboring tile that merges with
them into a whole slot grows into it — evict the bottom-left sixth and
the top-left sixth expands into the left third; free the middle third
and the right third becomes the right two-thirds (the right side wins
when both flanks could grow). The same reflow runs whenever a tiled
window leaves the layout (untile, drag-out, closing the window) or moves
to a free tile, and ⌃⌥⇧⌘Z undoes it together with the event that
caused it. A hole no neighbor can merge into exactly stays empty.

### Reset Splitters (⌥⇧R)

⌥⇧R always snaps the focused canvas's splitters back to even splits;
pressing it again resets again (and replaces the parked backup). The
one-step restore lives in the menu: a reset parks the positions from
before it, and the same row is then titled **Restore Previous
Splitters** until clicked, bringing those positions back. A drag alone
never arms the restore (and a drag after a reset doesn't clear it).
Windows stay in their slots either way; only the sizes change.

First launch opens Settings on a Welcome tab: focus any window and press the
Top Left slot key (⌥⇧U by default), with a miniature preview showing what the
top-left slot covers in both layouts. The guide shows your current binding
and the live switch shortcut; if the slot key is disabled or couldn't be
registered (another app owns the combo), it teaches menu bar → Tile Focused
Window → Top Left instead, and the Expand note names the menu row when that
combo is not live. A slot key never changes the layout: ⌥⇧\ switches it and
untiles every tiled window (undo restores them). Dismiss the guide once;
reopen it anytime from the menu bar menu → Tiled Guide.

The full list lives in the app too: menu bar → **Settings… → Shortcuts**.

Shortcuts are remappable: open the Shortcuts tab, click a shortcut, and
press a new combo. This covers every hotkey Tiled registers — the 11 slot
keys and the 6 app actions (Expand, Evict, Reset Splitters, Switch Layout,
Settings, Undo). Esc keeps the old one, ⌫ disables that action.
Disable or re-enable all eleven slot keys at once with the Enable/Disable
all button beside the Slot Keys section header (app actions disable one at
a time); your combos are parked aside and restored unchanged (re-recording
a disabled shortcut keeps the new combo and drops its park).

If two shortcuts use the same combo, the Shortcuts tab names the conflict
and keeps the old binding until you pick a free one. If a
shortcut fails to register, the menu says so. macOS does not report
another app owning a global shortcut to a non-exclusive registrant (the
key simply goes elsewhere), so Tiled can surface a dead combo but cannot
tell you which app took it.

## Tiling rules

- One window per slot.
- Tiling a window into a slot **evicts** any window occupying an overlapping
  slot. Evicted windows are restored to their pre-tile frames.
  - Two quads occupied on one side + the half key → both quads are evicted.
  - A half occupied + a quad key on that side → the half window steps aside
    into the other quad on that side when it's free; only then is it evicted.
- **Swap:** a tiled window tiling into a slot blocked by exactly one other
  tiled window swaps with it instead of evicting — unless the blocker's
  slot overlaps the target and its leftover (its slot minus the target) is
  exactly one whole slot, in which case the blocker steps aside into that
  leftover instead (see the re-house rule under Evict). Otherwise the
  blocker moves into the tile the requester vacated (which never overlaps
  the target), and both stay tiled. Focus follows the displaced window
  into the tile it landed in. (With more than one window in the way, or
  from an untiled window, the request evicts as above, and focus stays
  put.) Undo swaps back.
- Undo restores the displaced windows and returns the requester. If an
  app refuses a restore, undo reports that window instead of claiming
  success; a window that cannot be moved back keeps the slot it visibly
  holds, and the notice counts only the windows that landed.
- Tiling a window into its own tile does nothing: no restore, no reassert.
- A window re-tiling itself into an overlapping slot just moves (never evicts
  itself) and keeps its original pre-tile frame.
- **Drag a tiled window by its title bar**: past ~50pt of drag it untiles
  right where you dropped it (the drop is the placement; no pre-tile
  restore); a shorter drag snaps back into its tile. A single far jump
  with no recent hand press on the window (a programmatic move, not a
  hand drag) still snaps back, even if an unrelated click follows.
- Use the untile row in the menu (**Untile 1 Window** / **Untile N
  Windows**, titled by count) to restore every tiled window on the focused
  canvas, or open a
  tiled window's submenu to focus it, untile just that window, or tile the
  focused window into its slot. The untile row is omitted when the focused
  canvas has no tiled windows; the window list still names windows on every
  visible display.
- Each canvas tiles independently, where a canvas is one display's one
  Mission Control Space. Every Space you reach by swiping up with three
  fingers has its own layout, occupancy, splitters, undo history, and
  notices, and so does every display: the same tile can be occupied in
  several Spaces and on several displays at once. Tiling, switching,
  drag-resizing, and ⌃⌥⇧⌘Z on one canvas never disturb another; Untile
  All and Reset Splitters act on the focused canvas only. (Where the
  window server withholds a Space id, Tiled falls back to one canvas per
  display rather than guessing.)
- The menu-bar glyph follows the display under the pointer, and the
  focused-canvas rows follow the focused window's display and Space; the
  window list still groups every visible display's windows. Swiping the
  pointer's display to another Space (or moving the pointer to another
  display) redraws the glyph (2×2 or 3×2) and its occupancy for the
  canvas that just became visible, even though there was no tiling
  action. Windows parked in hidden Spaces stay tiled and keep their
  history; they simply wait off-menu until you swipe back.
- Quarters and sixths are mutually exclusive per canvas: ⌥⇧\ switches the
  layout of the display under the pointer, untiling every tiled window on
  that canvas and restoring each to its pre-tile frame. One undo returns
  the windows and the previous layout.
  A canvas keeps its layout when the board empties. A slot key never
  switches: a key with no slot in the active layout is inert and says where
  it belongs. The menu names the effect and how to undo it ("Switched to
  Sixths · 3 windows untiled. Undo from the Tiled menu.").
- A display change (unplug, rearrange, resolution) re-asserts every visible
  canvas immediately. Canvas identity follows the physical monitor's
  CoreGraphics display number, so reordering screens never moves a monitor's
  arrangement to another display. Hidden Spaces are marked stale instead:
  Tiled never writes an off-Space window, because an AX resize can pull it
  onto the visible Space. Swiping back re-asserts that Space against the new
  bounds. A display that disappears keeps its canvas: its last geometry,
  splitters, and undo history survive unplugged, and nothing is written to
  it until it returns and is re-asserted.
- Some apps refuse programmatic resizing. When that happens the window is
  left alone and the menu says which app refused, so state and screen never
  silently disagree.
- Evict, Untile All, a window's untile row, and Undo announce success only
  after the controller performed the action: an empty undo stack, an
  untiled window, or a refused restore answers with exactly one message
  describing what happened (naming the display when the action touched
  another display's canvas).

## Live resizing

Drag any edge of a tiled window and the shared grid splitter's fraction
updates as you drag; the neighbor windows on the other side — and the
dragged window's own tile — are rewritten when the mouse button is
released. The row splitters are independent per column (quarters) or per
third (sixths), so resizing one column's rows never moves the other, and
the same independence holds between monitors and Spaces, so dragging an
edge on one canvas never moves tiles on another. A two-thirds window
resizes as two equal one-thirds: the hidden splitter inside it follows
its outer edge, staying at the midpoint. A
neighbor pushed narrower (or shorter) than its app's minimum size simply
stops shrinking at that size, pinned to the screen edge it already held:
the window always stays inside the boundaries of the screen, never
sliding off it. Dragging an edge that coincides with the screen edge
itself (the top edge of a right two-thirds window, say) moves no
splitter — screen edges are fixed — and the edge snaps back to the
screen edge when you release: the drag is free while the button is
down, and the mouse-up re-assert pulls the edge home. A corner that
mixes a screen edge with a real splitter (the top-left corner of a
two-thirds window) resizes the splitter live as usual and keeps the
new splitter position; only the screen edge snaps back.
**Reset Splitters** in the menu (or ⌥⇧R) snaps the focused canvas's
splitters back to even splits. Once a reset has parked the pre-reset
positions, the same row is titled **Restore Previous Splitters** and
brings them back; that restore row stays until the backup is used, even
if Untile All empties the canvas. The plain **Reset Splitters** row needs
a tiled edge, so it is omitted when the focused canvas has no tiled
windows and no parked backup.

## Installing a release build

Download `Tiled-<version>.zip` from the
[releases page](https://github.com/edrickt/tiled/releases), move `Tiled.app`
to `/Applications`, then right-click it and choose **Open** on first launch
(the bundle is ad-hoc signed, so Gatekeeper needs that one-time override).
Grant Accessibility permission when Tiled asks and relaunch. Bundles are
universal (Apple Silicon and Intel) and target macOS 13 or later, and each
release ships a `.sha256` to verify the download:

```bash
shasum -a 256 -c Tiled-<version>.zip.sha256
```

## Building & running

Requires a recent Swift toolchain (tested with Swift 6.2).

```bash
swift build            # debug build
make check             # unit suite (940 tests) and the published count
make test              # same suite with the full transcript
make app               # release build bundled as build/Tiled.app
make app-universal     # same, fat binary for Apple Silicon + Intel
make install           # build, install to /Applications, launch
```

`make help` lists every task. The Makefile only wraps the scripts in
`scripts/`, which remain the source of truth and are what every gate runs; the
bundle version comes from `VERSION`.

### Running during development

The easiest dev loop: run the binary from your terminal and grant **Terminal**
(itself) Accessibility permission once, because TCC attributes AX requests from
subprocesses to the responsible process:

```bash
swift run
```

For the bundled app (`./scripts/make-app.sh`), grant **Tiled** Accessibility
permission in System Settings. Note: ad-hoc signing changes on every rebuild,
so macOS may ask you to re-grant the permission after rebuilds. For serious
use, sign with a stable identity (even a free Apple ID "Apple Development"
certificate) so TCC remembers the grant.

Quitting Tiled leaves your windows where they are.

## Testing

The layers, from hermetic to physical:

| Layer | Command | Needs |
|-------|---------|-------|
| Unit suite (940 tests) | `make check` | nothing; ~5s, no AX, no runloop |
| Focused tests | `swift test --filter <Suite>` | nothing |
| Full transcript | `make test` | nothing |
| Coverage report | `swift test --enable-code-coverage` then `xcrun llvm-cov report ...` | nothing |
| Live end-to-end | `./scripts/run-repro.sh` | GUI session + Accessibility permission |
| Test-quality audit | `python3 tools/mutation/mutate.py` | nothing; a few minutes for the full table (parallel workers) |

The unit suite drives the pure engine through `FakeWindowGateway`, with
clocks, schedulers, and the display set injected; only a few live-screen
identity checks touch AppKit. The live adapter (`LiveWindowGateway`) also has
a hermetic seam: `LiveGatewayWiringTests` drives its Space cache, observer
routing, destroy delivery, adoption, release pruning, focus memo, and
write-pair recovery through fakes, without a grant. Focus resolution itself,
the element registry fallback, and app-list assembly stay live-only. The
adapter is exercised end to end by `scripts/run-repro.sh`, which launches
the app plus a throwaway `host` app and drives real clicks, drags, and
global hotkeys: 40+ cases
covering the quarters family end to end (tiling, edge drags with
per-column row independence, clamping, screen edges, eviction, swap,
re-house, undo, closes) and the sixths family (the layout
switch, sixths geometry, per-third row independence, and a two-thirds
window's hidden divider). Drag-out has its own focused probes
(`tools/repro/dragout-sixth-test.swift`, `tools/repro/evict-drag-test.swift`). Handle
identity has one too (`tools/repro/handle-collision-repro.swift`): a
freshly focused same-app window sitting on a tiled window's exact frame
— the shape Firefox's tab tear-out produces — must not inherit its
handle and untile the original. Sixths boards stay disjoint in the suite: it
models the quarters eviction algebra, not a second occupancy model. The multi-display
suite checks same-slot coexistence, per-monitor moves, and splitter isolation
on two attached displays; unplug/replug, rearrange, and Mission Control
validation stays in the accompanying manual checklist. Run these before a
release; they cannot run headless (they move the real cursor and need a TCC
grant).

```
make check                              # the gate for every change
scripts/doctor.sh                       # read-only preflight for any live run
swift test --filter <Suite>             # focused inner loop
swift tools/repro/probe-spaces.swift     # what the live suites can cover here
./scripts/run-repro.sh                  # pre-release live check
./scripts/run-repro.sh tools/repro/multi-display-suite.swift  # two displays
./scripts/run-repro.sh tools/repro/driver.swift   # smaller focused driver
python3 tools/mutation/mutate.py        # verify the suite still catches bugs (a few minutes)
python3 tools/mutation/mutate.py --since HEAD~3  # only mutants whose source changed since a ref
python3 tools/mutation/mutate.py --resume       # only mutants the last run did not catch
python3 tools/mutation/mutate.py --list # show the injected-bug table
python3 tools/mutation/mutate.py --workers 2    # fewer workers on a loaded machine
```

The live suites park the host windows at fixed coordinates tuned for roughly
1512x982, so read the actual and expected frames before calling a failure a
regression and record the display size with the evidence. On a 1120x1050
single-display machine the full suite scored `PASS 37 FAIL 2` (S11a and S14b):
`HOSTC` and `HOSTD` start partly off-screen and `HOSTB`'s center sits under
`HOSTC`, so a focused case that clicks that center targets the wrong window and
an eviction restore can be clamped to the visible frame. The resize cases S2-S7
and the rest of the tiling sequence passed there.

Every live run starts through `scripts/run-repro.sh` or
`scripts/run-focus-loop.sh`, never against an instance someone else started,
and keeps its artifacts under `build/verification/<timestamp>-<feature>/` with
the `PASS`/`FAIL` lines and the command that produced them. A green unit suite
is necessary, not proof of the live adapter.

### Focused loops

Focused harnesses cover bugs whose signal is the status icon's
occupancy or the menu's rows rather than a window frame, and they must
stop any installed
`/Applications/Tiled.app` first (it owns the same global hotkeys; two
managers answering one keystroke make every case lie):

```
scripts/run-focus-loop.sh tools/repro/window-lifecycle-repro.swift  # MODE=kill-app (default)
MODE=close-window scripts/run-focus-loop.sh tools/repro/window-lifecycle-repro.swift
scripts/run-focus-loop.sh tools/repro/handle-collision-repro.swift  # identity across same-frame windows
swift tools/repro/destroy-notification-probe.swift <pid> <close|kill>
```

`window-lifecycle-repro.swift` tiles two windows (middle third, right
third) and then either closes one through AX (the reported gesture's
shape: Firefox closes the window a dragged tab left) or kills the whole
app. A closed window's slot must release inside a two-second budget
(observed releases are milliseconds) — the
adapter observes `AXUIElementDestroyed` and prunes on the spot — while a
killed process has no notifications left to send and releases on the 5s
tick plus 3s confirmation. The icon's cell count alone cannot tell a
reflowed survivor from a ghost (both light the same cells), so the suite
asserts the survivor's frame and, for a killed app, an empty icon.

`destroy-notification-probe.swift` measures that notification's latency
for any app (observed on the development machine: host app ~3ms; Firefox
~29ms), which is what makes the
event-driven release safe to promise.

`handle-collision-repro.swift` parks a second host window on a tiled
window's exact frame and tiles it: the tiled window's handle must
survive the newcomer (the menu keeps both rows, both frames stay
correct). Firefox's tab tear-out is the live gesture this models — the
detached window opens on the source window's frame — and the original
bug moved the tiled window's record to the newcomer's element, dropping
the original from the menu mid-layout.

See `tools/repro/multi-display-checklist.md` for the physical display-change
checks the suite cannot drive.

`tools/mutation` answers the question a green suite cannot ask itself:
would these tests notice if the code stopped working? Each entry in
`tools/mutation/mutants.json` is a plausible bug injected into `Sources/tiled`;
a mutant that survives is a test gap. The table runs in parallel: each worker
gets a scratch copy of `Sources`, `Tests`, and `Package.swift` (the real tree
is never touched, so uncommitted work is safe), and mutants are handed out as
workers free up. Before fanning out, the tool runs the unmutated suite once —
a red baseline aborts instead of scoring mutants. It exits non-zero on any
survivor or unresolved mutant, so it can gate a release branch. While a stage
is in flight, `--since <its base commit>` keeps the run to the mutants the
stage can affect: a source change selects that file's mutants, and a test or
`Package.swift` change puts every mutant in scope. Add `--resume` to recheck
only the mutants the last run did not catch, so adding tests to kill survivors
skips the already-caught table; the verdicts merge into
`build/mutation-results.json`. Resume trusts a prior caught verdict unless its
source file is in `--since` scope, so it is for adding tests: after changing
or deleting an existing test, run the full table so a weakened assertion
cannot hide. Run the full table before committing.
Four workers by default (`--workers N` to tune); the tool's own tests run with
`python3 tools/mutation/test_mutate.py`.

Nothing runs these gates for you: there is no CI, so `make check` before
every push and `python3 tools/mutation/mutate.py` before a release are the
gate. Both are cheap enough that a hand run is the whole cost. `docs/release.md`
has the release steps that `release.yml` used to run.

## Status / roadmap

- [x] Menu bar app (LSUIElement), Accessibility permission flow
- [x] 17 global hotkeys (11 shared slot keys + 6 app actions, all remappable, Carbon RegisterEventHotKey) + clickable menu equivalents
- [x] In-app keyboard-shortcut reference
- [x] Pure, unit-tested tiling state with eviction and layout-switch rules
- [x] Fixed-rect tiling via the Accessibility API
- [x] Live shared-edge resizing (observe native drag + compensate neighbors)
- [x] Sixths layout (3×2 grid, thirds, two-thirds)
- [x] Visible failure states (hotkey conflicts, apps refusing resize)
- [x] Display-change reassertion + automatic cleanup of closed windows
- [x] Per-Space layouts (Mission Control desktops independent per display)
- [x] Drag-out (short drag snaps back, long drag untiles in place)
- [ ] Owned overlay resize handles
- [x] Remappable shortcuts
- [ ] Gaps? (decided: no gaps for now)
