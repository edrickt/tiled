# 11: Presentation copy matches the undo model

**What to build:** The user-visible labels must describe what the app now does:

- the re-house notice names the slot the window finally holds after reflow, not the intermediate
  re-house slot;
- undo is "last displacement", not "last switch", and a swap is not narrated as "evicted";
- modified arrow keys render as keycaps, not hex;
- the Disable-all tooltip says it parks the current combos, not that it keeps defaults.

**Blocked by:** None (can start immediately).

**Findings:** F13, F15, F16, F17 (`.scratch/quality-audit/report.md`).

**Status:** TODO

- [ ] A re-housed window that then grows into a reflowed slot is named at its final slot.
- [ ] Menu and Shortcuts labels use displacement language; swap chapters do not say "evicted".
- [ ] Modified arrow keys and forward-delete render as readable keycaps in labels and VoiceOver.
- [ ] The Disable-all tooltip matches the park-and-restore behavior.
- [ ] Tests pin the new strings and the final-slot notice.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
