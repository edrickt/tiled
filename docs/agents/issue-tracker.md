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
- Comments and conversation history append to the bottom of the file
  under a `## Comments` heading
