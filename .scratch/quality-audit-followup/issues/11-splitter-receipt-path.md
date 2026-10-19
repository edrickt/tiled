# 11: Bring the splitter actions onto the receipt path (or document the silence)

**What to build:** Menu `resetDividers` announces fixed sentences
without a controller verdict
(`Sources/tiled/AppDelegate.swift:888-906`), while the hotkey route
announces nothing (`Sources/tiled/HotkeyActionRouter.swift:72-74`);
the controller returns `Void`/`Bool`, never an `ActionReceipt`
(`Sources/tiled/TilingController.swift:857-898`), and the restore
sentence is worded twice (`Sources/tiled/TilingSpace.swift:1504` vs
`AppDelegate.swift:894`). Return an `ActionReceipt` from the splitter
actions (or document the silence as intended), route both surfaces
through `present(_)` (`:925-937`), and source the restore sentence
once. A refused splitter write has no refusal sentence on either
surface today.

**Findings:** Follow-up audit F31 (`.scratch/quality-audit-followup/report.md`).

**Status:** TODO

- [ ] Splitter actions share one verdict path (or the intended silence is documented and pinned)
- [ ] Receipt tests cover the splitter actions, or the documented silence is pinned
- [ ] Gates: `swift build` warnings empty, `swift test` green, `check-test-count.sh` pass
