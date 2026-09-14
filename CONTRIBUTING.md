# Contributing

Thanks for looking. This project is small, opinionated, and dense with tests;
the fastest way in is to read [CONTEXT.md](CONTEXT.md) — one word per concept,
with the words to avoid — and [docs/architecture.md](docs/architecture.md) for
the module map.

## The loop

```bash
swift test                        # the gate for every change, ~2s
swift build -c release            # release configuration must stay warning-free
./scripts/make-app.sh             # bundle check: Info.plist + codesign verify
```

Before a release, also run the layers that a machine without a GUI cannot:

```bash
./scripts/run-repro.sh                                          # 39 live cases
./scripts/run-repro.sh tools/repro/multi-display-suite.swift    # two displays
python3 tools/mutation/mutate.py                                # 44 mutants
```

The live suites move the real cursor and need Accessibility permission for
your terminal, so quit any other window manager first (including an installed
Tiled): two managers answering one keystroke make every case lie.

## What a change is expected to prove

1. **A test that fails without the change.** The unit suite drives the pure
   engine through `FakeWindowGateway` with injected clocks, schedulers, and
   display sets; almost every behavior change can be pinned there. If your
   change touches real AX behavior, add a case to `tools/repro/suite.swift`
   and say in the PR which case covers it.
2. **A mutation entry when the behavior deserves one.** `tools/mutation/mutants.json`
   is a table of plausible bugs; a behavior that no mutant can break is a
   behavior the suite is not really guarding. Add `[file, description, old, new]`
   entries for new rules, and expect `mutate.py` to exit zero.
3. **The vocabulary.** Slots, layouts, canvases, splitters, eviction, swap,
   reflow, re-house, requester: use the words from `CONTEXT.md` in code,
   comments, commit messages, and documentation. If you need a new concept,
   name it there first.

## Style

- The engine is pure and deterministic: no `Date()`, no `DispatchQueue` in
  `Layout.swift`, no AppKit in the decision path. Time and effect boundaries
  are injected.
- Prefer a named phase over a long function; `PlanExecutor` and
  `DragTracker` exist because `TilingController` was doing too much.
- Comments explain *why* a rule exists, not what the next line does. The
  audit documents in `docs/audit/` record the reasoning behind the current
  shape.
- Keep user-visible strings in `MenuText` (and the settings tabs' own
  modules) so wording is testable without a run loop.

## Commits and pull requests

Commits are imperative and specific: "Fix undo integrity, AX failure handling,
and hotkey conflicts" rather than "fixes". A pull request should say what
changed, what it is protecting against, and which commands you ran. If a
change alters window behavior, say what the screen does before and after; the
capture pipeline in `tools/capture/` (see [docs/capture.md](docs/capture.md))
can record it if a description is not enough.

## Reporting bugs

Open an issue with the macOS version, how Tiled was installed, the app whose
window misbehaved, and the shortest sequence that shows it. If the menu is
warning about a shortcut or naming an app that refused a resize, quote that
row: it is the most useful evidence the product can give you, and the bug is
usually one of "the state says X, the screen shows Y". Include both.
