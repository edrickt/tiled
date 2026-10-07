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
