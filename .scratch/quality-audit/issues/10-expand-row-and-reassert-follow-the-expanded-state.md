# 10: Expand row and reassert follow the expanded state

**What to build:** The menu's Expand row must say "Return to …" for an expanded untiled window,
not "Expand to Fill Screen". A pending edge reassert must not reconcile splitters from an expanded
window's screen-sized frame; expanding a window ends or discards the pending resize.

Today `expandedFocusedSlot` returns nil when the expanded window has no slot, and `reconciledGrid`
does not exclude expanded windows even though `reassertPlan` does.

**Blocked by:** None (can start immediately).

**Findings:** F11 and F12 (`.scratch/quality-audit/report.md`).

**Status:** DONE (4509e2e)

- [ ] An expanded untiled window's menu row says it will return to the previous frame.
- [ ] An expanded tiled window's row still names its slot.
- [ ] Expanding a window with a pending edge reassert prevents a splitter rewrite from the
      full-screen frame; the next mouse-up is a no-op or a safe grid reassert.
- [ ] Tests cover the row state and the pending-reassert sequence.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
