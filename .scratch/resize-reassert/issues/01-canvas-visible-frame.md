# Stage 1 - The canvas owns its visible frame

Status: ready-for-agent
Blocked by: None (can start immediately)
Blocks: stage 2

## What to build

Each canvas tiles against one stored **visible frame** — the visible frame of the display that canvas lives
on — so no rect on a canvas is derived from whichever window's frame happens to be at hand. Today the bounds
are re-resolved per window at every call site, so two occupants of one canvas can compute different bounds
for the same shared edge. After this stage every canvas geometry read uses the one frame.

This is the geometry prefactor for the resize reassert; it is deliberately not the tracker change.

## Acceptance criteria

- [ ] A canvas stores one visible frame. The coordinator resolves it when the canvas is established and refreshes it on a display change, a swipe back, and a splitter reset — never per drag, never per window.
- [ ] The canvas's actions no longer take a per-frame bounds provider; every canvas geometry read (placement, reflow, undo, untile-all, reset/restore, reassert) uses the stored frame.
- [ ] The display-less fallback canvas resolves a frame (main screen); headless tests supply one. No production path resolves bounds from a window's own frame.
- [ ] A flush test pins the fix: two occupants of one canvas derive their shared edge from one bounds, so their frames touch.
- [ ] `swift build` clean, zero warnings; `swift test` green.

## Constraints (settled, do not re-decide)

- The canvas stays a pure value type with no I/O: the coordinator resolves the frame (through the screen provider) and injects it; the canvas only stores and reads it.
- One frame per canvas — not per window, not per layout, not a fallback that re-resolves per window.

## Gates

Run the stages per `.scratch/resize-reassert/README.md` ("Running one stage in a fresh session"). On
completion, record the commit hash here and in the README stage table.
