# Developing Tiled

> Build, test, and release reference. Back to [README](../README.md). See also [release](release.md) for the release steps.

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
make check             # unit suite (1010 tests) and the published count
make test              # same suite with the full transcript
make app               # release build bundled as build/Tiled.app
make app-universal     # same, fat binary for Apple Silicon + Intel
make install           # build, install to /Applications, launch
```

`make help` lists every task. The Makefile gives one obvious spelling per task:
the script-backed targets wrap `scripts/` (which remain the source of truth
where they exist), while `build`, `release`, `test`, `run`, `clean`, and
`exhaustive` invoke Swift directly; the bundle version comes from `VERSION`.

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
| Unit suite (1004 tests) | `make check` | nothing; ~5s, no AX, no runloop |
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
window's hidden splitter). Drag-out has its own focused probes
(`tools/repro/dragout-sixth-test.swift`, `tools/repro/evict-drag-test.swift`). Handle
identity has one too (`tools/repro/handle-collision-repro.swift`): a
freshly focused same-app window sitting on a tiled window's exact frame
— the shape Firefox's tab tear-out produces — must not inherit its
handle and untile the original. Sixths boards stay disjoint in the suite: it
models the quarters eviction algebra, not a second occupancy model. The multi-display
suite checks same-slot coexistence, per-display moves, and splitter isolation
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
single-display machine the 39-case suite at v0.3.x scored `PASS 37 FAIL 2`
(S11a and S14b): `HOSTC` and `HOSTD` start partly off-screen and `HOSTB`'s
center sits under `HOSTC`, so a focused case that clicks that center targets
the wrong window and an eviction restore can be clamped to the visible frame.
The resize cases S2-S7 and the rest of the tiling sequence passed there. The
suite has since grown (mirror group S18, reflow modeling for S14b) to 42
checks at v1.0.3; re-measure on the same small display before treating that
old score as the expected result.

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

