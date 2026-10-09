# 08: The tested routing table routes

**What to build:** When a registered hotkey fires, production must route it through the same routing
rule the tests pin. Today the routing rule exists in two shapes: production builds its own lookup,
while the flagship "callback routing table" test exercises a different construction production never
calls. A drift in an action's hotkey id then passes every test and silently misroutes (or kills) a
live global hotkey. One routing rule, one shape, and the tests pin the shape that runs.

**Blocked by:** 07 (collision serialisation — the pair shares the hotkey service's files).

**Findings:** report D20 (`.scratch/robustness-audit/report.md`).

**Status:** ready-for-agent

- [ ] Hotkey dispatch consumes the pinned routing rule; the duplicate construction is gone.
- [ ] A deliberate id-switch drift makes a test fail (name the test that would catch it).
- [ ] Every action still routes to exactly its own handler (existing uniqueness pinning survives).
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
