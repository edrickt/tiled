# 08: The restore goes through the write policy

**What to build:** The pre-tile restore must obey the same off-Space policy as every other write.
`restore(window:)` calls `context.gateway.setFrame` directly — no `isVisible` check, no echo
arming, no no-op skip (`TilingSpace.swift:716-724`). It is reached from `untile` (`:903`), `evict`,
controller undo (`TilingController.swift:837-858`), `applySwitchLayout` (`:387`), `applyTile`
(`:527-528`), `untileAll` (`:985`), and the re-house fallback (`:549,553`). The eviction restores
in `applyTile`/`applySwitchLayout` run *before* the requester's `place`, so on a hidden canvas the
policy-compliant `place` defers and rolls back while the restores have already dragged the hidden
windows through Mission Control and forgotten their records — the exact hazard the policy exists
to prevent.

Route restores through the write policy (or a policy-aware restore) so off-Space restores defer
and reconcile, while keeping the straddling pre-tile behaviour (`FrameWriter.swift:118-124,198-211`).

**Blocked by:** None (can start immediately).

**Findings:** report M4 (`.scratch/multi-display-audit/report.md`).

**Status:** DONE (2fcb3aa)

- [ ] A pre-tile restore to a window on an invisible canvas defers instead of writing (no
      Mission-Control pull), and is reconciled on swipe-back.
- [ ] A restore to a visible canvas is unchanged: the pre-tile frame is written, the slot released,
      and a straddling pre-tile frame is still left where the app put it.
- [ ] The restore participates in echo/no-op handling like other writes (no phantom expectation,
      no swallowed drag tick).
- [ ] Pinned by tests: hidden-canvas eviction → no direct write + reconcile on return; visible
      restore unchanged; straddling pre-tile restore preserved.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
