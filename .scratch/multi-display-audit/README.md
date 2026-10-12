# Multi-display & Spaces — robustness build arc

Audit origin: multi-display & Spaces audit of 2026-10-12. Full report (evidence,
`file:line` for every finding, verified-solid map): `report.md` in this directory. This file is
the arc hub: the ticket graph, the gates, and how to run one ticket in a fresh session.

## Where this is

Batch 1 is cut as 12 tracer-bullet tickets under `issues/`, numbered in dependency order. The
tickets reference the report's finding IDs (M*, L*) — read the report section before starting a
ticket. Batch 2 (report findings M11, M13, M15, the remaining Low items, and the
live-verification checklist) is deliberately **not** ticketed yet: it is cut after batch 1 lands,
re-checked against what batch 1 changed.

Base: `master` @ `690d680`. Note `master` predates the unmerged `robustness-audit` branch; when
that merges, re-check family 3 (the write policy) against the `WriteExpectations` shape.

## The ticket graph

| # | Ticket | Blocked by | Findings | Status |
|---|--------|-----------|----------|--------|
| 01 | One canvas per window | – | M1 | ready-for-agent |
| 02 | A record dies with its tiling | 01 | M6, L2 | ready-for-agent |
| 03 | Death confirmation excludes sleep | – | M2 (clock) | ready-for-agent |
| 04 | A moved listed frame is alive | 03 | M2 (frame) | ready-for-agent |
| 05 | One deferred-off-Space contract | – | M9 | needs-decision |
| 06 | A deferred request is retained | 05 | M10, M12 | ready-for-agent |
| 07 | Unknown Space is not an app refusal | 05 | M3 | ready-for-agent |
| 08 | The restore goes through the write policy | – | M4 | ready-for-agent |
| 09 | Visibility requires an attached display | – | M7 | ready-for-agent |
| 10 | An absent display keeps its frame | 09 | M8, L5 | ready-for-agent |
| 11 | Menu sections key on the display | – | M14, M16 | ready-for-agent |
| 12 | One canvas key per icon pass | – | L12 | ready-for-agent |

Edges 01→02 and 03→04 are **collision serialisation** (each pair shares files), not semantic
dependencies; 05→06 and 05→07 are semantic (ticket 05 decides the contract the other two encode),
and 09→10 is semantic (the visibility guard before the frame rule). Every other ticket is
independently grabbable. The frontier = every ticket whose blockers are DONE.

**Ticket 05 needs the owner's call** before 06/07 can run: it settles whether a deferred
off-Space write rolls back or stands-and-reconciles. The audit recommends stand-and-reconcile
(the reflow contract); the ticket states the recommendation and rationale. Settle it (accept or
override) before dispatching the write-policy family.

## Gates (non-negotiable in every ticket)

- `swift build 2>&1 | grep -E "warning:|error:"` -> empty
- `swift test` -> all green
- `python3 tools/mutation/mutate.py` -> every mutant CAUGHT, none STALE

## Running one ticket in a fresh session

One ticket per context window (or per implementer subagent). Start with:

```
Read .scratch/multi-display-audit/README.md, then implement
.scratch/multi-display-audit/issues/NN-<slug>.md
```

Then work the ticket:

1. Read this file, the ticket, the report section the ticket's findings point to, and `CONTEXT.md`.
   Domain words: canvas / tiling space, slot, Space, visible frame, reassert, eviction, reflow,
   re-house, expand, requester.
2. Build through the `tdd` skill: red test first (the ticket's acceptance criteria name the red
   tests), then the fix.
3. Gates green after every working step (see above).
4. Close with the `code-review` skill (Standards + Spec) against the ticket's base.
5. Commit on the integration branch in the repo's style (imperative subject, the why in the body,
   gate evidence at the end), then update the table above and the ticket's Status.

## Execution model

`/implement-spec`: one integration branch; implementer subagents across the ready frontier, each
in its own worktree driving `/tdd` and the gates; merger subagents land completed tickets and
re-open the frontier; one `code-review` over the integration branch at the end. Tickets are
self-contained — subagents communicate through these pointers, not through chat history.

## Out of scope (batch 2)

- M11 — undo's `applyLayout` hard-codes `check: .none`, so an ignored undo retile is never
  rolled back (`TilingSpace.swift:346-357,765-766`).
- M13 — off-Space is a single point-in-time probe over a multi-second write
  (`FrameWriter.swift:76`; `LiveWindowGateway.swift:51,884-922`). Needs live verification first.
- M15 — a display-parameters change mid-drag cancels a drag-out
  (`TilingController.swift:212-222`; `DragTracker.swift:212-217,414-417`).
- Low findings L1, L3, L4, L6, L7, L8, L10, L11 (see the report's Low table).

## Needs live verification (run these before or alongside batch 1)

Nothing in the audit was live-verified. These items change behaviour claims and are the human's
to run: M2 (lid sleep/wake with a rescaled layout), M3/M13 (whether `currentSpaces()` returns
empty transiently, and whether a write overlaps a swipe), M7/M9 (whether a nil-Space canvas and a
removed display actually coincide), M4/M16 (whether a hidden-canvas eviction and a
withheld→identified transition are production-reachable).
