# 06: Clear the memoized focus answer on release

**What to build:** `focusedWindow` returns the memoized handle without
revalidating it (`Sources/tiled/LiveWindowGateway.swift:355-367`), and
`release` never clears it (`:440-454`), so a released handle can answer
the focused-window query inside the 0.05 s window. Clear the memoized
focus answer in `release` when it names the released handle (and route
its stamps through the injected `now`, see ticket 14).

**Findings:** Follow-up audit F26 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] A released handle never answers `focusedWindow` after its release
- [ ] Hermetic pin through the adapter seam where possible (see ticket 14 for the clock half)
- [ ] Gates: `swift build` warnings empty, `swift test` green, `check-test-count.sh` pass
