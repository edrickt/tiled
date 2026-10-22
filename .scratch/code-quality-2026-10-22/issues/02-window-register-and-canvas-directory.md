# 02: Window register and canvas directory

**What to build:** a `WindowRegister` for the controller-owned identity
maps (`windowIDs`, `nextID`, `deadSince`, `pendingVerifications`), with
`liveID(for:)`, `claim(_:on:)`, and one `forget(_:)` that clears all
three. Ownership stays derived from canvas records; do not add an
id→canvas map. A `CanvasDirectory` owns the `spaces` table, stale
marks, last focus, visibility, the withheld fallback, and one
`visibleKeys()` enumeration. In the live adapter, one `WindowBinding`
struct per handle replaces the eight dictionaries and `release` is one
removal.

**First mechanical slice:** delete the four test-only display-scoped
overloads (`untileAll(on:)`, `resetDividers(on:)`, `restoreSplitters(on:)`,
`undoLastDisplacement(on:)`) once their tests use the focused-key path;
collapse the four `holdsAnything` copies into one property.

**Why:** "every table id is live" is false by design, so every reader
repeats the pairing check; `forgetBookkeeping` must be remembered at
four call sites. Eleven canvas resolvers and three visible-canvas
enumerations already disagree about whether to list one canvas or both;
`allTiledWindowsInfo` lists the withheld canvas while `actionSpaceKey`
resolves one of the pair.

**Findings:** `../report.md` "Still open 2"; `../slices/02-controller-write.md`
S1, S2, S7; A2/A3 in `../../quality-audit/report.md`.

**Status:** DONE (4f1231d)

- [x] Characterization tests pin the current visible-canvas enumeration
      and the withheld fallback for each surface.
- [x] Register and directory land behind the same behavior; the old
      maps/resolvers are deleted, not wrapped.
- [x] Live adapter's `release` is one binding removal.
- [x] Gates in `../README.md` pass for build, tests, and the published
      count; the mutation gate is deferred to the coordinator.

## Comments

Landed in seven commits: `5a50719` (delete the four test-only
screen-scoped bulk overloads and migrate their tests to the focused key;
one `TilingSpace.holdsAnything`), `12132ca` (characterization of the
visible-canvas surfaces), `5b65176` (`WindowRegister`), `86b3a98`
(`CanvasDirectory`), `f409ffb` (`WindowBinding`), `7c31362` (restore the
manage list's named-canvases-first row order), and `4f1231d` (ownership
doc comments).

`WindowRegister` is a final class taking three closures: `owner` (reads
the canvas holding an id's record through `CanvasDirectory.owner`),
`releaseForeignClaim` (the controller's release of a record another
canvas is claiming), and the convergence scheduler. It owns
`windowIDs`, `nextID`, `deadSince`, and `pendingVerifications`; `liveID`
consults the owner read, `claim` reuses a live id on the same canvas or
releases a foreign record and allocates, and `forget` clears the handle
entry, death clock, and pending check. No id-to-canvas map exists and
`nextID` never resets.

`CanvasDirectory` is a final class in its own file. It owns the canvas
table, stale marks, last focused canvas, visibility, the withheld-Space
fallback, and the one `visibleKeys()` enumeration. The funnel is
`withCanvas`/`modifyCanvas`, `key(for:)`, `keyForRequester`, `focusedKey`,
`actionKey`, `visibleKeys`, `isVisible`, `visibleFrame`, `refreshFrames`
(`refreshAllFrames`), `markStale`/`markAllStale`/`clearStale`, and the
screen-ownership pure helpers. The controller's `spaces`, `staleSpaces`,
`lastFocusedSpace`, and every old resolver (`tilingKey`, `actionSpaceKey`,
`activeSpaceKeys`, `withheldCanvas`, `focusedScreenID`, `isVisible`,
`visibleFrame`, `refreshVisibleFrames`, `spaceKeyForRequester`) are gone.

`WindowBinding` is one struct per handle (`element`, `pid`, `frames`,
`token`, `observedKey`, `changeHandler`, `destructionHandler`,
`lastFrame`), with a derived `tokenIndex` for notification routing.
`release` removes the binding and its token-index entry; the test seam's
missing element is an explicit nil; `adopt` rewrites one binding and
still scans bindings by pid rather than keeping a second index.

Behavior deliberately preserved: the manage list enumerates every named
canvas first, then each display's withheld fallback (pinned for two
displays and both withheld canvases); `actionKey` resolves the named
canvas when it holds anything, else the withheld one; the focused canvas
is that display action key, not the focused window's owning canvas. The
last point is the ticket's real disagreement: a display holding windows
on both canvases still lists the withheld canvas in the manage list
while display-scoped bulk actions and the glyph resolve the named one.
Rows are deduped by window in the menu, so the visible output is
unchanged, but a withheld-only window can still be listed while Untile
All does not reach it. That product call is left for a later ticket. No
CHANGELOG entry: no intended user-visible change.

The live adapter's registered test windows have no AX element by design;
liveness still reports `.dead` for them, as before.

Gates actually run after each unit: `swift build` with empty
warning/error grep, `swift test` green (882 tests, 1 skipped, 0
failures), and `./scripts/check-test-count.sh` reporting README 882
matches. Per `AGENTS.md`, the mutation table was not edited or run; it is
the coordinator's single final gate.

