# 03: Menu-bar presenter and honest snapshot

**What to build:** a `MenuBarPresenter` owning one
`MenuBarSnapshot { menu: MenuModel.Snapshot; icon: StatusIcon.Snapshot }`,
the last-snapshot diff, `menuOpen`, NSMenu construction, and status-item
show/hide; a `StatusIconRenderer` (snapshot in, `NSImage` out); and one
`MenuReads` value built from the canvas key so `activeWarnings` cannot
re-resolve focus. Put hotkey labels in the snapshot so
`MenuModel.items` needs no live binding closure, then delete
`force: true`. Collapse `Feedback` and the four receipt-overlay fields
into `ActionReceipt` plus one `NoticePresentation`.

**Why:** the AppDelegate mixes launch, permission, status icon,
refresh policy, snapshot assembly, menu wiring, settings/hotkey
lifecycle, actions, and the menu delegate in 1,076 lines. The setup
path resolves focus twice; the snapshot's equality is a lie for labels,
so every binding edit bypasses the diff.

**Findings:** `../report.md` "Still open 3"; `../slices/04-presentation.md`
P1–P3, P5.

**Status:** DONE (5411987)

- [x] A characterization test pins the current menu/icon output for a
      fixed canvas set, including label-only remaps.
- [x] `MenuBarSnapshot` carries everything the menu reads; `force:` is
      deleted.
- [x] Presenter and renderer extracted; AppDelegate keeps launch,
      permission, lifecycle, actions, and receipt presentation.
- [x] Gates in `../README.md` all pass for build, tests, and the
      published count. The mutation table is the coordinator's final
      gate per `AGENTS.md` and was not run here.

## Comments

Commits: `aeb1cef` pins the current menu, submenu, icon, and
slot/expand announcement output; `3a0d4ed` adds `MenuReads` and reads the
canvas's own error and warnings once; `8047d2d` puts hotkey labels in the
snapshot and deletes `refreshMenu(force:)`; `4f5d67b` extracts
`StatusIconRenderer`; `4449814` extracts `MenuBarPresenter` and
`MenuBarSnapshot`; `e585d31` returns `ActionReceipt` from slot and expand
actions and replaces the receipt fields with `NoticePresentation`;
`19f2564` pins the presenter's label-only snapshot diff; `5411987`
points the remaining presentation prose at receipts.

Shapes: `MenuReads` is one scoped pass over a resolved canvas key (canvas,
tile error, hotkey warnings, rows, trust, focused-window answer, expand
state, labels, per-display layouts). `MenuModel.Snapshot` carries
`[HotkeyAction: String]` labels, so `MenuModel.items(snapshot:)` is pure.
`MenuBarSnapshot { menu: MenuModel.Snapshot; icon: StatusIcon.Snapshot }`
is the presenter's one value. `MenuBarPresenter` owns the last snapshot,
`menuOpen`, NSMenu construction, show/hide, `RefreshPlan`, and
`NoticePresentation`; it never queries the AX gateway. `StatusIconRenderer`
takes a snapshot and returns the `NSImage`. `NoticePresentation` owns
`present`/`clear`/`overlay` plus the action generation.

Behavior preserved: the characterization suite pins literal menu order,
titles, enabled states, submenu rows, and the literal icon snapshot; every
refusal, no-op, already-tiled, expand-refusal, and deferral sentence still
comes from `MenuText`; all five notice-overlay cases are pinned; a silent
slot/expand success stays silent; a background receipt still overlays the
focused canvas's menu. A label-only remap now changes snapshot equality
and rebuilds through the ordinary diff. The cross-canvas warning read is
gone: a menu pass for a background canvas carries that canvas's tile
error. Gates run: `swift build` (no warning or error output), `swift test`
(900 tests, 1 skipped, 0 failures), and `./scripts/check-test-count.sh`
(README's 900 matches). The mutation table was not run; it is the
coordinator's final gate.

Design notes: a late silent-ignore convergence rollback has no action
caller, so it presents through `onLateReceipt` rather than losing its
spoken refusal. Slot and expand deferrals report `performed: true` because
a deferral is never a failure. The haptic now follows the receipt's
announcement (non-nil speaks and haptics, nil stays silent), matching the
ticket's one-haptic rule; previously only unsuccessful receipt actions
hapticked. The presenter still uses `AppDelegate.menuWiring` because the
selectors live on the delegate.
