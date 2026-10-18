# 17: Literal expectations for end-to-end tests

**What to build:** End-to-end tests must use expected values from outside the implementation. Some
currently compute rects through `TilingSpaceHarness.rect` (the canvas's own grid) or assert an
error equals `TilingSpace.refusalMessage(count:)` (the function under test), so a shared bug can
pass. Pin one literal rect per layout and one literal refusal string, and correct the two test
comments that describe the opposite motion ("grows down" / "70pt above").

**Blocked by:** None (can start immediately).

**Findings:** T5, F19 (`.scratch/quality-audit/report.md`); CODING_STANDARDS "Tests read as
behavior specs".

**Status:** DONE (e7e8b8a)

- [ ] One literal rect per layout is asserted end to end without the canvas grid helper.
- [ ] One refusal message is asserted as a literal.
- [ ] The two misleading test comments/names are corrected.
- [ ] The helper remains for structural tests, but the acceptance tests do not derive their
      expected value from it.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
