# Code-quality & feature-functionality audit — build arc

Audit origin: the 2026-10-17 audit of `master` @ `2f07c03`. Full evidence, feature map, and
verified-solid coverage: `report.md` in this directory. This file is the arc hub: the ticket
graph, the gates, and how to run one ticket in a fresh session.

## Where this is

Batch 1 is the recommended starting order: **F1** (refused move loses the old slot), **F2**
(destroy fast path bypasses the death clock), **F3** (Restore Previous Shortcuts destroys its
backup). **F1 and F3–F18 are DONE**; **F2 is parked on live display-teardown evidence**, as its
ticket requires. The rest of the functional findings and the test seams follow in the report's
triage order. The architecture candidates are **not** implementation tickets yet: A1/A2 have a
design phase, and A3–A6 are "worth exploring" only.

Base: `master` @ `2f07c03` (v0.2.2). The `robustness-audit` branch is unmerged; F3/F8/T4/F20
overlap findings already recorded there and are marked in the report.

## The ticket graph

| # | Ticket | Blocked by | Findings | Status |
|---|--------|-----------|----------|--------|
| 01 | A refused move keeps the old slot | – | F1 | DONE (`bb3819d`) |
| 02 | A transient dead probe cannot release on a destroy report | 01 | F2 | PARKED (live evidence) |
| 03 | Restore Previous Shortcuts restores atomically | – | F3 | DONE (`6324502`) |
| 04 | Undo tells the truth about a refused reveal | 01 | F4 | DONE (`748722d`) |
| 05 | A retile clears deferred restores across canvases | 04 | F5 | DONE (`bbeebe5`) |
| 06 | The manage menu keys on the focused canvas | – | F6 | DONE (`b9e0eb3`) |
| 07 | One action receipt for menu and announcement | 06 | F7, A5 | DONE (`0b8c54b`) |
| 08 | Hide-icon recovery names a live combo | – | F8 | DONE (`ede868c`) |
| 09 | Welcome tells the truth about permission and registration | – | F9, F10 | DONE (`cf59eb2`) |
| 10 | Expand row and pending reassert follow the expanded state | – | F11, F12 | DONE (`4509e2e`) |
| 11 | Presentation copy matches the undo model | – | F13, F15, F16, F17 | DONE (`6210427`) |
| 12 | Drag edges: programmatic jump and skipped-write baseline | – | F14, F18 | DONE (`a931559`) |
| 13 | Hotkey registration is testable | – | T1 | DONE (`572de00`) |
| 14 | App launch and action routing are testable | 13 | T2 | DONE (`702f938`) |
| 15 | The live AX adapter has a testable seam | – | T3 | TODO |
| 16 | One hotkey route, not a dead table | 13 | T4, A4 | DONE (`9856939`) |
| 17 | Literal expectations for end-to-end tests | – | T5 | DONE (`e7e8b8a`) |
| 18 | Splitter-backup drag semantics are pinned | – | T6 | DONE (`d8d4359`) |
| 19 | Conflict and registration-failure UI are pinned | 09 | T7 | DONE (`66df049`) |
| 20 | Welcome lifecycle is pinned | 09 | T8 | TODO |
| A1 | Explore: expected-write ledger | – | A1 | TODO (design) |
| A2 | Explore: window ownership register | – | A2 | TODO (design) |
| A3 | Explore: canvas directory | – | A3 | TODO (design) |
| A6 | Explore: parked shortcuts module | 03 | A6 | TODO (design) |

The functional queue and ticket 13 are complete; F19–F20 are the remaining test-hygiene
items, and test-seam ticket 20 is the prerequisite for trusting the live-only features.
A1/A2 come after the functional queue, per the audit's triage order. A3/A6 are exploratory
and should not be cut into implementation until their design is approved.

## Gates (non-negotiable in every ticket)

- `swift build 2>&1 | grep -E "warning:|error:"` -> empty
- `swift test` -> all green
- `./scripts/check-test-count.sh` -> README's count matches the suite
- `python3 tools/mutation/mutate.py` -> every mutant CAUGHT, none STALE

Run the full mutation table before committing. `--since <ref>` is for the stage gate only.

## Running one ticket in a fresh session

```
Read .scratch/quality-audit/README.md, then implement
.scratch/quality-audit/issues/NN-<slug>.md
```

Then:

1. Read this hub, the ticket, the report finding it points at, and `CONTEXT.md`.
2. Build through the `tdd` skill: red test first, then the fix.
3. Gates green after every working step.
4. Close with `code-review` (Standards + Spec) against the ticket's base.
5. Commit in the repo style (imperative subject, why in the body, gate evidence at the end),
   then update the table above and the ticket's Status.
