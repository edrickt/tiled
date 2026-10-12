# 12: One canvas key per icon pass

**What to build:** The status glyph must depict one canvas, resolved once per pass, and must name
its display to assistive tech. `AppDelegate.iconSnapshot` takes the display from
`controller.focusedScreen` and passes it to `canvas(for:)`, which re-resolves the Space via
`actionSpaceKey` at call time (`AppDelegate.swift:206-211`; `TilingController.swift:1218-1220,1321-1328`),
while the menu snapshot instead captures one `focusedTilingSpace` key for the whole pass
(`AppDelegate.swift:455`). A focus/display change landing between the two reads yields a glyph for a
different canvas until the next callback. Separately, neither the glyph nor
`StatusIcon.accessibilityDescription` names the display (`StatusIcon.swift:69-73`), so a VoiceOver
user cannot tell which monitor the icon depicts, though the menu headers do name it.

Read one `focusedTilingSpace` key per icon pass (mirror `menuSnapshot`), and append the screen name
to the accessibility description when more than one display is attached.

**Blocked by:** None (can start immediately).

**Findings:** report L12 (`.scratch/multi-display-audit/report.md`).

**Status:** DONE (1b2b6a0)

- [x] The icon snapshot resolves its canvas once per pass; a display change cannot make the menu
      and icon disagree mid-pass.
- [x] With more than one display, the icon's accessibility description names the display it
      depicts; with one display it is unchanged.
- [x] Pinned by tests: single key per pass (no second `actionSpaceKey` read), and the
      accessibility description in single- vs multi-display.
- [x] Gates green: warning-free build, full suite, every mutant CAUGHT.
