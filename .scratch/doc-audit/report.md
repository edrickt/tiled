# Documentation audit — 2026-10-07

Scope: `README.md`, `CONTEXT.md`, `tools/repro/multi-display-checklist.md` (deep audit);
`docs/ui-*.md` × 5 (triage). Axes: accuracy (code-cited), staleness, audience fit /
single-source-of-truth, agent-doc quality (writing-for-agents levers). Evidence bar:
every accuracy finding cites `file:line`. Verified-correct coverage maps are at the end
of each section. Baseline: commit `72616c5`.

---

## ⚠️ Open question — code vs. agreed rule (decide before the doc fix)

**OQ1. `stepAsideHome` is broader than "contains".** `CONTEXT.md` (and the grilled spec)
say the step-aside fires when the blocker's slot **contains** the target. The code guards
only `current.overlaps(target)` (`Layout.swift:556-558`). For same-layout slot pairs,
overlap-without-containment is reachable in exactly one family: the two two-thirds slots.
Example: **left two-thirds** tiled, requester asks for the **right two-thirds** →
leftover = the left third (one whole slot) → the blocker **steps aside into the left
third** instead of swapping/evicting. (The audit agent's original examples were invalid —
cross-layout pairs can't share a canvas — but the two-thirds case is real and reachable.)

Options:
- **(a) Keep the code, fix the docs** — "when the blocker's slot overlaps the target and
  its leftover is exactly one whole slot". The two-thirds outcome is coherent: the board
  ends fully covered (blocker keeps its left column, requester gets the right two-thirds).
- **(b) Tighten the code to containment** — `current.cells.isSuperset(of: target.cells)`,
  making the code match the doc as written; the two-thirds pair falls back to swap/evict.

➡ Recommendation: (a). The behavior is sensible, already shipped, and the doc is the
thing that overstates the condition.

---

## README.md

### High — factually wrong after commit 72616c5 (step-aside)

| # | Where | Problem | Evidence |
|---|-------|---------|----------|
| R1 | `README.md:106-111` | **Swap bullet**: no step-aside exception; a containing blocker with a clean leftover no longer swaps. Also omits that the vacated tile must be disjoint from the target. | `Layout.swift:522-527` (swap gated on `stepAsideHome == nil`), `Layout.swift:556-568` |
| R2 | `README.md:105` | "A half occupied + a quad key on that side → the half window is evicted" — now the half **steps aside into the other quad on that side** when it's free; eviction is only the fallback. | `Layout.swift:556-568`; `CONTEXT.md:45` names this exact case |
| R3 | `README.md:63-66` | Re-house prose states only the free-region rule ("leaves exactly one whole slot free") — but a step-aside victim re-tiles even when the request leaves 7 free cells. Reflow prose (66-73) verified accurate. | `Layout.swift:586-605` |
| R4 | `README.md:140-141` | Quoted switch notice doesn't exist in the app (fabricated tail: "Undo (⌃⌥⇧⌘Z) is one step… always reversible"), **and** the paren never closes. Real string: "Switched to Sixths · 3 windows untiled. Press ⌃⌥⇧⌘Z to undo." | `TilingSpace.swift:391-393` |

### Medium — stale counts / facts

| # | Where | Problem | Evidence |
|---|-------|---------|----------|
| R5 | `README.md:199` | "Unit suite (581 tests)" → **601** (fresh `swift test` run). | test output |
| R6 | `README.md:272` | "17 global hotkeys" → **21** (17 remappable slots + 4 fixed: evict, expand, settings, undo). | `HotkeyService.swift:207-262`, `Layout.swift:65-73` |
| R7 | `README.md:172` | Bundle path: `build/tiled.app` → `build/Tiled.app` (case). | `scripts/make-app.sh:8`, CI `tests.yml:44` |

### Low — markup / precision

| # | Where | Problem |
|---|-------|---------|
| R8 | `README.md:53` | "the slot shortcuts **below** are the remappable ones" — the tables are **above**. |
| R9 | `README.md:162` | Menu item is titled "Restore Previous Splitters" after a drag; "Reset Splitters" otherwise. Say both. (`MenuModel.swift:276-279`) |
| R10 | `README.md:40-41` | Settings/Undo rows sit under "### Sixths (hold ⌥⇧)" but neither combo holds just ⌥⇧ — needs a "Fixed combos" subsection or note. |
| R11 | `README.md:33` | Table cell `Bottom middle sixth|` missing alignment space. |

**Verified still true (coverage):** all 17 default bindings (`HotkeyService.swift:4-28`),
expand/evict fixed-shortcut semantics, Welcome tab claims, Shortcuts-tab remapping/conflict
behavior, remaining tiling rules (two-quad eviction, own-tile no-op, drag-out ~100pt
`DragTracker.swift:128`, per-canvas isolation, layout switch, display reassertion, refused
resizes), all reflow examples and tie-breaks (`Layout.swift:637-682`), live-resize section,
all referenced scripts/tools/CI paths, mutation-testing claims, "Owned overlay resize
handles" correctly unchecked.

---

## CONTEXT.md

### Accuracy

| # | Where | Problem | Evidence |
|---|-------|---------|----------|
| C1 | `CONTEXT.md:45,37` | Step-aside condition stated as "contains" — code implements "overlaps" (see OQ1). Doc fix depends on the OQ1 decision. | `Layout.swift:556-558, 522-524` |
| C2 | `CONTEXT.md:45` | Two re-house rules presented in reverse order — code checks **step-aside first** (`Layout.swift:575-576, 593`). Order is observable: half evicted by a top-left quad request gets the bottom-left **quad** (step-aside), not the bottom half (free-region). | `Layout.swift:593` |
| C3 | `CONTEXT.md:64` | "Plan execution: committing a decided plan (tile or switch)" — omits the **swap** branch. | `TilingSpace.swift:183-197` |
| C4 | `CONTEXT.md:45` | Free-region example ("moves into the free top-left sixth") silently assumes the bottom-left sixth is tiled; otherwise the evictee lands in the whole left third. Prefix the setup. | `Layout.swift:594-605` |
| C5 | `CONTEXT.md:11-13` | **Layout** entry states composition only; omits its one behavioral rule (a request in the other layout switches and untiles everyone rather than coexisting). | `Layout.swift:506-508` |

### Agent-doc quality (writing-for-agents levers)

| # | Where | Lever | Problem |
|---|-------|-------|---------|
| C6 | `CONTEXT.md:64-66` | Sprawl / no `_Code_` anchor | **Plan execution** is exposition, not vocabulary: no code anchor, duplicates `TilingSpace.swift:25-27` and `execute`'s doc. Delete it, folding the one load-bearing fact (canvas owns plan/commit/rollback; controller keeps focus, pruning, dispatch) into the Tiling-space entry's `_Code_` line — or give it `_Code_: TilingSpace.execute(decision:)` and fix the branch list. |
| C7 | `CONTEXT.md:45,41,48-50` | Co-location | Expanded-window exclusions are scattered ("never step aside" in Re-house, "never grow" in Reflow) while **Expand** is silent. One gate in code (`TilingSpace.swift:500, 796-798`). Add one sentence to Expand; reference it from the other two. |
| C8 | `CONTEXT.md:16` | No-op | "the thing a three-finger swipe up moves between" — teaches an agent nothing it doesn't know. Trim. |
| C9 | `CONTEXT.md:20` | Cache (borderline) | Withheld-Space-id fallback restates `DisplaySpace.swift:39-41,56` nearly verbatim; the *gotcha* is worth keeping but it's the first cut if the entry grows. |
| C10 | README ↔ CONTEXT | Duplication (SSOT) | Swap/re-house/reflow semantics are stated in full in both docs; every rule change now costs coordinated edits in two places (this audit is the evidence). Keep README prose (different audience) but consider a pointer for the full precedence rules. |

**Clean:** negation steering (all _Avoid_ lists, bodies positive), sediment (nothing stale),
all code-name references resolve, Swap mechanics, Reflow rules, Expand/Drag-out/Eviction/
Requester/Tiling-space entries verified.

---

## tools/repro/multi-display-checklist.md

| # | Where | Axis | Problem | Evidence |
|---|-------|------|---------|----------|
| M1 | `:11-18` | accuracy — **HIGH** | Setup is unrunnable as written: `run-repro.sh` launches tiled itself and its `trap cleanup EXIT` **kills both apps when the suite exits** — so nothing is running for the manual steps; scenarios 1/6 reference HOSTA/HOSTB which won't exist. Rewrite setup to relaunch both apps after the suite. | `run-repro.sh` trap; `TilingController.swift:159` |
| M2 | `:76-81` | accuracy | Instructions capture `TILED_DEBUG=1` output but nothing ever launches the app with that env var. Fold into the relaunch step. | `TilingController.swift:159` |
| M3 | `:71-72` | staleness | "Untile All" and "Reset Splitters" aren't the real titles ("Untile 1/N Window(s)"; the rows vanish once untiled — so Reset Splitters must run **first**; also note the "Restore Previous Splitters" retitle). | `MenuText.swift:16-18`, `MenuModel.swift:235, 276-279` |
| M4 | `:24-25` | accuracy | "Tile HOSTA into Top Left" — the suite leaves canvases in **sixths**; quarters Top Left triggers a layout switch that untiles the canvas (destructive, unstated). Name the slot exactly ("Top Left Sixth (⌥⇧U)") or state the expected switch notice. | `HotkeyBinding.swift:115,121`, `Layout.swift:506-508` |
| M5 | `:41-42` | accuracy | "the removed display's windows stay where they were" is unobservable — macOS relocates them. The app's testable contract: it **writes nothing to the removed canvas** while hidden. Reword. | `TilingController.swift:479-488`, `DisplayIdentityTests.swift:150-152` |
| M6 | after scenario 5 | gap (in scope) | Missing: "Displays have separate Spaces" **off** — canvases must stay per-display even when one Space spans both. | `TilingController.swift:1309-1311`, `DisplaySpace.swift:36-49` |
| M7 | scenario 3/4 area | gap (in scope) | Missing: lid close / clamshell wake with an external display tiled (the death-confirmation window exists for exactly this). | `LidSleepWakeTests.swift:66,92,120` |
| M8 | several | markup | Scenarios 1/4/5/6 lack the "Failure symptom" line the reporting section relies on; "display 1/2" never anchored to built-in/external. |

**Verified current:** automated-suite description matches `multi-display-suite.swift`
exactly; scenarios 1-5's behavior contracts match the code and test suites; no
swap/evict/re-house outcomes are described, so the step-aside change doesn't touch it.

---

## docs/ui-*.md — triage

| File | Status | Verdict |
|------|--------|---------|
| `ui-improvement-plan.md` | Steps 2-3 shipped (`317570d`, `956a999`); **steps 4-5 (menu labels, visual unification, VoiceOver checks) never started** | **Live** — the only one with open scope |
| `ui-audit.md` | Findings 1-3 fixed; 4-5 superseded by the plan; unique value is capture provenance | Archive |
| `ui-first-batch.md` | Shipped + reviewed clean (`a682dec`) | Archive |
| `ui-shortcut-groups.md` | Shipped (`956a999`, `32bfa5f`); code live at `SettingsShortcutsTab.swift:133-137` | Archive |
| `ui-first-batch-review.md` | Dispositioned review; only record of two waved-through smells | Archive |

➡ Recommendation: move the four archive files **plus `docs/ui-audit-captures/`** (the
docs link captures by relative path) to `.scratch/ui-polish/`, matching the
`.scratch/canvas-aggregate/` convention. Keep `ui-improvement-plan.md` in `docs/` iff
steps 4-5 are still on the roadmap; otherwise move it too (leaving `docs/` empty).
Nothing else references these files; delete nothing.

---

## Proposed fix batches (approve what to run)

- **A — Step-aside staleness (README)**: R1-R4. High-priority prose rewrites; ready-to-paste text exists.
- **B — Counts & markup (README)**: R5-R11. Mechanical.
- **C — CONTEXT.md accuracy + quality**: C2-C9 (C1 depends on the OQ1 decision).
- **D — Checklist**: M1-M8. Includes rewriting the setup and adding two scenarios.
- **E — Triage moves**: `.scratch/ui-polish/` move + the keep-vs-move call on the plan.
- **OQ1 — containment vs overlap**: doc-only fix (a) or code tightening (b).
