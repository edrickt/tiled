# 02: A layout switch's destruction stays undoable

**What to build:** A layout switch untiles every tiled window on the canvas — the most destructive
action in the app. If the requester's own placement is then refused by its app, all of that
destruction must still be recoverable with one undo. This is the promise the tile branch already
keeps ("the evictees really did go home, and without it that destruction would be silent and
unrecoverable"); the switch branch drops the undo chapter in exactly that case. Make the switch
branch keep it.

**Blocked by:** None (can start immediately).

**Findings:** report D1 (`.scratch/robustness-audit/report.md`).

**Status:** ready-for-agent

- [ ] After a switch that untiled one or more windows and whose placement did not land cleanly,
      one undo brings every untiled window home.
- [ ] The refused placement is still surfaced (refusal message), while the mass untile remains
      undoable — the two coexist exactly as the tile branch's pinned behaviour prescribes.
- [ ] The switch case is pinned by a test mirroring the tile branch's "refused placement after
      evictions keeps the destruction undoable" test.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
