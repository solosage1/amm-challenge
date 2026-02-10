# Leaderboard snapshot (2026-02-10)

This folder contains a point-in-time snapshot of the AMM Fee Strategy Challenge leaderboard plus derived per-submission metrics.

## Source

- Website: https://www.ammchallenge.com/
- Data captured: 2026-02-10 (UTC)

## Files

- `top20.json`
  - Top-20 leaderboard rows extracted from the site.
  - Includes `submission.id`, `author`, `name`, `createdAt`, wins/losses/draws, and reported `avgEdge` / `avgEdgeVsBaseline`.
- `top20_metrics.json`
  - Derived metrics for the same 20 submissions (fees and volume diagnostics).
  - Fields are computed from the site’s submission API responses at capture time.

## Notes / caveats

- Baseline (normalizer) metrics differ across these 20 entries in this snapshot. Interpret cross-entry deltas as potentially noisy; see `research/ASSUMPTIONS_REGISTER.md` and `research/LEADERBOARD_FINDINGS.md`.
- This snapshot does not include competitor Solidity source code. Treat any inference about *how* a strategy produced these numbers as `HYPOTHESIS`.

## Refresh procedure (manual)

This repo intentionally stores snapshots, not a live scraper. To refresh:

1. Capture the current leaderboard Top-20 into a new date folder `research/data/leaderboard/YYYY-MM-DD/`.
2. For each `submission.id`, pull the corresponding submission details from the site’s API endpoints (observed: `GET https://www.ammchallenge.com/api/submissions/<uuid>`) and recompute derived metrics.
3. Update the snapshot + findings docs to point at the new data.

Refreshing requires network access and is expected to be run outside restricted environments.

