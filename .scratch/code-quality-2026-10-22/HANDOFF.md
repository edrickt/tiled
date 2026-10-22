# Handoff: code-quality audit and next arc

State: `master` @ `f7bf4a4`. Build clean, 845 tests (1 skipped),
README count matches, mutation table 143/143 caught. No PR. The audit
and the first remediation batch are committed. Nothing depends on the
prior chat.

## Start here

1. Read `AGENTS.md`, `CONTEXT.md`, and `CODING_STANDARDS.md`.
2. Read `report.md` and `README.md` in this directory.
3. Pick a ticket from `issues/`. Ticket 01 is the recommendation.

## Recommended next: ticket 01

`issues/01-expected-write-transaction.md` is the expected-write
transaction and failure list. It deletes the five hand-rolled rollback
bodies and the single-refusal precedence rule, and it closes the
F21/F22 class at the root. It is M/L. Design the `MoveAttempt` shape
before editing, then land it in slices with the existing second-refusal
and swap tests as the pin. `slices/01-engine.md` findings 1 and 2 carry
the evidence.

Runner-up: `issues/05-input-seams.md`. Smaller, and F23 is a real edge
bug while F28 and F29 are testability gaps. Ticket 02 needs the
glossary conversation the prior audit called for. Ticket 03 is the
largest and mostly reader-load. Ticket 04 needs a product call on the
reset/restore button.

## Fresh-session prompt

Copy this into the new session:

> Read `AGENTS.md`, `CONTEXT.md`, `CODING_STANDARDS.md`, and
> `.scratch/code-quality-2026-10-22/{report.md,README.md,issues/01-expected-write-transaction.md}`.
> Implement ticket 01 as a refactoring. Pin the current behavior first,
> then land the `MoveAttempt` and the action-scoped failure list in
> small commits. Run every gate in the audit hub after each unit. Do not
> use the prior transcript; the committed docs are the record.

## Gates

- `swift build 2>&1 | grep -E "warning:|error:"` -> empty
- `swift test` -> all green
- `./scripts/check-test-count.sh` -> README's count matches
- `python3 tools/mutation/mutate.py` -> every mutant caught, none stale
  (use `--resume` only after adding tests; a changed source anchor needs
  retargeting)

## Verification gap

The fix batch is hermetic only. `make repro` has not been run against
live windows. If a quiet desktop and an Accessibility grant are
available, run it once before calling the focus, drag, and splitter
changes fully trusted. Otherwise record the limit in the report.
