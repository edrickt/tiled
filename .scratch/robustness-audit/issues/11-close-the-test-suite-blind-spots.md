# 11: Close the test-suite blind spots

**What to build:** Every rule the glossary states must be pinned by a test that fails when the rule
breaks. The audit found rules with no such test: the gap rules (an expanded window ignores the gap;
the gap is the same across layouts — sixths untested — and across displays and Spaces), and the
step-aside rule's one non-containment case (a left two-thirds blocking a right two-thirds request
steps aside into the left third). The shared harness also swallows what several bugs would manifest
as: neighbour pushes on the publish path, silent-ignore consequences, and (by defaulting the gap to
zero) the gap code itself. Close these blind spots without changing behaviour.

**Blocked by:** None (can start immediately).

**Findings:** report G1–G5, Q2, Q3 (`.scratch/robustness-audit/report.md`).

**Status:** ready-for-agent

- [ ] "An expanded window ignores the gap" pinned with a non-zero gap (a regression that gap-insets
      the expanded frame turns red).
- [ ] Gap pinned for sixths (shared-edge and screen-edge halves), and non-zero on a second display /
      Space.
- [ ] The step-aside non-containment case pinned in both directions (left two-thirds blocking a right
      two-thirds request, and the mirror).
- [ ] The harness observes the publish path and silent-ignore consequences; canvas tests run with a
      non-zero gap by default.
- [ ] The verify delay's wiring is exercised once through the production scheduler (arm → fire after
      the delay → cancelled check judges nothing).
- [ ] No behaviour changes: the suite stays green beyond the new pins, gates green (warning-free
      build, full suite, every mutant CAUGHT).
