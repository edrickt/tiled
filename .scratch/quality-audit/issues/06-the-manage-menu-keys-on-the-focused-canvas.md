# 06: The manage menu keys on the focused canvas

**What to build:** The manage rows must describe the focused canvas's action. Today the row group
is gated on all visible canvases' tiled windows while Untile is titled by the focused canvas
count, so a second display can produce "Untile 0 Windows". The undo row also disappears after
Untile All even though the focused canvas still has a live chapter.

**Blocked by:** None (can start immediately).

**Findings:** F6 (`.scratch/quality-audit/report.md`).

**Status:** TODO

- [ ] With windows on another display and an empty focused canvas, the menu omits the Untile row
      (or disables it with a reason) instead of saying "Untile 0 Windows".
- [ ] A live undo chapter stays reachable from the menu even when the focused canvas has no tiled
      windows.
- [ ] The reset/restore splitters row follows the focused canvas.
- [ ] Unit tests cover the cross-canvas snapshot mismatch.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
