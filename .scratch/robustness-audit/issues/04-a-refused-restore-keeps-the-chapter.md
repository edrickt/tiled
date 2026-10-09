# 04: One refused restore no longer disarms the chapter

**What to build:** When an eviction (or switch) restores several windows home and one app refuses its
restore write, the windows that really did go home must remain undoable. Today a single restore
failure drops the whole undo chapter, so the successful restorations — real destruction — become
silent and unrecoverable, while the narration still claims the windows "went back to where they
were". Keep the chapter whenever windows were restored; let the existing failure precedence narrate
the refusal.

**Blocked by:** 02 (the switch branch's chapter guard is restructured there).

**Findings:** report D5 (`.scratch/robustness-audit/report.md`).

**Status:** ready-for-agent

- [ ] A partial restore failure (1 of N evictees refuses) leaves an undo chapter covering the
      evictions; undo returns the windows that went home.
- [ ] The refused restore is still surfaced as its restore-failure message, ahead of any success
      sentence (existing precedence).
- [ ] The mixed case is pinned by tests (partial failure + clean placement; partial failure in a
      switch).
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
