# Coding standards

The judgement calls a reviewer enforces. Mechanical matters (builds,
warnings, the unit suite) are the tools' job.

## The glossary binds

`CONTEXT.md` is the vocabulary of record, and its `_Avoid_` lists bind in
every prose surface: CONTEXT.md itself, README, CHANGELOG, commit
messages, and new doc comments. Write "the mouse-up reasserts", not
"settles"; "display", not "monitor"; "slot", not "tile". If a concept has
no term, that's a signal: either the project speaks differently or the
glossary has a real gap.

## Behavior docs move with the behavior

A change that alters behavior updates, in the same commit:

- the README paragraph that describes the behavior,
- the `CONTEXT.md` entry, when the change touches a definition's scope,
- the `CHANGELOG.md` `[Unreleased]` section,
- any count the README publishes (`swift test` output).

Point-in-time records — release notes, `.scratch/` audit reports and arc
specs, ADRs — are frozen history: correct them with a new note, never by
rewriting the record.

## Tests read as behavior specs

A test's name states the behavior; its comments describe the actual
motion and values — a comment claiming the top edge while the code moves
the bottom is a defect even when the assertions pass. Expected values
come from outside the code under test: known-good literals, worked
examples, the spec.

## Doc comments explain why

The repo's voice: a doc comment says what the thing is for and why it is
shaped that way, naming the failure it prevents when that matters.
`DragTracker` and `TilingSpace` are the exemplars.
