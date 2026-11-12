# Agent notes

## Agent skills

### Issue tracker

Issues and specs are local markdown under `.scratch/` (a feature's spec
is its `README.md`; tickets are `issues/NN-slug.md`). See
`docs/agents/issue-tracker.md`.

### Domain docs

`CONTEXT.md` is the glossary; ADRs under `docs/adr/`. Read both before
exploring an area. Name concepts with the glossary's positive terms —
the `_Avoid_` lists bind. If an output contradicts an ADR, surface it
explicitly; if a concept has no term, the project either speaks
differently or the glossary has a real gap.

### Validation runs

Run `swift build` and `make check` after each unit. `make check` runs the
suite once through `scripts/test.sh` and prints only failures and the
summary. Inside a unit, run `swift test --filter <Suite>`; do not put a
full suite transcript in context.

Run the full mutation table (`python3 tools/mutation/mutate.py`) once at
the end, before push or hand-off, not after every unit. `--since <base>`
scopes a mid-stage run to the sources that stage changed.

Before hand-off, run `make exhaustive` (the exhaustive undo replay; the
hermetic cycle does not set `TILED_EXHAUSTIVE`).

This section is the only gate policy. Specs, tickets, and reports point
here; they do not restate or add gates.

## Codebase navigation

The file router is `docs/agents/codebase-map.md`: read it before the first
broad search (`ls`, tree-wide `grep`/`glob`, or reading whole directories).
It is verified against the working tree and lists per-file purposes, entry
points, test suites, and the directories not worth reading.

Top-level layout: `Sources/tiled/` holds the 42 flat Swift sources;
`Tests/tiledTests/` holds the hermetic suites; `Makefile` plus `scripts/`
are the commands; `docs/` holds the guides and ADRs.

Most changes start at one of: `Sources/tiled/TilingController.swift`
(action routing), `Sources/tiled/TilingSpace.swift` (canvas and placement
pipeline), `Sources/tiled/LiveWindowGateway.swift` (AX adapter),
`Sources/tiled/MenuModel.swift` (menu structure),
`Sources/tiled/SettingsShortcutsTab.swift` (shortcut editor).

Do not read generated or historical directories (`build/`, `.build/`,
`docs/release-notes/`, `docs/superpowers/`, `.scratch/`, `.audit/`,
`usage`); the map's Don't read section gives the reason for each.

Domain docs are worth reading per concept, not front to back: `CONTEXT.md`
before naming a concept, and the one relevant `docs/adr/*.md` before
changing the area it covers.
