# First UI batch review

Reviewed `git diff b4ee077...317570d` in independent Standards and Spec reviews.
Approved scope: `ui-first-batch.md`. Final code validation: 587 tests passed.

## Standards

### Hard violations

None found. Changed code follows documented domain terminology and surrounding
AppKit conventions; the required `swift test` validation passed.

### Judgment calls — low-priority smells

- **Primitive Obsession — `Sources/tiled/SlotPreviewView.swift:58–64`,
  `Sources/tiled/SettingsWelcomeTab.swift:107–109`.**
  Hunk: `case 2: displayCol = col / 2`, `case 3: …`,
  `default: displayCol = col`; caller: `displayColumns: 2`.
  The change extends an existing integer parameter whose values represent
  specific projection modes, not arbitrary column counts. A small enum such as
  refinement/quarters/sixths would communicate that contract explicitly and
  keep projection semantics inside the renderer. This is an optional interface
  improvement, not a documented-standard violation.

- **Duplicated Code — new test traversal helpers.**
  `Tests/tiledTests/ShortcutsGuidanceTests.swift:7–9`:
  `[view] + view.subviews.flatMap { descendants(of: $0) }`.
  `Tests/tiledTests/WelcomeInstructionsTests.swift:27–30`:
  `own + view.subviews.flatMap { labels(in: $0) }`.
  `Tests/tiledTests/SlotPreviewRenderingTests.swift:7–13` also recursively
  traverses `view.subviews` to find a matching preview. These introduce three
  versions of the same view-tree walk. A shared test-only descendant helper
  could centralize traversal while retaining each test's local predicate.
  Given their small size, leaving them local is also reasonable.

No other concrete baseline smells found in the reviewed changes.

Disposition: retain the existing renderer interface and small local test
helpers for this batch; these optional cleanup opportunities do not block it.

## Spec

No findings.

The approved three-item batch is implemented: Quarters renders as 2×2 with one
highlighted quarter; Welcome reflects customized/disabled bindings and explains
the Sixths menu fallback; recording guidance precedes the list and is visible
in the minimum-size capture.

Shortcut-change callbacks preserve app hotkey/menu refresh while updating
Welcome. No engine changes or unauthorized broader UI work found. Deferred
VoiceOver, menu, and end-to-end checks are not treated as missing implementation.

## Summary

Standards: 0 hard violations, 2 low-priority heuristic findings (projection-mode
integers and repeated test traversal). Spec: 0 findings. Neither axis found a
blocking issue.
