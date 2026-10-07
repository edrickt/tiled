# UI improvement plan

Status: approved direction; source audit recorded in `.scratch/ui-polish/ui-audit.md`.
Rendered Settings screenshot audit completed using isolated current-source
views; menu, permission, and interaction checks pending. First implementation
batch completed; see `.scratch/ui-polish/ui-first-batch.md` for its scope and evidence.
The user accepted that batch; shortcut subgroup alignment is implemented in
the next batch documented in `.scratch/ui-polish/ui-shortcut-groups.md`.

## Goal

Refine Tiled as a native macOS utility, prioritizing usability before visual
polish. Preserve familiar workflows and focus on three tasks:

1. Tile a window.
2. Customize shortcuts.
3. Recover from permission or shortcut problems.

This plan is based on the current source code, not a live visual audit.
Proposed improvements are candidates to validate, not confirmed UI defects.

## Guardrails

- Keep programmatic AppKit controls, semantic system colors, and native macOS conventions.
- Preserve keyboard navigation, VoiceOver announcements, and deliberate focus restoration.
- Preserve existing shortcuts, window behavior, permission recovery, and reversible actions.
- Use the domain language in `CONTEXT.md`: slot, layout, Space, canvas, splitter, and Expand.
- Avoid changing the tiling engine to accomplish presentation improvements.

## Implementation sequence

### 1. Audit the live UI

Capture the menu, permission onboarding, Welcome, General, and Shortcuts.
Check light and dark appearance, default and minimum window sizes, permission
denied/granted states, shortcut failures, and multiple displays where available.

Separate confirmed usability problems from visual preferences. Compare against
the current implementation rather than treating historical critiques as current.

Deliverable: annotated screenshots and a ranked list of confirmed improvements.
Record the baseline task flows for tiling, shortcut customization, and recovery.

### 2. Make shortcuts easier to scan

Primary file: `Sources/tiled/SettingsShortcutsTab.swift`.

- Improve row alignment, spacing, and section hierarchy based on the audit.
- Mirror the menu's slot subgroups where this reduces scanning effort.
- Evaluate small slot previews using `Sources/tiled/SlotPreviewView.swift`.
- Place recording guidance near the controls without adding repetitive clutter.
- Clearly distinguish recording, disabled, conflicting, and registration-failure states.
- Preserve collapse state, bulk enable/disable, backups, and focus restoration.

Acceptance: users can identify a slot, change its shortcut, understand a failure,
and recover without losing their existing configuration.

### 3. Simplify the Welcome guide

Primary file: `Sources/tiled/SettingsWelcomeTab.swift`.

- Emphasize one successful tiling action.
- Give the first action and layout previews clear visual hierarchy.
- Correct the confirmed Quarters preview mismatch: show two user-facing columns,
  not four internal refinement columns, without changing layout geometry.
- Move advanced behavior into secondary guidance while keeping it discoverable.
- Verify instructions against customized and disabled shortcut states.
- Preserve permission recovery and guide re-entry.

Acceptance: the first action is obvious, its instructions match actual bindings,
and the guide remains readable at the minimum window size.

### 4. Clarify menu actions and feedback

Primary files: `Sources/tiled/MenuModel.swift` and `Sources/tiled/AppDelegate.swift`.

- Review long labels and shorten them only where meaning remains explicit.
- Make layout-switch consequences understandable before acting.
- Clarify display/canvas scope for management actions.
- Keep warnings, recent outcomes, and current status distinguishable.
- Preserve existing slot grouping, undo, and actionable recovery links.

Acceptance: labels accurately describe action scope and consequences, and
recovery remains available when warnings are present.

### 5. Unify visual details

Primary files: the Settings tabs, `Sources/tiled/SettingsWindowController.swift`,
and `Sources/tiled/PermissionWindowController.swift`.

- Standardize typography, margins, section spacing, and button sizes.
- Use consistent permission-warning presentation across Settings surfaces.
- Keep the permission window's primary action prominent.
- Prefer existing native controls over custom decorative components.

Acceptance: related controls look and behave consistently without reducing
contrast, readability, or keyboard accessibility.

## Validation

For each implementation slice:

- Run `swift test` and add or update tests for changed presentation/state contracts.
- Manually check light/dark appearance and minimum window size.
- Check keyboard focus and VoiceOver labels/announcements.
- Exercise permission and shortcut failure/recovery paths.
- Capture before/after evidence for the relevant task flow.
- Confirm existing shortcuts, window behavior, and reversible actions remain intact.

Live GUI checks require Accessibility permission and may move real windows or
the cursor; coordinate those checks before running them.

## Out of scope

- New layouts or window gaps.
- Resize overlays or new resize interactions.
- Tiling-engine changes.
- A wholesale visual redesign or UI-framework migration.

## Next step

The first batch is implemented and reviewed. Complete the remaining live audit (see
`.scratch/ui-polish/ui-audit.md` for findings and access blockers) and choose the next small
implementation tasks in the sequence above. A runnable mockup is optional if a visual choice
cannot be settled from screenshots; it is not required for this planning phase.
