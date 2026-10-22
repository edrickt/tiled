# Slice 02 — controller, ownership, and the write path

Scope: `TilingController`, `WindowGateway`, `ActionReceipt`, `FrameWriter`,
`LiveWindowGateway`, `DisplaySpace`. Base `master` @ `47dea76`. Read-only: no
build, no tests, no live run. Prior reports: `.scratch/quality-audit/report.md`,
`.scratch/quality-audit-followup/report.md`.

## Open-finding cross-check

| ID | Status | Current evidence |
|---|---|---|
| F26 released handle answers the focus memo | **STILL PRESENT** | `focusedWindow` returns the memo unchecked (`LiveWindowGateway.swift:355-359`); `release` clears eight maps but not `focusedCache` (`:440-454`) |
| T9 focus cache stamps bypass `now` | **STILL PRESENT** | `Date()` at `:357,361,365`; Space cache uses the injected clock (`:284,786-793`); focus callback clears via static `active` (`:1156-1161`) |
| F31 splitter actions outside the receipt path | **STILL PRESENT** | `resetDividers`/`restoreSplitters` return `Void`/`Bool` (`TilingController.swift:857-898`); reset discards its `Outcome` (`:869-872`); menu speaks literals (`AppDelegate.swift:888-906`); hotkey is silent (`HotkeyActionRouter.swift:72-74`); restore sentence twice (`TilingSpace.swift:1504`, `AppDelegate.swift:894`) |
| F25 unreadable achieved frame drops the reassert | **STILL PRESENT** | `guard ... let achieved = gateway.frame ... else { return }` (`TilingController.swift:1156-1168`) |
| A1 expected-write ledger | **ABSENT** | Policy closures `FrameWriter.swift:42-56`; echo map + verdict `DragTracker.swift:114,265-277,305-330`; verification `TilingController.swift:456-474` |
| A2 window ownership register | **ABSENT** | `windowIDs`+`nextID`+`deadSince`+`pendingVerifications` (`:93-94,127,456`); `spaceOf` scans canvases (`:1649-1654`, 19 call sites) |
| A3 canvas directory | **ABSENT** | Eleven resolvers, three visible-canvas enumerations (S1) |

A1 first move: one `ExpectedWrites` value (arm/cancel/seed/schedule + the 1pt
tolerance) passed to `FrameWriter`, deleting its `DragTracker` import at
`FrameWriter.swift:104,154`. A2 first move: a `WindowRegister` for the three
controller-owned maps only — **not** an id→canvas map, which would contradict
`TilingSpace.swift:36-38` ("ownership cannot drift from a second registry").
A3 first move: S1's last paragraph.

## S1. Three visible-canvas enumerations, eleven resolvers; one directory owns display+Space identity

**Evidence.** Fields `spaces`/`staleSpaces`/`lastFocusedSpace`
(`TilingController.swift:88,132-133,138`). Resolvers at `:593-601,615-618,
626-631,1670-1681,1699-1707,1712-1714,1721-1728,1734-1741,1746-1759,1781-1783`.
The "identified or withheld canvas holds occupants/chapters" predicate is copied
four times (`:1358,1724-1725,1737-1738,1753`). `allTiledWindowsInfo`
(`:1345-1372`) lists the withheld canvas as a second source, while
`actionSpaceKey` (`:1734-1741`) resolves one of the pair, so a display holding
windows on both lists rows the bulk actions will not touch; the menu dedupes to
hide it (`AppDelegate.swift:623-627`). Nil keys resolve three ways:
`tilingKey(for: nil)`, `.displayless` (`TilingController.swift:65-73`), and
`Context.space ?? .displayless` (`TilingSpace.swift:1087`). `visibleFrame` is
written outside the mutation funnel at `TilingController.swift:629`.
**Cost.** "The canvas shown on a display is what every surface enumerates" has
no owner; the three copies already differ in whether they list one canvas or
both. ~30 direct `spaces[...]` reads and five key resolvers precede any action
trace.
**Remedy.** `CanvasDirectory` (own file): `spaces`, `staleSpaces`, last focus,
and the funnel `withCanvas`, `key(for:)`, `keyForRequester`, `focusedKey`,
`visibleKeys`, `isVisible`, `visibleFrame`, `refreshFrames`, `markStale`.
Mechanical first half: delete the four test-only display-scoped overloads
(`:827-828,864-865,887-888,929-930`) and collapse the four `holdsAnything`
copies into one property.
**Classification** design · **confidence** high · **effort** M

## S2. Three id rituals and four controller maps; one register removes "id without a record"

**Evidence.** `windowIDs`/`nextID`/`deadSince`/`pendingVerifications`
(`TilingController.swift:93-94,127,456`). `windowID(for:)` `:669-680` reuses an
id only while a record exists; `recordID(for:)` `:694-697` re-checks the same
thing; `allocateID(for:on:)` `:723-733` adds a foreign-claim release. Evict
issues an id before learning there is nothing to evict (`:1413`), so the table
legitimately holds dead ids. `forgetBookkeeping` `:789-793` is the only remover
and must be called from `:412,494,1011,1068`; a missed call leaks a death clock
and verification that no seam sees (`registeredID` reads only `windowIDs`,
`:703`). Six sites re-invent `spaceOf(...) ?? focusedSpaceKey()`
(`:647,1284,1414,1490,1516,1575`).
**Cost.** "A death clock or verification names a window with a record" is
convention; "every table id is live" is false by design, so every reader repeats
the pairing check. `spaceOf` is a linear scan on every action, tracker callback,
and menu row.
**Remedy.** `WindowRegister`: `liveID(for:)` (nil once the record is gone),
`claim(_:on:)`, `forget(_:)` clearing all three maps. Ownership stays derived
from canvas records, per the design rule above.
**Classification** design · **confidence** high · **effort** M

## S3. Splitter actions are the one action class with no receipt (F31)

**Evidence.** `TilingController.swift:857-898` returns nothing presentable;
`resetDividers(in:)` discards the canvas's `Outcome` (`:869-872`), so a refused
reassert after a reset reaches neither surface. The restore sentence is
duplicated (`TilingSpace.swift:1504` vs `AppDelegate.swift:894`).
**Cost.** "Every app action has exactly one receipt" holds for four actions and
fails here; a refusal is silent, and the menu/hotkey describe the action
differently by construction.
**Remedy.** Return `ActionReceipt` from both, built by the existing
`receipt(canvas:performed:failure:success:noOp:)` (`:1629-1639`) from the
`Outcome` and canvas notice; route both surfaces through `present(_:)`
(`AppDelegate.swift:925-937`); delete the duplicate sentence.
**Classification** design · **confidence** high · **effort** S

## S4. Four actions rebuild the same tail; three definitions of `performed`

**Evidence.** `handleEvict` `:1403-1436`, `untile(window:)` `:1448-1480`,
`untileAll(in:)` `:835-849`, `undoReceipt` `:940-955` repeat prune → mutate →
`apply` → `onChange` → read error → receipt. `performed` means `error == nil`,
`!refused`, `hadWindows && error == nil`, and `restored > 0 && failures.isEmpty`
respectively. `pruneDeadWindows` has eight entry points
(`:329,816,836,969,1405,1453,1487,1509`); `onChange` placement differs.
**Cost.** A fifth action can pick a fourth meaning of performed or skip the
refresh. ~20 guard/error/refresh branches collapse to ~8.
**Remedy.** One `perform(in:_:success:noOp:) -> ActionReceipt` owning prune,
mutation, `apply`, `onChange`, error capture, and one performed rule derived
from the `Outcome`. The action-side twin of the write ledger.
**Classification** design · **confidence** medium-high · **effort** S/M

## S5. An unknown achieved frame is unrepresentable at drag end (F25)

**Evidence.** `handleDragEnd` drops the reassert on a failed frame read
(`TilingController.swift:1156-1168`); `ReassertSource.resize(dragged:achieved:)`
requires a `CGRect` (`TilingSpace.swift:1531-1537`), so the planner cannot say
"edge drag ended, frame unknown". Convergence treats the same read as
can't-judge (`DragTracker.swift:322-326`).
**Cost.** "Every mouse-up reasserts its canvas" fails in the one state the type
cannot name; the fallback lives in a guard, so it is unpinnable.
**Remedy.** `resize(dragged: WindowID, achieved: CGRect?)`; `reconciledGrid`
already guards the dragged slot, so nil keeps the splitters (`.grid`) while
rects are still written. This makes the fallback a pure-suite case.
**Classification** design · **confidence** high · **effort** S

## S6. The focus memo outlives its handle and bypasses the injected clock (F26+T9)

**Evidence.** `focusedCache` `LiveWindowGateway.swift:222-223`; stamps `Date()`
at `:357,361,365`; `release` clears eight maps but not the memo (`:440-454`);
invalidation routes through static `active` (`:1156-1161`). `now` already exists
for the Space cache (`:284,786-793`).
**Cost.** "A memoized answer names a live handle" is false inside the 50 ms
window; the TTL cannot be pinned without sleeping; a second gateway steals the
first's invalidation route.
**Remedy.** `FocusMemo.resolve(now:read:)` plus `invalidate(_ handle:)` clearing
only when the released handle is the memoized one; `release` and the focus
callback call it; stamps use injected `now`.
**Classification** mechanical · **confidence** high · **effort** S

## S7. Eight handle-keyed dictionaries in the live adapter; one binding makes registration atomic

**Evidence.** `LiveWindowGateway.swift:203,204,208,212,216,231,248,254` hold
element, pid, frames, token, observed key, baseline, and two handlers per
handle. `release` clears all eight (`:440-454`); `registerTestWindow` fills
three (`:462-471`); `adopt` rewrites three plus registration (`:1070-1089`);
notification routing scans `observedKeys` per event (`:1173-1174`), adoption
scans `pids` (`:1019`).
**Cost.** "A handle's registration is all-or-nothing" is enforced only by
release remembering every map; a ninth field leaks silently, and the test seam's
partial handle is an illegal state the type cannot state.
**Remedy.** One `WindowBinding` struct per handle plus a derived
`tokenIndex: [UInt: WindowHandle]`; release is one removal, the test seam's nil
element is explicit.
**Classification** design · **confidence** medium-high · **effort** M

## S8. The clamp repair is a second write outside the one policy

**Evidence.** `FrameWriter.write` re-writes a repinned frame, ignores the Bool,
and arms an expectation anyway (`FrameWriter.swift:129-137`). If refused, the
caller gets `.written` while the window holds the clamped frame, and the pending
convergence check can read the missing echo as an ignore and roll the placement
back.
**Cost.** "The last expectation names a frame that landed" fails inside the
module that owns it; the repair escapes `Result` entirely.
**Remedy.** Read the repair: on refusal `cancelExpected`, seed from the actual
frame, return `.refused` (or a distinct `.writtenClamped`). The ledger (A1)
should own this second write rather than the policy body.
**Classification** design · **confidence** medium · **effort** S

## Minor, same files

`axTopLeft` (`LiveWindowGateway.swift:1476-1478`) is dead while `topLeft`/
`setTopLeft` (`:147-164`) hand-roll the flip. `trackedOccupants`
(`TilingController.swift:1551-1559`) merges same slots across canvases and is
unreachable: `DragTracker` always gets `occupantsOf` and only falls back when
the key is nil (`DragTracker.swift:674-679`), impossible for a window whose
`slotOf` is non-nil. Delete both, make `occupantsOf` non-optional. Mechanical, S.

## Ranked shortlist this week

1. **S6** — closes F26+T9 with one memo type; the TTL becomes testable.
2. **S3** — closes F31; one receipt, one sentence, refusals visible.
3. **S5** — closes F25 by making unknown-achieved a planner case.
4. **S4** — one action tail and one `performed` rule.
5. **S1, first half** — delete four test-only overloads and collapse
   `holdsAnything` into one `visibleKeys()`. Full `CanvasDirectory`, S2, S7 are
   the next arc. S8 and the minor cleanups can ride any touching commit.

## Verified solid

- `ActionReceipt` is minimal and single-purpose (`ActionReceipt.swift:8-20`); the
  four covered actions share one `receipt` builder.
- `FrameWriter.Result.stands` is the only reading of a write outcome in these
  files; no second interpretation of deferral exists.
- Ownership is deliberately derived from canvas records; this review does not
  ask to centralize it, only to stop maintaining parallel controller-side maps
  by convention.
