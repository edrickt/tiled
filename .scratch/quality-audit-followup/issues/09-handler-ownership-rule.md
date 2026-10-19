# 09: State the shared hotkey handler ownership rule

**What to build:** Registrations retire on service deinit
(`Sources/tiled/HotkeyService.swift:222-224`), but the handler lives on
the process-wide shared context (`:187-203`) and is never cleared, so a
replaced service's closure stays armed until the next assignment (a
dropped fire at worst — the AppDelegate call site captures weakly at
`Sources/tiled/AppDelegate.swift:180`). State the ownership rule at the
handler declaration (who clears, and when), or pin replacement ordering
through the registrar seam.

**Findings:** Follow-up audit F29 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] Handler behavior across service replacement is stated and pinned
- [ ] New test through the registrar seam (`Tests/tiledTests/HotkeyRegistrationTests.swift`)
- [ ] Gates: `swift build` warnings empty, `swift test` green, `check-test-count.sh` pass
