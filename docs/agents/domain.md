# Domain Docs

How the engineering skills consume this repo's domain documentation when
exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root: this repo's glossary (the file the
  skills call `GLOSSARY.md`). Every entry carries `_Avoid_` terms.
- **`docs/adr/`**: read the ADRs that touch the area you're about to
  work in.

## Use the glossary's vocabulary

When your output names a domain concept (an issue title, a test name, a
refactor proposal), use the term as defined in `CONTEXT.md`, and keep to
the positive terms: the `_Avoid_` lists bind, they are not advisory.
"Settle" is not a synonym for "reassert"; "monitor" is not "display";
"tile" is not "slot".

If the concept you need isn't in the glossary, that's a signal: either
you're inventing language the project doesn't use (reconsider) or
there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather
than silently overriding:

> _Contradicts ADR-0002 (the canvas owns the visible frame), but worth
> reopening because…_
