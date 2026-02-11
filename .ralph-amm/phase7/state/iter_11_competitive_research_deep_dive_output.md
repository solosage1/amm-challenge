# Iter 11 Output: Competitive Research Deep Dive -> Simplified Loop Upgrades

## Executive Summary

- **Baseline to beat:** our current champion is `GammaSquaredDualRegime` at **509.23** edge. (evidence: `.ralph-amm/phase7/state/.best_strategy.sol` :: `getName()`; evidence: `.ralph-amm/phase7/state/.best_edge.txt`)
- **Competitive frontier:** multiple forks cluster around **523-523.6** best-reported edge and public top scores are **524-527** edge, implying we likely need a **mechanism/backbone step-change** rather than incremental tuning of our current 4-slot strategy. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: Executive Summary, "Top leaderboard scores")
- **Winning architecture converges:** top forks largely implement a BandShield-family decomposition:
  - `Fee = Base(regime) + Symmetric(toxicity, activity) + Skew(direction)` using ~10-12 state slots with EMAs and tail compression. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "BandShield Family"; evidence: `.ralph-amm/research/forks/shl0k28/strategies/Strategy.sol` :: constants, slots, fee computation; evidence: `.ralph-amm/research/forks/The-CTra1n/experiments/STATUS.md` :: "New Thesis")
- **Simplified-loop mismatch:** our current simplified loop’s mechanism boundaries are defined around a small, dual-regime gamma-squared strategy and **cannot** express core winning mechanisms (dir skew, tox EMAs, sigma/lambda/size regime, tail compression) without a backbone swap plus new definitions. (evidence: `.ralph-amm/phase7/config/mechanism_definitions.json` :: mechanism keys and anchors; evidence: `.ralph-amm/phase7/state/.best_strategy.sol` :: slot layout)
- **Recommended path:** implement a controlled **Bootstrap + Refine**:
  1. **Bootstrap** champion to a BandShield-class backbone by porting a known-good external strategy file (from our local research archive).
  2. Immediately switch mechanism definitions to a BandShield-oriented set.
  3. Fix evaluation + promotion logic to incorporate **screen edge**, **robustness**, and **cross-seed** validation.
  4. Run 10 iterations targeting the biggest levers: arb classification width, stale-direction protection, convex toxicity (quad/cubic), trade-aligned tox boost, asymmetric tail compression. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Key Mechanisms That Work" + "Parameter Sensitivity"; evidence: `.ralph-amm/research/forks/shl0k28/notes/research_log.md` :: Iteration 33 findings; evidence: `.ralph-amm/research/forks/MacroWang001/strategies/yq-v2_523.sol` :: cubic tox, trade-tox boost, asym tail)

## Best-Known Competitive Strategy Blueprint (BandShield Family)

### The simulator microstructure that drives the solution

1. **Arb hits first each timestamp (step), retail follows in the same timestamp.**
2. **Fee chosen after a trade is a quote for the next unknown event.**
3. **Routing is sharply fee-sensitive:** being slightly above the 30 bps normalizer can lose a lot of retail share. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Simulator-Specific Insights")

### Canonical decomposition (what 520+ strategies implement)

All high performers implement some equivalent of:

1. **Arb classification (first trade + size-based)**
2. **Fair price estimation** (`pHat`) from post-trade spot and fee-in-use, with a **shock gate**
3. **Volatility proxy** (`sigmaHat`) tracking fair-price moves and feeding base fee
4. **Activity / flow intensity proxies** (`lambdaHat`, `sizeHat`, `actEma`)
5. **Toxicity/staleness** (`toxEma`) from `abs(spot - pHat) / pHat`, with **convex response** (quad/cubic)
6. **Directional pressure** (`dirState`) and a **skew application** that defends the vulnerable side and discounts the safe side
7. **Stale-direction protection** based on the sign of `(spot - pHat)`
8. **Tail compression** above a knee to avoid routing starvation at extreme fees (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Key Mechanisms That Work"; evidence: `.ralph-amm/research/forks/shl0k28/strategies/Strategy.sol` :: full afterSwap; evidence: `.ralph-amm/research/forks/The-CTra1n/experiments/STATUS.md` :: "Fee policy should be decomposed")

### Update and decision-rule pseudocode (canonical EMA style)

Below is pseudocode aligned to the clean, decomposed EMA designs (shl0k28 Strategy.sol / MacroWang yq-v2 / CTra1n thesis):

```text
on afterSwap(trade):
  load state: lastTs, bidFee, askFee, dirState, actEma, pHat, sigmaHat, lambdaHat, sizeHat, toxEma, stepTradeCount

  isNewStep = trade.timestamp > lastTs
  if isNewStep:
    elapsed = min(trade.timestamp - lastTs, ELAPSED_CAP)
    dirState = decayCentered(dirState, DIR_DECAY, elapsed)
    actEma   = actEma * ACT_DECAY^elapsed
    sizeHat  = sizeHat * SIZE_DECAY^elapsed
    toxEma   = toxEma * TOX_DECAY^elapsed
    lambdaHat = EMA(lambdaHat, stepTradeCount / (trade.timestamp - lastTs), LAMBDA_DECAY)   // when prior step had trades
    stepTradeCount = 0

  firstInStep = (stepTradeCount == 0)

  spot = reserveY / reserveX
  feeUsed = trade.isBuy ? prevBidFee : prevAskFee
  gamma = 1 - feeUsed
  pImplied = trade.isBuy ? spot * gamma : spot / gamma

  tradeRatio = amountY / reserveY  (clamp to cap)

  // Arb classification (common best practice)
  likelyArb = firstInStep && (tradeRatio <= arbCap)
  // where arbCap is often fixed OR adaptive (ratioEWMA + sigmaHat), capped

  // Fair price and sigma updates
  if firstInStep:
    ret = abs(pImplied - pHat) / pHat
    if ret <= shockGate (constant or adaptive with sigmaHat):
      pHat = EMA(pHat, pImplied, alphaArb if likelyArb else alphaRetail)
    sigmaHat = EMA(sigmaHat, clamp(ret), SIGMA_DECAY)
  else:
    sigmaHat = sigmaHat * SIGMA_RETAIL_DECAY  (optional slow decay)

  // Direction + activity + size updates (gated by signal threshold)
  if tradeRatio > SIGNAL_THRESHOLD:
    dirState += signedPush(trade.isBuy, tradeRatio)
    actEma   = EMA(actEma, tradeRatio, ACT_BLEND_DECAY)
    sizeHat  = EMA(sizeHat, tradeRatio, SIZE_BLEND_DECAY)

  // Toxicity update (every trade)
  tox = abs(spot - pHat) / pHat
  toxEma = EMA(toxEma, clamp(tox), TOX_BLEND_DECAY)

  // Fee model
  flowSize = lambdaHat * sizeHat
  fBase = BASE_FEE + SIGMA_COEF*sigmaHat + LAMBDA_COEF*lambdaHat + FLOW_SIZE_COEF*flowSize
  fMid  = fBase + TOX_COEF*toxEma + TOX_QUAD_COEF*toxEma^2 + ACT_COEF*actEma
  optionally: + TOX_CUBIC_COEF*toxEma^3 + SIGMA_TOX_COEF*(sigmaHat*toxEma)

  // Skew
  dirDev, sellPressure = abs(dirState - WAD), sign(dirState - WAD)
  skew = DIR_COEF*dirDev + DIR_TOX_COEF*(dirDev*toxEma)
  (bid, ask) = applySkew(fMid, skew, sellPressure)

  // Stale-direction protection
  staleShift = STALE_DIR_COEF * toxEma
  (bid, ask) = applyStaleShift(bid, ask, spot >= pHat, staleShift, optionalAsymAttract)

  // Optional trade-aligned boost (MacroWang)
  if (trade direction aligns with stale sign):
    add TRADE_TOX_BOOST * tradeRatio to the vulnerable side

  // Tail compression (possibly asymmetric slopes)
  bid = compressTail(bid); ask = compressTail(ask)
  bid = clampFee(bid); ask = clampFee(ask)

  stepTradeCount++
  store state, return (bid, ask)
```

Key differences between top implementations are not the spine, but:
- **arbCap design** (fixed vs adaptive ratioEWMA + sigma)
- **shock gate** (static vs sigma-adaptive)
- **convexity and interactions** (tox^2 vs tox^3 vs sigma*tox)
- **tail compression shape** (symmetric vs asymmetric protect/attract)
- **extra directional overlays** (trade-aligned boosts, asym stale attraction) (evidence: `.ralph-amm/research/forks/shl0k28/notes/research_log.md` :: Iteration 33 arb-width lever; evidence: `.ralph-amm/research/forks/MacroWang001/strategies/yq-v2_523.sol` :: "Adaptive Shock Gate", "Cubic Toxicity", "Trade-Tox Boost", "Asymmetric tail compression")

## Mechanism Inventory + State Slots (Minimal Set)

### Minimal state slots (10-12) that cover the winning blueprint

The smallest set that matches the decomposed BandShield family is:

1. `bidFee` (WAD)
2. `askFee` (WAD)
3. `lastTimestamp` (uint)
4. `dirState` centered at WAD (signed via offset from WAD)
5. `actEma`
6. `pHat` fair price
7. `sigmaHat`
8. `lambdaHat`
9. `sizeHat`
10. `toxEma`
11. `stepTradeCount`
12. (Optional but high ROI) `ratioEWMA` for adaptive arbCap

(evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Core state variables (11 slots)"; evidence: `.ralph-amm/research/forks/shl0k28/strategies/Strategy.sol` :: slot layout; evidence: `.ralph-amm/research/forks/MacroWang001/strategies/yq-v2_523.sol` :: slot layout; evidence: `.ralph-amm/research/forks/shl0k28/strategies/Strategy_evo_best.sol` :: ratioEWMA slot)

### Update cadence and what each slot "means"

- `lastTimestamp`: step boundary; defines firstInStep. (evidence: `.ralph-amm/research/forks/shl0k28/strategies/Strategy.sol` :: `isNewStep`, `firstInStep`)
- `stepTradeCount`: proxy for within-step burstiness; used to update `lambdaHat` on next step boundary. (evidence: `.ralph-amm/research/forks/shl0k28/strategies/Strategy.sol` :: lambda update block)
- `pHat`: only meaningful if you guard it; shock gate prevents retail manipulation / noise. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Fair Price Estimation"; evidence: `.ralph-amm/research/forks/MacroWang001/strategies/yq-v2_523.sol` :: adaptive gate)
- `sigmaHat`: per-step volatility proxy; drives base fee. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Volatility Tracking")
- `toxEma`: staleness signal; drives convex widening + stale-direction overlay. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Toxicity Signal")
- `dirState`: directional pressure; largest single lever via skew. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Directional Skew")
- `actEma`, `lambdaHat`, `sizeHat`: approximate "market is hot" and "orders are big"; these stabilize the base fee and protect in burst regimes. (evidence: `.ralph-amm/research/forks/The-CTra1n/experiments/STATUS.md` :: "Latent State Estimators"; evidence: `.ralph-amm/research/forks/shl0k28/strategies/Strategy.sol` :: `actEma`, `lambdaHat`, `sizeHat`)

### Parameter sensitivity hotspots (priors for fast iteration)

High sensitivity, tune carefully:
- `ARB_MAX_RATIO_WAD` / arbCap width (classification accuracy). (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Parameter Sensitivity"; evidence: `.ralph-amm/research/forks/shl0k28/notes/research_log.md` :: Iteration 33 "Strongest single lever")
- `STALE_DIR_COEF` (asymmetry impact). (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Parameter Sensitivity"; evidence: `.ralph-amm/research/forks/The-CTra1n/experiments/sweep_cma_latent.py` :: PARAMS includes STALE_DIR_COEF)
- `ACT_COEF` and `ACT_BLEND_DECAY` (activity widening can over-penalize routing share). (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Parameter Sensitivity"; evidence: `.ralph-amm/research/forks/The-CTra1n/experiments/sweep_cma_latent.py` :: ACT_BLEND_DECAY range)
- `TOX_QUAD_COEF` / convex tox terms (overly aggressive convexity can starve flow). (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Parameter Sensitivity"; evidence: `.ralph-amm/research/forks/MacroWang001/strategies/yq-v2_523.sol` :: TOX_CUBIC_COEF)

Moderate sensitivity:
- `BASE_FEE`, `DIR_COEF`, `FLOW_SIZE_COEF`, shock gate parameters. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Parameter Sensitivity"; evidence: `.ralph-amm/research/forks/The-CTra1n/experiments/sweep_cma_latent.py` :: PARAMS includes PHAT_SHOCK_GATE)

## Failure Modes and Anti-Patterns (Do Not Pursue)

These are empirically bad in this simulator and should be explicitly banned in prompts and/or treated as low-priority wildcards:

- **Continuation-hazard rebates / explicit carry-harvest controllers:** Any nonzero continuation rebate materially regressed; implication is that next-step carry protection dominates same-step harvesting. (evidence: `.ralph-amm/research/forks/shl0k28/notes/research_log.md` :: Iteration 10; evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Key finding from shl0k28")
- **Over-restrictive arb classifiers or side-alignment hard gates:** “Fee-aware, side-aligned arb classifier” regressed sharply. (evidence: `.ralph-amm/research/forks/shl0k28/notes/research_log.md` :: Iteration 11)
- **Regime FSMs / discrete ladders:** too complex, misfires, sometimes gas issues; net regression. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Regime Ladder / FSM"; evidence: `.ralph-amm/research/forks/shl0k28/notes/research_log.md` :: "Baseline Recovery" and early approaches)
- **Offside/mispricing gating:** consistently too punitive to routing share; large regressions. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Offside Gating")
- **Bayesian probability blending for arb vs retail:** miscalibration regressed. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Bayesian Arb Probability")
- **PI control / control-loop feedback:** overshoots; neutral to negative. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "PI Control")
- **First-trade-only fair recentering / over-filtering updates:** anchor becomes too stale; regression. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "First-Trade-Only Fair Recentering"; evidence: `.ralph-amm/research/forks/shl0k28/notes/research_log.md` :: Iteration 18)
- **Explicit arb-rate high-gain feedback states:** adding noisy arb-rate feedback regressed severely. (evidence: `.ralph-amm/research/forks/shl0k28/notes/research_log.md` :: Iteration 17)
- **Full architecture rewrites without a proven spine:** big regressions; incremental beats moonshots. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Full Architecture Rewrites"; evidence: `.ralph-amm/research/forks/shl0k28/notes/research_log.md` :: Iteration 9 + reversion check)

## Gap Analysis: Winning Mechanisms vs Our Simplified Loop

### What we have today

- Current champion is a **4-slot** strategy (`lastTimestamp`, `bidFee`, `askFee`, `fairPrice`) with a hard **tight-band 30 bps** and an outer regime that uses **gamma-squared competitor anchoring**. (evidence: `.ralph-amm/phase7/state/.best_strategy.sol` :: slot comment + afterSwap)
- Simplified-loop mechanisms are currently defined as:
  - `fair_price_estimation`, `flow_memory`, `arbitrage_response`, `tight_band_pricing`, `outer_regime_pricing`. (evidence: `.ralph-amm/phase7/config/mechanism_definitions.json`)

### What is missing vs the BandShield blueprint

Missing or non-representable with the current backbone:
- `dirState` + skew application (largest lever).
- `toxEma` + convex tox response.
- `sigmaHat` (and sigma-scaled base fee).
- `lambdaHat` and `sizeHat` (regime proxy).
- Tail compression (and asymmetric tail variants).
- Arb classification and adaptive arb caps.
- Trade-aligned toxicity boost / asym stale attraction variants. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Key Mechanisms That Work"; evidence: `.ralph-amm/research/forks/MacroWang001/strategies/yq-v2_523.sol`)

### Why "one mechanism at a time" currently blocks step-change exploration

Even if we add these ideas, they are tightly coupled:
- Adding `sigmaHat` requires both estimator updates and fee-model usage.
- Adding `toxEma` requires estimator updates plus symmetric widening plus stale-direction overlay.
- Directional skew needs `dirState` update and bid/ask assignment logic.

With the current five mechanisms centered on our current champion, these changes would span multiple regions and the loop would either reject candidates or silently allow uncontrolled edits when anchors fail to resolve. (evidence: `scripts/simplified_loop.py` :: `validate_candidate()` handling of `anchor_unresolved`; evidence: `.ralph-amm/phase7/config/mechanism_definitions.json` :: anchors tied to old spine)

### Evaluation gap: the loop treats "screen-only" as a failure

- `scripts/amm-test-pipeline.py` only sets `final_edge` when the 1000-sim gate runs; otherwise it records `testing.edge_screen` but leaves `final_edge` null. (evidence: `scripts/amm-test-pipeline.py` :: Step 6 gate; `final_edge` semantics)
- `scripts/simplified_loop.py` currently reads only `final_edge` and treats missing `final_edge` as an evaluation failure, incrementing invalid/compile-fail counts. (evidence: `scripts/simplified_loop.py` :: `evaluate_with_pipeline()`)

This materially slows exploration: many candidates that are informative at 200 sims get labeled as "failed" and are not incorporated as partial evidence.

### Concrete success criteria for loop changes

After upgrades, the loop should be able to:
- Bootstrap to a BandShield backbone (10-12 slots) and keep iterating safely.
- Have mechanism definitions that isolate at least these components:
  - `fair_price_and_arb`
  - `regime_estimators` (sigma/lambda/size + step decay)
  - `toxicity_and_activity`
  - `directional_skew_and_stale_protection`
  - `tail_compression`
- Promote champions only after a staged evaluation that includes robustness and at least light cross-seed checks. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Cross-Seed Validation (Critical)"; evidence: `.ralph-amm/research/forks/The-CTra1n/experiments/STATUS.md` :: "Evaluation Rules")

## Loop Upgrade Options (with Recommendation)

### Option 1: Bootstrap + refine (recommended)

#### What it is

Perform a controlled spine swap to a BandShield backbone, then refine the high-leverage mechanisms using the simplified loop.

#### Exactly which external strategy to port as the initial backbone

Start with one of these two already-local "BandShield EMA spine" candidates, evaluate quickly, then adopt the better one:

- Primary candidate: `.ralph-amm/research/forks/shl0k28/strategies/Strategy.sol` (`BandShield_ghost`) (evidence: `.ralph-amm/research/README.md` :: "Best-Performing Strategies")
- Alternative candidate with additional protections: `.ralph-amm/research/forks/MacroWang001/strategies/yq-v2_523.sol` (cubic tox + trade-tox boost + asymmetric tail compression) (evidence: `.ralph-amm/research/README.md` :: MacroWang note; evidence: `.ralph-amm/research/forks/MacroWang001/strategies/yq-v2_523.sol` :: constants + tail compression)

Minimal edits required:
- Ensure `contract Strategy` name preserved (both already do).
- Ensure imports are only `./AMMStrategyBase.sol` and `./IAMMStrategy.sol` or `TradeInfo` import; both compile under our inline compiler model. (evidence: `amm_competition/evm/compiler.py` :: inline sources include `AMMStrategyBase.sol`, `IAMMStrategy.sol`)
- Set `getName()` to an ASCII identifier if you want clean logging; not required for scoring.

#### Mechanism set changes (post-bootstrap)

Replace the current 5 mechanisms (built around GammaSquaredDualRegime) with a BandShield-oriented set aligned to real levers:

1. `fair_price_and_arb`
2. `regime_estimators` (step decay + sigma/lambda/size updates)
3. `toxicity_and_activity`
4. `directional_skew_and_stale_protection`
5. `tail_compression`

Rationale:
- Each maps to a coherent contiguous code region in decomposed EMA designs.
- It keeps the loop simple (5 mechanisms), but covers the actual winning mechanism families. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Key Mechanisms That Work"; evidence: `.ralph-amm/research/forks/The-CTra1n/experiments/STATUS.md` :: "explicitly separate three problems")

#### Mechanism-boundary migration (critical)

A spine swap invalidates the current anchors because they are keyed to the old champion code strings.

Do not rely on the default periodic policy evolution alone. Instead:
- Treat bootstrap as an explicit migration step:
  - copy in a prepared BandShield definitions file immediately, or
  - trigger policy evolution immediately after bootstrap to rebuild anchors to the new champion code.

This uses existing loop machinery rather than inventing a new system. (evidence: `scripts/simplified_loop.py` :: `maybe_run_policy_evolution()` and anchor validation)

#### Prompting changes (encode priors without drift)

Update the loop prompt template to include:
- A short "do not pursue" list (FSMs, hazard rebates, offside gating, PI control).
- A "must preserve spine" rule for all non-wildcard mechanisms:
  - Keep slot layout and estimators intact unless mechanism is explicitly `spine_swap`/wildcard.
- Parameter priors for the mechanism being edited (ranges, default starting point).

(evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Failed Approaches" and sensitivity tables; evidence: `.ralph-amm/research/forks/The-CTra1n/experiments/sweep_cma_latent.py` :: parameter ranges; evidence: `.ralph-amm/research/forks/shl0k28/notes/research_log.md` :: repeated revert discipline)

#### Evaluation changes (staged + cross-seed)

1. **Do not treat "no 1000-sim run" as failure.**
   - If `final_edge` is null, read `testing.edge_screen` and log it as a screen-only evaluation.
2. Promote only on an authoritative stage (1000-sim) plus robustness check.
3. Add cross-seed checks before promoting:
   - At minimum evaluate 3 offsets: `[0, 10000, 20000]`.
   - For final confirmations evaluate 5 offsets: `[0, 10000, 20000, 30000, 40000]`. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: cross-seed; evidence: `.ralph-amm/research/forks/The-CTra1n/experiments/sweep_cma_latent.py` :: TRAIN/HOLDOUT/FULL offsets)
4. Use a robust objective for promotion:
   - `mean_edge - k * std_edge` (CMA-ES style), or `mean_edge - penalty*(max-min)` (spread penalty),
   - and require it exceed champion by a margin (avoid overfitting noise). (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: "Robust objective"; evidence: `scripts/amm-test-pipeline.py` :: robustness spread penalty fields)

### Option 2: Expand mechanisms in-place (not recommended for step change)

#### What it is

Keep `GammaSquaredDualRegime` as the spine and try to add missing signals (toxicity, sigma proxy, direction memory) while preserving its two-regime pricing and competitor anchoring.

#### Why it is likely insufficient

- The current backbone has no natural place to incorporate the full decomposed EMA estimator stack without turning into a new backbone anyway.
- Mechanism boundaries are currently defined around tight-band/outside-band logic and fair update; you would be fighting the taxonomy.
- You will likely converge to an awkward hybrid that is harder to tune than directly adopting a known-good BandShield spine.

This option can still yield incremental gains, but it is not the fastest path to 520+. (evidence: `.ralph-amm/phase7/config/mechanism_definitions.json` :: current mechanisms; evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: Tier 1 requires 10-12 slots)

### Recommendation

Choose **Option 1 (Bootstrap + refine)**.

It is the cleanest way to:
- maximize reuse of external code that already works,
- keep the loop simple (5 real mechanisms),
- get an immediate step-change from ~509 toward the 520+ frontier.

## Concrete File-Level Change List

- `scripts/simplified_loop.py:1312`
  - Update `evaluate_with_pipeline()` to accept screen-only results:
    - If `final_edge` missing, use `testing.edge_screen` and record a status like `screen_only=true`.
    - Do not count screen-only as `compile_failed`.
  - Add optional multi-offset evaluation mode for promotion (e.g., `--seed-offsets 0,10000,20000`).
  - Add a bootstrap subcommand or flag:
    - `bootstrap --from .ralph-amm/research/forks/shl0k28/strategies/Strategy.sol` (or MacroWang),
    - runs pipeline, updates `.best_strategy.sol` and `.best_edge.txt`, resets `mechanism_stats.json`, installs new definitions.

- `scripts/amm-test-pipeline.py:372`
  - Optional: expose `testing.edge_screen` and gate decisions clearly (already present).
  - Optional: add a flag to "always set final_edge=edge_screen when 1000 is skipped" for loop friendliness, but only if you are comfortable with non-authoritative promotion semantics. Prefer the `simplified_loop.py` fix instead.

- `.ralph-amm/phase7/config/mechanism_definitions.json`
  - Add a BandShield definitions variant (recommended new file):
    - `.ralph-amm/phase7/config/mechanism_definitions_bandshield.json`
    - `.ralph-amm/phase7/config/mechanism_definitions_bandshield.yaml`
  - Keys: `fair_price_and_arb`, `regime_estimators`, `toxicity_and_activity`, `directional_skew_and_stale_protection`, `tail_compression`.
  - Anchors should be regex-first (`re:`) and keyed to stable code landmarks (slot comments, "isNewStep" block, fee-model block, tail compression helpers).

- `.ralph-amm/phase7/state/.best_strategy.sol`
  - For bootstrap: replace contents with the chosen backbone (`shl0k28 Strategy.sol` or `MacroWang yq-v2_523.sol`), then re-evaluate and update `.best_edge.txt`.

- `scripts/run-parallel-sims.sh`
  - Use it to benchmark multiple candidate backbones quickly during bootstrap selection (optional but high ROI).

## Next 10 Iterations: Experiment Roadmap

This roadmap assumes **Option 1** and a BandShield EMA backbone is adopted first. It also assumes we fix evaluation so screen-only results are logged and do not poison invalid counts.

1. **Bootstrap spine (wildcard/spine_swap)**
   - Compare `.ralph-amm/research/forks/shl0k28/strategies/Strategy.sol` vs `.ralph-amm/research/forks/MacroWang001/strategies/yq-v2_523.sol` at 200-sim screen across 3 seed offsets.
   - Promote the better mean minus penalty baseline.
   - Failure mode: mechanism definitions no longer match; immediately install BandShield definitions or trigger policy evolution once. (evidence: `scripts/simplified_loop.py` :: anchors; `.ralph-amm/research/LESSONS_LEARNED.md` :: cross-seed)

2. **Arb classification width (standard mechanism edit: `fair_price_and_arb`)**
   - Implement/adopt adaptive arbCap using ratioEWMA + sigmaHat and cap it.
   - Watch: arb leakage vs retail share proxy (edge; also robustness spread).
   - Failure mode: over-restrictive gates miss true arb anchors and stale pHat increases toxicity. (evidence: `.ralph-amm/research/forks/shl0k28/notes/research_log.md` :: Iteration 11 regression; Iteration 33 arb-width lever)

3. **Shock gate adaptation (standard edit: `fair_price_and_arb`)**
   - Replace static `PHAT_SHOCK_GATE` with sigma-adaptive gate and a floor (MacroWang style).
   - Watch: stability, reduced manipulation, improved robustness tails.
   - Failure mode: too permissive gate lets retail noise pollute pHat; too strict gate makes pHat stale. (evidence: `.ralph-amm/research/forks/MacroWang001/strategies/yq-v2_523.sol` :: adaptive gate; `.ralph-amm/research/forks/shl0k28/notes/research_log.md` :: Iteration 18 stale anchor)

4. **Convex toxicity: add cubic term (standard edit: `toxicity_and_activity`)**
   - Add `TOX_CUBIC_COEF * tox^3` or tune existing quad term.
   - Watch: reduced arb losses in high-tox windows without routing starvation.
   - Failure mode: too much convexity loses all retail share. (evidence: `.ralph-amm/research/forks/MacroWang001/strategies/yq-v2_523.sol` :: cubic tox)

5. **Trade-aligned toxicity boost (standard edit: `directional_skew_and_stale_protection`)**
   - Add a small extra fee on the vulnerable side when trade direction aligns with stale sign.
   - Watch: fewer pickoffs on vulnerable side, minimal safe-side harm.
   - Failure mode: high-gain feedback loops destabilize routing. (evidence: `.ralph-amm/research/forks/MacroWang001/strategies/yq-v2_523.sol` :: trade-tox boost; `.ralph-amm/research/forks/shl0k28/notes/research_log.md` :: warnings about feedback)

6. **Asymmetric stale attraction (standard edit: `directional_skew_and_stale_protection`)**
   - Introduce `STALE_ATTRACT_FRAC` so the safe-side discount is slightly stronger than the vulnerable-side widen.
   - Watch: routing share improvement without increasing arb exposure.
   - Failure mode: overly aggressive discount reintroduces pickoffs. (evidence: `.ralph-amm/research/forks/MacroWang001/strategies/yq-v2_523.sol` :: STALE_ATTRACT_FRAC)

7. **Asymmetric tail compression (standard edit: `tail_compression`)**
   - Use different slopes for protect vs attract side (MacroWang).
   - Watch: fewer catastrophic routing starvation events; improved robustness spread.
   - Failure mode: if knee too low, you under-earn in normal windows; if too high, you starve routing anyway. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: tail compression; `.ralph-amm/research/forks/MacroWang001/strategies/yq-v2_523.sol` :: tail slopes)

8. **Regime estimator tuning block (standard edit: `regime_estimators`)**
   - Tune `SIGMA_DECAY`, `LAMBDA_DECAY`, `SIZE_BLEND_DECAY`, plus coefficients `SIGMA_COEF`, `FLOW_SIZE_COEF`, `LAMBDA_COEF`.
   - Use small CMA-style coordinated sweeps if needed (but keep mechanism-only edits).
   - Failure mode: oversmoothing misses regime shifts; undersmoothing jitters fees and loses routing share. (evidence: `.ralph-amm/research/forks/The-CTra1n/experiments/sweep_cma_latent.py` :: interacting params; `.ralph-amm/research/forks/The-CTra1n/experiments/STATUS.md` :: separation thesis)

9. **Cross-seed promotion hardening (loop change, not Solidity)**
   - Implement: screen on 200 sims, validate on 1000 sims for top candidates, then run 3-offset mean - k*std before promoting.
   - Failure mode: promoting on a single offset leads to regressions online. (evidence: `.ralph-amm/research/LESSONS_LEARNED.md` :: cross-seed overfit gap)

10. **Mechanism-boundary maintenance (policy evolution / definitions update)**
   - After significant edits, run policy evolution or manually tighten anchors so validation is meaningful and not silently skipping unresolved spans.
   - Failure mode: anchors drift and "one mechanism at a time" becomes unenforced. (evidence: `scripts/simplified_loop.py` :: `anchor_unresolved` behavior; policy evolution templates)

