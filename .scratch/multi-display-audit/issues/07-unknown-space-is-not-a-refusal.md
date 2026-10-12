# 07: Unknown Space is not an app refusal

**What to build:** "The window server cannot name the visible Space" must not be mistaken for
"the canvas is hidden". `isVisible` returns `false` for any key with a non-nil Space id when
`activeSpaceID(on:)` answers nil (`TilingController.swift:1291-1294`), and the Space cache stores
an empty/parse-failed table for its whole 0.1 s TTL even though a single `setFrame` can block
~3.3 s plus ~1 s frame reads (`LiveWindowGateway.swift:391-412,418-429,404,51,884-922`). The
resulting `.deferredOffSpace` then makes `place` narrate the standard resize-refusal message
(`TilingSpace.swift:690-697`), so a visibly-correct app is told "the app refused to resize it" and
the placement is discarded when the real cause was a Space-table hiccup.

Distinguish "Space unknown" from "known different Space": on unknown, defer *without* the refusal
vocabulary and retain the intent for swipe-back (the withheld-Space path already treats unknown as
visible, `TilingController.swift:1292`), or re-probe before deciding.

**Blocked by:** 05 (the contract decides what a deferral does).

**Findings:** report M3 (`.scratch/multi-display-audit/report.md`).

**Status:** DONE (2e0637d)

- [ ] A placement whose canvas's Space cannot be named (empty/parse-failed table) is not narrated
      as an app refusal, and does not claim the app refused anything.
- [ ] The unknown-Space case is distinguishable from the genuinely-hidden canvas case in the write
      result and in the narration.
- [ ] A genuinely visible canvas is not rolled back because of a transient unknown read (re-probe,
      or treat unknown as visible and reconcile).
- [ ] Pinned by tests: unknown-Space read → deferral narration (not refusal); genuinely-hidden
      canvas → existing deferral behaviour unchanged.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
