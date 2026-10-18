# 07: One action receipt for menu and announcement

**What to build:** An action's user-visible truth — owning canvas, menu notice, and announcement —
must come from one place. Today `AppDelegate` announces success before the controller's
asynchronous no-op feedback arrives, so Undo with an empty stack says both "restored" and "nothing
to undo". The canvas's notice/Outcome and `MenuText` are also reassembled in the delegate.

**Blocked by:** 06 (the menu snapshot it reads).

**Findings:** F7 and A5 (`.scratch/quality-audit/report.md`).

**Status:** DONE (0b8c54b)

- [ ] Evict, Untile All, single-window untile, and Undo announce success only when the controller
      actually performed the action.
- [ ] A no-op announces exactly one message, never a success followed by a contradiction.
- [ ] The outcome carries the owning canvas and the text the menu/announcement needs, or one
      mapping module does; AppDelegate presents rather than reconstructs.
- [ ] A background-canvas refusal names the right canvas.
- [ ] Tests cover performed and no-op outcomes for each action.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
