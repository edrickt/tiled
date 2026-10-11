# The canvas owns one visible frame and the resize reassert

Status: accepted

The live edge-resize reconcile used to sit in `DragTracker`: it recomputed each neighbour's rect from that window's own frame and deliberately excluded the dragged window, so "the window ends up in its tile" was an assumption nothing checked. We decided the canvas (`TilingSpace`) owns a single `visibleFrame` — the display's visible frame, resolved once at establishment and refreshed only on a display change, a swipe back, and a splitter reset — and owns the reconcile as one operation, `reassert`, over a pure core `reassertPlan`. The reassert writes every tiled occupant including the dragged window, and reconciles any app-clamped edge back to the dragged window's achieved frame before asserting, so neighbours abut the window itself rather than a splitter the cursor moved past.

Reasons: bounds derived per window let two occupants of one canvas disagree about their shared edge (the reported gaps); excluding the dragged window left its far edges uncorrected; and the clamp case opened a gap between a window pinned at its app minimum and the neighbour tracking the phantom splitter. Splitting the reconcile into a pure plan (headless, in the ~2s suite) and a thin effectful wrapper keeps the mechanism's one non-obvious behaviour testable without AX.

Considered options: keep the reconcile in `DragTracker` (rejected: leaves the two no-op-write policies and two grid writers in lockstep); a rich request type with scope/check knobs (rejected as speculative — no current caller); folding neighbour-size clamps into the same pass (deferred: the dragged window's own clamp is the reported symptom; a neighbour clamp is a separate fixed-point).

Consequences: `TilingSpace.Context` loses `boundsOf`; `DragTracker` becomes decide-only and loses its rect math, coalescing, and duplicate no-op skip, but still commits live splitter fractions during the drag. The trigger stays the global mouse-up; committing on the drag's own end instead is a deliberate follow-up, not part of this decision.
