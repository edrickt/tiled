# Slice 01 — engine (TilingSpace, Layout, ExpandToggleState, TilingState)

Read-only structural audit on `47dea76` (`Sources/` unchanged since `3c3a432`, so the
follow-up report's line refs hold). `TilingSpace.swift` 1,701 lines; `Layout.swift` 717
(`TilingState` at `:502`); `ExpandToggleState.swift` 17. No build or test run.

## New findings

### 1. A move's rollback is hand-rolled five ways; the reverse write's outcome is the step that gets dropped

**Evidence.** The same move-then-write-then-undo sequence is written independently in
`place` (`TilingSpace.swift:869-921`, rollback 885-910), both halves of `applySwap`
(`:582-652`, rollback 616-639), `restoreEvictees` (`:451-532`, rollback 503-529), and
`reflow` (`:1117-1160`, rollback 1143-1155). The re-house at `:719-735` adds a sixth
variant that falls back to eviction. Each captures a different pre-state (slot only,
slot plus `WindowRecord`, whole `TilingState`, or nothing) and decides separately whether
the rollback re-writes a frame.

**Breaks / reader load.** To answer "if write N is refused, what is in state and what is
on screen?" the reader must diff five bodies. F21's unread home-write result (`:635`) and
F22's discarded recovery-pass result (`:1153`) are the two dropped outcomes today; the prior
F1 was the state-side instance of the same shape. `place`'s `Refusal?` also hides two extra
states in `records[id] == nil` and its `inout deferred` flag, which callers re-probe at
`:334-336` and `:555-559`.

**Code-judo.** A single-window `MoveAttempt` value `(id, from: Slot?, to: Slot,
previousRecord: WindowRecord?)` with `commit(into:)` and `rollback(into:)`, where
`rollback` restores the captured slot and record **and re-writes the reverse frame
through the same push**, returning a failure instead of a discarded result. `place`,
`restoreEvictees`, and re-house become one shape; `applySwap` composes two attempts (the
second rollback writes the first home); `reflow` uses a batch whose rollback writes the
old rects. Disappears: the five rollback idioms, the `records[id] == nil` probes, and the
caller obligation to remember the reverse write.

**Class.** design · **Confidence.** high · **Effort.** M (L if the reflow batch is included)

### 2. One action's failures share a single `Refusal` slot, so a second failed write has nowhere to speak

**Evidence.** `Refusal` carries one message and one optional name (`:794-797`); `settle`
maps it to one `Result` (`:314-323`) and writes one `error` (`:379`); `reportRestoreFailures`
drops restore failures whenever a placement refusal already exists (`:983-986`);
`reconcileDeferredRequests` collapses N failures to a count (`:1043-1063`); the receipt
keeps one `performed` Bool and one notice (`ActionReceipt.swift:13-19`).

**Breaks / reader load.** F21 is the current instance (see cross-check): a swap can fail
twice and tell one story. `reportRestoreFailures`'s precedence rule exists only because
there is one slot, and a future reflow recovery refusal cannot be named beside the grow
refusal. Each branch invents its own precedence rule.

**Code-judo.** An action-scoped `[Failure]` (window name, kind, frame intent) collected by
the push/rollback layer; one `compose()` builds the canvas `error`/announcement once in
`settle`. The optional `windowName` and `reportRestoreFailures` disappear; callers cannot
silently discard a failure because appending is the only channel.

**Class.** design · **Confidence.** high · **Effort.** M

### 3. The achieved-edge reconcile is written twice

**Evidence.** `reconciledGrid` (`:1572-1588`) and `reconcileAchievedEdges` (`:1661-1689`)
both loop `TileEdge.allCases` → `GridLayout.boundary` → `TilingSpace.position(of:in:)`
(`:1693-1700`) → `GridLayout.centeringTwoThirds` → `GridLayout.update`. The centering rule
was already centralized (`Layout.swift:351-368`); the loop around it was not.

**Breaks / reader load.** A new edge rule (rounding policy, two-thirds symmetry,
screen-edge exclusion) must be changed twice; the two can drift, and only the
dragged-window loop is directly pinned by `ReassertPlanTests`.

**Code-judo.** One helper, e.g. `GridLayout.reconcileEdges(of:to:occupants:moving:) ->
Bool`, where `moving` is the tolerance filter: `reconciledGrid` passes all edges,
`reconcileAchievedEdges` passes only edges whose landed/target delta exceeds
`DragTracker.noOpWriteTolerance`. One boundary/centering/update site.

**Class.** mechanical · **Confidence.** high · **Effort.** S

### 4. The undo chord is copied into five notices although Undo is a configurable binding

**Evidence.** `TilingSpace.swift:566-568, 644-646, 804-806, 838-852, 1287-1290` hardcode
`⌃⌥⇧⌘Z`. `.undo` is a configurable `HotkeyAction` (`HotkeyAction.swift:13`, `appActions`
`:28-29`; recorder rows `SettingsShortcutsTab.swift:178`), and the menu title already reads
the live label (`MenuModel.swift:283-290`).

**Breaks / reader load.** After a remap, every eviction, switch, and untile notice names a
chord that does nothing; five copies imply a constant where the code has a binding.

**Code-judo.** One cue resolved once from `hotkeyStore.binding(for: .undo).label`, passed
as `TilingSpace.Context.undoCue: String` (contexts are built per action), and interpolated
at the five sites. Tests assert the injected cue, not the literal.

**Class.** design · **Confidence.** high · **Effort.** S

### 5. `EvictedWindow.space` is optional but total; `applyLayout(on:)` is a second, fictional canvas resolution

**Evidence.** `EvictedWindow.space` is `TilingSpaceKey?` (`:21-26`), but both construction
sites pass `context.space` (`:824-830`, `:1334-1335`); the controller still carries
`evicted.space ?? space` at `TilingController.swift:1043` and `:1109` with "legacy
untagged" comments. `applyLayout(on space:)` (`:1074-1094`) receives `entry.space` only at
`:496` and `context.space` everywhere else, then falls back to `.displayless` at `:1087`.
`restoreEvictees` is invoked per destination canvas (`TilingController.swift:1042-1058`),
so `entry.space == context.space` in every production call.

**Breaks / reader load.** The type claims an undo entry may have no canvas, but no store
produces one (the undo stack is in-memory). A nil would silently re-home an entry through
`?? space`, and `applyLayout` could pair one canvas's key with another canvas's
`visibleFrame`. The reader must decide which of the two resolutions is authoritative.

**Code-judo.** Make `EvictedWindow.space` a required `TilingSpaceKey` (it stays the
controller's grouping key), delete both `?? space` fallbacks, and drop `applyLayout`'s
`on:` parameter so it writes on `context.space`. `.displayless` remains the headless key,
not a write fallback.

**Class.** mechanical · **Confidence.** high · **Effort.** S

### 6. Every action hand-clears `notice`/`error`; the lifecycle is copy-paste

**Evidence.** Eight sites, fifteen assignments: `:268-269`, `:1219-1220`, `:1258-1259`,
`:1283-1284`, `:1375-1376`, `:1410-1411`, `:1490-1491`, `:1503-1504`.

**Breaks / reader load.** A new action can forget one of the two and leave a stale
error/notice in the menu. The rule "an action that attempts a change replaces the last
notice" exists only in the copies; `evict`'s no-op path (`:1232-1240`) shows that guard
placement is itself a decision.

**Code-judo.** `mutating func beginAction() { notice = nil; error = nil }`, called after
each action's early guard (after the no-op guard in `apply`, after the slot guard in
`evict`), so no-op behavior is unchanged. Deletes the fifteen assignments and gives any
future action-scoped reset one home.

**Class.** mechanical · **Confidence.** high · **Effort.** S

### 7. `preTileFrame` uses `.zero` as "unknown"; three production sites test the sentinel and a test converts it back to nil

**Evidence.** `WindowRecord.preTileFrame` (`:7-10`); seeded `.zero` at `:208`; tested at
`:879`, `:950`, `TilingController.swift:644`, `:1771`. `Tests/tiledTests/ExhaustiveUndoTests.swift:270`
already writes `record.preTileFrame == .zero ? nil : ...`.

**Breaks / reader load.** `.zero` is a legal `CGRect`, so "unknown" and "a window at origin
with zero size" collide; a missed check silently skips a restore or treats a record as
untiled.

**Code-judo.** `preTileFrame: CGRect?` (nil = not captured yet): `attach`/`beginRecord`
seed nil, `place` fills it on first tiling, `restore` uses `if let frame`, and
`EvictedWindow.preTileFrame` becomes optional or is guaranteed at chapter construction.
The three `!= .zero` checks disappear.

**Class.** design · **Confidence.** medium-high · **Effort.** S/M

## Cross-check of open findings

**F21 — STILL PRESENT.** `applySwap`'s requester-refusal branch (`:629-639`) restores both
occupancies and writes the displaced window home at `:635`, but `applyLayout` records no
`error` and the result is discarded. Worse, `settle:379` then writes only the requester's
refusal, so a local "read the result" patch would still be overwritten. Issue 01's expected
behavior (name the home-write failure on the canvas; test at `TilingSpaceTests.swift:311-330`)
is not met. The durable fix is finding 2's failure list, or a combined branch message.

**F22 — FIXED at the issue's behavioral bar; residue only.** The recovery pass at
`:1153` is `_ = writeRects(...)`, but `writeRects` already writes the refusal message to the
canvas (`:1192-1194`) and no later step clears it, so the disagreement is announced.
Remaining: the unread return (readability) and no second-refusal test (`ReflowTests.swift:398-411`).
F23/F24/F25 are DragTracker/controller paths, out of this slice; not re-checked.

**A1 (expected-write ledger) — unchanged, and this slice bears on it.** `FrameWriter` still
imports `DragTracker.noOpWriteTolerance` (`FrameWriter.swift:104, 154`) and returns
`.refused` with no reason; the canvas owns the deferred maps and messages. Findings 1-2 are
the canvas-side half (reverse writes, failure accumulation), a first slice of A1, not a
re-claim. **A2 — unchanged:** `records` remains the ownership primitive and
`Context.allocateID` the handoff; finding 5 removes a second canvas tag, not the register.
**A3 — unchanged:** finding 5 removes `applyLayout`'s second resolution; the controller's
grouping remains the one directory.

## File-size check

`TilingSpace.swift` is 1,701 lines, but no split of the planner is justified: `applyTile`
(114 lines), `settle` (103), and `applySwap` (76) are the deep module; extracting them
would recreate the coordinator/canvas split. The one extraction that clearly helps is the
move/reverse-write/failure layer of findings 1-2 (~250 lines); its concept is the
expected-write transaction, and it deletes rollback bodies and push helpers, not just lines.
`Layout.swift`'s geometry and `TilingState` halves are cohesive; splitting them is a file
move, not a design change. `ExpandToggleState` has two real consumers, not a thin wrapper.

## Smaller observations (not ranked)

- `retileExpanded` (`:1455-1461`) is `applyLayout` (`:1074-1094`) with a different log line;
  it is a one-caller duplicate and should fold into the push helper.
- `TilingState.plan`, `rehousingHome`, and `reflow` each scan `Slot.allCases` for an exact
  cell set (`Layout.swift:593-595, 638, 689-691`); one `Slot.withCells` lookup would encode
  the exact-or-nil rule once.

## Ranked shortlist (this week)

1. **Findings 1 + 2 together** — a move transaction that owns rollback, the reverse write,
   and a failure list. Fixes the class F21/F22 belong to. (design, M)
2. **Finding 5** — make the canvas tag required and delete `applyLayout`'s `on:` parameter.
   (mechanical, S)
3. **Finding 3** — one achieved-edge reconcile helper. (mechanical, S)
4. **Finding 4** — one live undo cue in `Context`. (design, S)
5. **Finding 6** — `beginAction()`. (mechanical, S)

Backlog: finding 7, `retileExpanded`, the exact-cell lookup.
