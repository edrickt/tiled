# 02: Observe the Reflow recovery rewrite on a refused grow write

**What to build:** When a Reflow grow write is refused, the recovery
re-write of the old rects discards its outcome
(`Sources/tiled/TilingSpace.swift:1143-1155`). Observe the recovery
pass; on refusal, surface the shared refusal message on the canvas (the
`writeRects` helper at `:1177-1196` already owns that message).

**Findings:** Follow-up audit F22 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] A refused recovery rewrite is announced instead of silent
- [ ] `Tests/tiledTests/ReflowTests.swift:398-411` gains a refused-recovery case
- [ ] Gates: `swift build` warnings empty, `swift test` green, `check-test-count.sh` pass
