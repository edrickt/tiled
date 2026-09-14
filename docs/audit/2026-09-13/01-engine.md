# Pure engine (geometry, tiling algebra, drag) — audit findings

## Summary
Read-only static review of `Sources/tiled/Layout.swift` (geometry + `TilingState` algebra), the pure decision parts of `Sources/tiled/PlanExecutor.swift`, and `Sources/tiled/DragTracker.swift`, cross-checked against `CONTEXT.md`, `README.md` and the unit suite. Geometry (cell→rect, per-column/per-third row independence, clamps, ordering guards, two-thirds midpoint) and the drag decision logic match their stated rules; the two material defects are both in the **undo** path, where `PlanExecutor.undo` commits slots directly and therefore bypasses the plan-level overlap and layout rules (F1: cell double-booking, F2: two layouts on one canvas). F3 is a rule-vs-code disagreement about the free region `rehousingHome` uses.

Note on method: everything below is static reading; I ran no build/test/git command, so line numbers are from the files as they are on disk now.

## Rule-by-rule verification table

### (a) Geometry — `Layout.swift`

| Rule (CONTEXT/README) | Code | Verdict |
|---|---|---|
| One declaration per slot's geometry; cells, overlap and rect all derive from it | `Layout.swift:48-63` (`SlotGeometry`), `:77-97` (spans), `:113-121` (`cells`), `:123-125` (`overlaps`), `:413-424` (`rect`) | MATCH |
| Quarters: 2×2 quads + full-height halves | `Layout.swift:78-83`, `:242-249`, `:255-266`; `GridLayoutTests.testDefaultQuads/Halves`, `testQuadsPartitionTheirHalf` | MATCH |
| Sixths: 3×2 corners + thirds + two-thirds; refinement line 2 rides the 2/3 divider | `Layout.swift:84-96`, `:242-249`; `testSixthsRects`, `testSixthsThirdsPartitionTheScreen`, `testBoundariesSplitBothLayouts` | MATCH |
| Adjacent tiles tile exactly (no gap/overlap): shared edge is one expression | `Layout.swift:413-424` × `verticalLinePosition:387-395` / `horizontalLinePosition:399-409` — both neighbours read `bounds.minX + fraction * bounds.width` | MATCH in our arithmetic; pixel-level caveat → F7 |
| Per-column (quarters) and per-third (sixths) row independence; halves/thirds/two-thirds ignore row splitters | `Layout.swift:255-266`, `:399-409`; `testDraggingLeftColumnRowEdgeLeavesRightColumnUntouched`, `testDragSixthsMiddleRowEdgeLeavesOtherColumnsUntouched`, `testHalvesIgnoreRowSplits`, sweep `testEachLayoutsPartitionTilesItsBoundsExactly` | MATCH |
| Clamps: columns 0.15–0.85, rows 0.2–0.8, sixths columns 0.1–0.9; refuse degenerate bounds / non-finite positions | `Layout.swift:232-234`, `:315-322`, `:341-352`; `testClampRangesAreTheDocumentedLiterals`, `testUpdateRefusesDegenerateBoundsAndNonFinitePositions` | MATCH |
| Ordering guard: the two sixths column splitters cannot cross | `Layout.swift:184-197`, `:345-351`; `testSixthsDividersCannotCross` | MATCH |
| Two-thirds window keeps its hidden divider at the midpoint, for its own edge **and** the adjacent third's facing edge | `Layout.swift:363-385`, `:328-338`; `DragTracker.swift:501-530`; `testResizingLeftTwoThirdsCentersItsHiddenThirdDivider`, `testResizingTheAdjacentThirdAlsoCentersTheTwoThirdsHiddenDivider` | MATCH (except an expanded two-thirds — see residual) |
| Write dead-zone (0.001) and "did it change" return | `Layout.swift:354-361`; `testUpdateDeadZone`, `testUpdateAtAndBeyondClampBounds` | MATCH (intended) |
| Derived inner divider is exempt from its own clamp | `Layout.swift:370-385`; `testTwoThirdsResizeClampsTheDraggedEdgeButNotTheDerivedDivider` (asserts 0.05) | MATCH as documented; Low note: a later independent drag of that divider snaps to 0.1 (1.5–5 % of width) |
| No integralization/rounding of tile rects | `Layout.swift:413-424` → `TilingController.swift:606-639` → `LiveWindowGateway.swift:755+` (no `rounded`/`integral` anywhere) | RISK → F7 |

### (b) Tiling algebra — `TilingState` / `PlanExecutor` decisions

| Rule | Code | Verdict |
|---|---|---|
| One window per tile; no cell double-booked | `Layout.swift:499-519`; BFS `TilingStateTests.swift:646-696`, `LayoutSwitchTests.assertHealthy:92-116`, `MatrixCrossCheckTests.assertHealthy:82-90` | MATCH for the plan/commit protocol; **MISMATCH via undo → F1** |
| A tiling request evicts every overlapping window other than the requester | `Layout.swift:504-513`; `testHalfOverTwoQuadsEvictsBoth`, `testQuadOverOccupiedHalfEvictsHalf*` | MATCH |
| Swap: exactly one blocker + tiled requester + vacated tile disjoint from target; otherwise eviction | `Layout.swift:515-518`; `PlanExecutor.swift:207-223` (degenerate → eviction) | MATCH |
| Layout switch: requester moves, every other tiled window restored, no reflow | `Layout.swift:501-502`; `PlanExecutor.swift:153-196`; `MatrixCrossCheckTests.swift:36-40` | MATCH for requests; **MISMATCH via undo → F2** |
| Same-slot request is a strict no-op | `Layout.swift:500`; `PlanExecutor.swift:131-133` | MATCH |
| Requester never evicts itself; a self-move keeps its original pre-tile frame | `Layout.swift:504-506`, `PlanExecutor.swift:517-527` | MATCH |
| Reflow: exact-or-empty whole-slot union, occupied cells block, one merge per pass, requester/expanded excluded, rightmost → larger → declaration order, an unmergeable hole stays empty | `Layout.swift:589-640` (`freed.subtract` at `:595`, `.max` tie-break at `:615-640`), skip set `TilingController.swift:1363-1371` | MATCH (verified `freed ⊆ grown.cells` always, so the retry loop cannot merge twice) |
| Re-house: exactly one whole free slot, evictee must overlap the target, else untile | `Layout.swift:550-558`; `PlanExecutor.swift:315-320`, `:341-355` | **MISMATCH → F3** |
| One undo chapter per event *and* its reflow together | `TilingController.swift:459-467` (call context) | MATCH |
| Undo: evictees return to their slots, requester to its pre-tile frame, chapter consumed, depth 5 | `PlanExecutor.swift:387-445`; `TilingController.swift:1001-1086` | **MISMATCH → F1, F2** |
| A move to a free tile reflows the vacated cells; the reflow's undo does not move the requester | `PlanExecutor.swift:363-367`; `ReflowTests:385-428` | MATCH |
| Eviction notice names the displaced app(s) | `PlanExecutor.swift:369-381`, `:482-503` | **MISMATCH → F4** |
| `activeLayout` = the layout on screen | `Layout.swift:490-492` | MATCH while occupancy is single-layout; arbitrary otherwise → F2 |

### (c) DragTracker

| Rule (README) | Code | Verdict |
|---|---|---|
| ~100 pt untile distance | `DragTracker.swift:122`, `:437` (`distance > untileDragDistance`) | MATCH |
| A single far jump always snaps back | `DragTracker.swift:437-438` (`drag.ticks >= 2`); `DragTrackerTests.testSingleFarJumpSnapsBackInsteadOfUntiling` | MATCH |
| Snap-back = the tile's rect (bounds from the last frame's screen); drag-out = leave the drop, no pre-tile restore | `DragTracker.swift:439-441`, `:299-305`; `TilingController.swift:1524-1536` | MATCH |
| Per-edge direction mapping + neighbour compensation (incl. corner drags moving two boundaries) | `DragTracker.swift:456-497`; `Layout.swift:274-282`; `testCornerDragMovesTwoBoundariesInOneChange` | MATCH |
| Neighbours resize when the button is released | `DragTracker.swift:490-497` (defer), `:532-542` (`mouseLifted`); `testResizeDefersNeighborPushUntilMouseUp` | MATCH with a trailing-tick exception → F6 |
| Expanded window interaction | `DragTracker.swift:310-311` + `TilingController.swift:1500-1505` (`trackedSlot` nil for expanded) → no splitter move, no drag-out | MATCH as designed; README silent → F5 |
| Echo suppression: 32 pt radius, escape on increasing distance, 3 s stale, 1 s settle, 1 pt no-op, conservative convergence verdict | `DragTracker.swift:103-135`, `:210-245`, `:309-404`, `:574-608` | MATCH |
| Drag end = 0.5 s of move silence; a mid-drag pause ends it early | `DragTracker.swift:124`, `:405-422` | MATCH (documented) |

## Findings

### F1 — Undo restores a window into a slot that is now *overlapped* by others, double-booking cells [High | Confidence High | code-defect]
- Location: `PlanExecutor.swift:421` (pure commit), `Layout.swift:526-531` (`commit`), guard at `TilingController.swift:1017-1023`
- Evidence — the undo path commits slots directly, and the only protection matches the slot *identity*:
```swift
// PlanExecutor.undo (PlanExecutor.swift:421)
state.commit(window: id, into: entry.slot)
// TilingController.swift:1019-1021  (call context)
if let current = spaceState(for: destination).occupant(of: evicted.slot),
   let record = records[current], record.handle != evicted.handle
{ untile(window: current, reflowing: false) }
```
```swift
// Layout.swift:526-531 — commit only clears the *moving window's* own slots
mutating func commit(window: WindowID, into slot: Slot) {
    for s in Slot.allCases where occupantBySlot[s] == window { occupantBySlot[s] = nil }
    occupantBySlot[slot] = window
}
```
- Trigger (quarters, one canvas, all via hotkeys): (1) A → ⌥⇧⌘U (`topLeft`); (2) focus B (untiled) → ⌥⇧⌘U → `plan` = `.tile(evicting: [A])`, chapter `[A → topLeft]`; (3) B → ⌥⇧⌘J (`leftHalf`) — a self-move, `plan` = `.tile(evicting: [])`, which pushes **no** chapter (`PlanExecutor.swift:369` requires `!evicted.isEmpty`), so the A-chapter is still on top; (4) ⌃⌥⇧⌘Z. `occupant(of: .topLeft)` is nil (B is at `leftHalf`), so nothing is untiled, and `undo` commits A into `topLeft` while B holds `leftHalf`. Final state `{topLeft: A, leftHalf: B}`: `topLeft.cells ⊂ leftHalf.cells` — cells `col0Top/col1Top` are double-booked. (Equivalent A/B/C variant: A `leftHalf`, B evicts A into `topLeft`, C tiles the free `bottomLeft`, undo → A's half covers both quads.)
- Impact: the invariant the repo's own tests assert (`LayoutSwitchTests.swift:108-116`, `MatrixCrossCheckTests.swift:86-90`: "no cell double-booked", "one window per tile") is violated at runtime: the restored window's frame covers the other tiled windows, two/three slots are reported occupied for one area, the status icon lights overlapping cells, and the next request evicts windows the user cannot see. Also reachable when a reflow-grown survivor covers a chapter's slot (survivor at `sixthLeft`, chapter entry `sixthBottomLeft`).
- Fix: make the undo path honour the same overlap rule as `plan` — displace every occupant whose slot overlaps the restored one (e.g. `spaceState(for: destination).occupants.first { $0.key.overlaps(evicted.slot) }`), or give `TilingState` a commit variant that clears overlapping occupants so no caller can create a double-booking.

### F2 — Undoing a layout switch after new tiling in the new layout leaves two layouts on one canvas [High | Confidence Medium | code-defect]
- Location: `PlanExecutor.swift:184-188` (chapter/notice), `PlanExecutor.swift:421` (restore), `Layout.swift:490-492` (`activeLayout`), `Layout.swift:501-502`
- Evidence — the switch chapter records the *old* layout's slots, and undo replays them with no layout reconciliation anywhere:
```swift
// Layout.swift:490-492 — the canvas layout is derived, not stored
var activeLayout: LayoutKind { occupantBySlot.keys.first.map(\.layout) ?? .sixths }
// Layout.swift:501-502 — and it steers every later request
if !occupantBySlot.isEmpty, slot.layout != activeLayout {
    return .switchLayout(evicting: tiledWindows.sorted())
}
```
- Trigger: (1) A tiled `topLeft` (quarters). (2) focus B (untiled) → ⌥⇧U (`sixthTopLeft`): `plan` = `.switchLayout(evicting: [A])`, notice "Switched to Sixths · 1 window untiled. Press ⌃⌥⇧⌘Z to undo." (3) C → ⌥⇧. (`sixthBottomRight`) — a plain `.tile(evicting: [])`, no eviction so no chapter is pushed (`TilingController.swift:541`), leaving the switch chapter on top. (4) ⌃⌥⇧⌘Z: requester B is untiled, A is committed back into `topLeft` — while C stays tiled at `sixthBottomRight`. Final state `{topLeft: A (quarters), sixthBottomRight: C (sixths)}`.
- Impact: "Quarters and sixths are mutually exclusive per canvas" (`README.md:131`) is broken persistently, and `activeLayout` is now `occupantBySlot.keys.first` — Dictionary key order, not a documented choice — so the glyph (`AppDelegate.swift:198-201` → `StatusIcon.snapshot`) and the menu pick one layout arbitrarily while a window of the other stays tiled. The next cross-layout request then mass-untiles the stray window (`.switchLayout(evicting: tiledWindows.sorted())`), i.e. a hotkey in the layout the user believes is active silently destroys the other layout's arrangement. `LayoutSwitchTests.assertHealthy:100-102` (`layouts.count <= 1`) is exactly the invariant this breaks — it is only asserted for plan/commit sequences, never across undo. (Its neighbouring `activeLayout` assertion at `:103-106` is tautological with the implementation, so it cannot catch this.)
- Fix: record the restored layout in the chapter (the entries' `slot.layout` already implies it) and have `undoLastDisplacement` re-establish it — untiling the destination canvas's other-layout occupants the same way a switch does — or refuse the undo when the canvas has since moved to the other layout.

### F3 — `rehousingHome` ignores the cells the requester vacates, so a lone evictee untiles although one whole slot is free [Medium | Confidence Medium | code-defect]
- Location: `Layout.swift:550-558` (occupied loop at `:552-554`), comment `Layout.swift:539-540`; caller `PlanExecutor.swift:315-320`; README `:64-66`
- Evidence — the comment promises the post-request region, the code computes the pre-request one (the requester is still holding its old slot when this runs, `PlanExecutor.swift:308` `previous` is captured but not passed):
```swift
// Layout.swift:540 "once the requester takes `target`, the cells left free form a region"
guard let current = slot(of: evictee), current.overlaps(target) else { return nil }
var occupied = target.cells
for (slot, window) in occupantBySlot where window != evictee {
    occupied.formUnion(slot.cells)     // requester's *current* slot counted as occupied
}
let free = Set(TileCell.allCases).subtracting(occupied)
```
- Trigger (sixths): R tiled `sixthsLeftTwoThirds` (⌥⇧H), V tiled `sixthRight` (⌥⇧L); focus R, press ⌥⇧; (`sixthsRightTwoThirds`). `plan` → `.tile(evicting: [V])` (previous `L2` overlaps the target, so no swap), single blocker so re-house is consulted: `occupied = R2.cells ∪ L2.cells = all 8 cells` → `free = ∅` → `nil`. V is therefore restored to its pre-tile frame. After the request the truly free cells are `L2 \ R2 = {col0Top, col0Bottom}` = exactly `sixthLeft`, one whole slot, so per `README.md:64-66` ("When a tiling request evicts a window and leaves exactly one whole slot free, the victim re-tiles into that slot instead") V should have stayed tiled in the left third.
- Impact: on this branch the documented re-house grace silently doesn't happen — the window leaves the layout back to its pre-tile frame and the left third stays empty, and the notice says "went back to where it was" instead of naming its new tile. The disagreement is structural: `reflow` *does* treat the requester's vacated cells as freed (`PlanExecutor.swift:363-366` adds `previous.cells`; `Layout.swift:595` then subtracts only still-occupied cells), so two answers to the same question ("where do the freed cells go?") use different free regions.
- Fix: pass the requester (or its vacated slot) into `rehousingHome(evicting:for:requester:)` and exclude that slot from `occupied`, then re-add `target.cells` — the same free region `reflow` already computes. Add a test with a *tiled* requester whose old slot is not covered by the target (the existing `testEvicteeReHousesWhenTheRequesterAbsorbsItsOtherCells` only covers the case where the target swallows the requester's old cells, so it cannot catch this).

### F4 — The eviction notice ignores the evicted count whenever it has one or two names [Low | Confidence Medium | code-defect]
- Location: `PlanExecutor.swift:482-503`, called at `:379` with `count: evicted.count`
- Evidence:
```swift
switch names.count {
case 0: head = count == 1 ? "1 window went back to where it was."
                          : "\(count) windows went back to where they were."
case 1: head = "\(names[0]) went back to where it was."     // count unused
case 2: head = "\(names[0]) and \(names[1]) went back to where they were."
```
- Trigger: an eviction of N > names.count windows where at least one handle resolves no app name — `appName` is nil when the gateway can't name the app (`LiveWindowGateway.swift:563-567` → `NSRunningApplication(processIdentifier:)?.localizedName`, or `FakeWindowGateway.addWindow(frame:appName: nil)`). Two evictees, one named → the menu says "Safari went back to where it was." although two windows were untiled.
- Impact: the notice under-reports the destruction it just narrated (the `Undo` row's count at `TilingController.swift:87` stays correct), which is the exact confusion the function's own doc comment (`PlanExecutor.swift:476-481`) tries to avoid for the all-unnamed case.
- Fix: branch on `count`, not `names.count` (`case 1: count > 1 ? "\(names[0]) and \(count - 1) more went back…" : …`), and add a case with one name and two evictees.

### F5 — README's drag-out rule does not exclude expanded windows, which the code deliberately exempts [Low | Confidence High | doc-gap]
- Location: `DragTracker.swift:310-311` (`guard context.slotOf(id) != nil else { return }`), `TilingController.swift:1500-1505` (`trackedSlot` returns nil for expanded), README `:109-112`
- Evidence:
```swift
// TilingController.swift:1503-1505
private func trackedSlot(of id: WindowID) -> Slot? {
    expanded[id] == nil ? slotOfWindow(id) : nil
}
```
- Trigger: expand a tiled window (⌥⇧⏎), drag its title bar 300 pt, drop it. The tracker never sees the window (slot nil), so no untile fires and no snap-back rect is written: the window stays where dropped **and** stays tiled+expanded; pressing ⌥⇧⏎ retiles it into its slot, discarding the drop.
- Impact: for a user who reads "Drag a tiled window by its title bar: past ~100 pt of drag it untiles right where you dropped it", an expanded window (which per README keeps its slot, i.e. is tiled) is a silent exception — and after collapsing, the drop is thrown away. The behaviour is coherent (an expanded window is "like focusing"), only undocumented.
- Fix: one clause in README's drag-out bullet: expanded windows are not dragged out; a title-bar drag of the covering window is left where dropped and the layout returns on the next ⌥⇧⏎.

### F6 — README says neighbours resize on mouse-up, but a trailing resize tick defers it to the next click [Low | Confidence High | doc-gap]
- Location: `DragTracker.swift:490-497` (re-arm), `:532-542` (`mouseLifted`), comment `:151-156`; README `:5-6`; test `DragTrackerTests.swift:343-418`
- Evidence:
```swift
// DragTracker.swift:490-497
if changed {
    // ... the neighbors it will displace wait for mouse-up ...
    pendingResizeApplies[context.spaceOf(id)] = id
}
```
- Trigger: any resize notification that lands *after* the button-release monitor fired (AX streaming the drag's final frame — the case the type's own comment names). `processResize` re-arms the canvas's pending entry, and nothing re-pushes until the next left-mouse-up anywhere, so the neighbours keep the pre-drag rects while the dragged window is at its final edge.
- Impact: the user-visible promise "neighbors sharing the edge resize when the mouse button is released" holds only when no tick trails; otherwise the neighbours jump on an unrelated later click. Deliberate and unit-tested ("the trailing tick waits for the next mouse-up"), so this is a documentation/precision issue, not a coding slip.
- Fix: state the caveat in README, or commit the deferred re-push on the first idle tick after the trailing notification.

### F7 — RISK/QUESTION: tile rects are never integralized, so seams/overlaps depend on each app's own rounding [Low | Confidence Medium | design-risk]
- Location: `Layout.swift:413-424` → `TilingController.swift:606-639` → `LiveWindowGateway.swift:755+`
- Evidence:
```swift
let x0 = verticalLinePosition(g.columns.lowerBound, in: g.layout, bounds: bounds)
let x1 = verticalLinePosition(g.columns.upperBound, in: g.layout, bounds: bounds)
return CGRect(x: x0, y: yBottom, width: x1 - x0, height: yTop - yBottom)
```
No `rounded`/`integral`/`floor` exists anywhere in `Sources/` (grep), so a width like 1120 gives thirds at 373.333… and those rects are written verbatim.
- Trigger: I could **not** construct a decisive static trigger: both neighbours' shared edge comes from the identical expression, so our own arithmetic cannot open a gap. A seam/overlap can only appear if the target app rounds its own frame (this repo's own comment names that class of app: "Terminal rounds to character cells", `DragTracker.swift:322-324`), which needs a live GUI session.
- Impact if it happens: 1 px seams or overlaps between adjacent tiles on odd-width or scaled displays.
- Fix (only worth doing if a live run confirms it): snap tile edges to a per-display pixel grid before writing, or accept and document.

## Verified-clean areas (what I checked and why it held)
- **Cell→rect single source of truth**: `cells`, `overlaps` and `rect` all derive from `SlotGeometry` spans (`Layout.swift:48-125`), and the sweep `testRectsAndCellsAgreeOnOverlapWithinEachLayout` / `testEachLayoutsPartitionTilesItsBoundsExactly` pins the model↔pixel agreement at clamp extremes, tight sibling gaps, negative origins and a 320×200 screen. I found no slot whose cells and rect can disagree.
- **Flushness**: every shared edge is read from one expression (`verticalLinePosition`/`horizontalLinePosition`), so `tl.maxX == tr.minX` bit-exactly; also true after arbitrary drags (`testSixthsTilesStayFlushAfterDrag`).
- **Row-split independence**: derivation is by the slot's column span (`Layout.swift:255-266`), and halved/thirds/two-thirds short-circuit at indices 0 and 2, so full-height slots never consult a row splitter. Verified per column and per third.
- **Clamps/ordering**: all stored fractions stay inside their clamps; the sixths pair keeps a 0.01 gap; derived two-thirds dividers stay strictly inside their span for every clamped drag (`Layout.swift:370-385`), and the default splitter set is consistent with both two-thirds slots' midpoints.
- **Refusal guards**: degenerate bounds and non-finite positions are refused before any write, so no NaN/±inf can reach a splitter (`Layout.swift:315-317`); no rect can be zero-width because derived dividers stay strictly inside (0.05…0.95).
- **`plan` algebra**: eviction, swap conditions (`blockers.count == 1`, `!previous.overlaps(slot)`, untiled requester falls back), self-tiling/no-op, requester-never-evicts-itself, and cross-layout switching all read as specified, and the exhaustive BFS (`TilingStateTests.swift:646-696`) plus `MatrixCrossCheckTests` (pure model vs. real controller) agree with the documented rules.
- **`reflow`**: `freed ⊆ grown.cells` always holds (a candidate's union must equal a slot exactly), so "one merge per pass" is provable and the retry loop cannot merge twice or loop; occupied cells (requester included) are subtracted before candidates are chosen; the rightmost → larger → declaration-order tie-break matches "the right side wins"; excluded (requester/expanded) windows can neither grow nor be grown into. The `testRightFlankPreferredWhenBothThirdsCouldGrow` and door/hole tests cover the documented cases.
- **Drag decisions**: the 100 pt threshold is strict (`> 100`) and gated on `ticks >= 2`, so a single far tick always snaps back; edge→boundary direction mapping is correct for all four edges (left→`minX`, right→`maxX`, top→`maxY`, bottom→`minY`), including corner drags that move two boundaries and screen edges that move none; neighbour compensation is deferred to `mouseLifted`; echo suppression, escape, stale-write and settle-window logic are internally consistent and conservative (an unreadable live frame is never judged an ignore).
- **Expanded windows**: `trackedSlot` returns nil, so the tracker ignores them entirely — no splitter drift, no phantom drag-out, no echo misread. That is what makes the drag-out rule safe while a window covers the layout.

## Residual uncertainty (what static reading cannot decide)
1. **Mutation-run caveat**: the task states `Sources/*.swift` is being rewritten in place by `tools/mutation/mutate.py` during this audit. I could not verify that the files I read are the pristine sources (no git/shell allowed); every line number above is from the files as read, and an injected mutant could in principle sit in code I quoted. `tools/mutation/mutants.json` should be cross-checked against these line numbers before this report is used.
2. **F7 needs a live host app**: whether fractional tile edges actually seam depends on each app's frame rounding (AX + AppKit), which only `./scripts/run-repro.sh` can show.
3. **An expanded two-thirds window**: while expanded it is filtered out of `trackedOccupants` (`TilingController.swift:1519`), so dragging the adjacent third moves `sixthsLeftSplit`/`sixthsRightSplit` *without* the midpoint symmetry (`DragTracker.centeredTwoThirds:501-530`). On collapse the two-thirds slot can read as two unequal thirds until the next symmetrised drag. Invisible while expanded; I could not decide whether that is acceptable without a live check.
4. **F2's user-visible severity**: the mixed-occupancy state is certain from the code; how disruptive it feels (glyph/menu vs. hotkey behaviour) depends on UI paths owned by other slices (`StatusIcon`, `MenuModel`, `AppDelegate`).
5. **Undo depth interaction**: I traced F1/F2 with a single chapter on the stack; with several chapters (depth 5) the same class of mismatch recurs by construction, but I did not enumerate every interleaving.
6. I ran no command at all (no `swift test`, no `git status`), so the "530 tests green" premise is taken from the task, and the index state of the working tree was not inspected.