# First UI improvement batch

## Approved scope

The user approved this one-session batch after the UI audit:

1. Correct the Quarters preview to show a 2×2 layout.
2. Make Welcome instructions accurate for customized or disabled shortcuts.
3. Put shortcut-editing guidance above the list.

Broader styling, menu changes, new features, and tiling-engine changes are not
part of this batch. The review baseline is `b4ee077`, confirmed by the user.

## Changes

- Welcome renders quarters as two columns and sixths as three; internal slot
  geometry is unchanged.
- Welcome reads the current Top Left binding. A disabled binding teaches the
  menu action, including Switch to Quarters when Sixths is active, and points
  to Shortcuts without enabling or replacing a binding.
- Instructions refresh when the guide reopens, Settings reloads, or the
  Shortcuts tab changes a binding. The guide no longer promises default modifier
  families for customized bindings.
- The Welcome headline no longer promises a keypress when the shortcut is disabled.
- Recording, Escape, and disable guidance appears above the first shortcut
  section. Reset/restore stays in the footer; all 17 recorders remain.
- The README's first-launch shortcut example now matches the quarters default.

## Agreed test boundaries

- Built Welcome view: default, customized, disabled, and refreshed instructions.
- Rendered Welcome Quarters preview: two columns and one highlighted quarter.
- Built Shortcuts view: guidance precedes recorders and is visible at default
  and minimum sizes; all recorders remain available.

Tests use isolated preferences. No private methods or real tiling actions are
used to validate these changes.

Validation: each regression was observed failing before its fix; focused tests
then passed. Final `swift test`: 587 tests passed, zero failures. `git diff
--check` passed. Screenshot review confirms the corrected diagram, current and
disabled binding text, and guidance visible at the minimum window size.

Independent [Standards and Spec review](ui-first-batch-review.md) found no
blocking issues: zero documented-standard violations, two optional cleanup
suggestions, and zero spec findings.

## Visual evidence

Captures use the actual Settings views compiled from the current checkout in an
isolated helper, not the installed app. No global shortcuts are registered by
the helper. Window captures may show inactive chrome depending on focus.

| Surface | Before | After |
| --- | --- | --- |
| Welcome, light | [Before](ui-audit-captures/welcome-light-default.png) | [After](ui-audit-captures/after/welcome-light-default.png) |
| Welcome, dark | [Before](ui-audit-captures/welcome-dark-default.png) | [After](ui-audit-captures/after/welcome-dark-default.png) |
| Shortcuts, minimum size | [Before](ui-audit-captures/shortcuts-light-minimum.png) | [After](ui-audit-captures/after/shortcuts-light-minimum.png) |

Additional captures cover all three tabs, both appearances, default/minimum
sizes, and [disabled](ui-audit-captures/after-disabled/welcome-light-default.png)
and [customized](ui-audit-captures/after-customized/welcome-light-default.png)
Welcome instructions.

## Remaining work

The broader plan in `ui-improvement-plan.md` remains active. Permission/menu
captures, VoiceOver navigation, native scroll interaction, subgroup alignment,
and broader polish are not claimed complete by this batch. The installed app
has not been rebuilt or replaced.
