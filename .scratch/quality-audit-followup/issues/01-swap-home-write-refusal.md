# 01: Read the Swap home-write through the write policy

**What to build:** When the requester write of a Swap is refused, the
displaced window's home-write outcome is currently discarded
(`Sources/tiled/TilingSpace.swift:629-639`). Read it through the shared
write policy; on refusal, surface the shared restore-failure message on
the canvas instead of keeping a silent state/display disagreement.

**Findings:** Follow-up audit F21 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] A refused home-write after a refused requester write names the failure on the canvas
- [ ] `Tests/tiledTests/TilingSpaceTests.swift:311-330` gains a refused-second-write case
- [ ] Gates: `swift build` warnings empty, `swift test` green, `check-test-count.sh` pass
