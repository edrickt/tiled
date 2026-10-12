# 11: Menu sections key on the display

**What to build:** The manage list must group and match by display identity, not display name.
`monitorPresentation` groups rows with `Dictionary(grouping: rows, by: \.screenName)` and keys each
section by `row.screenName` (`AppDelegate.swift:497-511`), and `MenuModel` matches rows to sections
by `screenName == section.key` (`MenuModel.swift:245-254`) — even though each row already carries
the stable `screen: ScreenID?` (`TilingController.swift:997-1006`). Two simultaneously connected
displays with the same `localizedName` (or two unlabeled ones, which both fall back to the literal
`"Display"`, `AppDelegate.swift:507`) collapse into one section with one layout. A display with
both an identified and a withheld canvas can likewise double-list under one name-keyed section
(`TilingController.swift:1040-1057`).

Group and match by `ScreenID`, using `screenName` only for the header text.

**Blocked by:** None (can start immediately).

**Findings:** report M14, M16 (`.scratch/multi-display-audit/report.md`).

**Status:** ready-for-agent

- [ ] Two displays sharing a name render as two sections, each with its own layout and count.
- [ ] Two unlabeled displays no longer merge into one `"Display"` section.
- [ ] A display with both an identified and a withheld canvas lists each window once, under that
      display's section.
- [ ] The header still shows the human-readable display name; the section key is the `ScreenID`.
- [ ] Pinned by tests: duplicate-`screenName` case; two-canvas-per-display case.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
