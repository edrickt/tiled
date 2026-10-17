# 16: One hotkey route, not a dead table

**What to build:** The Carbon callback and the routing test must consume the same mapping. Today
`HotkeyService.route` is called only by tests; the callback routes through `Context.actionByID`, a
second table. Delete the dead table or make the callback use it, and pin the production path.

**Blocked by:** 13 (the testable hotkey service).

**Findings:** T4 and A4 (`.scratch/quality-audit/report.md`); robustness-audit D20.

**Status:** TODO

- [ ] One routing declaration is consumed by production and its test.
- [ ] Every action's Carbon id routes to that action; unknown ids fall through unhandled.
- [ ] Adding an action cannot be present in one map and absent from the other.
- [ ] The dead table is deleted or put on the production path.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
