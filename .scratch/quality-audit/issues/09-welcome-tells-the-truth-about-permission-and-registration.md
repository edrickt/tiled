# 09: Welcome tells the truth about permission and registration

**What to build:** The Welcome guide must show its Accessibility warning whenever the install is
untrusted, and must not teach a Top Left combo that lost global registration. Today the permission
row is built before the provider is assigned and is not refreshed on `show()`, and the guide reads
only the stored binding, never `failedActions`.

**Blocked by:** None (can start immediately).

**Findings:** F9 and F10 (`.scratch/quality-audit/report.md`).

**Status:** DONE (cf59eb2)

- [ ] Opening Settings → Welcome while untrusted shows the warning and the grant button.
- [ ] Granting permission while Welcome is open hides the warning without reopening.
- [ ] A failed Top Left registration makes the guide teach the menu path, not the dead combo.
- [ ] A disabled Top Left keeps the existing menu instructions.
- [ ] Tests cover the untrusted first open and the failed-registration path.
- [ ] Gates green: warning-free build, full suite, every mutant CAUGHT.
