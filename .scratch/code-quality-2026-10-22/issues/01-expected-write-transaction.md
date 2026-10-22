# 01: Expected-write transaction and failure list

**What to build:** one `MoveAttempt` value for a single window
(`id`, `from: Slot?`, `to: Slot`, `previousRecord: WindowRecord?`) whose
`commit`/`rollback` own the state restore and the reverse write, and an
action-scoped `[Failure]` collected by the push layer and composed once
in `settle`. `place`, `restoreEvictees`, the two halves of `applySwap`,
and `reflow` become composes of that shape; the reflow batch keeps its
own all-or-nothing rule through the same failure channel. Read the clamp
repair in `FrameWriter` through the same policy: it currently ignores
the second write's result and arms an expectation anyway.

**Why:** the rollback idiom is written five ways; each captures a
different pre-state and decides separately whether to re-write. F21
(the swap home write) and F22 (the reflow recovery write) are the two
dropped outcomes today. One `Refusal` slot forces every branch to invent
a precedence rule; `reportRestoreFailures` is that rule.

**Findings:** `../report.md` "Still open 1"; `../slices/01-engine.md`
findings 1–2; `../slices/02-controller-write.md` S8; F21/F22 in
`../../quality-audit-followup/report.md`.

**Status:** TODO

- [ ] Characterization tests pin every current rollback outcome,
      including the second-refusal cases added for F21.
- [ ] `MoveAttempt` lands; every caller migrated; no old rollback body
      remains.
- [ ] Failure list composes the canvas error once; the single-`Refusal`
      precedence rule is deleted.
- [ ] `FrameWriter`'s clamp repair reads its result and cancels or
      reseeds its expectation.
- [ ] Gates in `../README.md` all pass.
