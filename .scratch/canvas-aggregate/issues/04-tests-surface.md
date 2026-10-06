# Stage 4 - Tests and the surface

Status: DONE at `60cea51` ("Make the canvas the test surface and collapse the accessor facade"),
master.
Blocked by: stage 3 (DONE, `2524826`)
Blocks: -

## What shipped

- New `TilingSpaceTests` (53 cases) drives the canvas through one `TilingSpaceHarness`: fake
  gateway, injected bounds, tracker and `FrameWriter` wired to the same space. Coverage spans
  placement (tile, no-op, refusal, hidden-canvas deferral), eviction, reflow (grow, rollback,
  move-freed cells, expanded exclusion), re-house (victim stays tiled, refused write falls back,
  refused requester leaves the victim alone), undo (busy/dead/refused/plural/current-grid),
  expand (fill, tiled collapse, refusal, deferral, unreadable frame), splitter reset/restore,
  `release`, `evict`, `discard`, `untileAll`, `reassert`, `publish`, and the cross-layout
  sequences.
- `PlanExecutorTests` deleted; its branch expectations live in `TilingSpaceTests` through
  `apply` (state-derived plan) with `execute` kept only for the deliberately degenerate swap
  cases the state cannot produce.
- Hand-written production copies dissolved: `LayoutSwitchTests.apply` deleted with its seven
  sequence tests (moved to `TilingSpaceTests`), and `MatrixCrossCheckTests.applyExpected`
  replaced by a canvas-vs-model replay - the pure plan plus `rehousingHome`/`reflow` define the
  contract, the canvas executes, and three tests cover both requester kinds and a short-sequence
  BFS invariant sweep.
- Duplicated controller read spellings deleted: `state` / `grid` / `activeLayout` (zero-arg),
  `state(on:)` / `grid(on:)` / `activeLayout(on:)` / `occupant(of:on:)`, and their `(in:)`
  forms. The single scoped read is `canvas(for:)` (by `TilingSpaceKey` or `ScreenID?`, with the
  withheld-Space fallback); menus and tests read `canvas.state`, `canvas.grid`,
  `canvas.undoStack`, `canvas.notice`, `canvas.error`, `canvas.hasSplitterBackup`, and
  `canvas.evictedCount`. `surfaceSpace` / `noteSurfaceCanvas` died with the derived surface.
  The scoped *action* overloads (`untileAll(on:)`, `resetDividers(on:)`,
  `restoreSplitters(on:)`, `undoLastDisplacement(on:)`) stay: a canvas action needs the
  coordinator's placement `Context`, which menus and tests cannot build.
- Geometry migrated to injected `ScreenProvider`s: `SwapTests`, `ReflowTests`,
  `ControllerBulkOperationTests`, and `ControllerGatewayTests` (named in the ticket), plus
  `ExpandToggleTests` and `EvictTests`, which the accessor pass touched. The only live
  `NSScreen` use left is `DisplayIdentityTests.testLiveScreenInfoUsesItsDisplayNumberAsIdentity`,
  which exists to pin the AppKit adapter mapping.
- Dead-code sweep: deleted the unused `TilingController.slotOfWindow`; `publish` and reflow now
  share one `writeRects` loop; the `DragTracker.apply` contract lost its dead `Int`; the
  window-refusal sentence has one declaration (`TilingSpace.refusalMessage(windowName:)`);
  stale `executor`/`lastNotice`/shared-surface comments were refreshed; unused `AppKit` imports
  removed; README's stale 530-test count corrected.

## Evidence

- `swift build`: clean, zero warnings.
- `swift test`: 581/581 (was 556; -22 `PlanExecutorTests` cases, -7 `LayoutSwitchTests`
  sequences, +53 `TilingSpaceTests`, +1 `MatrixCrossCheckTests` net).
- `python3 tools/mutation/mutate.py`: 50/50 caught, none STALE/INVALID/TIMEOUT. The deleted
  derived-surface target ("derived surface tracks focus instead of the canvas that acted") was
  re-pointed to "screen canvas read ignores the named display"; it is caught by the per-display
  tests.
- Files removed: `Tests/tiledTests/PlanExecutorTests.swift`. Added:
  `Tests/tiledTests/TilingSpaceTests.swift`, `Tests/tiledTests/TilingSpaceHarness.swift`.
- `code-review` on both axes against `26c1db3` (the whole arc):
  - Standards: removed the dead `slotOfWindow` and the dead `DragTracker.apply` return;
    deduplicated `publish`/reflow into `writeRects` and the refusal sentence into
    `TilingSpace.refusalMessage(windowName:)`; added `TilingSpace.evictedCount` so the menu's
    count has one spelling; refreshed the stale `executor`/`lastNotice`/shared-surface comments;
    flipped the mechanical `XCTAssertFalse(!canvas.undoStack.isEmpty)` double negations;
    corrected README's test count. Reasoned: per-file `canvas`/`expectedRect`/`assertHealthy`
    fixtures mirror the repo's existing self-contained test style; the scoped action overloads
    stay (see above).
  - Spec: no wrong behaviour found. Two reasoned deviations: the settled design's narrow
    `WindowDriver` and clock are not separate injected types - the fake driver is
    `FakeWindowGateway` (the canvas still reaches `liveness` through it, which a narrow driver
    would hide) and the canvas has no clocked policy, so the only clock (death confirmation) is
    coordinator-side and keeps its injected-clock tests. Coverage and ScreenProvider injection
    extend slightly past the ticket's named lists where the pass touched the file
    (`ExpandToggleTests`, `EvictTests`; extra canvas actions beyond the required eight).
