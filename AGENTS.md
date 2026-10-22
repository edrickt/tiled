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

Run `swift build`, `swift test`, and `./scripts/check-test-count.sh`
after each unit. Run the full mutation table (`python3
tools/mutation/mutate.py`) once at the end, before push or hand-off,
not after every unit.
