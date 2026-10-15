# Issue tracker: Local Markdown

Issues and specs for this repo live as markdown files in `.scratch/`.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The spec is `.scratch/<feature-slug>/README.md`: the single source of
  truth for that feature's design, decisions, and stage map
- Implementation issues are one file per ticket at
  `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`,
  never a single combined tickets file
- Issue files open with `# <NN>: <title>`, then `**What to build:**`,
  `**Blocked by:**` (when blocked), `**Findings:**` (pointers to the
  audit or report that raised it), a `**Status:**` line (`TODO`,
  `DONE (<sha>)`, `PARKED`, …), and the acceptance checklist
- Triage roles are recorded in the same `**Status:**` vocabulary when
  `/triage` runs (see `triage-labels.md` for the role strings)
- Comments and conversation history append to the bottom of the file
  under a `## Comments` heading

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/` (creating the
directory if needed).

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the
path or the issue number directly.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a file with one **child** file per
ticket.

- **Map**: `.scratch/<effort>/map.md` (the Notes / Decisions-so-far /
  Fog body).
- **Child ticket**: `.scratch/<effort>/issues/NN-<slug>.md`, numbered
  from `01`, with the question in the body. A `Type:` line records the
  ticket type (`research`/`prototype`/`grilling`/`task`); a `Status:`
  line records `claimed`/`resolved`.
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is
  unblocked when every file it lists is `resolved`.
- **Frontier**: scan `.scratch/<effort>/issues/` for files that are
  open, unblocked, and unclaimed; first by number wins.
- **Claim**: set `Status: claimed` and save before any work.
- **Resolve**: append the answer under an `## Answer` heading, set
  `Status: resolved`, then append a context pointer (gist + link) to
  the map's Decisions-so-far in `map.md`.
