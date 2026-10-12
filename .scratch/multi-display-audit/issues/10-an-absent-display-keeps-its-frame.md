# 10: An absent display keeps its frame

**What to build:** A canvas kept "for replug" must keep the geometry it had. `visibleFrame(for:)`
falls back to `mainScreenInfo(screens())` when the canvas's own display is absent
(`TilingController.swift:550-558`), and the screen-change observer refreshes *every* canvas
including removed ones (`:218` → `:572-576`). So the unplugged canvas's stored visible frame
silently becomes another display's geometry; correctness then depends entirely on the visibility
guard ticket 09 repairs. Do not refresh a canvas whose display is absent — leave its last-known
frame (already marked stale, recomputed on replug). Reserve the main-screen fallback for genuinely
display-less keys.

Also fix the companion mark/clear ordering: `applyAll` clears a key's stale mark *before* a
reassert that can early-return on a degenerate frame, so a deferred reassert can be dropped
(`TilingController.swift:483-492`; `TilingSpace.swift:1256-1261`). Clear the mark only on an actual
write.

**Blocked by:** 09 (the visibility guard must be in place first).

**Findings:** report M8, L5 (`.scratch/multi-display-audit/report.md`).

**Status:** ready-for-agent

- [ ] Unplugging a display does not change its canvas's stored visible frame; the last-known frame
      survives until replug recomputes it.
- [ ] The main-screen fallback still applies to genuinely display-less keys.
- [ ] A stale mark is cleared only after a real reassert write; a degenerate-frame early-return
      keeps the canvas marked stale so it retries on the swipe back.
- [ ] Pinned by tests: unplug → frame unchanged; degenerate frame → stale mark retained; normal
      reassert → mark cleared.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
