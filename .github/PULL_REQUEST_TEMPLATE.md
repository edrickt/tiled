## What changed

<!-- One or two sentences. Name the rule or module, not the diff. -->

## Why

<!-- The behavior this protects, or the bug shape it closes. Link an issue if there is one. -->

## Proof

- [ ] `swift test` passes
- [ ] A test fails without this change (which one?)
- [ ] `python3 tools/mutation/mutate.py` still exits zero (new rule? add a mutant)
- [ ] Behavior change: live suite covers it, or `docs/capture/` updated

## Window behavior, before/after

<!--
If this changes what happens to real windows, say what the user sees now
versus before. Screenshots from tools/capture/ are welcome; drags and
layout transitions are easier to show than to describe.
-->

## Screens

<!--
Which combinations did you check? Accessibility and Space behavior cannot be
tested by the unit suite, so say what you exercised by hand:
-->
- [ ] Single display, single Space
- [ ] Multiple Spaces
- [ ] Multiple displays
- [ ] An app that refuses programmatic resizing
