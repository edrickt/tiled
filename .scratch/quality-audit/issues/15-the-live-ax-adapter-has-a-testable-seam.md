# 15: The live AX adapter has a testable seam

**What to build:** The live adapter's wiring must be testable without a real Accessibility grant:
Space lookup/cache, observer registration and routing, destroy reports, adoption, and
partial-write recovery. Also close the fake-fidelity gap: `FakeWindowGateway.release` must drop
the window's readable state and baseline like the live adapter, so release-on-a-released-handle
bugs cannot pass.

Inject the Space table, observer/registry, and write primitives at the adapter's seams; keep the
pure mapping tests.

**Blocked by:** None (can start immediately).

**Findings:** T3, F20 (`.scratch/quality-audit/report.md`); robustness-audit G6.

**Status:** DONE (3078538)

- [ ] The adapter is constructible with injected Space/observer/write collaborators.
- [ ] Tests pin Space lookup and cache refresh, observer registration/routing, and destroy
      delivery.
- [ ] Partial-write recovery is exercised through the adapter, not only the pure policy.
- [ ] `FakeWindowGateway.release` drops the window, frame baseline, and handlers; a test pins it.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
