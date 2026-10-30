# A floor-clamped neighbour holds its floor and the splitter keeps the drag's edge

Status: accepted

Dragging a shared edge to grow a tile over a neighbour whose app clamps it at
its minimum size used to pull the splitter back to the neighbour's achieved
edge. The reassert's achieved-edge readback treated the neighbour's clamped
frame like any rounded frame, so the expanding window was re-derived to abut
it and the user's drag was undone at mouse-up. We decided a frame that lands
*larger* than its target is a floor clamp: the app refused the requested
shrink and grew away from the target's origin (the floor-clamped frame may
escape the visible frame, and the write policy repins it to hold the screen
edge it already hugged). The window keeps its floor there, the splitter stays
where the drag put it, and the expanding window keeps the edge it reached; the
two windows overlap, the expanding one in front. A frame that lands *smaller*
than its target fell short by rounding or an inset; its achieved edge still
pulls the splitter, so no gap opens.

Reasons: the drag is the user's decision and the floor is the app's; a fixed
layout cannot satisfy both without overlap, so the interaction the user is
steering must win. The repin already promised a clamped window "stops
shrinking at the screen edge", and pulling the splitter back contradicted that
receipt: the window held its floor while the window beside it changed under
the user's mouse. ADR 0002 deferred neighbour clamps as a separate fixed
point; growth-versus-shortfall is that fixed point's discriminator, and it
needs no extra AX reads.

Considered options: shrink the expanded window to abut the neighbour
(rejected: loses the drag, the reported bug); push the neighbour inward
(rejected: no room, and it would shrink below its floor); refuse the drag
(rejected: the expanding window's write is legitimate, and a refusal cannot be
attributed to the neighbour); treat every size divergence as a floor
(rejected: the reported row-rounding gap reopens).

Consequences: the reassert's readback skips both edges on an axis a window grew
past its target on; a later grid reassert (display change, swipe back)
re-clamps the neighbour in place, so the overlap is stable until the user drags
the splitter back past the neighbour's achieved edge. Overlap is now an
intentional canvas state: the occupancy glyph still shows slots, not frames.
The dragged window's own floor keeps its existing rule: the pre-write reconcile
moves the splitter to the edge the window actually reached, so its neighbour
abuts it.
