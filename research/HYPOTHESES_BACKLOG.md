# Hypotheses backlog

This file converts leaderboard observations and simulator mechanics into testable hypotheses, with concrete predictions and experiment plans.

For the mechanics and constraints these hypotheses must respect, see:

- `research/JUDGING_ALGORITHM.md`
- `research/TESTING_GUIDE.md`
- `contracts/src/IAMMStrategy.sol`
- `contracts/src/AMMStrategyBase.sol`
- `amm_sim_rs/src/simulation/engine.rs`
- `amm_sim_rs/src/amm/cfmm.rs`
- `amm_sim_rs/src/market/arbitrageur.rs`
- `amm_sim_rs/src/market/router.rs`

## How to use this backlog

- Each hypothesis has an ID `H-###`, a status, and an experiment recipe.
- Create an experiment log under `research/experiments/` using `research/templates/EXPERIMENT_TEMPLATE.md`.
- Update the hypothesis status with links to the experiments that support or reject it.

## Status values

- `proposed`: not yet implemented
- `testing`: implemented and being evaluated
- `supported`: repeatedly improves edge in 1000-sim tests
- `rejected`: does not improve edge or is too fragile
- `blocked`: cannot be implemented under constraints (gas, slots, validator)

## Calibration priors from the Top-20 snapshot (`FACT`, but not necessarily optimal)

From `research/LEADERBOARD_SNAPSHOT_2026-02-10.md`:

- Average quoted fees cluster around ~35–38 bps.
- Most strategies have `askFee < bidFee` on average, by ~1–3 bps.

Treat these as priors for parameter sweeps, not as a prescription.

---

## H-001 — Infer fair price from arbitrage-like trades

- Status: `proposed`
- Depends on: A-001, A-002, A-006
- Mechanism (`FACT` references):
  - Arbitrage executes before retail each step (`amm_sim_rs/src/simulation/engine.rs`).
  - Arbitrage uses closed-form optimal sizing (`amm_sim_rs/src/market/arbitrageur.rs`).
- Hypothesis:
  - Some trades hitting our AMM can be classified as arbitrage, and their post-trade reserves imply the fair price (or a tight bound).
  - Using that inferred price to set fees (and optionally to estimate volatility) increases retail edge and/or reduces arb losses.
- Measurable prediction:
  - Higher AvgEdge at 1000 sims vs a comparable strategy without price inference, without collapsing retail volume share.
- Implementation sketch (submission-feasible):
  - Store last fee quote (bid/ask) and last inferred price estimate in `slots[]`.
  - On a candidate arbitrage trade, compute `k = reserveX * reserveY` and infer `p_est` from the post-trade `reserveX` and the fee `gamma`.
  - Use `p_est` + inventory state to set next fees.
- Experiment plan:
  - Implement two strategies: (a) baseline heuristic, (b) same heuristic + price inference path.
  - Validate at 10 sims, then compare at 100 sims across multiple runs, then confirm at 1000 sims.
  - Log retail/arb volume diagnostics if available.

## H-002 — “Post-arb tighten, post-retail widen” fee schedule

- Status: `proposed`
- Depends on: A-001
- Mechanism (`FACT` references):
  - Arbitrage is first; retail routes after (`amm_sim_rs/src/simulation/engine.rs`).
  - `afterSwap` runs immediately after each trade (`amm_sim_rs/src/amm/cfmm.rs`).
- Hypothesis:
  - When the first trade at a timestamp is arbitrage-like, temporarily quote tighter fees for the remainder of that timestamp to win retail routing while the pool is near the fair price.
  - After retail trades (or in later trades at the same timestamp), widen fees to reduce informed-flow leakage.
- Measurable prediction:
  - Increased retail volume share with limited increase in arb volume; net edge improves.
- Implementation sketch:
  - Track `lastTimestamp`, `tradeIndexWithinTimestamp`, and a short-lived “tight-mode” flag/decay counter in `slots[]`.
  - If `tradeIndexWithinTimestamp == 0` and trade size/price impact suggests arbitrage, set fees to `baseLow` for the rest of that timestamp; otherwise revert via decay.
- Experiment plan:
  - Sweep `baseLow` (e.g., 25–35 bps), `baseHigh` (e.g., 35–60 bps), and tight-mode duration (timestamp-only vs a few trades).

## H-003 — Inventory-skewed asymmetric bid/ask fees

- Status: `proposed`
- Depends on: A-001
- Mechanism (`FACT` references):
  - Only state is `slots[0..31]` (`contracts/src/AMMStrategyBase.sol`).
  - Fees are directional (bid fee when AMM buys X; ask fee when AMM sells X) (`amm_sim_rs/src/amm/cfmm.rs`).
- Hypothesis:
  - Skewing bid/ask based on reserve ratio (inventory imbalance) improves edge by attracting the “good” side of retail flow while discouraging the side that increases arb vulnerability.
- Measurable prediction:
  - Edge improves vs symmetric-fee control at equal average fee, with reduced tail losses (better p05 edge).
- Implementation sketch:
  - Store initial reserves (or initial ratio) in slots at `afterInitialize`.
  - On each trade, compute a normalized imbalance metric and apply a bounded skew: `bidFee = base + skew(imbalance)`, `askFee = base - skew(imbalance)`.
- Experiment plan:
  - Sweep skew strength and clamp ranges; compare to symmetric baseline at 100 and 1000 sims.

## H-004 — Volatility proxy via inferred price changes or trade shock

- Status: `proposed`
- Depends on: H-001 (or a fallback proxy), A-001
- Mechanism (`FACT` references):
  - Fair price follows GBM; per-sim sigma varies (`research/JUDGING_ALGORITHM.md`).
- Hypothesis:
  - Estimating short-term volatility and widening the spread in high-vol regimes reduces arb losses more than it reduces retail capture.
- Measurable prediction:
  - Edge improves primarily by reducing arbitrage edge leakage; retail volume may decrease slightly.
- Implementation sketch:
  - Maintain an EMA of absolute log-returns of `p_est` (from H-001) or of trade price impact as a proxy.
  - Map volatility estimate to a base fee within a clamp band (e.g., 28–55 bps).
- Experiment plan:
  - Compare fixed-fee baselines vs volatility-adaptive fee baselines; test across multiple 1000-sim runs.

## H-005 — Hysteresis/decay to avoid fee oscillation

- Status: `proposed`
- Depends on: A-001
- Mechanism (`FACT` references):
  - Strategy is only called on trades and must be stable under random retail flow (`amm_sim_rs/src/market/retail.rs`).
- Hypothesis:
  - Adding hysteresis/decay to fee updates improves edge by preventing overreaction to noisy retail trades while still reacting to genuine shocks.
- Measurable prediction:
  - Lower edge standard deviation (`edgeStd`) at similar mean edge, and improved p05 edge.
- Implementation sketch:
  - Store current fee(s) and a decay counter; update fees by bounded increments; decay toward base when no shock signal.
- Experiment plan:
  - Sweep decay rates and step sizes; validate improvement persists at 1000 sims.

## H-006 — Trade-size reactive widening with direction-aware thresholds

- Status: `proposed`
- Depends on: A-001
- Mechanism (`FACT` references):
  - Retail sizes are lognormal; some large outliers exist (`amm_sim_rs/src/market/retail.rs`).
- Hypothesis:
  - Using different “large trade” thresholds for buys vs sells (and widening only the vulnerable side) beats symmetric “widen after large trades”.
- Measurable prediction:
  - Improved edge at similar average fee and similar retail volume.
- Experiment plan:
  - Implement per-side thresholds based on `amountY / reserveY` and test a small grid.

---

## Triage notes

- If baseline edge variance across evaluations is large (A-003), prioritize hypotheses that win robustly on local seeds rather than chasing tiny leaderboard deltas.
- If interpretation of “average fees” differs (A-002), use volume-weighted diagnostics in our own experiment logs in addition to step-average fees.

