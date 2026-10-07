# UI audit

## Evidence and limits

This audit combines source inspection with rendered Settings screenshots from
the current checkout. Keyboard, VoiceOver, live menu, and window-management
checks have not been completed.

The attempted live audit found Screen Recording preflight access unavailable;
the System Events UI-automation probe timed out. An installed
`/Applications/Tiled.app` instance was also running. The repository-built copy
launched for the audit was stopped to avoid two window managers sharing hotkeys.
The installed instance was left running. No shortcuts or permission settings
were changed, and no tiling actions were invoked.

After the user enabled capture access, Screen Recording preflight passed.
UI automation still timed out, and the audit process's Accessibility trust
probe returned false. No on-screen Tiled windows were found for capture, so
opening Settings manually is the next step. Screen Recording alone does not
authorize clicking controls or navigating menus.

To proceed without granting UI-control access, a temporary standalone helper
was compiled from the current sources with a separate entry point. It opens the
actual `SettingsWindowController` and its tab views directly, using a fresh
isolated preferences suite. It does not instantiate `AppDelegate`, register
global shortcuts, or run the window manager. This is a Settings preview, not
the installed app or an end-to-end tiling test.

Window-only screenshots are saved in `docs/ui-audit-captures/`: Welcome,
General, and Shortcuts, each in light/dark appearance at default and minimum
window sizes. The minimum 400×300 window has a 400×268 content area on this
system. Captures include native window chrome; the windows appear inactive.
An additional `shortcuts-live-window.png` captures the preview left open.

## Ranked findings

These findings describe the pre-change baseline. The first implementation batch
addresses Welcome shortcut accuracy, the Quarters diagram, and shortcut-editing
guidance placement; see `ui-first-batch.md` for current behavior and evidence.

### 1. Welcome can teach the wrong shortcut when Top Left is disabled

**Classification:** confirmed source-level behavior; high priority.

`Sources/tiled/SettingsWelcomeTab.swift:84` uses the current Top Left binding,
but substitutes `⌥⇧U` when its label is nil. A disabled binding has no key code
(`Sources/tiled/HotkeyBinding.swift:200–202`). The substituted shortcut is the
default for Top Left Sixth, not Top Left, as documented in `README.md:14–39`.
Depending on customization, this shortcut may invoke another action or do
nothing; it cannot reliably perform the action described by the guide.

**Recommendation:** show the actual enabled binding. If Top Left is disabled,
teach the menu path to Top Left and offer a path to Shortcuts; do not fabricate
a replacement binding or silently enable it.

**Acceptance:** default, customized, and disabled bindings produce accurate
instructions. The preview and described slot agree. Existing bindings remain
unchanged.

### 2. Shortcut settings and the menu use different subgroup structures

**Classification:** confirmed structural difference; usability benefit unverified.

`Sources/tiled/MenuModel.swift:174–213` groups quarters into Quads/Halves and
sixths into Corners/Thirds/Two-Thirds. The Shortcuts tab loops over all slots
within each layout (`Sources/tiled/SettingsShortcutsTab.swift:117–128`) without
those subgroups, despite its documentation describing matching grouping.

**Recommendation:** reuse the existing `SlotPresentation` subgroup definitions
for lightweight subgroup labels within each collapsible layout section.
Keep bulk enable/disable scoped to the entire layout. Evaluate small slot
previews only after checking density and scrolling in the running UI.

**Acceptance:** menu and settings use the same subgroup ordering; all 17 slot
recorders remain reachable; collapse, bulk actions, and focus restoration work.

### 3. Welcome mixes live shortcut instructions with fixed modifier guidance

**Classification:** confirmed copy inconsistency under customization.

The first action uses the current Top Left binding, while the later paragraph
hardcodes the default modifier families
(`Sources/tiled/SettingsWelcomeTab.swift:156–161`). Users can remap or disable
those shortcuts, so the general instruction is not always true for their setup.
The README's first-launch example also uses `⌥⇧U` while describing Top Left
(`README.md:76–78`), conflicting with its quarters shortcut table.

**Recommendation:** identify modifier families as defaults, or replace that
paragraph with guidance to the actual bindings in Shortcuts. Correct the README
example when updating onboarding. Keep advanced behavior secondary to the first
successful action.

**Acceptance:** guide copy remains accurate after remapping, and documentation
agrees with factory defaults.

### 4. Layout-switch labels explain the destination but omit the untile consequence

**Classification:** confirmed wording gap; visual presentation unverified.

Switch rows name the destination layout and focused window's destination slot
(`Sources/tiled/MenuModel.swift:194–220`). Switching also untiles the current
canvas's tiled windows (`README.md:134–138`). That consequence is not explicit
in the switch row itself.

**Recommendation:** evaluate concise wording or a clearly associated explanation
that communicates the untile consequence and available undo before acting.
Do not introduce a confirmation dialog or change switching behavior without a
separate decision.

**Acceptance:** consequence and canvas scope are understandable before choosing
the action, without making the submenu excessively wide.

### 5. Visual consistency needs a live comparison

**Classification:** audit candidate, not a confirmed defect.

Settings currently uses different top insets and stack spacing across tabs:
Welcome 24/12, General 20/12, and Shortcuts 16/4 (inset/spacing in points).
Some differences may be appropriate for their content. Source values alone do
not establish a visual problem.

**Recommendation:** compare rendered surfaces before standardizing spacing,
typography, row widths, button sizing, or permission-warning presentation.
Preserve native controls and semantic system colors.

## Proposed small implementation tasks

1. Correct Welcome's disabled/customized shortcut instructions and README example.
2. Align Shortcuts subgroup structure with the menu while preserving interaction state.
3. Refine Welcome's visual hierarchy after screenshot review.
4. Clarify layout-switch consequences after evaluating native menu width.
5. Apply only visually justified consistency changes across settings/onboarding.

Add the confirmed preview mismatch below to the onboarding task. Prioritize
accurate instructions and diagrams before cosmetic spacing changes.

These are proposed tasks, not authorization to implement them yet. The first
task has the strongest source evidence; visual tasks remain conditional.

## Remaining live checks

- Capture permission onboarding and the installed app's status menu.
- Check active-window appearance and scroll interactions; the Settings
  light/dark and default/minimum screenshot matrix is captured.
- Inspect both layout menus and single-/multiple-display scope labels.
- Check enabled, recording, disabled, duplicate, and registration-failure states.
- Check permission recovery without revoking an existing permission for the audit.
- Navigate all controls by keyboard and inspect VoiceOver labels/announcements.
- Compare the three baseline task flows: tile, customize a shortcut, recover.
- Verify the audited executable corresponds to the current source; screenshots
  of the installed app alone may represent an older build.

## Rendered Settings findings

### Quarters preview contradicts its caption

**Classification:** confirmed visual mismatch; high priority.

In `docs/ui-audit-captures/welcome-light-default.png`, the left diagram shows
four columns of individually separated cells. Its caption says “Quarters:
two columns,” and Top Left is drawn as two separate highlighted rectangles.
`SettingsWelcomeTab.swift:109` uses the default four-column rendering from
`SlotPreviewView.swift:25–27`; the sixths diagram explicitly selects three.

**Recommendation:** render quarters as a 2×2 diagram, projecting the internal
cell refinement into user-facing slots. Preserve the underlying slot geometry;
this is a presentation change, not a layout-engine change.

**Acceptance:** quarters shows two columns, sixths shows three, and Top Left is
one highlighted quarter consistent with its caption and accessibility label.

### Welcome is verbose relative to its first-action goal

**Classification:** observed hierarchy/density issue; improvement is a design choice.

The default-size guide shows numbered steps, menu guidance, two previews,
modifier guidance, drag-out/Expand guidance, dismissal, and re-entry guidance.
The minimum-size screenshot ends partway through the previews; the dismissal
and secondary guidance are below the visible viewport. This is not proof of
inaccessible content: the view has a scroll container, which still needs an
interaction check.

**Recommendation:** retain one concrete first action and the corrected previews
as primary content; shorten secondary guidance and the dismissal label. Do not
remove scrolling or hide the advanced guidance permanently.

### Shortcut recording guidance is below the initial viewport

**Classification:** observed discoverability issue.

The default Shortcuts view displays quarters and most sixths corners before
continuing below the viewport. Instructions for recording/canceling/disabling
and the reset action are in the footer after all 17 rows. Tooltips exist, but
the initial visible view does not explain how to edit a binding.

**Recommendation:** add a short instruction near the top or the recorders,
while retaining the footer's reset/recovery actions. Introduce the existing
slot subgroups without making every row substantially taller.

Use Tiled-only screenshots where possible. Do not change system appearance,
saved window geometry, real shortcut preferences, or window arrangements merely
to populate the matrix without coordinating those changes first.
