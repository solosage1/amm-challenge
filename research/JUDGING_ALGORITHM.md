# AMM Challenge: Judging Algorithm & Simulation Methodology

This document describes the exact algorithm used to judge entries in the AMM challenge, how metrics are computed, and strategies for achieving results as close as possible to the website's evaluation.

## Overview

The challenge judges entries through **head-to-head simulations** comparing your strategy against a fixed normalizer baseline (30 bps fees). Winners are determined by **edge**, not raw profit. Multiple simulations with randomized market conditions test strategy robustness.

---

📚 **For Practical Testing Workflows:** See [TESTING_GUIDE.md](TESTING_GUIDE.md) for step-by-step testing methodology, debugging guidance, and result interpretation.

---

## 1. Match Structure & Win Criteria

### Match Configuration

A match consists of multiple independent simulations, each running the submission strategy and baseline strategy in parallel under identical market conditions.

**Default configuration** ([amm_competition/competition/config.py](../amm_competition/competition/config.py)):
- **Number of simulations**: 1000
- **Steps per simulation**: 10,000
- **Initial reserves**: 100 X, 10,000 Y (price = 100)
- **Initial price**: 100.0
- **GBM drift (μ)**: 0.0 (no directional bias)
- **GBM dt**: 1.0
- **Retail buy probability**: 0.5
- **Retail order size volatility (σ)**: 1.2

### Hyperparameter Variance

Each simulation randomizes market conditions to test robustness ([amm_competition/competition/config.py](../amm_competition/competition/config.py)):

```python
BASELINE_VARIANCE = HyperparameterVariance(
    retail_mean_size_min=19.0,
    retail_mean_size_max=21.0,
    vary_retail_mean_size=True,
    
    retail_arrival_rate_min=0.6,
    retail_arrival_rate_max=1.0,
    vary_retail_arrival_rate=True,
    
    gbm_sigma_min=0.000882,      # 0.088%
    gbm_sigma_max=0.001008,      # 0.101%
    vary_gbm_sigma=True,
)
```

Each simulation independently samples:
- **GBM volatility**: σ ~ U[0.088%, 0.101%]
- **Retail arrival rate**: λ ~ U[0.6, 1.0] orders/step
- **Retail mean order size**: μ ~ U[19, 21] (in Y terms)

([amm_competition/competition/match.py](../amm_competition/competition/match.py), `_build_configs()` method)

### Win Determination Per Simulation

A single simulation produces two edge values: one for your strategy and one for the normalizer. **Your strategy wins the simulation if its edge exceeds the normalizer's edge.**

```python
# From amm_competition/competition/match.py, run_match() method
if edge_a > edge_b:
    wins_a += 1
elif edge_b > edge_a:
    wins_b += 1
else:
    draws += 1
```

**Match outcome**: Across all simulations, the strategy with more wins is the winner. Final scores include:
- Win count (how many simulations won)
- Total edge sum (aggregate edge across all simulations)
- Total PnL sum (aggregate profit across all simulations)

---

## 2. Edge Calculation

Edge is the primary metric determining winners. It measures profitability from different types of trades.

### Definition

Edge is the sum of profits/losses across two types of trades: **retail trades** and **arbitrage trades**.

**For each trade**:
- If AMM **buys X** (retail sells X): `edge += amount_x × fair_price - amount_y`
- If AMM **sells X** (retail buys X): `edge += amount_y - amount_x × fair_price`

Fair price is the true price (from GBM) at trade time, not the AMM's spot price.

### Code Implementation

**Arbitrage edge** ([amm_sim_rs/src/simulation/engine.rs](../amm_sim_rs/src/simulation/engine.rs), lines 142-146):

```rust
if let Some(arb_result) = arbitrageur.execute_arb(amm, fair_price, t as u64) {
    let entry = edges.entry(arb_result.amm_name).or_insert(0.0);
    // AMM edge is the negative of arbitrageur profit at true price
    *entry += -arb_result.profit;
}
```

The arbitrageur extracts `profit` at the true fair price; the AMM loses this exact amount.

**Retail trade edge** ([amm_sim_rs/src/simulation/engine.rs](../amm_sim_rs/src/simulation/engine.rs), lines 154-162):

```rust
for trade in routed_trades {
    let trade_edge = if trade.amm_buys_x {
        trade.amount_x * fair_price - trade.amount_y
    } else {
        trade.amount_y - trade.amount_x * fair_price
    };
    let entry = edges.entry(trade.amm_name).or_insert(0.0);
    *entry += trade_edge;
}
```

Edge accumulates across the entire 10,000-step simulation.

### Interpretation

- **Positive edge from retail**: Retail traders are uninformed; AMM profits from the spread
- **Negative edge from arbitrage**: Informed arbitrageurs exploit mispricings; AMM loses when mispriced
- **Net edge**: Good strategies maximize retail edge while minimizing arbitrage losses

---

## 3. PnL Calculation

PnL measures absolute profitability and is computed at simulation end.

### Definition

PnL is the change in total portfolio value from start to end of simulation.

**Initial value** = `(init_x × initial_fair_price) + init_y`

**Final value** = `(final_x × final_fair_price) + final_y + (fees_x × final_fair_price) + fees_y`

**PnL** = Final value - Initial value

Both reserves and accumulated fees are included in final value.

### Code Implementation

([amm_sim_rs/src/simulation/engine.rs](../amm_sim_rs/src/simulation/engine.rs), lines 196-205):

```rust
for (amm, name) in amms.iter().zip(names.iter()) {
    let (init_x, init_y) = initial_reserves.get(name).unwrap();
    let init_value = init_x * initial_fair_price + init_y;
    let (final_x, final_y) = amm.reserves();
    let (fees_x, fees_y) = amm.accumulated_fees();
    let reserves_value = final_x * final_fair_price + final_y;
    let fees_value = fees_x * final_fair_price + fees_y;
    let final_value = reserves_value + fees_value;
    pnl.insert(name.clone(), final_value - init_value);
}
```

**Key detail**: All valuations use fair price (not spot price), both at initialization and finalization.

### Running PnL

At each step, running PnL is captured for visualization ([amm_sim_rs/src/simulation/engine.rs](../amm_sim_rs/src/simulation/engine.rs), lines 235-244):

```rust
let (init_x, init_y) = initial_reserves.get(name).unwrap();
let init_value = init_x * initial_fair_price + init_y;
let (curr_x, curr_y) = amm.reserves();
let (fees_x, fees_y) = amm.accumulated_fees();
let reserves_value = curr_x * fair_price + curr_y;
let fees_value = fees_x * fair_price + fees_y;
let curr_value = reserves_value + fees_value;
pnls.insert(name.clone(), curr_value - init_value);
```

---

## 4. Simulation Step Sequence

Each of the 10,000 steps follows a fixed sequence:

### Step Order

1. **Price moves**: GBM generates new fair price
2. **Arbitrageurs trade**: Execute optimal arbitrage against both AMMs
3. **Retail orders arrive**: Randomly generated orders routed to best AMM

([amm_sim_rs/src/simulation/engine.rs](../amm_sim_rs/src/simulation/engine.rs), lines 136-180):

```rust
for t in 0..self.config.n_steps {
    // 1. Generate new fair price
    let fair_price = price_process.step();

    // 2. Arbitrageur extracts profit from each AMM
    for amm in amms.iter_mut() {
        if let Some(arb_result) = arbitrageur.execute_arb(amm, fair_price, t as u64) {
            // Record arb result
        }
    }

    // 3. Retail orders arrive and get routed
    let orders = retail_trader.generate_orders();
    let routed_trades = router.route_orders(&orders, &mut amms, fair_price, t as u64);
    for trade in routed_trades {
        // Record retail trade result
    }
    
    // 4. Capture step result
    let step = capture_step(...);
}
```

This sequence ensures:
- Arbitrage happens before retail (arbs interact with stale AMM state)
- Both trades use the same fair price
- Retail routing compares AMMs after arb has moved them

---

## 5. RNG Seeding & Variance

This is critical for understanding divergence between local and website results.

### Seed Generation

The simulation engine uses **deterministic seed-based RNG** for reproducibility. Simulations are seeded sequentially: each of N simulations gets seed 0, 1, 2, ..., N-1.

([amm_competition/competition/match.py](../amm_competition/competition/match.py), `_build_configs()` method):

```python
for i in range(self.n_simulations):
    rng = np.random.default_rng(seed=i)  # Seed = simulation index
    # Hyperparameters sampled from rng
    cfg = amm_sim_rs.SimulationConfig(
        # ...
        seed=i,  # Passed to Rust engine
    )
```

### Multi-Generator Architecture

Within each simulation, there are **multiple independent RNG streams**:

([amm_sim_rs/src/simulation/engine.rs](../amm_sim_rs/src/simulation/engine.rs), lines 54-67):

```rust
let mut price_process = GBMPriceProcess::new(
    // ...
    Some(seed),  // RNG for price moves
);

let mut retail_trader = RetailTrader::new(
    // ...
    Some(seed + 1),  // Separate RNG for retail orders
);
```

- **Price process RNG**: Uses seed `i`
- **Retail trader RNG**: Uses seed `i + 1`

This ensures price movements and retail flows are independent within a simulation.

### Why Results Diverge

The website uses a specific set of RNG seeds that are **not documented and differ from local execution**. When you run locally with seed=0, 1, 2, ..., you're generating different random values than the website's execution, causing:
- Different GBM price paths
- Different retail order arrivals and sizes
- Different arbitrage opportunities

**Variance is reduced by running more simulations** (law of large numbers): with 1000 simulations covering diverse market scenarios, the aggregate edge/PnL converges to the true distribution.

---

## 6. Running Simulations Locally

### CLI Usage

Compile and run your strategy via the CLI:

```bash
python -m amm_competition run-match path/to/Strategy.sol
```

This runs 1000 simulations with full variance. Results will show:
- Win/loss/draw counts
- Average edge
- Total edge and PnL

([amm_competition/cli.py](../amm_competition/cli.py), `run_match_command()` function)

### Configuration Overrides

All baseline hyperparameters can be overridden:

```bash
python -m amm_competition run-match Strategy.sol \
  --simulations 10000 \
  --volatility 0.000945 \
  --retail-rate 0.8 \
  --retail-size 20.0
```

When you override a hyperparameter, variance for that parameter is **disabled** (set to fixed value).

([amm_competition/cli.py](../amm_competition/cli.py), lines 99-110):

```python
variance = HyperparameterVariance(
    retail_mean_size_min=retail_size if args.retail_size is not None else BASELINE_VARIANCE.retail_mean_size_min,
    retail_mean_size_max=retail_size if args.retail_size is not None else BASELINE_VARIANCE.retail_mean_size_max,
    vary_retail_mean_size=False if args.retail_size is not None else BASELINE_VARIANCE.vary_retail_mean_size,
    # ... (same pattern for other params)
)
```

### Getting Closer to Website Results

**Strategy**: Run more simulations locally to reduce random noise.

From README:
> "Local results may diverge slightly from submission scores due to different RNG seeds. Run more simulations locally (`--simulations 1000`) to reduce variance and get closer to expected server results."

**Why this works**: 
- Each simulation uses a different seed (0, 1, 2, ...)
- Website also uses 1000 different seeds (though different values)
- With 1000 diverse market scenarios, aggregate metrics converge to stable values
- The set of market scenarios matters more than specific seed values

**Do not override hyperparameters** when trying to match website results—variance should be enabled to explore the full range of market conditions.

---

## 7. Baseline Strategy

Your strategy is compared against the **normalizer**: `VanillaStrategy.sol` hardcoded to 30 bps fees on both buys and sells.

([amm_competition/evm/baseline.py](../amm_competition/evm/baseline.py)):
```python
def load_vanilla_strategy():
    # Loads VanillaStrategy.sol bytecode
    # Returns EVMStrategyAdapter with 30 bps fixed fees
```

This strategy never changes:
- Always 30 bps (0.3%) bid fee
- Always 30 bps (0.3%) ask fee
- No dynamic adjustment

The normalizer serves two purposes:
1. **Anchor for comparison**: Your strategy's edge is judged relative to a known, stable baseline
2. **Prevention of trivial wins**: You can't win by just underpricing (30 bps − 1 bp) because retail would still route flow optimally

---

## 8. Summary: Local ↔ Website Fidelity

| Aspect | Local | Website |
|--------|-------|---------|
| **Judging algorithm** | Identical | Identical |
| **Metrics (edge, PnL)** | Identical | Identical |
| **Baseline strategy** | 30 bps fixed | 30 bps fixed |
| **Steps per simulation** | 10,000 | 10,000 |
| **Number of simulations** | 1,000 (default) | 1,000 (likely) |
| **Hyperparameter variance** | Enabled (default) | Enabled (likely) |
| **RNG seeds** | 0, 1, 2, ..., 999 | Unknown/different |
| **Random divergence** | Yes | Yes (different seeds) |
| **Convergence at N=1000** | Yes | Yes |

**For maximum fidelity**: Run locally with `--simulations 1000` and no parameter overrides. This produces an unbiased estimate of your strategy's true edge/PnL distribution, though specific values will differ due to seed selection.

---

## References to Code

All claims in this document are backed by these files:

- [amm_competition/competition/match.py](../amm_competition/competition/match.py) — MatchRunner, win criteria, match logic
- [amm_sim_rs/src/simulation/engine.rs](../amm_sim_rs/src/simulation/engine.rs) — Edge/PnL calculation, step sequence
- [amm_sim_rs/src/simulation/runner.rs](../amm_sim_rs/src/simulation/runner.rs) — Parallel execution, seed handling
- [amm_competition/competition/config.py](../amm_competition/competition/config.py) — Baseline settings, variance configuration
- [amm_competition/cli.py](../amm_competition/cli.py) — CLI interface, parameter overrides
- [amm_competition/evm/baseline.py](../amm_competition/evm/baseline.py) — Normalizer strategy loading
- [README.md](../README.md) — High-level explanation (less precise)
