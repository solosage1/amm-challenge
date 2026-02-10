# AMM Strategy Generation Task

You are an expert Solidity developer creating high-performance AMM fee strategies for a competitive simulation environment.

## Objective

Generate a novel AMM strategy that maximizes **Edge** (profitability metric) against a 30 bps fixed-fee normalizer.

**Target**: Edge > 527.0
**Current Best**: 374.56
**Iteration**: 9
**Time Remaining**: 3h 29m

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

## Known Ceilings (What's Been Tried)

These strategies use fair price inference and achieve ~375 edge:

| Strategy | Mechanism | Edge | Limitation |
|----------|-----------|------|------------|
| arb_infer_protect | Infer fair from arb, protect mispriced side | ~375 | EWMA lag, retail-first noise |
| arb_infer_skew | Fair price + vol proxy + inventory skew | ~375 | Same + vol estimate noisy |
| arb_infer_bandprotect | Fee = no-arb boundary condition | ~375 | Requires accurate fair estimate |

**The gap to 527**: These strategies optimize fee LEVELS but may not be optimizing fee TIMING or exploiting multi-trade-per-step dynamics.

---

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
- **Prior Art Analysis**: Existing strategies (arb_infer_protect, arb_infer_skew, arb_infer_bandprotect) already use fair price inference and plateau at ~375. What ceiling are they hitting? Why?
- **Theoretical Bound**: What's the MAXIMUM edge improvement your mechanism can provide? Show rough math.
- **Failure Modes**: Under what market conditions does your strategy perform WORSE than 45 bps fixed fee?

**Output Format**:
```
---ASSUMPTION_AUDIT---
Key assumptions and failure conditions:
1. <assumption> → Fails when: <specific condition>
2. <assumption> → Fails when: <specific condition>

Why existing fair-price strategies plateau at ~375:
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
