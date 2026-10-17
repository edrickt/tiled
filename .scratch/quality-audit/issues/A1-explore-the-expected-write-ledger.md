# A1: Explore the expected-write ledger

**What to build:** A design decision, not code yet. The expected write is a named domain concept
with no owning module: `FrameWriter` imports the gesture tracker's tolerance, `DragTracker` owns
the expected frames, convergence, and baselines, the canvas seeds baselines, and the controller
schedules the late verdict. Decide the module boundary, its interface, what stays in the tracker
(live splitter commits per ADR 0002), and how the existing `FrameWriter` result vocabulary maps
onto it.

**Blocked by:** None (design can start immediately; implementation follows the functional queue).

**Findings:** A1 (`.scratch/quality-audit/report.md`, HTML candidate A1).

**Type:** design

**Status:** TODO

- [ ] The owning module's interface and seam are agreed.
- [ ] The tracker's remaining responsibilities are explicit; ADR 0002 is respected.
- [ ] The migration keeps the suite green and does not reintroduce a second verification scheduler.
- [ ] The design is recorded in an ADR or a spec update before implementation.
