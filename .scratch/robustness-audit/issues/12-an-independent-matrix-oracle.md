# 12: An independent matrix oracle

**What to build:** The matrix cross-check compares the canvas against a model of the plan rules — but
the model's re-housing expectation is computed by the very pure function the canvas calls, so a
wrong re-housing home is agreed with, not caught. The cross-check's job is divergence detection
between canvas and model; rule correctness must rest on expectations that are written independently
of the code under test. Give the cross-check an oracle that states the expected outcome per matrix
case in its own terms, and make its survivor assertions check content rather than presence.

**Blocked by:** None (can start immediately).

**Findings:** report Q1 (`.scratch/robustness-audit/report.md`).

**Status:** ready-for-agent

- [ ] The re-housing expectation per matrix case is stated independently (explicit expected homes),
      not derived from the function under test.
- [ ] A deliberate bug in the re-housing rule turns the cross-check red (name the mutant-like
      provocation you used and show it fails).
- [ ] Survivor assertions verify which slot each survivor holds (cells/rect), not mere presence.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
