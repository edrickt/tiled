---
name: undo-exhaustive
description: Exhaustively check Tiled's undo promise over every board reachable with three windows. Use when a change touches TilingState.plan/commit, TilingSpace's apply/execute/settle/undo chapters, TilingController's handle/undo/restore path, eviction, swap, re-house, reflow, or layout switching.
---

# Exhaustive undo check

## What it proves

For every board reachable with three windows in any slot on one visible
canvas, one undo applies the pushed chapter exactly, and nothing else:

- every snapshot entry returns to its recorded slot;
- a requester with a snapshot entry returns to that slot;
- a requester without an entry is restored to its pre-tile frame when the
  chapter names it (a layout switch, or a fresh eviction), and is left where
  the request put it when the chapter does not (a move whose only
  displacement is a reflow);
- no other window moves.

It also checks that every reachable board is structurally healthy: no cell
owned by two windows, one layout per canvas, and no window in two slots.

The harm if this breaks: Undo restores the wrong window to the wrong slot,
moves a window nobody displaced, leaves a snapshot entry floating, or
double-books a cell. The user has to rebuild the layout by hand.

## Why the requester can stay put

"One undo returns the prior board" is stronger than the app promises, and
using it turns intended behavior into false findings. Two tests pin the
semantics:

- `Tests/tiledTests/TilingSpaceTests.swift::testSwitchSnapshotsEvictedAndNotices`
  asserts a switch chapter holds only the evicted windows; the requester is
  carried separately and is restored to its pre-tile frame.
- `Tests/tiledTests/TilingSpaceTests.swift::testMoveReflowsVacatedCellsToTheNeighbour`
  asserts "the move's requester is excluded from the chapter; only the
  survivor moves" when a tiled window moves to a free slot and a neighbor
  reflows.

The README's promise is about displaced windows and the reflow they cause,
not about undoing the requester's own move. Do not "fix" the requester
behavior without an explicit product decision and updates to those tests.

## Tool and why

A Swift XCTest that drives the real `TilingController` and `TilingSpace`
through `FakeWindowGateway`. The placement rules are not reimplemented: the
search asks the canvas's own `plan`, applies through `handle(slot:)`, reads
the pushed chapter, and undoes through `undoLastDisplacement()`.

No Swift model checker is in this repo. The state space is finite and small
(652 boards, 31,683 transitions, 24,402 undo checks), so exhaustive
breadth-first search over the real code is stronger than example tests and
needs no new toolchain. TLA+ was not used because it would verify a second
model of the rules, not the Swift code that ships.

## Scope and bounds

- Three windows, all 17 slots, one visible 1600x1200 canvas, one display and
  one Space.
- Breadth-first search to a fixpoint over occupancy; no step-depth cap.
- `FakeWindowGateway` accepts every write; no refusal, death, or deferral.
- Not covered: four or more windows, multiple displays or Spaces, refused or
  deferred writes, Expand, drag-out, splitter changes, window death, live AX,
  menu receipts. Use `.opencode/skills/verify/` for the live adapter.

## Run

From the repo root:

```sh
TILED_EXHAUSTIVE=1 swift test --filter ExhaustiveUndoTests/testEveryReachableBoardUndoesItsLastDisplacement
```

It takes about 7 seconds. Plain `swift test` skips it through the environment
gate, so the hermetic suite stays at 833 tests and `make check-counts` agrees.
The check prints:

```text
DONE states=652 edges=31683 undoChecks=24402 signatures=0 elapsed=...
```

Exit 0 and `signatures=0` mean the promise holds in scope. A non-zero exit
prints one counterexample per distinct signature.

## Current result

Confirmed on 2026-10-22 at commit
`a556fd8385eef5891ea7ad28280d884f211fbc56`: `signatures=0` over 652 boards,
31,683 transitions, and 24,402 undo checks. The structural-health assertion
is self-tested at the start of the run by feeding it a double-booked board.

An earlier version of this check asserted full prior-board equality and
produced three apparent counterexamples around the requester. Investigation
showed all three were the intended behavior described above, pinned by the
two tests; the check was corrected, not the app.

## Reading a failure

The failure lists one example per signature:

```text
<signature>: <count> checks
  replay   win0 -> topLeft, win1 -> bottomLeft, win0 -> topRight
  chapter  [win0:topLeft] requester=win1
  expected [topLeft: 0, bottomLeft: 1]
  undone   [topRight: 0, bottomLeft: 1]
```

- `chapter` is what the action pushed; `expected` is that chapter applied to
  the post-action board, plus the named requester's pre-tile restore.
- An occupancy difference is a broken chapter: report the replay in the
  code's words.
- A frames-only difference points at a write or echo issue, not at the
  chapter's occupancy.
- A signature not explained by the intended requester semantics is a new
  finding. Report it with the replay; do not bless it as expected output.

## Coverage record

- `Sources/tiled/Layout.swift`: `Slot`, `TilePlan`, `TilingState.plan`,
  `TilingState.commit`, `remove`, `rehousingHome`, `reflow`.
- `Sources/tiled/TilingSpace.swift`: `apply`, `execute`, `applyTile`,
  `applySwap`, `applySwitchLayout`, `settle`, `pushUndo`, `restoreEvictees`,
  `restore`.
- `Sources/tiled/TilingController.swift`: `handle(slot:)`,
  `undoLastDisplacement`, `undoAction`, `restoreChapter`, `blockers`.
- `Tests/tiledTests/FakeWindowGateway.swift`: the fake gateway.
- Test: `Tests/tiledTests/ExhaustiveUndoTests.swift`.
- Confirmed against commit `a556fd8385eef5891ea7ad28280d884f211fbc56`.
- Move the sync commit forward only after rerunning the check and confirming
  the covered code still matches. If the code changed intentionally, update
  the search or the documented promise first, not the assertion.

## When to update

- Any change to a covered file: rerun. A new counterexample is a finding.
- A new plan kind, action, or canvas model: extend the edge generator, state
  the new bound, and keep the same property.
- An intentional change to undo semantics, including the requester rules:
  update the two pinning tests, the README promise, and this check together,
  and say so in the report.
