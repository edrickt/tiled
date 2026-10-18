# 19: Conflict and registration-failure UI are pinned

**What to build:** The Shortcuts tab's inline conflict message and registration-failure rows must
be tested through the real controls. The store gate and menu warning text are pinned, but no test
reads the tab's labels after a rejected duplicate or a failed action.

**Blocked by:** 09 (the registration-failure provider it shares).

**Findings:** T7 (`.scratch/quality-audit/report.md`).

**Status:** DONE (66df049)

- [ ] Recording a duplicate keeps the old binding and shows a conflict label naming the owner.
- [ ] A failed registration surfaces beside the recorder that accepted the combo.
- [ ] The messages clear when the conflict is resolved.
- [ ] Tests drive the real recorder/tab controls against temporary defaults.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
