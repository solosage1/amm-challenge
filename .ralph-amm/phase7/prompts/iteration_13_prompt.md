# AMM Strategy Generation Task

You are an expert Solidity developer creating high-performance AMM fee strategies for a competitive simulation environment.

## Objective

Generate a novel AMM strategy that maximizes **Edge** (profitability metric) against a 30 bps fixed-fee normalizer.

**Target**: Edge > 527.0
**Current Best**: 505.61
**Iteration**: 13
**Time Remaining**: 9h 55m

---

## Execution Contract (CRITICAL)

This is a **non-interactive** generation run inside an autonomous loop.

- **DO NOT** run shell commands or try to inspect files/repos.
- **DO NOT** write/modify any files.
- The orchestrator will compile + simulate after your response; your job is to **output the final strategy** in the required format.
- If you don’t produce the required response blocks, the iteration will fail.

---

## Environment Context

### Simulation Mechanics

- **AMM Type**: Constant product (x*y=k), fee-on-input
- **Competition**: Head-to-head vs 30 bps normalizer
- **Duration**: 10,000 steps per simulation
- **Price Process**: GBM with varying volatility (σ ~ U[0.088%, 0.101%])
- **Retail Flow**: Poisson arrival (λ ~ U[0.6, 1.0]), lognormal sizes
- **Arbitrage**: Closed-form optimal sizing, executes before retail each step

### Edge Definition

```
Edge = Σ (amountX × fairPrice - amountY)  [when AMM sells X]
     + Σ (amountY - amountX × fairPrice)  [when AMM buys X]
```

- Retail trades → Positive edge (you profit from spread)
- Arbitrage trades → Negative edge (you lose to informed flow)

**Goal**: Maximize retail edge while minimizing arb losses.

---

## Critical Simulation Mechanics (EXPLOIT THESE)

These are the exact formulas used by the simulation engine. Understanding them is key to beating 527 edge.

### 1. Router Split Formula

The router splits retail orders to equalize marginal prices across AMMs. For a trader buying X (spending Y):

```
γ_i = 1 - fee_i           (gamma = 1 minus fee)
A_i = sqrt(x_i * γ_i * y_i)   (liquidity coefficient)
r = A_1 / A_2              (split ratio)

Optimal split: Δy_1 = (r*(y_2 + γ_2*Y) - y_1) / (γ_1 + r*γ_2)
```

**Key insight**: Lower fees → higher γ → higher A → you get MORE of the order (but less per unit).
The relationship is nonlinear (square root), so small fee changes can shift large volume fractions.

### 2. Fair Price Inversion from Arbitrage

After an arbitrage trade, you can EXACTLY infer the fair price that motivated it:

```
When AMM sells X (buy arb):
  p_fair = k / (γ * x_post²)    where k = x_pre * y_pre, γ = 1 - ask_fee

When AMM buys X (sell arb):
  p_fair = k * γ / x_post²      where γ = 1 - bid_fee
```

**Key insight**: Post-arb, you KNOW fair price exactly (not estimated). Use this for protective fees.

**Failure modes**:
- Arb capped at 99% of reserves → biased estimate (check if amountX ≈ 0.99 * pre_reserveX)
- Retail trades first in a step (no arb when vol is low) → no signal

### 3. Fee Update Timing

```
Within each step:
  1. Fair price moves (GBM)
  2. Arbitrageur executes using CURRENT fees → afterSwap called → fees UPDATE
  3. Retail orders execute using NEW fees → afterSwap called → fees UPDATE
  4. Next step begins with fees from last trade
```

**Key insight**: After arb, you can set fees for retail in the SAME step. Two-phase quoting:
- Phase 1 (after arb): Set competitive fees to attract retail
- Phase 2 (after retail): Set protective fees for next step's arb

### 4. Multi-Trade Sequencing

Multiple trades can occur per step (arb + 0-N retail orders).

**Detection via timestamp**:
```solidity
if (trade.timestamp != lastTimestamp) {
    // First trade of new step (usually arb)
    lastTimestamp = trade.timestamp;
} else {
    // Same-step follow-on trade (usually retail)
}
```

**Key insight**: First trade often sets fair price anchor; subsequent trades can use it.

### 5. The 99% Reserve Cap

Arb trades are capped: `amount = min(optimal, reserve * 0.99)`

When the cap is hit, fair price inversion is BIASED. Detect via:
- `amountX > 0.95 * (reserveX + amountX)` for buy arb
- Spot still far from inferred fair after trade

---

## Hard Constraints (CRITICAL - Violations = Immediate Failure)

### 1. Storage Constraint
```solidity
// ✓ VALID: Use slots[0..31] for all state
slots[0] = bpsToWad(30);
slots[1] = trade.timestamp;

// ✗ INVALID: No state variables outside slots
uint256 myFee;                    // BLOCKED
mapping(uint => uint) feeMap;     // BLOCKED
```

### 2. Security Constraints
```solidity
// ✗ BLOCKED PATTERNS (will cause validation failure):
.call()                    // External calls
.delegatecall()           // Proxy calls
assembly { ... }          // Inline assembly
new Contract()            // Contract creation
selfdestruct()           // Dangerous ops
.transfer() / .send()    // Transfer ops
```

### 3. Contract Structure
```solidity
// ✓ REQUIRED STRUCTURE:
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    function afterInitialize(uint256 initialX, uint256 initialY)
        external override returns (uint256 bidFee, uint256 askFee) {
        // Initialize state in slots[0..31]
        // Return opening fees (WAD format)
    }

    function afterSwap(TradeInfo calldata trade)
        external override returns (uint256 bidFee, uint256 askFee) {
        // Read/update state in slots[0..31]
        // Return updated fees (WAD format)
    }

    function getName() external pure override returns (string memory) {
        return "YourStrategyName";
    }
}
```

### 4. Available Helpers (from AMMStrategyBase)
```solidity
WAD = 1e18                          // 100% in WAD
BPS = 1e14                          // 1 basis point in WAD
MAX_FEE = 1000 * BPS                // 10% max fee

clampFee(uint256)                   // Clamp to [0, MAX_FEE]
bpsToWad(uint256)                   // Convert bps to WAD
wmul(uint256, uint256)              // Multiply two WAD values
wdiv(uint256, uint256)              // Divide two WAD values
sqrt(uint256)                       // Square root (WAD)
```

### 5. TradeInfo Fields
```solidity
struct TradeInfo {
    bool isBuy;          // true if AMM bought X (trader sold X to AMM)
    uint256 amountX;     // X tokens traded (WAD)
    uint256 amountY;     // Y tokens traded (WAD)
    uint256 timestamp;   // Step number
    uint256 reserveX;    // Post-trade X reserve (WAD)
    uint256 reserveY;    // Post-trade Y reserve (WAD)
}
```

---

## Current State

**Recent Test Results**:

- ArbOracleDualRegime_Tight30_Buf4: Edge 511.68 [harvested] (Hypothesis: H-baseline)
- ArbOracleDualRegime_Tight30_Buf4: Edge 505.61 [harvested] (Hypothesis: H-baseline)
- Unknown: Edge N/A [codex_failed | stage=codex | msg=codex failed] (Hypothesis: H-baseline)
- Unknown: Edge N/A [codex_failed | stage=codex | msg=codex failed] (Hypothesis: H-baseline)
- Unknown: Edge N/A [codex_failed | stage=codex | msg=codex failed] (Hypothesis: H-baseline)

---

## Hypothesis Gaps to Explore

**Priority Targets** (least explored → most potential):

- **H-001**: Fair price inference from arbitrage
- **H-002**: Post-arb tighten, post-retail widen
- **H-003**: Inventory-skewed asymmetric fees
- **H-004**: Volatility proxy via price changes
- **H-005**: Hysteresis/decay to avoid oscillation

**Recommended Focus for This Iteration**:
Fair price inference from arbitrage

---


---

## AI-Generated Insights

### Previous Iteration Discoveries (Manual sims from iteration 8–9 logs)

- `ArbBandProtect`: **490.96 Edge @ 1000 sims** (`iteration_8_codex.jsonl:202`)
- `ArbOracleBandMatch2`: **497.57 Edge @ 1000 sims** (`iteration_8_codex.jsonl:223`)
- `ArbOracleDualRegime`: **502.27 Edge @ 1000 sims** (`iteration_9_codex.jsonl:197`)
- `ArbOracleDualRegimeExact`: **502.58 Edge @ 1000 sims** (`iteration_9_codex.jsonl:200`)
- `ArbOracleDualRegime_Tight30_Buf4`: **505.61 Edge @ 1000 sims** (local run, 2026-02-10)
- `ArbOracleDualRegimeRecenter`: **504.93 Edge @ 1000 sims** (local run, 2026-02-10)

Notes:
- Dual-regime + (tight=30bps) is currently best-known locally, but still ~21.4 edge short of **527**.
- Next likely gains come from: (1) better arb-vs-retail classification on the first trade of a step, (2) per-step two-phase quoting (after arb, go aggressively competitive for same-step retail), and (3) handling the arb “cap at 99% reserves” case to avoid biased fair anchors.


### Simulation Forensics Insights
- **Edge Timing**: Early game 37%, Mid game 46%, Late game 17%
- **Fee Timing**: GOOD: High fees align with high mispricing

### Cross-Strategy Synthesis
- **Top Mechanisms**: exact_arb_inversion (504 avg edge), dual_regime_quoting (492 avg edge), max_jump_limit (486 avg edge)
- **ewma_smoothing**: EWMA alpha near 0.20 performs best
- **protection_buffer**: Protection buffer near 10 bps performs best

### Assumption Audit

### Persistent Knowledge Store
### Known Parameter Optima
| Parameter | Best Value | Best Edge |
|-----------|------------|-----------|
| ewma_alpha | 0.2 | 502.5 |

### Mechanism Ceilings (Known Limits)
| Mechanism | Ceiling | Appearances |
|-----------|---------|-------------|
| fair_inference | 502.5 | 1 |
| dual_regime | 502.5 | 1 |


## Known Ceilings (What's Been Tried)

Treat “ceilings” as provisional. Use the **AI-Generated Insights** section (if present) as the source of truth for current best-known results.

Historically, simple “infer fair then protect mispriced side / undercut other side” strategies tended to plateau well below target. Recent variants that use **exact arb inversion** + **dual-regime quoting** can reach ~500 edge (1000 sims) but still miss 527 — suggesting the remaining gap is about **classification + timing + regime selection**, not just fee-level tuning.

Your job: propose a mechanism that can plausibly move the current ceiling meaningfully upward without collapsing routing/volume.

---


## Accumulated Knowledge from Sessions

**True Best Edge**: 505.61 (ArbOracleDualRegime_Tight30_Buf4)

### Lessons Learned
- after each arbitrage trade, I can update fees before retail trading occurs to encourage participa...
- I can set fees but need clarity on how afterSwap returns updates for future trades, not just the ...
- can reduce retail flow. The retail trade edge formula highlights this intricacy. When a trader se...
- this could reduce gamma, but it seems to increase the upper edge when the spot is greater than fa...
- squared scaling didn't work as well, so I'll go ahead with the square root discount scaling inste...
- we didn’t set the `timeout_ms`. The wrapper tool function has a default that might be 10,000 mill...
- for a buy, the trader inputs X and the AMM outputs Y, clarifying that amountY is indeed an output

### Strategies Tested (Harvested from Sessions)

| Strategy | Edge | Sims | Iter |
|----------|------|------|------|
| ArbOracleDualRegime_Tight | 518.99 | 100 | 9 |
| ArbOracleDualRegimeExact | 510.98 | 200 | 8 |
| ArbOracleDualRegime | 510.72 | 200 | 8 |
| ArbOracleDualRegimeExact | 508.74 | 300 | 9 |
| Candidate | 508.46 | 300 | 9 |
| ArbOracleDualRegime | 508.45 | 300 | 9 |
| Tmp | 507.18 | 300 | 9 |
| ArbOracleGapAwareDualRegi | 507.06 | 300 | 9 |
| ArbOracleDualRegimeExact_ | 506.32 | 200 | 9 |
| ArbOracleBandMatch2 | 505.75 | 200 | 8 |
| ArbOracleBandMatch2 | 503.57 | 300 | 9 |
| ArbBandProtect | 499.32 | 200 | 8 |

### Regressions to Avoid
These modifications made performance worse:
- **ArbBandProtect** (491.1) -> **ArbInferredSkew** (327.9) [-163.2]
- **ArbBandProtect** (491.1) -> **Const_200bps** (313.8) [-177.4]
- **ArbBandProtect** (491.1) -> **Const_20bps** (289.0) [-202.1]
- **ArbBandProtect** (491.1) -> **Const_10bps** (163.0) [-328.1]
- **ArbOracleDualRegimeExact** (511.0) -> **ArbInferredSkew** (319.3) [-191.7]

## Generation Workflow (REQUIRED STRUCTURE)

Follow this exact 5-step workflow in your response:

### STEP 1: DRAFT_STRATEGY_IDEA

Briefly describe your strategy concept:
- **Hypothesis Target**: Which gaps does this address?
- **Core Mechanism**: What's the novel insight?
- **Edge Balance**: How do you balance retail capture vs arb protection?
- **State Usage**: Which slots will you use and why?

**Output Format**:
```
---DRAFT_STRATEGY_IDEA---
<Your strategy description here>
---END_DRAFT_STRATEGY_IDEA---
```

### STEP 1.5: ASSUMPTION_AUDIT (RED TEAM YOUR IDEA)

Before implementation, stress-test your assumptions:

- **Information Limits**: What can you NOT observe? (fair price is hidden, other AMM state unknown, future prices unpredictable)
- **Inference Validity**: If inferring fair price from arb trades, when does this fail?
  - Retail trades first (no arb opportunity when vol is low)
  - Fair price drifts between trades
  - EWMA smoothing introduces lag
- **Prior Art Analysis**: Existing strategies already use fair inference (e.g., `arb_infer_*`, `arb_oracle_*`). What ceiling do they hit in this repo’s latest results, and why?
- **Theoretical Bound**: What's the MAXIMUM edge improvement your mechanism can provide? Show rough math.
- **Failure Modes**: Under what market conditions does your strategy perform WORSE than 45 bps fixed fee?

**Output Format**:
```
---ASSUMPTION_AUDIT---
Key assumptions and failure conditions:
1. <assumption> → Fails when: <specific condition>
2. <assumption> → Fails when: <specific condition>

Why existing fair-price strategies plateau below target:
<your analysis of what limits them>

Theoretical edge bound for this approach:
<rough calculation or reasoning>

Worst-case scenarios where this underperforms:
- <scenario>: Expected impact
---END_ASSUMPTION_AUDIT---
```

### STEP 2: DESIGN_REVIEW

Critically review your draft:
- **Constraint Violations**: Any security or storage issues?
- **Edge Cases**: How do you handle zero reserves, max fees, etc.?
- **Numerical Stability**: Any division by zero or overflow risks?
- **Gas Efficiency**: Any expensive operations in hot path?
- **Optimizations**: What can be improved?

**Output Format**:
```
---DESIGN_REVIEW---
<Critical analysis>

Revisions to apply:
- <Concrete change 1>
- <Concrete change 2>
- <Concrete change 3>
---END_DESIGN_REVIEW---
```

### STEP 3: REVISED_IMPLEMENTATION

Implement the strategy incorporating ALL review feedback.

**Output Format**:
```
---REVISED_IMPLEMENTATION---
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // Your implementation here
}
```
---END_REVISED_IMPLEMENTATION---
```

### STEP 4: STRATEGY_METADATA

Provide structured metadata:

**Output Format**:
```
---STRATEGY_METADATA---
{
  "name": "DescriptiveStrategyName",
  "hypothesis_ids": ["H-001", "H-003"],
  "slots_used": 5,
  "key_innovation": "One-sentence description of novel mechanism",
  "expected_edge_range": [380, 420]
}
---END_STRATEGY_METADATA---
```

---

## Your Task

Generate a novel AMM strategy following the 4-step workflow above.

**Focus Area**: Fair price inference from arbitrage

**Constraints Reminder**:
- Use ONLY slots[0..31] for state
- NO external calls, assembly, or dangerous ops
- Return fees in WAD format (e.g., 30 * BPS = 30 bps)
- Keep afterSwap gas-efficient (<100k target)

**Creativity Encouraged**:
- Combine multiple hypotheses if beneficial
- Introduce novel state tracking mechanisms
- Experiment with asymmetric bid/ask logic
- Consider timestamp-based patterns

Begin your response with `---DRAFT_STRATEGY_IDEA---` and follow the workflow structure exactly.
