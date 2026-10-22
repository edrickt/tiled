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

**Status:** TODO

- [ ] A characterization test pins the current menu/icon output for a
      fixed canvas set, including label-only remaps.
- [ ] `MenuBarSnapshot` carries everything the menu reads; `force:` is
      deleted.
- [ ] Presenter and renderer extracted; AppDelegate keeps launch,
      permission, lifecycle, actions, and receipt presentation.
- [ ] Gates in `../README.md` all pass.
