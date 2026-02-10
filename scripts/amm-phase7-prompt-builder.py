#!/usr/bin/env python3
"""
AMM Phase 7 Prompt Builder
Constructs context-aware prompts for Codex that enforce Draft→Review→Revise pattern
"""

import argparse
import json
import time
from pathlib import Path
from typing import Dict, List, Tuple

# ============================================================================
# PROMPT TEMPLATE
# ============================================================================

PROMPT_TEMPLATE = """# AMM Strategy Generation Task

You are an expert Solidity developer creating high-performance AMM fee strategies for a competitive simulation environment.

## Objective

Generate a novel AMM strategy that maximizes **Edge** (profitability metric) against a 30 bps fixed-fee normalizer.

**Target**: Edge > {current_target}
**Current Best**: {best_edge}
**Iteration**: {iteration}
**Time Remaining**: {hours}h {minutes}m

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
assembly {{ ... }}          // Inline assembly
new Contract()            // Contract creation
selfdestruct()           // Dangerous ops
.transfer() / .send()    // Transfer ops
```

### 3. Contract Structure
```solidity
// ✓ REQUIRED STRUCTURE:
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {{AMMStrategyBase}} from "./AMMStrategyBase.sol";
import {{IAMMStrategy, TradeInfo}} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {{
    function afterInitialize(uint256 initialX, uint256 initialY)
        external override returns (uint256 bidFee, uint256 askFee) {{
        // Initialize state in slots[0..31]
        // Return opening fees (WAD format)
    }}

    function afterSwap(TradeInfo calldata trade)
        external override returns (uint256 bidFee, uint256 askFee) {{
        // Read/update state in slots[0..31]
        // Return updated fees (WAD format)
    }}

    function getName() external pure override returns (string memory) {{
        return "YourStrategyName";
    }}
}}
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
struct TradeInfo {{
    bool isBuy;          // true if AMM bought X (trader sold X to AMM)
    uint256 amountX;     // X tokens traded (WAD)
    uint256 amountY;     // Y tokens traded (WAD)
    uint256 timestamp;   // Step number
    uint256 reserveX;    // Post-trade X reserve (WAD)
    uint256 reserveY;    // Post-trade Y reserve (WAD)
}}
```

---

## Current State

{recent_champions}

---

## Hypothesis Gaps to Explore

**Priority Targets** (least explored → most potential):

{prioritized_hypotheses}

**Recommended Focus for This Iteration**:
{primary_gap_target}

---

## Generation Workflow (REQUIRED STRUCTURE)

Follow this exact 4-step workflow in your response:

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

import {{AMMStrategyBase}} from "./AMMStrategyBase.sol";
import {{IAMMStrategy, TradeInfo}} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {{
    // Your implementation here
}}
```
---END_REVISED_IMPLEMENTATION---
```

### STEP 4: STRATEGY_METADATA

Provide structured metadata:

**Output Format**:
```
---STRATEGY_METADATA---
{{
  "name": "DescriptiveStrategyName",
  "hypothesis_ids": ["H-001", "H-003"],
  "slots_used": 5,
  "key_innovation": "One-sentence description of novel mechanism",
  "expected_edge_range": [380, 420]
}}
---END_STRATEGY_METADATA---
```

---

## Your Task

Generate a novel AMM strategy following the 4-step workflow above.

**Focus Area**: {primary_gap_target}

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
"""

# ============================================================================
# STATE LOADING
# ============================================================================

def load_state(state_dir: Path) -> Dict:
    """Load current Phase 7 state"""
    state = {
        'best_edge': float((state_dir / '.best_edge.txt').read_text().strip()),
        'iteration': int((state_dir / '.iteration_count.txt').read_text().strip()),
        'start_time': int((state_dir / '.start_timestamp.txt').read_text().strip()),
        'strategies_log': []
    }

    # Load strategies log if it exists and is valid
    strategies_file = state_dir / '.strategies_log.json'
    if strategies_file.exists():
        try:
            state['strategies_log'] = json.loads(strategies_file.read_text())
        except json.JSONDecodeError:
            pass

    return state

# ============================================================================
# HYPOTHESIS PRIORITIZATION
# ============================================================================

def select_hypothesis_gaps(state: Dict) -> List[Tuple[str, str]]:
    """Prioritize hypothesis gaps to explore"""
    # Identify which hypotheses have been under-explored
    tested_hypotheses = {}
    for entry in state['strategies_log']:
        hyp_ids = entry.get('hypothesis_ids', [])
        if isinstance(hyp_ids, list):
            for hyp in hyp_ids:
                tested_hypotheses[hyp] = tested_hypotheses.get(hyp, 0) + 1

    # Priority order based on research backlog
    all_gaps = [
        ("H-001", "Fair price inference from arbitrage"),
        ("H-002", "Post-arb tighten, post-retail widen"),
        ("H-003", "Inventory-skewed asymmetric fees"),
        ("H-004", "Volatility proxy via price changes"),
        ("H-005", "Hysteresis/decay to avoid oscillation"),
        ("H-006", "Trade-size reactive widening"),
        ("GAP-A", "Fair price inference strategies"),
        ("GAP-B", "Multi-regime adaptive fees"),
        ("GAP-C", "Directional asymmetry with hysteresis"),
        ("GAP-D", "Real-time volatility signaling"),
        ("GAP-E", "Timestamp-level fee coherence"),
        ("GAP-F", "Cross-AMM retail volume inference"),
        ("GAP-G", "Arb-informed price bands"),
        ("GAP-H", "Entropy-based fee scheduling"),
    ]

    # Return least-tested gaps first
    return sorted(all_gaps, key=lambda x: tested_hypotheses.get(x[0], 0))

def format_hypothesis_gaps(gaps: List[Tuple[str, str]]) -> str:
    """Format hypothesis gaps for prompt"""
    lines = []
    for gap_id, gap_desc in gaps:
        lines.append(f"- **{gap_id}**: {gap_desc}")
    return '\n'.join(lines)

# ============================================================================
# RECENT RESULTS FORMATTING
# ============================================================================

def format_recent_results(state: Dict) -> str:
    """Format last 5 test results for context"""
    recent = state['strategies_log'][-5:]

    if not recent:
        return "**No strategies tested yet.** This is the first iteration."

    lines = ["**Recent Test Results**:", ""]
    for entry in recent:
        name = entry.get('strategy_name', 'Unknown')
        edge = entry.get('final_edge', 0)
        hyp_ids = entry.get('hypothesis_ids', [])

        if isinstance(hyp_ids, list):
            hyp_str = ','.join(hyp_ids) if hyp_ids else 'H-baseline'
        else:
            hyp_str = 'H-baseline'

        lines.append(f"- {name}: Edge {edge:.2f} (Hypothesis: {hyp_str})")

    return '\n'.join(lines)

# ============================================================================
# PROMPT BUILDING
# ============================================================================

def build_prompt(iteration: int, state_dir: Path, output_path: Path):
    """Build complete prompt for Codex"""
    state = load_state(state_dir)
    gaps = select_hypothesis_gaps(state)

    # Calculate time remaining
    elapsed = int(time.time()) - state['start_time']
    remaining = max(0, 36000 - elapsed)  # 10 hours - elapsed
    hours = remaining // 3600
    minutes = (remaining % 3600) // 60

    # Build prompt from template
    prompt = PROMPT_TEMPLATE.format(
        current_target=527,
        best_edge=state['best_edge'],
        iteration=iteration,
        hours=hours,
        minutes=minutes,
        recent_champions=format_recent_results(state),
        prioritized_hypotheses=format_hypothesis_gaps(gaps[:5]),
        primary_gap_target=gaps[0][1] if gaps else "Explore novel fee strategies"
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(prompt)
    print(f"Prompt built: {output_path}")

# ============================================================================
# MAIN
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="Build Phase 7 Codex prompt")
    parser.add_argument("--iteration", type=int, required=True, help="Current iteration number")
    parser.add_argument("--state-dir", required=True, help="Path to state directory")
    parser.add_argument("--output", required=True, help="Output path for prompt")
    args = parser.parse_args()

    build_prompt(args.iteration, Path(args.state_dir), Path(args.output))

if __name__ == "__main__":
    main()
