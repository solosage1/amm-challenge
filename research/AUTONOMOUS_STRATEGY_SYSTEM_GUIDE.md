# Autonomous Strategy Development/Testing/Scoring — Onboarding Guide

Audience: an expert building an **autonomous** system to generate, test, and iterate AMM fee strategies for this repo’s simulator.

Goal: align your system with (a) what the simulator actually optimizes and (b) a scientific workflow that keeps leaderboard-inspired ideas reproducible and falsifiable.

This guide is an entrypoint; it links out to the repo’s canonical documentation and the research artifacts added in `research/`.

## 1) Ground truth: what you are optimizing

### Edge (primary objective)

`FACT`: Website-style matches are **head-to-head** against a fixed **30 bps normalizer**, and the winner is determined by **Edge**, not PnL.

- Edge definition + code pointers: `research/JUDGING_ALGORITHM.md`
- Where edge is accumulated in the Rust engine: `amm_sim_rs/src/simulation/engine.rs`

Intuition:

- Retail flow is “uninformed” and generates **positive edge** (you earn spread).
- Arbitrage is “informed” and generates **negative edge** (you lose to correct pricing).

So “good” = maximize retail edge **while** minimizing arb losses.

### PnL (secondary / diagnostic)

PnL is computed from end-of-simulation portfolio value at fair price (reserves + accumulated fees). It is **not** the win criterion, but often correlates with edge.

- PnL definition + engine pointers: `research/JUDGING_ALGORITHM.md`

### Match and randomness model (important for your autonomous system)

`FACT`: Local runs use deterministic RNG seeding: simulation `i` uses seed `i`, and the same seed drives both the GBM and the per-simulation hyperparameter draws (retail rate, mean size, sigma). This is described in `research/JUDGING_ALGORITHM.md` and implemented in `amm_competition/competition/match.py`.

Implication:

- A “100-sim score” is a deterministic average over seeds `0..99`.
- Increasing `--simulations` increases the seed set and reduces sampling error.
- “Website vs local” differences are primarily about **different seeds/seed schedules** and potentially different aggregation/diagnostics; see `research/TESTING_GUIDE.md`.

## 2) Simulator mechanics your generator must respect

### Step order and the “arb signal” opportunity

`FACT`: Each step runs:

1. Fair price moves (GBM)
2. Arbitrage executes first on each AMM (≤ 1 arb trade per AMM per step)
3. Retail orders arrive and get optimally routed

See `amm_sim_rs/src/simulation/engine.rs`.

`FACT`: The strategy is only called when your AMM trades; `afterSwap` runs **immediately after each trade** and sets the fee quote for the next trade. See `amm_sim_rs/src/amm/cfmm.rs` and `contracts/src/IAMMStrategy.sol`.

Key leverage:

- If an arbitrage trade hits you at timestamp `t`, your `afterSwap` executes before any retail trades at the same timestamp. You can treat “an arb just happened” as an immediate signal and adjust fees for retail later in that step.

### AMM model (what fee changes actually do)

`FACT`: Constant-product (`x*y=k`), fee-on-input, and **fees are not reinvested** into reserves (so `k` does not inflate). See `amm_sim_rs/src/amm/cfmm.rs`.

Implication:

- Your fee policy changes:
  - the no-arbitrage band (when arb is profitable)
  - the size/frequency of arb trades (closed form in `amm_sim_rs/src/market/arbitrageur.rs`)
  - retail routing share (nonlinear in fees via `amm_sim_rs/src/market/router.rs`)

### Strategy interface and available signals

`FACT`: You only see the `TradeInfo` for the trade that just happened (direction, amounts, timestamp, post-trade reserves). See `contracts/src/IAMMStrategy.sol`.

You do **not** directly observe:

- the fair price
- the retail order stream when you don’t get routed
- which AMM the normalizer quoted, except indirectly via your own routing outcomes

Any inference about those must be treated as a `HYPOTHESIS` and validated.

### Hard constraints (must be enforced in autonomous generation)

`FACT` constraints you must compile/validate against:

- 32 storage slots only: `contracts/src/AMMStrategyBase.sol`
- Forbidden opcodes in deployed runtime bytecode: `amm_competition/evm/compiler.py`
- Blocked source patterns (no calls/assembly/new/etc.): `amm_competition/evm/validator.py`
- Gas limits per callback: `amm_sim_rs/src/evm/strategy.rs`

Practical guidance:

- Avoid unbounded loops and heavy math in `afterSwap`.
- Stick to integer/WAD arithmetic and the helpers in `AMMStrategyBase`.
- Keep state minimal and explicit (document your `slots[]` layout for each strategy).

## 3) What we learned from the leaderboard (and what we did NOT)

### Snapshot and findings

We captured a Top-20 snapshot and derived diagnostics:

- Snapshot table: `research/LEADERBOARD_SNAPSHOT_2026-02-10.md`
- Findings summary: `research/LEADERBOARD_FINDINGS.md`
- Raw/derived data: `research/data/leaderboard/2026-02-10/`

`FACT` (from the snapshot):

- Top-20 AvgEdge clustered tightly (~523.8–526.4).
- Reported average quoted fees clustered ~35–38 bps.
- 19/20 entries showed average `askFee < bidFee` (small asymmetry).
- Reported volumes: retail and arb volumes both decreased as average fee increased (strong negative correlation within the Top-20 snapshot).

`UNKNOWN`:

- Competitor Solidity source code was not publicly available at capture time.

Therefore:

- Any statement of the form “the winners are doing X in code” is a `HYPOTHESIS`.
- Our job is to turn those into experiments and falsify/validate them locally.

## 4) The scientific methodology (how this repo keeps progress reproducible)

Start here: `research/README.md`.

We explicitly separate:

- `FACT`: verified by code or committed data
- `ASSUMPTION`: required for interpretation but unverified
- `HYPOTHESIS`: testable claim with measurable prediction
- `UNKNOWN`: explicitly not known

### Registers (the “spine” your autonomous system should plug into)

- Assumptions: `research/ASSUMPTIONS_REGISTER.md`
  - Use when a claim depends on external/uncertain details (e.g., “website average fees are step-average”).
- Hypotheses: `research/HYPOTHESES_BACKLOG.md`
  - Convert patterns into testable items with clear predictions + experiments.
- Experiments: `research/experiments/README.md`
  - Each experiment log captures commands, config, git SHA, and a decision.

### Templates (use these verbatim to keep logs consistent)

- `research/templates/HYPOTHESIS_TEMPLATE.md`
- `research/templates/ASSUMPTION_TEMPLATE.md`
- `research/templates/EXPERIMENT_TEMPLATE.md`

## 5) How to adapt an autonomous system to this methodology

### A. Treat candidate generation as “hypothesis instantiation”

Instead of producing arbitrary strategies, structure generation around hypotheses:

1. Select `H-###` from `research/HYPOTHESES_BACKLOG.md`
2. Generate a family of implementations + parameter variants that all correspond to that hypothesis
3. Run the testing pyramid (10 → 100 → 1000) and record results as an experiment
4. Promote or kill the hypothesis, not just the candidate

This prevents “blind search” that can’t be explained or reproduced.

### B. Enforce constraints early (fail fast)

Autonomy killer: spending compute on candidates that can’t be submitted.

Your pipeline should hard-gate:

1. `amm-match validate <file>` (static validator + compilation)
2. `amm-match run <file> --simulations 10` (runtime smoke test)

Only then do 100/1000-sim evaluations.

### C. Use controlled comparisons and ablations

Make your scoring system produce answers to:

- “Did the new mechanism help?” (control vs treatment)
- “Which component matters?” (ablation tests)
- “Is it robust?” (more seeds / more sims / multiple seed batches)

Minimum record for every run:

- strategy file path + content hash
- constants/parameters
- simulation count and any config overrides
- git SHA
- outputs (avgEdge, and any diagnostics you collect)

### D. Don’t confuse “average fee diagnostics” with your internal objective

`FACT`: edge is the objective; “average fees” are only a diagnostic. Also, “average fees” may not be volume-weighted (see A-002 in `research/ASSUMPTIONS_REGISTER.md`).

Recommendation:

- Always optimize edge directly.
- Track both step-average and volume-weighted fees in your internal analytics if you add instrumentation.

### E. Add robustness evaluation beyond seeds 0..N-1

`FACT`: local CLI uses seeds `0..N-1` deterministically (`amm_competition/competition/match.py`).

If your system is truly autonomous, add one of:

- a seed-offset capability (multiple independent “batches” of 100/1000 sims)
- or direct use of `MatchRunner` with custom `SimulationConfig.seed` values

This reduces overfitting to the fixed seed schedule and improves transfer to website evaluation.

### F. Prefer improvements that exploit known mechanics

The current backlog already encodes several high-leverage directions:

- H-001: infer fair price from arb-like trades
- H-002: “post-arb tighten” to win retail routing in the same step
- H-003: inventory-skewed asymmetric bid/ask quoting
- H-004: volatility proxy (adaptive base fee)
- H-005: hysteresis/decay to avoid oscillation
- H-006: direction-aware trade-size thresholds

Use these as the “curriculum” for your generator, not as guarantees.

### G. Score more than “one scalar” in your internal system

`FACT`: The public CLI prints a single scalar (average edge of the submission AMM), but the match result also contains baseline edge/PnL and win counts. See `amm_competition/cli.py` and `amm_competition/competition/match.py`.

Recommendation:

- Internally record at least:
  - `avgEdge_submission`, `avgEdge_normalizer`, and `edgeAdvantage = submission - normalizer`
  - `avgPnL_submission`, `avgPnL_normalizer` (diagnostic)
  - `wins/losses/draws` (diagnostic)
- If you add instrumentation, also record:
  - retail and arb volumes (Y)
  - step-average vs volume-weighted average fees (bid/ask)

This lets your system distinguish “better because more retail share” vs “better because less arb leakage” and prevents optimizing the wrong proxy.

### H. Make robustness a first-class objective (not an afterthought)

`FACT`: With deterministic seeds `0..N-1`, it’s easy to overfit to that fixed schedule.

A practical autonomous pattern is:

1. Optimize on a development seed-batch (e.g., 100–300 sims)
2. Periodically run a *different* seed-batch (“holdout”) and require the improvement persists
3. Only then spend budget on 1000+ sims

Implementing multiple batches requires either:

- a seed-offset parameter in your runner, or
- direct construction of `SimulationConfig` with custom `seed` values

Even a small number of independent batches materially improves transfer to the website.

## 6) Suggested minimal integration plan (what to do first)

1. Read `research/README.md`, `research/JUDGING_ALGORITHM.md`, and `research/TESTING_GUIDE.md`.
2. Reproduce baseline sanity checks in `research/SIMULATION_RESULTS.md`.
3. Pick one hypothesis (e.g., H-003) and implement it as a parameterized strategy family.
4. Run and log one full experiment using `research/templates/EXPERIMENT_TEMPLATE.md`.
5. Update hypothesis status in `research/HYPOTHESES_BACKLOG.md` and note any new assumptions in `research/ASSUMPTIONS_REGISTER.md`.

## 7) File map (share these with the expert)

Research entrypoints:

- `research/README.md`
- `research/AUTONOMOUS_STRATEGY_SYSTEM_GUIDE.md` (this file)

Leaderboard research artifacts:

- `research/LEADERBOARD_SNAPSHOT_2026-02-10.md`
- `research/LEADERBOARD_FINDINGS.md`
- `research/data/leaderboard/2026-02-10/README.md`
- `research/data/leaderboard/2026-02-10/top20.json`
- `research/data/leaderboard/2026-02-10/top20_metrics.json`

Scientific workflow:

- `research/ASSUMPTIONS_REGISTER.md`
- `research/HYPOTHESES_BACKLOG.md`
- `research/experiments/README.md`
- `research/templates/HYPOTHESIS_TEMPLATE.md`
- `research/templates/ASSUMPTION_TEMPLATE.md`
- `research/templates/EXPERIMENT_TEMPLATE.md`

Canonical mechanics + workflow:

- `research/JUDGING_ALGORITHM.md`
- `research/TESTING_GUIDE.md`
- `research/SIMULATION_RESULTS.md`

Key code references (ground truth mechanics/constraints):

- Engine step order + edge accumulation: `amm_sim_rs/src/simulation/engine.rs`
- AMM model + `afterSwap` timing: `amm_sim_rs/src/amm/cfmm.rs`
- Arb closed-form: `amm_sim_rs/src/market/arbitrageur.rs`
- Retail routing split formulas: `amm_sim_rs/src/market/router.rs`
- Retail flow model: `amm_sim_rs/src/market/retail.rs`
- Match runner + seed schedule: `amm_competition/competition/match.py`
- CLI entrypoint (what is printed vs what is available): `amm_competition/cli.py`
- Strategy interface: `contracts/src/IAMMStrategy.sol`
- Slot helpers/limits: `contracts/src/AMMStrategyBase.sol`
- Compiler forbidden opcodes: `amm_competition/evm/compiler.py`
- Validator blocked patterns: `amm_competition/evm/validator.py`
- Gas limits: `amm_sim_rs/src/evm/strategy.rs`
