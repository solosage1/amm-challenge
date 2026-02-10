# Leaderboard findings (from the 2026-02-10 snapshot)

This document summarizes what we can say with high confidence from the stored leaderboard snapshot, and what we should treat as hypotheses to test locally.

Data source: `research/data/leaderboard/2026-02-10/` and `research/LEADERBOARD_SNAPSHOT_2026-02-10.md`.

## What “performance” means in this codebase (`FACT`)

- Strategies are judged by average **Edge** over many simulations, in a head-to-head match vs a fixed 30 bps normalizer. See `research/JUDGING_ALGORITHM.md` and `amm_sim_rs/src/simulation/engine.rs`.
- Edge is accumulated per trade at the **true fair price**, with separate contributions from retail trades and arbitrage trades. See `research/JUDGING_ALGORITHM.md`.
- Per-step sequence is:
  1. Fair price evolves (GBM)
  2. Arbitrage executes first on each AMM (at most once per AMM per step)
  3. Retail orders arrive and are optimally routed across AMMs
  See `amm_sim_rs/src/simulation/engine.rs`.
- The strategy contract is only called when its AMM trades; `afterSwap` runs immediately after each trade and sets the fees shown for subsequent trades. See `amm_sim_rs/src/amm/cfmm.rs` and `contracts/src/IAMMStrategy.sol`.
- Fees are fee-on-input and are not reinvested into reserves; `k` stays constant. See `amm_sim_rs/src/amm/cfmm.rs`.
- Retail order routing is nonlinear in fee differences; small changes in quoted fees can shift large fractions of retail flow. See `amm_sim_rs/src/market/router.rs`.

## Snapshot observations (`FACT`)

From the stored Top-20 snapshot:

- Score levels: AvgEdge ~523.8–526.4 (mean 524.38).
- Fee regime: “average fee” diagnostics cluster ~35.0–38.2 bps (mean ~37.0).
- Asymmetry: 19/20 strategies show `askFee < bidFee` on average (mean askMinusBid = -1.279 bps).
- Reported volumes to the submission AMM: retail ~74.9k–78.9k Y; arbitrage ~21.8k–25.4k Y.
- Within this Top-20 snapshot, average quoted fees are strongly negatively correlated with both retail volume and arbitrage volume (Pearson correlation ~ -0.95 and ~ -0.88 respectively). This is descriptive, not causal.
- Baseline variance: implied normalizer AvgEdge differs across entries (347.5–365.3), so leaderboard deltas may include evaluation noise.

All details and the underlying data are in `research/LEADERBOARD_SNAPSHOT_2026-02-10.md` and `research/data/leaderboard/2026-02-10/`.

## What could explain “winning” results (`HYPOTHESIS`, to test locally)

The simulator makes score improvements mechanically come from three knobs:

1. Capture more retail volume (router share) at acceptable fees.
2. Increase edge per unit retail volume (spread earned at fair price).
3. Reduce arbitrage losses (edge leakage) by managing mispricing and no-arb bands.

Given the observed fee/volume clustering, plausible (but unverified) patterns include:

- Competitive fee banding: keep fees near the 30 bps normalizer most of the time to retain router share, but widen selectively when conditions suggest informed-flow risk.
- Asymmetric inventory quoting: quote different bid/ask fees to bias which side of flow you attract, using only on-chain signals (`TradeInfo`) and limited state.
- Arb-signal reactivity: because arbitrage executes before retail each step, an arbitrage trade can act as an early signal at a timestamp; updating fees immediately after that trade can change retail routing later in the same step.
- Implicit fair price inference: if a trade is (or resembles) the closed-form arbitrage, reserves + trade size may allow estimating the fair price used by arbitrage; this could be used to tune fees and/or detect volatility regimes.

Each of the above is tracked as concrete, testable work items in `research/HYPOTHESES_BACKLOG.md`.

## Practical implications for our strategy process (`FACT`)

- Without competitor source code, treat leaderboard-derived ideas as hypotheses and validate them using the local simulator and the testing pyramid in `research/TESTING_GUIDE.md`.
- Because website evaluation seeds/conditions may differ from local seeds, prioritize robustness: validate across multiple runs and avoid overfitting to one seed set.
