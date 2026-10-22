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

**Status:** TODO

- [ ] Characterization tests pin the current visible-canvas enumeration
      and the withheld fallback for each surface.
- [ ] Register and directory land behind the same behavior; the old
      maps/resolvers are deleted, not wrapped.
- [ ] Live adapter's `release` is one binding removal.
- [ ] Gates in `../README.md` all pass.
