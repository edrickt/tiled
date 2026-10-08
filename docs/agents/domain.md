# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — this repo's domain glossary (the repo's name for the skills' `GLOSSARY.md`). It defines the tiling concepts: canvas (`TilingSpace`), slot, layout, space, splitter, eviction, swap, reflow, re-house, expand, drag-out, requester, window handle, plan execution.
- **`docs/adr/`**: read ADRs that touch the area you're about to work in. (None yet — `/domain-modeling` creates them lazily when a decision actually gets recorded.)

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

Single-context repo:

```
/
├── CONTEXT.md          ← domain glossary (this repo's GLOSSARY.md)
├── docs/
│   ├── adr/            ← created lazily on the first recorded decision
│   └── agents/         ← this configuration
├── Sources/tiled/      ← app sources
└── Tests/tiledTests/   ← test suite
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md` — canvas, slot, eviction, reflow, re-house, and so on. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (…), but worth reopening because…_
