# Multi-display & Spaces audit — 2026-10-12

Scope: the display / Mission Control Space subsystem of Tiled — canvas identity and
ownership, visible-frame resolution and display lifecycle, the frame-write policy's
off-Space deferral, and cross-display interaction/presentation.

Base: `master` @ `690d680` ("Record stage 5 in the resize-reassert arc").

Method: four parallel source+test tracers, one per slice (A identity & ownership, B geometry
& lifecycle, C writes & off-Space deferral, D interaction & presentation). Every finding cites
`file:line`. One behavioural claim (the retired D17) was confirmed by executing a cross-display
drag through the test harness.

Limits and caveats:

- **Not live-verified.** Nothing here was run against two real displays, Mission Control,
  a lid sleep/wake, or with Accessibility permission. Items marked *needs live verification*
  are readable from code/tests but their production frequency is unknown.
- **Master predates the unmerged `robustness-audit` branch** (58 commits), which holds the
  `WriteExpectations` refactor of the write policy. The prior report's D15/D16 are re-derived
  here against master's actual `FrameWriter`-era code.
- Domain words per `CONTEXT.md` (canvas / tiling space, slot, Space, visible frame, reassert,
  eviction, reflow, re-house, expand, requester).

---

## Verdict

The identity model is sound. A canvas is keyed by the CoreGraphics display number plus the
window-server Space id (`DisplaySpace.swift:9-49`), never by list index; display reorder,
unplug/replug, per-Space independence, and the one-visible-frame-per-canvas rule are all pinned
by tests. The engine-level reassert work of the last arc is intact.

The failures cluster in three places:

1. **Ownership lifecycle** — records outlive occupancy, and undo can put one window on two
   canvases. The invariant "at most one canvas holds a record per window" is neither stated nor
   enforced (M1, M6, A5).
2. **The lifecycle edges of the visibility/geometry contract** — sleep blinds the death clock
   (M2), a removed display's canvas is still written (M7/M8), and a transient "Space unknown"
   read is mistaken for "canvas hidden" (M3).
3. **Incomplete write-policy coverage** — the pre-tile restore path bypasses the policy entirely
   (M4), a deferred placement/expansion is never reconciled (M10/M12), and off-Space is a single
   point-in-time probe over a multi-second write (M13).

Findings: **4 High**, **12 Medium**, **12 Low**, plus 1 prior finding retired and 1 found vacuous.

---

## Prior findings re-derived against master

| Prior | Re-derived here | Status |
|---|---|---|
| D15 — `.deferredOffSpace` is failure in `applyLayout`, success in `writeRects` | **M9** | **Confirmed** on master; same split (`TilingSpace.swift:775` vs `:867`). |
| D16 — pre-tile restore bypasses off-Space deferral | **M4** | **Confirmed**; `restore(window:)` writes gateway-direct (`TilingSpace.swift:716-724`). |
| D17 — cross-display short drag snaps into the wrong display's geometry | **D1 (Info)** | **Retired.** Does not reproduce on master: snapback routes to the owner canvas's frame via `spaceOf` (`TilingController.swift:919-933`). The resize-reassert arc's "tracker decides only, canvas settles" split already fixed it. Keep a regression test. |
| G5 — no test asserts a non-zero gap on a second display | **D9 (Info)** | **Vacuous.** No inter-tile gap feature exists (`Layout.swift:438-449`; `AppSettings.swift:1-25`). Drop it, or model a per-canvas inset first if spacing is roadmap. |

---

## HIGH — state corruption / data loss / user-visible wrong behaviour

### M1. Undo can put one window on two canvases, clobbering the handle→id table

`TilingSpace.undo` resolves an id per snapshot entry *within its own canvas*, falling back to
`context.allocateID` when the handle is absent (`TilingSpace.swift:328-334`). `allocateID`
unconditionally overwrites the global table (`TilingController.swift:408-414`). The controller's
undo groups restores by the window's original canvas and never clears a record the window holds
on the canvas it currently lives on (`TilingController.swift:844-875`).

Reachable sequence: tile W on canvas C → evict W by tiling another window on C → re-tile W on a
different canvas D (W gets a fresh id on D) → `undoLastDisplacement(on:)` for C. D holds W under
one id, C allocates a **second** id for the same handle; both records persist and both canvases
write the same physical window. `spaceOf` is a first-match scan over an unordered dictionary
(`TilingController.swift:1252-1257`), so the duplicate resolves nondeterministically; the menu
counts the window twice and two canvases reassert competing rects.

**Recommendation:** state and enforce "at most one canvas holds a record per handle." Before
restoring a snapshot entry, the controller (which owns `windowIDs`) should evict any record the
handle already has elsewhere; at minimum `allocateID` should refuse to overwrite a live id.
**Test gap:** no test evicts on A, re-tiles the same handle on B, then undoes A.

### M2. Death confirmation is wall-clock, so sleep counts toward it — a live window can be pruned on the first post-wake tick

Death confirms when `timestamp.timeIntervalSince(first) >= deathConfirmation` against wall-clock
`Date`s, default 3.0 s (`TilingController.swift:105,108,175,647-655`). Sleep inflates
`timeIntervalSince` with no prune tick running, so a `deadSince` left before sleep confirms
immediately at the first post-wake tick. Independently, the live gateway can answer `.dead` for a
*listed* live window when its frame no longer matches the stale cached `lastFrames` baseline —
exactly what macOS rescaling/relocation during sleep produces (`LiveWindowGateway.swift:185,
240-251,297-300,754-768`). If the prune runs before any post-wake frame read refreshes the
baseline, the live window is untiled and its slot reflowed.

**Recommendation:** measure confirmation with a monotonic uptime clock that excludes sleep, or
require two distinct prune *ticks* (a counter on `deadSince`); and treat a listed window whose
frame moved as alive rather than requiring the stale baseline. *Needs live verification* on real
lid sleep/wake with a rescaled layout. **Test gap:** `LidSleepWakeTests` builds the controller with
`pruneInterval: nil` and never drives liveness, so the prune/death path across sleep is untested
(`LidSleepWakeTests.swift:32-33`).

### M3. A transient "Space unknown" read is treated as "canvas hidden", rolling back a visible placement and narrating an app refusal

`isVisible` returns `false` for any key with a non-nil Space id whenever `activeSpaceID(on:)`
answers nil (`TilingController.swift:1291-1294`). The Space cache stores an empty/parse-failed
table for its whole 0.1 s TTL (`LiveWindowGateway.swift:391-412,418-429,404`). `applyLayout`
treats the resulting `.deferredOffSpace` as failure (`TilingSpace.swift:775`) and `place` narrates
the standard resize-refusal message (`TilingSpace.swift:690-697`). A single `setFrame` can block
~3.3 s plus two ~1 s frame reads (`LiveWindowGateway.swift:51,884-922`), all well past the cache
TTL, so a Space-table hiccup mid-action surfaces to the user as "the app refused to resize it"
while the placement is discarded.

**Recommendation:** distinguish "Space unknown" from "known different Space." On unknown, defer
without the refusal vocabulary and retain the intent for swipe-back (the withheld-Space path
already treats unknown as visible, `TilingController.swift:1292`), or re-probe before deciding.
*Needs live verification* of whether `currentSpaces()` returns empty transiently on real hardware.

### M4. The pre-tile restore bypasses the entire write policy (D16)

`restore(window:)` calls `context.gateway.setFrame` directly — no `isVisible` check, no echo
arming, no no-op skip (`TilingSpace.swift:716-724`). It is reached from `untile` (`:903`),
`evict`, controller undo (`TilingController.swift:837-858`), `applySwitchLayout` (`:387`),
`applyTile` (`:527-528`), `untileAll` (`:985`), and the re-house fallback (`:549,553`). The
eviction restores in `applyTile`/`applySwitchLayout` run *before* the requester's `place`, so on a
hidden canvas the policy-compliant `place` defers and rolls back while the restores have already
dragged the hidden windows through Mission Control and forgotten their records.

**Recommendation:** route restores through the write policy (or a policy-aware restore) so
off-Space restores defer and reconcile, while keeping the straddling-pre-tile behaviour
(`FrameWriter.swift:118-124,198-211`). *Needs live verification* of whether a hidden-canvas
placement with eviction is reachable in production.

---

## MEDIUM — robustness risk / significant quality issue

| # | Finding | Evidence |
|---|---|---|
| M5 | **A canvas whose Space id is withheld *after* tiling leaves the menu.** `allTiledWindowsInfo`/`activeSpaceKeys` add the nil-Space fallback but never the identified `(screen, S1)` canvas when the table currently answers nil, so managed windows vanish from the manage list and focused Untile All/undo until the id returns. Reachability is one-directional (`withheldCanvas` only recognises `space: nil`). | `TilingController.swift:1040-1068,1308-1328,1333-1346`; `TilingSpace.swift:770-772` |
| M6 | **Records outlive occupancy, entrenching stale ownership.** A refused placement leaves `records[id]` intact (`TilingSpace.swift:690-697,224-225`), and `handleEvict` calls `attach` *before* `evict`, returning early on `.nothingToEvict` (`TilingController.swift:1104-1113`, `TilingSpace.swift:139-143`). Since `spaceKeyForRequester` returns `spaceOf` first, a window later dragged to the second monitor re-tiles onto the **original** display. | `TilingController.swift:584-593,1248-1251`; `TilingSpace.swift:690-697` |
| M7 | **A nil-Space (withheld) canvas on a removed display is treated as visible**, so a hotkey writes the removed canvas. `isVisible` returns `true` unconditionally when `space == nil` and never checks screen attachment; the stored frame has already been overwritten with the main display's via the removed-display fallback, so an unplugged window is re-laid-out against the wrong display instead of deferred. | `TilingController.swift:1291-1294,550-558,572-576,218-219`; `FrameWriter.swift:76-80` |
| M8 | **`refreshVisibleFrames` writes the main display's frame into an unplugged canvas.** `visibleFrame(for:)` falls back to `mainScreenInfo(screens())` when the canvas's display is absent, and the screen-change observer refreshes *every* canvas. The canvas kept "for replug" now holds another display's geometry; correctness depends entirely on the incomplete visibility guard (M7). | `TilingController.swift:550-558,572-576,218` |
| M9 | **`.deferredOffSpace` is a rollback in `applyLayout` but a success in `writeRects`** (D15). Same policy outcome, two contracts: a placement is "app refused" and rolled back; a reflow keeps state and reconciles on return. | `TilingSpace.swift:775` vs `:867,825-837` |
| M10 | **A deferred placement is never re-tried.** The deferral marks the canvas stale but arms nothing, and `place` has already removed occupancy; swipe-back only reasserts *current* occupants, so the requested slot is gone and the user just saw a refusal. | `FrameWriter.swift:76-80`; `TilingController.swift:277-300,483-492`; `TilingSpace.swift:688-696` |
| M11 | **Undo's `applyLayout` hard-codes `check: .none`**, justified by `settle` scheduling verification — but undo calls it outside `settle` and its `UndoOutcome` has no verify field, so a silently-ignored undo retile is never rolled back and its echo entry lingers. | `TilingSpace.swift:346-357,765-766,128-132,252-264` |
| M12 | **Expand/collapse deferral discards the expansion and never reconciles it.** `writeExpandedFrame` maps `.deferredOffSpace` → `.deferred`; `expand` returns `.expandRefused` without recording `expanded[id]`, so swipe-back cannot restore a toggle that was never recorded. | `TilingSpace.swift:1133-1148,1039-1060`; `TilingController.swift:277-300` |
| M13 | **Off-Space detection is a single check at write entry** (`FrameWriter.write` → `isVisible` once); a swipe concurrent with a multi-second AX write is not detected. *Needs live verification* of overlap frequency. | `FrameWriter.swift:76`; `LiveWindowGateway.swift:51,884-922` |
| M14 | **Menu monitor sections group by display *name*, not display identity** (also A7). Two identically-named monitors (or two unlabeled ones, all `"Display"`) merge into one section; `MenuModel` then matches by name. | `AppDelegate.swift:497-511`; `MenuModel.swift:245-254`; `TilingController.swift:997-1006` |
| M15 | **A display-parameters change mid-drag cancels the in-flight drag, losing a drag-out.** The screen-change reassert writes the dragged window, whose `markExpected` calls `clearDrag` and cancels the pending drag-end, so a drag-out snaps back instead of untiling. Narrow race but the one path where a gesture is silently discarded. | `TilingController.swift:212-222`; `DragTracker.swift:212-217,414-417` |
| M16 | **A display with both an identified and a withheld canvas can double-list its windows** under one name-keyed section, with a name-derived count. *Needs live verification* (requires a withheld→identified transition with windows left on each). Overlaps M14. | `TilingController.swift:1040-1057`; `MenuModel.swift:245-254` |

---

## LOW — quality / hygiene / edge

| # | Finding | Evidence |
|---|---|---|
| L1 | Screen-scoped bulk/undo overloads resolve the raw `tilingKey`, not `actionSpaceKey`, so they can act on the empty identified canvas while the withheld canvas holds the windows. Latent (production uses the focused forms). | `TilingController.swift:707-709,736-740,759-763,798-802` |
| L2 | `windowIDs` entries leak when an undo restore fails: the canvas forgets the window but the controller only clears the requester's bookkeeping. Small persistent map, reads stay guarded. | `TilingSpace.swift:353-357`; `TilingController.swift:854-861,408-414` |
| L3 | Canvases (and stale marks) for removed displays are never pruned — intended "keep for replug", but undocumented and can leave a permanently-removed display's canvas unreachable. | `TilingController.swift:82,219,483-492,1237-1242`; `DisplayIdentityTests.swift:129-166` |
| L4 | `visibleScreen`/`focusedScreenID` fall back to the main display for any frame overlapping no screen, so an off-detached-display window's first tile lands on the main canvas. | `TilingController.swift:526-536,541-543,584-593` |
| L5 | `applyAll` clears the stale mark *before* a reassert that may early-return on a degenerate frame, so a deferred reassert can be dropped. | `TilingController.swift:483-492`; `TilingSpace.swift:1256-1261` |
| L6 | `mainScreenInfo` is `screens.first`, not `NSScreen.main`, contradicting its comment; differs from the real menu-bar display when the origin display isn't the focused one. | `TilingController.swift:184,538-543,556-557` |
| L7 | Reassert's achieved-edge readback trusts a written occupant's frame even if the app relocated it off-canvas; the fraction is out of range and clamps the splitter to an extreme. Bounded by `maxAchievedEdgePasses` and limited to just-written occupants. | `TilingSpace.swift:1312-1341,1290`; `Layout.swift:308-326` |
| L8 | The swipe-back reassert is deferred one main-queue hop, so a hotkey in the same turn can target the previous canvas. | `LiveWindowGateway.swift:139-150`; `TilingController.swift:236-238,277-287,1279-1284` |
| L9 | Refused writes arm an echo nothing verifies (`markExpected` runs before the `setFrame` guard); `untileAll`'s primer is immediately cleared by `restore`'s `forget`. | `FrameWriter.swift:91-95,111`; `TilingSpace.swift:969-974,722,705-710` |
| L10 | `verifyConvergence`'s `on space:` parameter is unused; the rollback lands on the window's current canvas, not the scheduled one. | `TilingController.swift:429-432` vs `:448-471` |
| L11 | Reassert/reflow writes share the placement convergence check, so a re-push that draws total echo silence for 3.5 s calls `discard`/`forget` — untiling a window as a side effect of resize propagation. | `TilingSpace.swift:857-868`; `TilingController.swift:448-472` |
| L12 | The status glyph re-resolves the focused canvas twice per pass and carries no display identity in its accessibility description, so VoiceOver can't tell which monitor it depicts. | `AppDelegate.swift:206-211,455`; `TilingController.swift:1218-1220,1321-1328`; `StatusIcon.swift:69-73` |

---

## Verified solid (traced, not just read)

- **Display identity is display-based, not order-based.** `ScreenID` prefers the CG number,
  index only as a `0` fallback (`DisplaySpace.swift:22-24,87-96`); reorder/unplug/replug pinned
  (`DisplayIdentityTests.swift:71-166`).
- **Space identity round-trips by UUID, not index**, with an unambiguous single-display fallback
  (`LiveWindowGateway.swift:470-505`; `LiveGatewayMappingTests.swift:117-196`).
- **Per-display, per-Space canvases are independent**, including the same slot on two Spaces and
  on two displays sharing one Space id (`SpaceIndependenceTests.swift:67-161`).
- **One visible frame per canvas; every rect derives from it** — placement, reflow, undo,
  untile-all, expand/retile, and the pure plan all read the canvas frame
  (`PerMonitorTests.swift:426-459`; `TilingSpace.swift:750-776`).
- **All reassert trigger sources route to the canvas's stored frame** (edge-drag mouse-up,
  title-bar snapback, display change, swipe back, splitter reset); the tracker computes no rects.
- **Off-Space writes are deferred and the canvas marked stale**; reflow's deferral is genuinely
  reconciled on swipe-back (`SpaceIndependenceTests.swift:338-415`; `FrameWriter.swift:73-80`).
- **The no-op skip prevents phantom silent-ignore evictions** (`FrameWriter.swift:81-90`;
  `ControllerGatewayTests.swift:394-419,455-494`).
- **Convergence consulting is careful**: the live frame is read before silence is called an
  ignore, and an unreadable frame is "can't judge" (`DragTracker.swift:237-265`).
- **Clamped writes are repinned against the canvas's frame**, preserving a straddling pre-tile
  restore (`FrameWriter.swift:118-148`; `FrameWriterTests.swift:130-211`).
- **Death is not a single failed probe**: liveness falls through to app-list/frame confirmation
  or process death; destroy only accelerates (`LiveWindowGateway.swift:212-273,742-768`).
- **The pure reassert core is isolated and value-tested** (`TilingSpace.reassertPlan`,
  `ReassertPlanTests.swift:42-193`).
- **No production-reachable force-unwraps / `try!` / `fatalError`** found in scope.

---

## Test gaps (each maps to a finding)

- **M1**: no cross-canvas evict → re-tile on B → undo A case; no "one record per handle" assertion.
- **M6**: no test presses Evict on an untiled window, nor asserts record state after a *refused*
  first tile.
- **M7/M8**: `SpaceIndependenceTests` covers a withheld canvas only with the display attached;
  `DisplayIdentityTests` stops before a hotkey after unplug. No nil-Space + unplug interaction.
- **M2**: `LidSleepWakeTests` runs with `pruneInterval: nil` and never drives liveness.
- **M9/M10/M12**: `SpaceIndependenceTests` asserts a hidden placement rolls back but never asks
  whether it should be re-tried; no hidden-canvas eviction; hidden expand covers only the "no
  write" half.
- **M11**: no test that undo's `applyLayout` schedules (or fails to schedule) verification.
- **M13**: no slow-write / mid-action Space-cache scenario; `FakeGatewayFidelityTests` exercises
  one shape of four (`FakeWindowGateway.swift:29,39,44`).
- **M14/M16**: no duplicate-`screenName` case; no display with two canvases.
- **D1 (retired)**: no cross-display snapback regression test — add one so a future tracker refactor
  cannot reintroduce D17.
- **L6/D5**: no controller-level test of the full `visibleScreen`/`screenInfo` fallback chain.
- **Cross-cutting**: no test drags across two canvases at all
  (`DragTrackerTests.swift:44-89` leaves `spaceOf`/`occupantsOf` unset).

---

## Recommended fix families (triage order)

1. **Ownership invariant** — M1 + M6 + L2: "at most one canvas holds a record per handle; a record
   exists only while the window is tiled." One rule, enforced in the controller and the undo path.
2. **Sleep-safe death standard** — M2: monotonic confirmation (or tick-counter) + accept a moved
   listed frame as alive. Closes the lid-wake data-loss class.
3. **Write-policy coverage** — M3 + M4 + M9 + M10 + M12 + L9: one contract for `.deferredOffSpace`
   across placement/reflow/restore/expand, restore routed through the policy, deferred intent
   retained for swipe-back, and a distinct "Space unknown" narration that is not an app refusal.
4. **Removed-display visibility** — M7 + M8 + L5: visibility requires the screen to be attached;
   don't overwrite an absent display's stored frame; clear the stale mark only on a real write.
5. **Presentation correctness** — M14 + M16 + L12: group and match canvases by `ScreenID`, not
   name; give the status glyph one canvas key per pass and a display-aware accessibility label.
6. Remaining Low items (L1, L3, L4, L6, L7, L8, L10, L11) as capacity allows.

Each family is an `/implement`-ready unit; its test-gap row is its red tests.
