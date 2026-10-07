# Shortcut subgroup batch

## Approved scope

After trying and accepting the first UI batch, the user approved lightweight
subgroup labels in Shortcuts matching the existing menu:

- Quarters: Quads / Halves.
- Sixths: Corners / Thirds / Two-Thirds.

Keep existing bindings, collapsible layout sections, keyboard navigation,
and layout-wide bulk enable/disable actions unchanged. No subgroup-specific
controls, menu changes, new features, or tiling-engine changes are included.

## Implementation

`Sources/tiled/SettingsShortcutsTab.swift` uses the existing `SlotPresentation`
slot arrays used by the menu. Small bold labels in the semantic secondary text
color separate subgroups; modest spacing marks subgroup boundaries. Recorder
rows themselves retain their existing size, order, actions, and accessible
names. Labels are static text, not new keyboard stops.

Both layouts retain their existing disclosure controls and Enable/Disable all
buttons. Collapsing a layout removes its subgroup labels together with its
recorders. Guidance remains above the list; reset/restore stays in the footer.

## Validation boundaries

The previously agreed built-Shortcuts-view test boundary is reused with
isolated preferences. New regression coverage checks:

- The expected subgroup and recorder order, with a customized binding retained.
- Collapse and reopen behavior, subgroup visibility, and the first recorder.
- Sixths' layout-wide disable/enable action across all subgroups, with Quarters
  untouched and previous bindings restored.

The grouping regression was observed failing before adding the labels. The
focused grouping, guidance, and existing bulk-action tests then passed.

Final `swift test`: 590 tests passed, zero failures. The light/dark and
default/minimum-size screenshots were inspected; all five groups are visible
in the taller-window captures. `git diff --check` passed.

## Visual evidence

Captures use an isolated helper compiled from the actual Settings source, not
the installed app. No global hotkeys or window-management actions are run.

- [Before, default size](ui-audit-captures/after/shortcuts-light-default.png).
- [After, default size](ui-audit-captures/grouped/shortcuts-light-default.png).
- [After, minimum size](ui-audit-captures/grouped/shortcuts-light-minimum.png).
- [After, dark appearance](ui-audit-captures/grouped/shortcuts-dark-default.png).
- [All five subgroups, taller light window](ui-audit-captures/grouped-full-list/shortcuts-light-default.png).
- [All five subgroups, taller dark window](ui-audit-captures/grouped-full-list/shortcuts-dark-default.png).

Default/minimum-size views still require scrolling, as before. Headings add
some document height in exchange for easier scanning; no recorder is removed.
The taller screenshots show the entire list for inspection, not a new default
window size. VoiceOver navigation and installed-app end-to-end checks remain
separate from these source-view tests and screenshots.

## Standards review

Independent review used the same user-confirmed UI-work baseline:
`git diff b4ee077...956a999`. No documented-standard violations found. New
subgroup labels use native AppKit controls, semantic colors, existing domain
vocabulary, and shared `SlotPresentation` slot arrays. The README's test gate
passed with 590 tests.

Still-existing optional findings from the first batch:

- **Primitive Obsession:** `SlotPreviewView.swift` uses `case 2: displayCol =
  col / 2`, `case 3: …`, `default: displayCol = col`, with callers passing
  `displayColumns: 2`. A projection enum could clarify that existing interface.
- **Duplicated Code:** the small recursive test view-tree helpers could be
  shared. `ShortcutsGroupingTests.swift:26–28` adds another occurrence of
  `[view] + view.subviews.flatMap { descendants(of: $0) }`, already present in
  `ShortcutsGuidanceTests`. Its isolated-preferences fixture also resembles
  `WelcomeInstructionsTests`.

No distinct production-code smell was identified in the subgroup change.
Disposition: retain these small local helpers and the existing preview
interface; the optional cleanup opportunities do not block this batch.

## Spec review

No findings.

The five static subgroup labels match the existing menu arrays and preserve
all 17 recorders and their order. Native labels introduce no keyboard stops;
recorder accessibility names, collapse/rebuild focus restoration, bindings,
and layout-wide bulk actions remain unchanged.

Rendered evidence shows readable guidance at minimum size and all groups in
taller captures. No unauthorized menu, engine, or window-size changes found.
Deferred installed-app and VoiceOver checks are not missing batch requirements.

Summary: Standards has zero hard violations and two continuing low-priority
cleanup opportunities (test duplication gains a new occurrence); Spec has
zero findings. Neither axis found a blocking issue.
