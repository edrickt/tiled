# Robustness & quality fixes — build arc

Audit origin: full-codebase robustness & quality audit of 2026-10-08. Full report (evidence,
`file:line` for every finding, verified-solid maps): `report.md` in this directory. This file is the
arc hub: the ticket graph, the gates, and how to run one ticket in a fresh session.

## Where this is

Batch 1 is cut as 12 tracer-bullet tickets under `issues/`, numbered in dependency order. The
tickets reference the report's finding IDs (D*, G*, Q*, L*) — read the report section before
starting a ticket. Batch 2 (report findings D6–D10, D14, D15 (needs OQ3 first), D16, D17, the Low
findings, and the mutation-guard gaps) is deliberately **not** ticketed yet: it is cut after batch 1
lands, re-checked against what batch 1 changed.

## The ticket graph

| # | Ticket | Blocked by | Findings | Status |
|---|--------|-----------|----------|--------|
| 01 | A late check only ever judges its own write | – | D3, D11, L16 | ready-for-agent |
| 02 | A layout switch's destruction stays undoable | – | D1 | ready-for-agent |
| 03 | Undo restores a tiled switch-requester to its vacated slot | 02 | D2 | ready-for-agent |
| 04 | One refused restore no longer disarms the chapter | 02 | D5 | ready-for-agent |
| 05 | Restore Previous Shortcuts restores or keeps every entry | – | D4 | ready-for-agent |
| 06 | The hide-icon confirm names a recovery that works | – | D19, L9 | ready-for-agent |
| 07 | A dead HotkeyService unregisters everything | – | D18 | ready-for-agent |
| 08 | The tested routing table routes | 07 | D20 | ready-for-agent |
| 09 | A half-applied frame write is put back | – | D12 | ready-for-agent |
| 10 | Death confirmation cannot prune a live window | 09 | D13 | ready-for-agent |
| 11 | Close the test-suite blind spots | – | G1–G5, Q2, Q3 | ready-for-agent |
| 12 | An independent matrix oracle | – | Q1 | ready-for-agent |

Edges 07→08 and 09→10 are **collision serialisation** (the pair shares files), not semantic
dependencies; every other ticket is independently grabbable. The frontier at any moment = every
ticket whose blockers are DONE.

## Gates (non-negotiable in every ticket)

- `swift build 2>&1 | grep -E "warning:|error:"` -> empty
- `swift test` -> all green
- `python3 tools/mutation/mutate.py` -> every mutant CAUGHT, none STALE

## Running one ticket in a fresh session

One ticket per context window (or per implementer subagent). Start with:

```
Read .scratch/robustness-audit/README.md, then implement
.scratch/robustness-audit/issues/NN-<slug>.md
```

Then work the ticket:

1. Read this file, the ticket, the report section the ticket's findings point to, and `CONTEXT.md`.
   Domain words: slot, canvas, eviction, swap, reflow, re-house, expand, drag-out, requester,
   expected write. Architecture words: module, interface, depth, seam, adapter, leverage, locality.
2. Build through the `tdd` skill: red test first (the ticket's acceptance criteria name the red
   tests), then the fix.
3. Gates green after every working step (see above).
4. Close with the `code-review` skill (Standards + Spec) against the ticket's base.
5. Commit on the integration branch in the repo's style (imperative subject, the why in the body,
   gate evidence at the end), then update the table above with the commit hash and status.

## Execution model

`/implement-spec`: one integration branch; implementer subagents across the ready frontier, each in
its own worktree driving `/tdd` and the gates; merger subagents land completed tickets and re-open
the frontier; one `code-review` over the integration branch at the end. Tickets are self-contained —
subagents communicate through these pointers, not through chat history.

## Out of scope (batch 2)

- Cross-canvas undo double-booking (D6), rollback-write failures (D7), blocker-untile failures (D8),
  the settle/decision seam (D9), pre-tile-frame capture (D10).
- Main-thread stall budget (D14 — needs design), `.deferredOffSpace` semantics (D15 — blocked on the
  report's OQ3 decision), restore-path deferral policy (D16), cross-display snapback (D17).
- The Low findings, the remaining fake-fidelity gaps (G7, G9, G11), and the mutation-guard gaps.
