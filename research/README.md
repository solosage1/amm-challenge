# Research

This directory is the repo’s research notebook: leaderboard snapshots, empirical findings, and a hypothesis-driven process for building and testing AMM fee strategies.

## Canonical references (ground truth)

- [JUDGING_ALGORITHM.md](JUDGING_ALGORITHM.md) — match structure, scoring (edge vs PnL), step ordering, RNG variance
- [TESTING_GUIDE.md](TESTING_GUIDE.md) — practical workflow (10/100/1000 sims), debugging, iteration
- [SIMULATION_RESULTS.md](SIMULATION_RESULTS.md) — environment setup + baseline run sanity checks

## Definitions

We label statements explicitly to avoid “cargo-culting” leaderboard patterns:

- `FACT`: verified by code in this repo or by data files committed here
- `ASSUMPTION`: required for interpretation, but not yet verified (tracked in [ASSUMPTIONS_REGISTER.md](ASSUMPTIONS_REGISTER.md))
- `HYPOTHESIS`: a testable claim with a measurable prediction (tracked in [HYPOTHESES_BACKLOG.md](HYPOTHESES_BACKLOG.md))
- `UNKNOWN`: explicitly not known (e.g., private competitor code)

## Workflow (systematic loop)

1. Snapshot external data (leaderboard / submissions) into `research/data/...`
2. Summarize empirical patterns as `FACT` in `LEADERBOARD_*` docs
3. Translate patterns into `HYPOTHESIS` entries with clear predictions and tests
4. Implement and run local experiments (10 → 100 → 1000 sims)
5. Log results in `research/experiments/` and update hypothesis/assumption statuses

## Contents

- Onboarding
  - [AUTONOMOUS_STRATEGY_SYSTEM_GUIDE.md](AUTONOMOUS_STRATEGY_SYSTEM_GUIDE.md)
- Leaderboard
  - [LEADERBOARD_SNAPSHOT_2026-02-10.md](LEADERBOARD_SNAPSHOT_2026-02-10.md)
  - [LEADERBOARD_FINDINGS.md](LEADERBOARD_FINDINGS.md)
  - `research/data/leaderboard/` — raw + derived snapshot data
- Registers
  - [ASSUMPTIONS_REGISTER.md](ASSUMPTIONS_REGISTER.md)
  - [HYPOTHESES_BACKLOG.md](HYPOTHESES_BACKLOG.md)
- Process assets
  - `research/templates/` — templates for assumptions, hypotheses, and experiments
  - `research/experiments/` — experiment logs (results + decisions)

## Key mechanics to cite in research

These are `FACT` and should be referenced when writing hypotheses:

- Step sequence: fair price move → arbitrage → retail routing ([amm_sim_rs/src/simulation/engine.rs](../amm_sim_rs/src/simulation/engine.rs))
- Strategy is only called on trades; `afterSwap` runs immediately after each trade ([amm_sim_rs/src/amm/cfmm.rs](../amm_sim_rs/src/amm/cfmm.rs), [contracts/src/IAMMStrategy.sol](../contracts/src/IAMMStrategy.sol))
- Constant-product AMM, fee-on-input; fees are not reinvested into reserves ([amm_sim_rs/src/amm/cfmm.rs](../amm_sim_rs/src/amm/cfmm.rs))
- Router can shift large retail volume with small fee changes ([amm_sim_rs/src/market/router.rs](../amm_sim_rs/src/market/router.rs))
- Hard constraints: 32 storage slots, forbidden opcodes/patterns, and per-callback gas limits
  - Slots: [contracts/src/AMMStrategyBase.sol](../contracts/src/AMMStrategyBase.sol)
  - Forbidden opcodes: [amm_competition/evm/compiler.py](../amm_competition/evm/compiler.py)
  - Blocked patterns: [amm_competition/evm/validator.py](../amm_competition/evm/validator.py)
  - Gas limits: [amm_sim_rs/src/evm/strategy.rs](../amm_sim_rs/src/evm/strategy.rs)
