# AMM Challenge: Strategy Testing Guide

**A comprehensive guide to testing, debugging, and optimizing your AMM fee strategies**

---

## Table of Contents

1. [Introduction & Quick Start](#1-introduction--quick-start)
2. [Development Workflow](#2-development-workflow)
3. [Understanding Test Results](#3-understanding-test-results)
4. [Debugging Strategies](#4-debugging-strategies)
5. [Testing at Scale](#5-testing-at-scale)
6. [Strategy Development Patterns](#6-strategy-development-patterns)
7. [Local vs Website Results](#7-local-vs-website-results)
8. [Pre-Submission Checklist](#8-pre-submission-checklist)
9. [Advanced Testing Techniques](#9-advanced-testing-techniques)
10. [Reference & Troubleshooting](#10-reference--troubleshooting)

---

## 1. Introduction & Quick Start

### Overview

This guide provides a systematic approach to testing AMM fee strategies from initial development through submission. Testing follows a progression:

**validate → iterate → optimize → submit**

The guide bridges the mathematical documentation ([JUDGING_ALGORITHM.md](JUDGING_ALGORITHM.md)) with practical development workflows, helping you systematically improve your strategy's Edge score.

### Prerequisites

Before starting, ensure your environment is ready:

- ✅ Rust 1.93+ installed (ARM64 native on Apple Silicon)
- ✅ Python 3.13+ with venv_fresh activated
- ✅ Dependencies installed (pyrevm, py-solc-x, amm_sim_rs)
- ✅ Baseline test passes: `amm-match run contracts/src/StarterStrategy.sol --simulations 10`

**Expected baseline:** Edge ~390 ± 50 in under 2 seconds

If you haven't set up your environment yet, see [SIMULATION_RESULTS.md](SIMULATION_RESULTS.md) for setup instructions.

### The 3-Tier Testing Pyramid

Testing follows three scales, each serving a different purpose:

| Tier | Simulations | Runtime | Variance | Purpose |
|------|-------------|---------|----------|---------|
| **Quick Validation** | 10 | ~2 sec | ±50 edge | Smoke test: "Does it compile and run?" |
| **Development Testing** | 100 | ~10 sec | ±15 edge | Iteration: "Is my logic working?" |
| **Baseline Comparison** | 1000 | ~24 sec | ±5 edge | Submission: "Am I competitive?" |

**Key Principle:** Start small (10 sims), iterate quickly (100 sims), validate thoroughly (1000 sims).

### Your First Test

```bash
# Activate your environment
source venv_fresh/bin/activate

# Step 1: Validate syntax and security
amm-match validate contracts/src/StarterStrategy.sol

# Expected output:
# Validating strategy...
# Compiling strategy...
# Strategy 'StarterStrategy' validated successfully!
```

```bash
# Step 2: Run quick test
amm-match run contracts/src/StarterStrategy.sol --simulations 10

# Expected output:
# Validating strategy...
# Compiling strategy...
# Strategy: StarterStrategy
#
# Running 10 simulations...
#
# StarterStrategy Edge: 392.08
```

**Interpreting the output:**
- **Edge: 392.08** — Your strategy's profitability metric
- Positive edge (>0) means your strategy outperforms the normalizer
- StarterStrategy baseline: ~390 ± 50 at 10 sims, ~369 at 1000 sims

### Quick Links

- **Mechanics:** See [README.md](../README.md) for how strategies work
- **Scoring Details:** See [JUDGING_ALGORITHM.md](JUDGING_ALGORITHM.md) for edge calculation
- **Baseline Results:** See [SIMULATION_RESULTS.md](SIMULATION_RESULTS.md) for expected performance
- **Research Loop:** See [README.md](README.md) for hypotheses, assumptions, and experiments

---

### ✅ Checkpoint 1: Environment Ready

**Run this command:**
```bash
amm-match run contracts/src/StarterStrategy.sol --simulations 10
```

**Expected result:**
- Edge around 390 ± 50
- Completes in ~2 seconds
- No errors or warnings

**If this passes**, your environment is correctly configured and you're ready to develop strategies.

---

## 2. Development Workflow

### The Development Cycle

Effective strategy development follows an iterative cycle:

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  Idea → Code → Validate → Test (10) → Iterate (100) ────┐  │
│    ↑                                           │         │  │
│    │                                           ↓         │  │
│    └────────────── Improve ←──── Baseline (1000) ←──────┘  │
│                                           │                 │
│                                           ↓                 │
│                                        Submit               │
└─────────────────────────────────────────────────────────────┘
```

**Typical iteration:**
1. Modify strategy logic
2. Validate (amm-match validate)
3. Quick test (10 sims) — confirms it runs
4. Development test (100 sims) — evaluates improvement
5. If edge improves, continue iterating
6. When satisfied, run baseline (1000 sims)
7. Submit if edge beats target

### Research documentation loop

To keep strategy development reproducible across contributors, treat each change as a hypothesis + experiment:

- Write or select a hypothesis in [HYPOTHESES_BACKLOG.md](HYPOTHESES_BACKLOG.md) and record any dependencies in [ASSUMPTIONS_REGISTER.md](ASSUMPTIONS_REGISTER.md).
- Run the testing pyramid (10 → 100 → 1000 sims) and log results in `research/experiments/` using `research/templates/EXPERIMENT_TEMPLATE.md`.
- Update the hypothesis status and link the experiment log.

This keeps leaderboard-inspired ideas anchored to measurable outcomes in the local simulator.

### Starting from StarterStrategy

The best way to begin is by copying and modifying the starter template:

```bash
# Copy the template
cp contracts/src/StarterStrategy.sol contracts/src/MyStrategy.sol

# Edit MyStrategy.sol with your changes
# Key modifications:
# 1. Change contract name from "Strategy" to "Strategy" (keep it as "Strategy")
# 2. Update getName() to return your unique strategy name
# 3. Modify fee logic in afterInitialize() and afterSwap()
```

**Example modification:**
```solidity
// Original StarterStrategy (50 bps fixed)
function afterSwap(TradeInfo calldata) external pure override
    returns (uint256, uint256) {
    return (FEE, FEE);  // FEE = 50 * BPS
}

// Your modification (dynamic fees)
function afterSwap(TradeInfo calldata trade) external override
    returns (uint256, uint256) {
    uint256 baseFee = 40 * BPS;  // Start at 40 bps

    // Widen fees for large trades
    uint256 tradeRatio = wdiv(trade.amountY, trade.reserveY);
    if (tradeRatio > WAD / 20) {  // Trade > 5% of reserves
        baseFee = clampFee(baseFee + 10 * BPS);  // Add 10 bps
    }

    return (baseFee, baseFee);
}
```

### Development Testing Scale (100 Simulations)

**Why 100 simulations?**
- **Fast feedback:** ~10 seconds per test
- **Good signal-to-noise:** ±15 edge variance (meaningful)
- **Efficient iteration:** Test multiple ideas quickly
- **Cost-effective:** Don't waste time on 1000-sim tests during development

**How to use 100-sim testing:**

```bash
# Test your strategy
amm-match run MyStrategy.sol --simulations 100

# Example output:
# Strategy: MyAdaptiveStrategy
# Running 100 simulations...
# MyAdaptiveStrategy Edge: 378.45
```

**Interpretation at 100 sims:**
- Edge 365-385: Slightly better than StarterStrategy (369 baseline)
- Edge 385-400: Notable improvement
- Edge 400+: Excellent performance
- Edge variance: Expect ±15 edge between runs

**When to move to baseline testing:**
- Your 100-sim edge is consistently > 375 (across 3+ runs)
- Edge has stabilized (not improving with more iterations)
- You've tested edge cases and your strategy handles them well

### Incremental Testing Strategy

**Don't test everything at once.** Make one change at a time:

```bash
# Iteration 1: Test base fee level
amm-match run MyStrategy_40bps.sol --simulations 100
# Edge: 372

# Iteration 2: Add dynamic adjustment
amm-match run MyStrategy_40bps_dynamic.sol --simulations 100
# Edge: 378 (improvement!)

# Iteration 3: Tune adjustment threshold
amm-match run MyStrategy_40bps_dynamic_tuned.sol --simulations 100
# Edge: 382 (better!)

# Iteration 4: Baseline test
amm-match run MyStrategy_40bps_dynamic_tuned.sol --simulations 1000
# Edge: 376.5 (submission-ready)
```

**Key principle:** Each test should answer one question: "Did this change improve the edge?"

---

### ✅ Checkpoint 2: Basic Strategy Works

**Run these commands:**
```bash
# Create your first strategy modification
cp contracts/src/StarterStrategy.sol contracts/src/MyStrategy.sol
# (Edit MyStrategy.sol to change getName() to "MyFirstStrategy")

# Validate
amm-match validate contracts/src/MyStrategy.sol

# Test
amm-match run contracts/src/MyStrategy.sol --simulations 100
```

**Expected result:**
- Validation passes
- Edge score appears (any value is fine for now)
- No runtime errors

**If this passes**, you can successfully create and test custom strategies.

---

## 3. Understanding Test Results

### Reading the Output

When you run a simulation, the output shows:

```bash
$ amm-match run MyStrategy.sol --simulations 100

Validating strategy...
Compiling strategy...
Strategy: MyAdaptiveStrategy          # ← Your strategy name

Running 100 simulations...

MyAdaptiveStrategy Edge: 378.45       # ← Your score
```

**The Edge score** is your primary metric:
- **What it measures:** Net profitability across all simulations
- **Formula:** Edge = Retail Profit - Arbitrage Loss
- **Higher is better:** Positive edge beats the normalizer
- **Scale:** Total edge across all simulations (not per-simulation average)

### Comparing Against Baseline

Your strategy competes against a **30 bps fixed-fee normalizer** (VanillaStrategy). Understanding baseline performance helps interpret your results:

| Strategy | Fee | Expected Edge (1000 sims) | Interpretation |
|----------|-----|---------------------------|----------------|
| VanillaStrategy (normalizer) | 30 bps | 250-350 | Baseline competitor |
| StarterStrategy | 50 bps | ~369 | Reference starting point |
| Good custom strategy | Variable | 375-400 | Notable improvement |
| Excellent strategy | Variable | 400+ | Top-tier performance |

**At different scales:**

**10 simulations:**
- StarterStrategy: ~390 ± 50 edge
- High variance makes comparisons unreliable
- Use only for smoke testing

**100 simulations:**
- StarterStrategy: ~370 ± 15 edge
- Meaningful comparisons possible
- Good for development iteration

**1000 simulations:**
- StarterStrategy: ~369 ± 5 edge
- High confidence in results
- Use for final validation

### Statistical Significance

**How much improvement is meaningful?**

| Simulation Count | Expected Variance | Significant Improvement | Use Case |
|------------------|-------------------|-------------------------|----------|
| 10 | ±50 edge | ±50+ edge change | Smoke test only |
| 100 | ±15 edge | ±15+ edge change | Development iteration |
| 1000 | ±5 edge | ±5+ edge change | Submission validation |

**Example:**
```bash
# Your strategy at 100 sims
$ amm-match run MyStrategy.sol --simulations 100
# Edge: 385

# StarterStrategy baseline at 100 sims
$ amm-match run contracts/src/StarterStrategy.sol --simulations 100
# Edge: 370

# Difference: +15 edge
# At 100 sims, ±15 is meaningful → your strategy is likely better!
```

**Why more simulations reduce variance:**
- Each simulation uses different random market conditions
- More simulations → better sampling of possible scenarios
- **Law of Large Numbers:** Aggregate metrics converge to true value
- Reference: [JUDGING_ALGORITHM.md Section 5](JUDGING_ALGORITHM.md#5-rng-seeding--variance) for details

### Edge Components

Edge is the sum of two components:

**Edge = Retail Profit - Arbitrage Loss**

**1. Retail Edge (Positive):**
- Profit from uninformed retail traders
- They trade at your quoted prices without knowledge of fair value
- Higher fees → more profit per trade
- But too high → lose volume to competitor (normalizer)

**2. Arbitrage Edge (Negative):**
- Losses to informed arbitrageurs
- They exploit pricing gaps between your AMM and fair price
- Lower fees → less arbitrage opportunity
- But too low → give away profit

**Example scenarios:**

```
Strategy A: 60 bps fixed fees
├─ Retail edge: +600 (high fees, less volume)
├─ Arbitrage edge: -250 (wide quotes, fewer arb opportunities)
└─ Net edge: 350

Strategy B: 30 bps fixed fees
├─ Retail edge: +350 (low fees, high volume)
├─ Arbitrage edge: -400 (tight quotes, more arbitrage)
└─ Net edge: -50 (worse than normalizer!)

Strategy C: 40 bps dynamic fees
├─ Retail edge: +450 (balanced fees, good volume)
├─ Arbitrage edge: -320 (adapts to conditions)
└─ Net edge: 130 (balanced approach)
```

**Key insight:** Good strategies maximize retail profit while minimizing arbitrage losses. Pure fee optimization (too high or too low) usually underperforms adaptive strategies.

---

### ✅ Checkpoint 3: Interpreting Results

**Run this command:**
```bash
amm-match run contracts/src/StarterStrategy.sol --simulations 100
```

**Can you answer these questions?**
- ✅ What is the Edge score?
- ✅ Is it higher or lower than ~370?
- ✅ What does the ± variance mean at 100 sims?
- ✅ Why is Edge = Retail Profit - Arbitrage Loss?

**If yes**, you understand how to interpret test results and are ready to debug and optimize strategies.

---
## 4. Debugging Strategies

### Common Issues and Solutions

#### Issue 1: Validation Fails

**Symptoms:**
```bash
$ amm-match validate MyStrategy.sol

Validation failed:
  - External calls not allowed
```

**Common causes and fixes:**

**Problem: External calls detected**
```solidity
// ❌ Bad: External calls forbidden
contract Strategy is AMMStrategyBase {
    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        address(0).call("");  // Forbidden!
        return (bpsToWad(30), bpsToWad(30));
    }
}
```

**Fix:** Remove all `.call()`, `.delegatecall()`, `.staticcall()` syntax

**Problem: Assembly blocks**
```solidity
// ❌ Bad: Assembly forbidden
function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
    assembly {  // Forbidden!
        // ...
    }
}
```

**Fix:** Use Solidity built-in operations only

**Problem: Invalid imports**
```solidity
// ❌ Bad: Path traversal
import "../../BadPath.sol";

// ❌ Bad: Absolute paths
import "/absolute/path/Something.sol";

// ✅ Good: Relative imports only
import "./AMMStrategyBase.sol";
```

**Reference:** See [tests/test_security_hardening.py](../tests/test_security_hardening.py) for all security checks

---

#### Issue 2: Compilation Fails

**Symptoms:**
```bash
Compiling strategy...
Compilation failed:
  - TypeError: ...
```

**Common causes:**

**Problem: Fee format incorrect**
```solidity
// ❌ Bad: Returns raw basis points
function afterSwap(TradeInfo calldata) external pure override returns (uint256, uint256) {
    return (30, 30);  // Wrong! Not in WAD format
}

// ✅ Good: Uses bpsToWad helper
function afterSwap(TradeInfo calldata) external pure override returns (uint256, uint256) {
    return (bpsToWad(30), bpsToWad(30));  // Correct: 30e14
}
```

**Problem: Storage violations**
```solidity
// ❌ Bad: Custom storage variables
contract Strategy is AMMStrategyBase {
    uint256 myVar;  // Forbidden! Use slots[] instead
}

// ✅ Good: Uses allocated slots
contract Strategy is AMMStrategyBase {
    // Use slots[0..31] for persistent state
    function afterInitialize(uint256, uint256) external override returns (uint256, uint256) {
        slots[0] = bpsToWad(30);  // Correct
        return (bpsToWad(30), bpsToWad(30));
    }
}
```

**Problem: Missing contract name**
```solidity
// ❌ Bad: Wrong contract name
contract MyCustomStrategy is AMMStrategyBase { ... }

// ✅ Good: Must be named "Strategy"
contract Strategy is AMMStrategyBase { ... }
```

---

#### Issue 3: Edge Lower Than Expected

**Symptoms:**
```bash
$ amm-match run MyStrategy.sol --simulations 1000
MyStrategy Edge: 150.00
# Much worse than StarterStrategy baseline (369)
```

**Diagnostic steps:**

**Step 1: Check if fees are too high**
```bash
# High fees lose volume to normalizer
$ amm-match run MyStrategy.sol --simulations 10
# If edge is very low, fees might be too high

# Test with lower fees temporarily
# Modify strategy to use 20 bps instead of current fee
$ amm-match run MyStrategy_20bps.sol --simulations 100
# If edge improves significantly, original fees were too high
```

**Step 2: Check if fees are too low**
```bash
# Low fees lose money to arbitrage
# Review your afterSwap logic - are you returning fees in correct format?

# Common mistake:
# return (30, 30);           // Wrong: 30 Wei, effectively 0%
# return (bpsToWad(30), bpsToWad(30));  // Correct: 30 bps = 0.30%
```

**Step 3: Test with different market conditions**
```bash
# High retail environment
$ amm-match run MyStrategy.sol --simulations 100 --retail-rate 1.0

# Low retail environment
$ amm-match run MyStrategy.sol --simulations 100 --retail-rate 0.6

# If edge varies dramatically, your strategy may not adapt well
```

**Step 4: Review logic errors**
```solidity
// Common mistake: Dividing instead of multiplying
function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
    uint256 fee = bpsToWad(30);
    
    // ❌ Bad: Division makes fee smaller
    if (trade.amountY > WAD * 10) {
        fee = wdiv(fee, WAD * 2);  // Reduces fee by half
    }
    
    // ✅ Good: Multiplication increases fee
    if (trade.amountY > WAD * 10) {
        fee = wmul(fee, WAD * 15 / 10);  // Increases fee by 1.5x
    }
    
    return (clampFee(fee), clampFee(fee));
}
```

---

#### Issue 4: Edge Highly Volatile

**Symptoms:**
```bash
$ amm-match run MyStrategy.sol --simulations 100
# Edge: 380

$ amm-match run MyStrategy.sol --simulations 100
# Edge: 320

# Variance > ±30 at 100 sims suggests instability
```

**Possible causes:**

**1. Not enough simulations**
```bash
# Solution: Increase simulation count
$ amm-match run MyStrategy.sol --simulations 1000
# Should stabilize to ±5 edge variance
```

**2. Strategy too reactive**
```solidity
// ❌ Bad: Fees jump dramatically
function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
    if (trade.amountY > WAD * 5) {
        return (bpsToWad(100), bpsToWad(100));  // 1% - huge jump!
    }
    return (bpsToWad(20), bpsToWad(20));  // 0.20%
}

// ✅ Good: Gradual adjustments
function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
    uint256 baseFee = bpsToWad(30);
    uint256 adjustment = 0;
    
    if (trade.amountY > WAD * 5) {
        adjustment = bpsToWad(10);  // Add 10 bps, not 80 bps
    }
    
    return (clampFee(baseFee + adjustment), clampFee(baseFee + adjustment));
}
```

**3. Consider smoothing/averaging**
```solidity
// Use slots to track moving average
function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
    // slots[0] = exponential moving average of trade sizes
    // slots[1] = current fee
    
    uint256 ema = slots[0];
    uint256 currentSize = trade.amountY;
    
    // EMA update: new_ema = 0.9 * old_ema + 0.1 * current
    ema = wmul(ema, WAD * 9 / 10) + wmul(currentSize, WAD / 10);
    slots[0] = ema;
    
    // Adjust fee based on smoothed metric, not raw value
    uint256 fee = bpsToWad(30);
    if (ema > WAD * 15) {
        fee = bpsToWad(35);
    }
    
    slots[1] = fee;
    return (fee, fee);
}
```

---

### Debugging Workflow

Follow this systematic approach when encountering issues:

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Validation Fails?                                        │
│    ├─ Check error message                                   │
│    ├─ Review security constraints                           │
│    └─ Fix forbidden patterns                                │
│                                                              │
│ 2. Compilation Fails?                                       │
│    ├─ Check Solidity syntax                                 │
│    ├─ Verify fee format (WAD precision)                     │
│    └─ Fix type errors                                       │
│                                                              │
│ 3. Runs but Edge is Low?                                    │
│    ├─ Test at 10 sims (smoke test)                          │
│    ├─ Verify fee logic (bpsToWad used correctly)            │
│    ├─ Test edge cases (high/low volatility, retail rate)    │
│    └─ Review strategy logic for errors                      │
│                                                              │
│ 4. Edge is Volatile?                                        │
│    ├─ Increase simulations (100 → 1000)                     │
│    ├─ Add smoothing to reactive logic                       │
│    └─ Test with fixed parameters to isolate issue           │
└─────────────────────────────────────────────────────────────┘
```

---

### Testing Specific Scenarios

Use parameter overrides to test edge cases and diagnose issues:

```bash
# High volatility environment (arbs more profitable)
amm-match run MyStrategy.sol --simulations 100 --volatility 0.001008

# Low volatility environment (arbs less profitable)
amm-match run MyStrategy.sol --simulations 100 --volatility 0.000882

# High retail flow (more uninformed volume)
amm-match run MyStrategy.sol --simulations 100 --retail-rate 1.0

# Low retail flow (less uninformed volume)
amm-match run MyStrategy.sol --simulations 100 --retail-rate 0.6

# Large order sizes
amm-match run MyStrategy.sol --simulations 100 --retail-size 30

# Small order sizes
amm-match run MyStrategy.sol --simulations 100 --retail-size 15
```

**When to use overrides:**
- **Diagnosing:** Understanding which conditions hurt/help your strategy
- **Stress testing:** Ensuring strategy handles extremes
- **NOT for submission prep:** Always use default variance for final testing

---

### ✅ Checkpoint 4: Debugging Skills

**Run this diagnostic sequence:**
```bash
# Introduce a deliberate error in a copy of StarterStrategy
# (e.g., return (30, 30) instead of (bpsToWad(30), bpsToWad(30)))

# Attempt to validate
amm-match validate MyBrokenStrategy.sol

# Fix the error using the debugging workflow

# Verify fix
amm-match run MyBrokenStrategy.sol --simulations 10
```

**If you can:**
- ✅ Identify the validation/compilation error
- ✅ Understand the root cause
- ✅ Apply the fix and verify success

**Then** you can systematically debug strategy issues.

---

## 5. Testing at Scale

### The 1000-Simulation Baseline

**Why 1000 simulations?**
- **Website standard:** Competition uses 1000 sims for judging
- **Statistical convergence:** ±5 edge variance (high confidence)
- **Comprehensive coverage:** Tests strategy across diverse market conditions
- **Final validation:** Ensures submission-ready performance

**Runtime expectations:**
```bash
$ time amm-match run MyStrategy.sol --simulations 1000

Strategy: MyStrategy
Running 1000 simulations...
MyStrategy Edge: 376.45

# Expected runtime: 20-30 seconds on modern hardware
# CPU utilization: 400-500% (4-5 cores parallelized)
```

**When to run 1000-sim baselines:**
- ✅ Before submission (mandatory)
- ✅ After major strategy changes (validation)
- ✅ When 100-sim results stabilize (confidence check)
- ❌ During rapid iteration (too slow for development)

---

### Hyperparameter Variance

Each simulation randomizes market conditions to test strategy robustness. The following parameters vary independently per simulation:

| Parameter | Range | Effect |
|-----------|-------|--------|
| **GBM Volatility (σ)** | 0.088% - 0.101% | Price movement intensity |
| **Retail Arrival Rate (λ)** | 0.6 - 1.0 orders/step | Volume of uninformed trades |
| **Retail Mean Order Size (μ)** | 19 - 21 (Y terms) | Average trade size |

**Why variance matters:**
- Tests strategy across 1000 different market scenarios
- Prevents overfitting to specific conditions
- Ensures robust performance in diverse environments
- **Reflects real-world uncertainty** in market conditions

**Example simulation diversity:**

```
Sim 1:  σ=0.0889, λ=0.72, μ=19.3  (low volatility, low flow)
Sim 2:  σ=0.0998, λ=0.95, μ=20.7  (high volatility, high flow)
Sim 3:  σ=0.0912, λ=0.81, μ=19.8  (mixed conditions)
...
Sim 1000: σ=0.0956, λ=0.67, μ=20.2
```

**Key principle:** Do NOT override parameters when testing for submission. Default variance ensures fair comparison.

**Reference:** See [amm_competition/competition/config.py](../amm_competition/competition/config.py) for parameter ranges

---

### RNG Seeds and Variance

**How randomness works:**
- Each simulation uses a **deterministic seed** (0, 1, 2, ..., 999)
- Same seed → same market conditions (reproducible)
- Different seeds → different scenarios (diversity)
- Multiple independent RNG streams:
  - Price process RNG (seed = sim_index)
  - Retail trader RNG (seed = sim_index + 1)

**Local vs Website seeds:**
- **Local:** Uses seeds 0-999 sequentially
- **Website:** Uses different (but similarly distributed) seeds
- **Same algorithm, different random draws**

**Why local and website results differ:**
```
Local Sim 0:   seed=0  → specific market path → edge=12.5
Website Sim 0: seed=X  → different market path → edge=14.2

Aggregate across 1000:
Local:   Edge = 376.5 ± 5
Website: Edge = 373.2 ± 5

Difference: ~3 points (within expected variance)
```

**Key insight:** Individual simulations differ, but **aggregate metrics converge** to similar values due to Law of Large Numbers.

**Reference:** See [JUDGING_ALGORITHM.md Section 5](JUDGING_ALGORITHM.md#5-rng-seeding--variance) for technical details

---

### Performance Optimization

**Running simulations efficiently:**

```bash
# Default: Uses all available cores
amm-match run MyStrategy.sol --simulations 1000

# Runtime breakdown:
# - Compilation: ~1 second (one-time)
# - Simulation: ~23 seconds (parallelized)
# - Total: ~24 seconds

# Performance factors:
# - CPU cores: More cores → faster (up to ~8 cores)
# - Python version: 3.13 recommended
# - Architecture: ARM64 native (not Rosetta emulation)
```

**Don't:**
- ❌ Run 1000 sims for every iteration (use 100 for development)
- ❌ Override hyperparameters for submission testing (breaks fairness)
- ❌ Run on battery power (may throttle CPU)

**Do:**
- ✅ Use quick tests (10 sims) for rapid iteration
- ✅ Use development scale (100 sims) for evaluation
- ✅ Use baseline (1000 sims) for final validation only
- ✅ Enable parallelization (automatic, no config needed)

---

### ✅ Checkpoint 5: Baseline Testing

**Run the full baseline:**
```bash
$ amm-match run contracts/src/StarterStrategy.sol --simulations 1000
```

**Verify:**
- ✅ Completes in 20-30 seconds
- ✅ Edge ~369 ± 5
- ✅ No errors or warnings
- ✅ CPU utilization high (parallelization working)

**Expected output:**
```
Strategy: StarterStrategy
Running 1000 simulations...
StarterStrategy Edge: 369.45
```

**If this matches**, your environment is correctly configured for final testing and you understand variance.

---

## 6. Strategy Development Patterns

### Fixed Fee Strategies

The simplest approach: set fees once and never change them.

**Testing different fee levels:**

```bash
# Create variations with different fees
# Modify StarterStrategy to use 20, 30, 40, 50, 60 bps

# Test each at development scale
amm-match run FixedFee_20bps.sol --simulations 100  # Edge: ~340
amm-match run FixedFee_30bps.sol --simulations 100  # Edge: ~350
amm-match run FixedFee_40bps.sol --simulations 100  # Edge: ~365
amm-match run FixedFee_50bps.sol --simulations 100  # Edge: ~370
amm-match run FixedFee_60bps.sol --simulations 100  # Edge: ~360

# Baseline test the best performer
amm-match run FixedFee_50bps.sol --simulations 1000  # Edge: 369
```

**Expected edge ranges (1000 sims):**
- 20 bps: 320-340 (too low, arbitrage losses)
- 30 bps: 340-360 (normalizer level)
- 40 bps: 360-370 (moderate improvement)
- 50 bps: 365-375 (good baseline)
- 60 bps: 350-365 (too high, volume loss)

**When fixed fees work well:**
- Stable, predictable market conditions
- Retail-heavy environments
- When simplicity is valuable

**Limitations:**
- Can't adapt to volatility changes
- Vulnerable to extreme market conditions
- Misses opportunities for dynamic optimization

---

### Adaptive Fee Strategies

Adjust fees based on market conditions observed through TradeInfo.

**Pattern 1: Volume-Based Adjustment**

```solidity
contract Strategy is AMMStrategyBase {
    function afterInitialize(uint256, uint256) external override returns (uint256, uint256) {
        slots[0] = bpsToWad(30);  // base fee
        return (bpsToWad(30), bpsToWad(30));
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 fee = slots[0];
        
        // Widen fees after large trades (potential volatility)
        uint256 tradeRatio = wdiv(trade.amountY, trade.reserveY);
        if (tradeRatio > WAD / 20) {  // > 5% of reserves
            fee = clampFee(fee + bpsToWad(10));
        } else if (fee > bpsToWad(30)) {
            // Decay back to base fee
            fee = fee - bpsToWad(1);
        }
        
        slots[0] = fee;
        return (fee, fee);
    }

    function getName() external pure override returns (string memory) {
        return "VolumeAdaptive";
    }
}
```

**Testing approach:**
```bash
# Test with different thresholds
# 3%, 5%, 7%, 10% of reserves

amm-match run VolumeAdaptive_3pct.sol --simulations 100
# Edge: 372

amm-match run VolumeAdaptive_5pct.sol --simulations 100
# Edge: 378 (best)

amm-match run VolumeAdaptive_7pct.sol --simulations 100
# Edge: 374

# Baseline best performer
amm-match run VolumeAdaptive_5pct.sol --simulations 1000
# Edge: 375.2
```

**Pattern 2: Inventory-Based Pricing**

```solidity
contract Strategy is AMMStrategyBase {
    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        // Calculate reserve ratio: X/Y
        uint256 ratio = wdiv(trade.reserveX * 100, trade.reserveY);  // Scaled for precision
        
        uint256 baseFee = bpsToWad(35);
        uint256 bidFee = baseFee;
        uint256 askFee = baseFee;
        
        // If too much X (ratio > initial): charge more to buy X (widen ask)
        if (ratio > 1) {  // > 1 means imbalanced
            askFee = clampFee(baseFee + bpsToWad(5));
        }
        
        // If too little X (ratio < initial): charge more to sell X (widen bid)
        if (ratio < 1) {  // < 1 means imbalanced
            bidFee = clampFee(baseFee + bpsToWad(5));
        }
        
        return (bidFee, askFee);
    }

    function getName() external pure override returns (string memory) {
        return "InventoryBased";
    }
}
```

---

### State Management with slots[0..31]

Use storage slots to track metrics across trades:

**Common patterns:**

```solidity
// slots[0] = current fee
// slots[1] = trade counter
// slots[2] = cumulative volume
// slots[3] = exponential moving average of trade sizes
// slots[4] = last large trade timestamp

function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
    // Increment counter
    slots[1] = slots[1] + 1;
    
    // Track cumulative volume
    slots[2] = slots[2] + trade.amountY;
    
    // Update EMA (exponential moving average)
    uint256 ema = slots[3];
    uint256 alpha = WAD / 10;  // 0.1 smoothing factor
    ema = wmul(ema, WAD - alpha) + wmul(trade.amountY, alpha);
    slots[3] = ema;
    
    // Detect large trades
    if (trade.amountY > WAD * 20) {
        slots[4] = trade.timestamp;  // Record when
    }
    
    // Use accumulated state for decisions
    uint256 fee = bpsToWad(30);
    
    // If recent large trade (within 100 steps), widen fees
    if (trade.timestamp - slots[4] < 100) {
        fee = bpsToWad(40);
    }
    
    slots[0] = fee;
    return (fee, fee);
}
```

**Testing state persistence:**
```bash
# Run with 100+ sims to verify state accumulates correctly
amm-match run StatefulStrategy.sol --simulations 100

# Check that edge improves vs stateless version
# State should help strategy adapt better over 10,000 steps
```

---

### Complete Walkthrough: "Widen After Large Trades"

**Step 1: Write the strategy**

```solidity
// WidenStrategy.sol
contract Strategy is AMMStrategyBase {
    function afterInitialize(uint256, uint256) external override returns (uint256, uint256) {
        slots[0] = bpsToWad(30);  // base fee
        return (bpsToWad(30), bpsToWad(30));
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 fee = slots[0];
        
        // Widen after large trades
        uint256 tradeRatio = wdiv(trade.amountY, trade.reserveY);
        if (tradeRatio > WAD / 20) {  // 5% threshold
            fee = clampFee(fee + bpsToWad(10));
        } else if (fee > bpsToWad(30)) {
            fee = fee - bpsToWad(1);  // Decay
        }
        
        slots[0] = fee;
        return (fee, fee);
    }

    function getName() external pure override returns (string memory) {
        return "WidenAfterLargeTrades";
    }
}
```

**Step 2: Validate**
```bash
$ amm-match validate WidenStrategy.sol
Strategy 'WidenAfterLargeTrades' validated successfully!
```

**Step 3: Quick test**
```bash
$ amm-match run WidenStrategy.sol --simulations 10
WidenAfterLargeTrades Edge: 385.2
# Looks promising! (~390 baseline ± 50 variance)
```

**Step 4: Development testing**
```bash
$ amm-match run WidenStrategy.sol --simulations 100
WidenAfterLargeTrades Edge: 378.5
# Improvement over StarterStrategy (~370)!
```

**Step 5: Test variations (threshold tuning)**
```bash
# Create variations with different thresholds (3%, 5%, 7%)

$ amm-match run WidenStrategy_3pct.sol --simulations 100
Edge: 374.2

$ amm-match run WidenStrategy_5pct.sol --simulations 100
Edge: 378.5 (best)

$ amm-match run WidenStrategy_7pct.sol --simulations 100
Edge: 376.1
```

**Step 6: Baseline test best performer**
```bash
$ amm-match run WidenStrategy_5pct.sol --simulations 1000
WidenAfterLargeTrades Edge: 375.8

# Improvement: 375.8 vs 369.0 (StarterStrategy) = +6.8 edge
# At 1000 sims, ±5 variance → this is significant!
```

**Step 7: Verify consistency**
```bash
# Run again to confirm stability
$ amm-match run WidenStrategy_5pct.sol --simulations 1000
Edge: 376.2 (within ±1 of previous)

# Strategy is stable and ready for submission!
```

---

### ✅ Checkpoint 6: Strategy Development

**Complete this exercise:**
1. Copy StarterStrategy.sol to MyAdaptiveStrategy.sol
2. Implement a simple adaptive feature (e.g., widen fees for large trades)
3. Validate, test at 10 sims, then 100 sims
4. Compare edge vs StarterStrategy baseline

**Can you:**
- ✅ Implement a working adaptive strategy?
- ✅ Use slots[] for persistent state?
- ✅ Test and compare edge improvements?
- ✅ Interpret whether improvement is significant?

**If yes**, you can develop and evaluate custom fee strategies.

---
## 7. Local vs Website Results

### Why Results Differ

Your local simulations use the **same judging algorithm** as the website, but produce slightly different results due to randomness:

**What's identical:**
- Edge calculation formula
- Simulation engine (Rust code)
- Match structure (1000 sims, 10,000 steps each)
- Hyperparameter variance ranges
- Baseline normalizer (30 bps VanillaStrategy)

**What differs:**
- **RNG seeds:** Local uses seeds 0-999, website uses different (but similar) seeds
- **Specific market paths:** Different seeds → different price movements and trade sequences

**The key principle:**
```
Individual simulations differ, but aggregate metrics converge.
```

**Example:**
```
Local:   Sim 0 (seed=0)  → edge=12.5
Website: Sim 0 (seed=X)  → edge=14.2

Local:   Total edge across 1000 sims = 376.5
Website: Total edge across 1000 sims = 373.8

Difference: 2.7 points (well within ±5 variance)
```

---

### Maximizing Fidelity

To get the closest approximation to website results:

**Do:**
1. ✅ **Always run 1000 simulations** (not 10 or 100)
2. ✅ **Use default variance** (don't override parameters)
3. ✅ **Run multiple times** to see consistency range
4. ✅ **Compare relative performance** (your strategy vs baseline)

**Example of good fidelity:**
```bash
# Run 1: Edge 376.2
# Run 2: Edge 375.8
# Run 3: Edge 376.5

Average: 376.2 ± 0.3
Expected website: 373-379 (±3 typical divergence)
```

**Don't:**
1. ❌ Override `--volatility`, `--retail-rate`, or `--retail-size` for submission testing
2. ❌ Use fewer than 1000 simulations
3. ❌ Expect exact matching (different seeds make this impossible)
4. ❌ Worry about small differences (±5 edge is normal)

**Why parameter overrides break fidelity:**
```bash
# ❌ Bad: Fixed parameters
amm-match run MyStrategy.sol --simulations 1000 --volatility 0.0009

# This tests only ONE volatility level, not the full range
# Website uses variance → your score will diverge significantly

# ✅ Good: Default variance
amm-match run MyStrategy.sol --simulations 1000

# Tests full range [0.088%, 0.101%] like the website
```

---

### Expected Divergence Range

**Typical divergence between local and website:**

| Scenario | Expected Divergence |
|----------|---------------------|
| Same strategy, different seeds | ±3-5 edge points |
| 1000 sims with variance enabled | ±5 edge points |
| Multiple local runs | ±1-2 edge points |

**Example interpretation:**
- Local: 376.5 edge → Website likely: 371-381 edge
- Local: 365.0 edge → Website likely: 360-370 edge
- **Relative rankings preserved:** If you beat baseline locally, you'll likely beat it on website

**Confidence check:**
```bash
# Run your strategy 3 times locally
$ amm-match run MyStrategy.sol --simulations 1000
Edge: 376.2

$ amm-match run MyStrategy.sol --simulations 1000
Edge: 375.8

$ amm-match run MyStrategy.sol --simulations 1000
Edge: 376.5

# If all 3 runs are within ±2 edge: strategy is stable
# Expected website range: 373-379
```

---

### Red Flags

**Signs of a problem (not just seed variance):**

🚩 **Local: 400, Website: 200**
- Difference > 100 edge suggests logic bug
- Review: Fee format (WAD vs raw values)
- Review: Forbidden operations causing silent failures

🚩 **Local edge swings ±50 between runs**
- Even at 1000 sims, this suggests instability
- Likely cause: Strategy too reactive or logic error
- Fix: Add smoothing, review logic

🚩 **Website validation fails, local passes**
- Import path issues (relative vs absolute)
- Contract naming (must be "Strategy")
- Check submission format requirements

🚩 **Consistent negative edge locally**
- Strategy fundamentally losing to normalizer
- Review fee levels (too high or too low)
- Test with different market conditions

---

### ✅ Checkpoint 7: Local/Website Understanding

**Run this consistency check:**
```bash
# Run StarterStrategy 3 times
amm-match run contracts/src/StarterStrategy.sol --simulations 1000
# Record edge: ___________

amm-match run contracts/src/StarterStrategy.sol --simulations 1000
# Record edge: ___________

amm-match run contracts/src/StarterStrategy.sol --simulations 1000
# Record edge: ___________
```

**Verify:**
- ✅ All 3 runs are within ±2 edge (e.g., 369±2)
- ✅ You understand why website results will differ slightly
- ✅ You know how to maximize fidelity (1000 sims, default variance)

**If this checks out**, you understand local vs website variance and can confidently prepare submissions.

---

## 8. Pre-Submission Checklist

Use this systematic checklist to ensure your strategy is submission-ready:

### Code Requirements

```markdown
**Contract Structure:**
- [ ] Contract is named `Strategy` (not `MyStrategy` or `CustomStrategy`)
- [ ] Inherits from `AMMStrategyBase`
- [ ] File saved as `<YourName>Strategy.sol` or similar

**Required Methods:**
- [ ] `afterInitialize(uint256, uint256)` implemented
- [ ] `afterSwap(TradeInfo calldata)` implemented
- [ ] `getName()` implemented with unique name
- [ ] All methods return (bidFee, askFee) in WAD format

**Fee Logic:**
- [ ] Fees returned using `bpsToWad()` helper
- [ ] Fees clamped with `clampFee()` or manually to [0, MAX_FEE]
- [ ] Both bidFee and askFee are within valid range
- [ ] No division by zero or overflow risks

**Storage:**
- [ ] Only uses `slots[0..31]` for persistent state
- [ ] No custom storage variables declared
- [ ] Slot indices are 0-31 (not 32+)

**Security:**
- [ ] No external calls (`.call()`, `.delegatecall()`, `.staticcall()`)
- [ ] No assembly blocks
- [ ] No forbidden opcodes
- [ ] Imports use relative paths only (e.g., `./AMMStrategyBase.sol`)
```

---

### Testing Requirements

```markdown
**Validation:**
- [ ] `amm-match validate Strategy.sol` passes
- [ ] No validation errors or warnings
- [ ] Compiles successfully (no TypeErrors)
- [ ] Contract deploys to EVM without errors

**Quick Testing:**
- [ ] 10-sim test completes without errors
- [ ] Edge score appears (any value indicates basic functionality)
- [ ] No runtime exceptions or reverts

**Development Testing:**
- [ ] 100-sim test shows edge > 350 (beats weak baseline)
- [ ] Edge is stable across multiple runs (±15 variance)
- [ ] Strategy adapts as expected (if dynamic)

**Baseline Testing:**
- [ ] 1000-sim test shows edge > 369 (beats StarterStrategy)
- [ ] Edge consistent across 2-3 runs (±5 variance)
- [ ] No degradation after multiple runs
```

---

### Import and Path Verification

```markdown
**Import Statements:**
- [ ] Uses relative import: `import "./AMMStrategyBase.sol";`
- [ ] No path traversal: No `../../` patterns
- [ ] No absolute paths: No `/absolute/path/Something.sol`
- [ ] SPDX license identifier present: `// SPDX-License-Identifier: MIT`
- [ ] Pragma version matches: `pragma solidity ^0.8.24;`

**Contract Naming:**
- [ ] Main contract named exactly `Strategy`
- [ ] `getName()` returns unique identifier (not "Strategy")
- [ ] File can be named anything, but contract must be `Strategy`
```

---

### Logic Verification

```markdown
**Fee Calculation:**
- [ ] afterInitialize returns sensible initial fees (20-60 bps typical)
- [ ] afterSwap fee adjustments are gradual (not 0 → 100 bps jumps)
- [ ] Fee logic makes economic sense
- [ ] No accidental fee inversions (bidFee < 0 or > MAX_FEE)

**State Management:**
- [ ] Slots initialized in afterInitialize (if used)
- [ ] Slot values persist correctly across trades
- [ ] No slot index errors (0-31 only)
- [ ] State updates are intentional (not accidental)

**Edge Cases:**
- [ ] Handles first trade correctly
- [ ] Handles very large trades (> 50% of reserves)
- [ ] Handles very small trades (< 0.01% of reserves)
- [ ] Works across all market conditions (high/low volatility, retail)
```

---

### Final Validation Sequence

**Run this exact sequence before submission:**

```bash
# Step 1: Clean validation
amm-match validate contracts/src/Strategy.sol

# Expected: "Strategy 'YourStrategyName' validated successfully!"

# Step 2: Quick smoke test
amm-match run contracts/src/Strategy.sol --simulations 10

# Expected: Edge appears, no errors

# Step 3: Development confidence check
amm-match run contracts/src/Strategy.sol --simulations 100

# Expected: Edge > 360 (at minimum)

# Step 4: Final baseline
amm-match run contracts/src/Strategy.sol --simulations 1000

# Expected: Edge > 369 (beats StarterStrategy)

# Step 5: Consistency verification
amm-match run contracts/src/Strategy.sol --simulations 1000

# Expected: Edge within ±2 of Step 4 result
```

**Submission criteria:**
- ✅ All 5 steps pass
- ✅ 1000-sim edge beats your target (e.g., > 375 for competitive submission)
- ✅ Consistency check shows ±2 variance
- ✅ No errors, warnings, or unexpected behavior

---

### ✅ Checkpoint 8: Submission Ready

**Complete the full checklist above, then verify:**

- ✅ Contract named `Strategy`
- ✅ Validation passes
- ✅ 1000-sim edge > 369
- ✅ Consistent across multiple runs
- ✅ Import paths are relative
- ✅ No security violations
- ✅ Logic handles edge cases

**If all boxes checked**, you're ready to submit your strategy!

---

## 9. Advanced Testing Techniques

### Sensitivity Analysis

Test how your strategy performs across the full parameter space:

```bash
# Test volatility sensitivity (5 points)
for vol in 0.000882 0.00090 0.00095 0.00100 0.001008; do
  echo "Testing volatility: $vol"
  amm-match run MyStrategy.sol --simulations 100 --volatility $vol
done

# Expected output:
# 0.000882: Edge 372 (low vol → less arb opportunity)
# 0.001008: Edge 368 (high vol → more arb losses)

# Interpretation: If edge drops >20 points in high vol,
# strategy may need better arbitrage protection
```

**Retail flow sensitivity:**
```bash
# Test across retail arrival rates
for rate in 0.6 0.7 0.8 0.9 1.0; do
  echo "Testing retail rate: $rate"
  amm-match run MyStrategy.sol --simulations 100 --retail-rate $rate
done

# Expected: Edge should increase with retail rate
# (more uninformed volume = more profit opportunity)
```

**Order size sensitivity:**
```bash
# Test with different order sizes
for size in 15 17 19 21 23 25; do
  echo "Testing order size: $size"
  amm-match run MyStrategy.sol --simulations 100 --retail-size $size
done

# Expected: Strategy should handle all sizes gracefully
```

---

### A/B Testing Strategy Variants

Compare multiple strategy versions systematically:

```bash
# Variant A: Base fee 30 bps, widen +10 bps
amm-match run StrategyA.sol --simulations 100
# Edge: 372

# Variant B: Base fee 35 bps, widen +8 bps
amm-match run StrategyB.sol --simulations 100
# Edge: 378 (better!)

# Variant C: Base fee 40 bps, widen +5 bps
amm-match run StrategyC.sol --simulations 100
# Edge: 375

# Conclusion: Variant B is best at development scale
# Now test at baseline:
amm-match run StrategyB.sol --simulations 1000
# Edge: 376.5 (confirmed improvement)
```

**Use consistent seeds for fair comparison:**
- Run all variants at same simulation count
- Use default variance (don't override parameters)
- Test at 100 sims first, then 1000 for top 2-3 variants

---

### Performance Tuning

**Optimize fee adjustment parameters:**

```bash
# Test decay rate variations
# slots[0] decay: fee -= bpsToWad(X)

# Slow decay (1 bps per trade)
amm-match run SlowDecay.sol --simulations 100
# Edge: 374

# Medium decay (2 bps per trade)
amm-match run MediumDecay.sol --simulations 100
# Edge: 378 (best)

# Fast decay (5 bps per trade)
amm-match run FastDecay.sol --simulations 100
# Edge: 371
```

**Balance reactivity vs stability:**
- Too reactive → high variance, potentially lower edge
- Too stable → misses opportunities, potentially lower edge
- **Sweet spot:** Gradual adjustments with smoothing

---

### Stress Testing

Test extreme scenarios to identify weaknesses:

```bash
# Extreme high volatility (2x normal)
amm-match run MyStrategy.sol --simulations 100 --volatility 0.002

# Expected: Edge should degrade gracefully, not crash
# If edge drops to <200, strategy needs better protection

# Extreme retail flow (2x normal)
amm-match run MyStrategy.sol --simulations 100 --retail-rate 2.0

# Expected: Edge should increase (more opportunity)
# If edge decreases, fees may be too high

# Extreme order sizes
amm-match run MyStrategy.sol --simulations 100 --retail-size 50

# Expected: No division by zero, no overflows
# Strategy should handle large trades gracefully

# Minimal retail (barely any volume)
amm-match run MyStrategy.sol --simulations 100 --retail-rate 0.1

# Expected: Low edge (little profit opportunity)
# Strategy should not crash or produce negative edge
```

**Interpretation:**
- Strategy should **degrade gracefully** in extreme conditions
- No crashes, reverts, or unexpected behavior
- Edge may be lower in extremes, but should remain positive

---

### ✅ Checkpoint 9: Advanced Testing

**Complete one advanced test:**

Option A: Sensitivity analysis
- Test your strategy at 5 different volatility levels
- Record edge scores
- Identify which conditions favor your strategy

Option B: A/B testing
- Create 3 variants of your strategy
- Test all at 100 sims
- Baseline test the best performer

Option C: Stress test
- Test at extreme volatility (0.002)
- Test at extreme retail rate (2.0)
- Verify no crashes or unexpected behavior

**If you can complete any of these**, you can systematically optimize and validate strategies beyond basic testing.

---

### 9.1 Seed Robustness Testing

Test your strategy's stability across different random seed batches:

**Why test across seed batches?**
- Detects strategies that overfit to specific market conditions
- Verifies consistent performance across different random scenarios
- Builds confidence before submission

**How seed batches work:**
- Default batch (offset 0): seeds 0-999
- Batch 1 (offset 1000): seeds 1000-1999
- Batch 2 (offset 2000): seeds 2000-2999

Each batch tests the same strategy with different (but statistically similar) market conditions.

**Manual robustness testing:**

```bash
# Test with default seeds (0-999)
python scripts/amm-test-pipeline.py MyStrategy.sol \
  --output result_batch0.json

# Test with batch 1 (seeds 1000-1999)
python scripts/amm-test-pipeline.py MyStrategy.sol \
  --output result_batch1.json --seed-offset 1000

# Test with batch 2 (seeds 2000-2999)
python scripts/amm-test-pipeline.py MyStrategy.sol \
  --output result_batch2.json --seed-offset 2000
```

**Automated robustness checking:**

```bash
# Run 3 batches automatically and generate report
python scripts/amm-learning-engine.py robustness-check \
  --strategy MyStrategy.sol --batches 3
```

**Interpreting robustness results:**

| Std Deviation | Assessment | Interpretation |
|---------------|------------|----------------|
| < 5 | Excellent | Strategy is very stable across conditions |
| 5-10 | Good | Normal variance, strategy is reliable |
| 10-15 | Moderate | Strategy sensitive to market conditions |
| > 15 | Poor | Strategy may be overfitting |

**When to use robustness testing:**
- ✅ Before final submission (verify stability)
- ✅ After major strategy changes (ensure no regressions)
- ✅ When comparing competing designs (choose more robust)
- ❌ During rapid iteration (too slow for development)

**Best practices:**
- Test at least 3 batches (3000 total simulations)
- Look for σ < 10 for submission-ready strategies
- If σ > 15, consider adding smoothing or reducing reactivity
- Remember: website uses different seeds, so some variance is expected

---

## 10. Reference & Troubleshooting

### Command Reference

**Validation:**
```bash
amm-match validate <strategy.sol>
```

**Quick Testing:**
```bash
amm-match run <strategy.sol> --simulations 10
```

**Development Testing:**
```bash
amm-match run <strategy.sol> --simulations 100
```

**Baseline Testing:**
```bash
amm-match run <strategy.sol> --simulations 1000
```

**Custom Parameters (for diagnostics only):**
```bash
amm-match run <strategy.sol> \
  --simulations 100 \
  --volatility 0.0009 \
  --retail-rate 0.8 \
  --retail-size 20.0 \
  --initial-price 100.0 \
  --initial-x 100.0 \
  --initial-y 10000.0 \
  --steps 10000
```

---

### Common Error Messages

**"Validation failed: External calls not allowed"**
- **Cause:** Strategy uses `.call()`, `.delegatecall()`, or `.staticcall()`
- **Fix:** Remove all external call syntax

**"Compilation failed: Forbidden opcodes"**
- **Cause:** Bytecode contains CALL, DELEGATECALL, CREATE, etc.
- **Fix:** Remove assembly, external calls, or contract creation

**"Storage outside allowed range"**
- **Cause:** Accessing `slots[32]` or higher
- **Fix:** Use only `slots[0]` through `slots[31]`

**"Fee value out of range"**
- **Cause:** Fee returned > MAX_FEE (1e17 = 10%)
- **Fix:** Use `clampFee()` helper or manually clamp to [0, MAX_FEE]

**"Strategy not found"**
- **Cause:** Contract not named `Strategy`
- **Fix:** Rename contract to exactly `Strategy`

**"Import path not allowed"**
- **Cause:** Using absolute paths or path traversal (`../` or `/`)
- **Fix:** Use relative imports (`./AMMStrategyBase.sol`)

---

### Getting Help

**Documentation:**
- **Strategy Writing:** [README.md](../README.md)
- **Judging Details:** [JUDGING_ALGORITHM.md](JUDGING_ALGORITHM.md)
- **Baseline Results:** [SIMULATION_RESULTS.md](SIMULATION_RESULTS.md)

**Code References:**
- **Interface:** [contracts/src/IAMMStrategy.sol](../contracts/src/IAMMStrategy.sol)
- **Base Contract:** [contracts/src/AMMStrategyBase.sol](../contracts/src/AMMStrategyBase.sol)
- **Starter Template:** [contracts/src/StarterStrategy.sol](../contracts/src/StarterStrategy.sol)
- **Normalizer:** [contracts/src/VanillaStrategy.sol](../contracts/src/VanillaStrategy.sol)

**Test Examples:**
- **Security Tests:** [tests/test_security_hardening.py](../tests/test_security_hardening.py)
- **Competition Tests:** [tests/test_competition.py](../tests/test_competition.py)
- **Strategy Tests:** [contracts/test/Strategy.t.sol](../contracts/test/Strategy.t.sol)

**Configuration:**
- **Baseline Config:** [amm_competition/competition/config.py](../amm_competition/competition/config.py)
- **CLI Implementation:** [amm_competition/cli.py](../amm_competition/cli.py)

---

### Quick Troubleshooting Guide

```
Problem: Validation fails
├─ Check error message for specific issue
├─ Review security constraints (no external calls, assembly, etc.)
├─ Verify import paths are relative
└─ Ensure contract named "Strategy"

Problem: Compilation fails
├─ Check Solidity syntax
├─ Verify fee format (use bpsToWad())
├─ Ensure storage uses slots[0..31] only
└─ Check for type mismatches

Problem: Edge is low (<300)
├─ Test at 10 sims to verify it runs
├─ Check fee format (WAD vs raw values)
├─ Test with parameter overrides to diagnose
└─ Review strategy logic for errors

Problem: Edge is volatile
├─ Increase simulations (10 → 100 → 1000)
├─ Add smoothing to reactive logic
├─ Check for logic errors causing instability
└─ Verify state management is correct

Problem: Local differs from website
├─ Ensure 1000 simulations used
├─ Verify default variance (no parameter overrides)
├─ Check for logic bugs (not just seed variance)
└─ Expect ±3-5 edge divergence (normal)
```

---

### Final Tips

1. **Start simple:** Copy StarterStrategy, make small changes
2. **Test incrementally:** 10 → 100 → 1000 simulations
3. **Use checkpoints:** Verify each section's checkpoint before continuing
4. **Embrace variance:** ±5 edge at 1000 sims is normal
5. **Read error messages:** They usually tell you exactly what's wrong
6. **Compare baselines:** Always test against StarterStrategy (369 edge)
7. **Trust the process:** validate → quick test → dev test → baseline → submit

**Success path:**
```
Copy template → Modify logic → Validate → Test (10) → 
Iterate (100) → Optimize → Baseline (1000) → Verify consistency → Submit
```

---

## Conclusion

This guide has covered the complete testing workflow from initial validation through submission-ready optimization. You now have:

✅ A systematic testing methodology  
✅ Tools to debug common issues  
✅ Understanding of statistical significance  
✅ Pre-submission validation checklist  
✅ Advanced optimization techniques  

**Next steps:**
1. Review [JUDGING_ALGORITHM.md](JUDGING_ALGORITHM.md) for scoring details
2. Copy [StarterStrategy.sol](../contracts/src/StarterStrategy.sol) as your template
3. Follow the development workflow (Section 2)
4. Use checkpoints to validate your progress
5. Submit when your 1000-sim edge consistently beats your target

**Good luck building winning AMM strategies!**

---

*Last updated: 2026-02-10*  
*Part of the AMM Design Competition Testing Suite*
