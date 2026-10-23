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

This section is the only gate policy. Specs, tickets, and reports point
here; they do not restate or add gates.
