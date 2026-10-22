# Code-quality audit hub — 2026-10-22

Audit of `master` @ `47dea76`; full evidence in `report.md` and
`slices/`. The one-batch remediation is landed. The tickets below are
the open structural work, ordered by reader-load payoff.

## Gates (every ticket)

- `swift build 2>&1 | grep -E "warning:|error:"` -> empty
- `swift test` -> all green
- `./scripts/check-test-count.sh` -> README's count matches
- `python3 tools/mutation/mutate.py` -> every mutant caught, none stale

## Tickets

| # | Ticket | Findings | Shape | Size |
|---|---|---|---|---|
| 01 | Expected-write transaction and failure list | A1, F21/F22 class, S8 | design | M/L |
| 02 | Window register and canvas directory | A2, A3, S1/S2/S7 | design | M |
| 03 | Menu-bar presenter and honest snapshot | P1/P2/P3/P5 | design | L |
| 04 | Shortcut park and priority notice | A6, S1/S3/S4/S6, T11 | design | M |
| 05 | Input seams: tick classifier and Carbon router | F23, F28, F29 | design | M |
| 06 | One controller test harness | tests 8/9/10 | mechanical | M |

Each ticket starts with a characterization test for the behavior it
preserves, then lands in small commits. No ticket changes user-visible
copy without a CHANGELOG entry and a test.
