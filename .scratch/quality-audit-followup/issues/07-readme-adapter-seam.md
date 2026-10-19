# 07: Name the hermetic adapter seam in the README (docs)

**What to build:** `README.md:285-289` still partitions the live
adapter to the live suite only, although the Space cache, observer
routing, destroy delivery, adoption, release pruning, and write-pair
recovery run hermetically in
`Tests/tiledTests/LiveGatewayWiringTests.swift:11-397`. Add one
sentence naming the hermetic adapter seam beside the live-suite
sentence; optionally name the residual live-only paths (focus
resolution, element registry fallback, app-list assembly).

**Findings:** Follow-up audit F27 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] README names both the hermetic seam and the live suite for `LiveWindowGateway`
- [ ] `./scripts/check-test-count.sh` still passes (docs-only change)
- [ ] No `_Avoid_` glossary terms in the new prose
