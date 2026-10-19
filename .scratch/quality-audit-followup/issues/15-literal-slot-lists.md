# 15: Pin literal slot-name lists for both submenu layouts

**What to build:** `Tests/tiledTests/MenuModelTests.swift:171,194-198`
compare the submenu's slots to the same `SlotPresentation` constants
`MenuModel.items` iterates (`Sources/tiled/MenuModel.swift:185-190,208-219`),
so a slot dropped from both stays green. Assert one literal slot-name
list per layout (as ticket 17 did for rects and the refusal string),
keeping the constant-derived form as a secondary shape check.

**Findings:** Follow-up audit T10 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] One literal slot-name list per layout in `MenuModelTests`
- [ ] Gates: `swift build` warnings empty, `swift test` green, `check-test-count.sh` pass
