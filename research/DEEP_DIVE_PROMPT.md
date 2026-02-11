# Phase 7 Deep Dive Prompt (Expert): Explore Problem + Action Space, Expand Opportunity Catalog

You are an expert in market microstructure, AMM design, statistical inference, and control/learning systems. Your job is to explore the *actual* problem defined by this repository (not generic AMM advice), then expand the autonomous opportunity catalog using the scientific method.

## Mission

1. Build a clear, falsifiable model of *what drives Edge* in this simulator (retail edge vs arbitrage loss, routed competition vs the 30 bps normalizer).
2. Map the strategy action space: what signals you can infer, what state you can store, and what controls you can apply.
3. Study all accumulated lessons/insights in-repo and in Phase 7 state.
4. Expand the opportunity catalog so it contains **12 total family classes** and **at least 20 new opportunities** beyond the baseline catalog, with concrete search plans.

If the catalog already meets the numerical targets, treat (4) as: verify it, then improve the taxonomy and search plans so the added opportunities are truly orthogonal and testable.

## Ground Truth Artifacts (Read These First)

- Simulator + objective:
  - `README.md`
  - `research/JUDGING_ALGORITHM.md`
  - `research/TESTING_GUIDE.md`
  - `amm_sim_rs/src/simulation/engine.rs`
  - `amm_sim_rs/src/market/arbitrageur.rs`
  - `amm_sim_rs/src/market/router.rs`
  - `contracts/src/IAMMStrategy.sol`
  - `contracts/src/AMMStrategyBase.sol`
- Scientific workflow scaffolding:
  - `research/AUTONOMOUS_STRATEGY_SYSTEM_GUIDE.md`
  - `research/ASSUMPTIONS_REGISTER.md`
  - `research/HYPOTHESES_BACKLOG.md`
  - `research/templates/HYPOTHESIS_TEMPLATE.md`
  - `research/templates/EXPERIMENT_TEMPLATE.md`
- Phase 7 state (lessons + best mechanisms so far):
  - `.ralph-amm/phase7/state/.best_strategy.sol`
  - `.ralph-amm/phase7/state/.best_edge.txt`
  - `.ralph-amm/phase7/state/.knowledge_context.json`
  - `.ralph-amm/phase7/state/synthesis_report.md`
  - `.ralph-amm/phase7/state/.opportunity_history.json`
  - `.ralph-amm/phase7/state/.execution_gates.json`

## Known High-Performance Mechanisms (From Synthesis)

From `.ralph-amm/phase7/state/synthesis_report.md`, mechanisms that repeatedly appear in higher-edge strategies include:

- `fair_price_inference`, `gamma_calculation`, `inventory_skew`
- `dual_regime_quoting`, `regime_switching`, `timestamp_gating`
- `max_jump_limit`, `ewma_smoothing`, `protection_buffer`

Treat these as *observations*, not prescriptions: they motivate hypotheses and ablations.

## Map The Action Space (What You Can Actually Do)

### Observations available at each callback

- Only `TradeInfo` for the trade that hit *your* AMM:
  - direction (`isBuy`)
  - sizes (`amountX`, `amountY`)
  - time (`timestamp`)
  - post-trade reserves (`reserveX`, `reserveY`)

### Controls

- You set next quote via `(bidFee, askFee)` every time your AMM trades.
- Fees are directional and bounded (see validator/contract helpers).

### State / memory

- Exactly `slots[0..31]` (no contract state vars).
- Any inference must be deterministic and robust to not being called on steps where you receive no flow.

### Derived signals (explicitly label as `HYPOTHESIS` until validated)

- Spot price, inventory ratio, and price impact from the last trade
- Arb-vs-retail classification (e.g., closed-form arb sizing consistency)
- Arb-implied fair price estimator (from post-trade reserves + your quoted gamma)
- Short-term volatility proxy (from inferred price changes, impact, arb frequency)
- Flow burst / order-flow imbalance proxies (signed volume, streaks, trade counts)
- Confidence/uncertainty measures for any inferred state (to gate behavior)

## Scientific Method Requirements (Do Not Skip)

For any new family class or opportunity you add:

1. **Observation**: cite which repo artifact motivated it (mechanism table, leaderboard findings, failure modes in priors/history).
2. **Question**: what decision boundary or tradeoff is being targeted (retail capture vs arb leakage, brittleness vs responsiveness, etc.)?
3. **Hypothesis**: one sentence, falsifiable, with a measurable prediction under `amm-match run --simulations 1000`.
4. **Experiment design**: control vs treatment, ablations, and a parameter sweep plan.
5. **Decision rule**: promotion/kill criteria and what you will conclude either way.

Use the repo’s templates and registers (`research/templates/*`, `research/*REGISTER*.md`) to keep it reproducible.

## Catalog Expansion Deliverable (What To Add)

The catalog is implemented by the Phase 7 opportunity engine:

- `scripts/amm-phase7-opportunity-engine.py`

Your changes must add:

- **>= 2 new family classes** if fewer than 12 exist.
- **>= 20 new opportunities** beyond the baseline catalog.

### Opportunity definition checklist

Each opportunity should have:

- A stable snake_case `id` (prefer suffix `_search`).
- A `family_class` (snake_case).
- A small `subfamily` catalog (2-4 options) representing orthogonal variants.
- A short rationale that ties to a hypothesis and the current signals (`plateau_strength`, `brittleness_strength`, `sweep_failure_strength`).
- A search plan template (`frozen_core`, `mutation_dimensions`, `run_budget`, `promotion_criteria`, `kill_criteria`, and ideally a `falsification_test`).

Avoid “same idea, new name” opportunities. Each should change either:

- what is being inferred (state-estimation), or
- how control is applied (gating/asymmetry/optimal control), or
- how search is conducted (BO/meta-search), or
- what robustness criterion is enforced (tail risk / distribution shift / guardrails).

## Implementation Guidance (Where to Edit)

In `scripts/amm-phase7-opportunity-engine.py`, you will typically need to update:

- `FAMILY_CLASS_BY_ID` (map opportunity id -> family class)
- `SUBFAMILY_CATALOG_BY_ID` (opportunity id -> list of subfamilies)
- `NOVELTY_PRIOR_BY_FAMILY_CLASS` and `BREAKTHROUGH_PRIOR_BY_FAMILY_CLASS` (for new family classes)
- `build_candidates()` (add candidates with expected uplift/confidence/etc)
- `default_plan_template()` (ensure new opportunities get a meaningful plan template)

## Acceptance Criteria

You are done when:

- The catalog contains **12 total family classes**.
- The catalog includes **at least 20 new opportunities** beyond the baseline.
- The opportunity engine still runs end-to-end without schema breaks.
- Each new family class has at least one opportunity with a concrete search plan and falsification test.

## Output Required From You (Expert Report)

Produce a short report (1-2 pages) that includes:

- Updated family-class taxonomy and what each family is for
- A table of all new opportunities: `id`, `family_class`, `hypothesis`, `primary mutation dimensions`
- The top 5 opportunities you would execute next, with experiment plans and expected failure modes

