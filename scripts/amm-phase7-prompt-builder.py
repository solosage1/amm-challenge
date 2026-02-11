#!/usr/bin/env python3
"""
AMM Phase 7 Prompt Builder
Constructs context-aware prompts for Codex that enforce Draft→Review→Revise pattern
"""

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Dict, List, Tuple

# Add scripts directory to path for local imports
sys.path.insert(0, str(Path(__file__).parent))

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
if (trade.timestamp != lastTimestamp) {{
    // First trade of new step (usually arb)
    lastTimestamp = trade.timestamp;
}} else {{
    // Same-step follow-on trade (usually retail)
}}
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

## Known Ceilings (What's Been Tried)

Treat “ceilings” as provisional. Use the **AI-Generated Insights** section (if present) as the source of truth for current best-known results.

Historically, simple “infer fair then protect mispriced side / undercut other side” strategies tended to plateau well below target. Recent variants that use **exact arb inversion** + **dual-regime quoting** can reach ~500 edge (1000 sims) but still miss 527 — suggesting the remaining gap is about **classification + timing + regime selection**, not just fee-level tuning.

Your job: propose a mechanism that can plausibly move the current ceiling meaningfully upward without collapsing routing/volume.

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

def load_knowledge_context(state_dir: Path) -> dict:
    """Load harvested knowledge context if available."""
    knowledge_path = state_dir / '.knowledge_context.json'
    if knowledge_path.exists():
        try:
            return json.loads(knowledge_path.read_text())
        except json.JSONDecodeError:
            pass
    return {}


def load_state(state_dir: Path) -> Dict:
    """Load current Phase 7 state"""
    state = {
        'best_edge': float((state_dir / '.best_edge.txt').read_text().strip()),
        'iteration': int((state_dir / '.iteration_count.txt').read_text().strip()),
        'start_time': int((state_dir / '.start_timestamp.txt').read_text().strip()),
        'strategies_log': [],
        'knowledge_context': {}
    }

    # Load strategies log if it exists and is valid
    strategies_file = state_dir / '.strategies_log.json'
    if strategies_file.exists():
        try:
            state['strategies_log'] = json.loads(strategies_file.read_text())
        except json.JSONDecodeError:
            pass

    # Load knowledge context from session harvester
    knowledge = load_knowledge_context(state_dir)
    if knowledge:
        state['knowledge_context'] = knowledge
        # Override best_edge if knowledge shows higher
        true_best = knowledge.get('true_best_edge', 0)
        if true_best > state['best_edge']:
            state['best_edge'] = true_best

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
# KNOWLEDGE CONTEXT FORMATTING
# ============================================================================

def format_knowledge_section(knowledge: dict) -> str:
    """Format harvested knowledge context for prompt inclusion."""
    if not knowledge:
        return ""

    sections = []

    # True best edge header
    true_best = knowledge.get('true_best_edge', 0)
    best_strategy = knowledge.get('true_best_strategy', 'Unknown')
    if true_best > 0:
        sections.append(f"**True Best Edge**: {true_best:.2f} ({best_strategy})")
        sections.append("")

    # Lessons learned
    lessons = knowledge.get('lessons_learned', [])
    if lessons:
        sections.append("### Lessons Learned")
        for lesson in lessons[:7]:  # Limit to 7
            # Truncate long lessons
            if len(lesson) > 100:
                lesson = lesson[:97] + "..."
            sections.append(f"- {lesson}")
        sections.append("")

    # Strategies tested table
    all_tested = knowledge.get('all_tested_strategies', [])
    if all_tested:
        sections.append("### Strategies Tested (Harvested from Sessions)")
        sections.append("")
        sections.append("| Strategy | Edge | Sims | Iter |")
        sections.append("|----------|------|------|------|")
        for s in all_tested[:12]:  # Limit to top 12
            name = s.get('name', 'Unknown')[:25]
            edge = s.get('edge', 0)
            sims = s.get('sims', 0)
            iteration = s.get('iteration', 0)
            sections.append(f"| {name} | {edge:.2f} | {sims} | {iteration} |")
        sections.append("")

    # Regressions to avoid
    regressions = knowledge.get('regressions', [])
    if regressions:
        sections.append("### Regressions to Avoid")
        sections.append("These modifications made performance worse:")
        for reg in regressions[:5]:  # Limit to 5
            from_s = reg.get('from', 'Unknown')
            from_e = reg.get('from_edge', 0)
            to_s = reg.get('to', 'Unknown')
            to_e = reg.get('to_edge', 0)
            delta = to_e - from_e
            sections.append(f"- **{from_s}** ({from_e:.1f}) -> **{to_s}** ({to_e:.1f}) [{delta:+.1f}]")
        sections.append("")

    if not sections:
        return ""

    return "## Accumulated Knowledge from Sessions\n\n" + "\n".join(sections)


# ============================================================================
# RECENT RESULTS FORMATTING
# ============================================================================

# ============================================================================
# INSIGHT LOADING (from forensics, synthesis, auditor)
# ============================================================================

def load_iteration_discoveries(state_dir: Path) -> str:
    """Load discoveries from previous iterations' knowledge files and manual discoveries."""
    discoveries = []

    # Check for manual discoveries file first (highest priority)
    manual_path = state_dir / 'discoveries_iter8_9.md'
    if manual_path.exists():
        return manual_path.read_text()

    # Load from knowledge JSON files (parsed from codex.jsonl)
    for i in range(1, 100):
        knowledge_path = state_dir / f'iteration_{i}_knowledge.json'
        if not knowledge_path.exists():
            continue
        try:
            data = json.loads(knowledge_path.read_text())
            experiments = data.get('edge_experiments', [])
            # Get top 3 from this iteration
            top = sorted(experiments, key=lambda x: x.get('edge', 0), reverse=True)[:3]
            for exp in top:
                discoveries.append(f"- {exp['strategy']}: {exp['edge']:.1f} edge")
        except Exception:
            continue

    if discoveries:
        return "### Previous Iteration Discoveries\n" + "\n".join(discoveries[:15])
    return ""


def load_insights(state_dir: Path) -> Dict:
    """Load insights from forensics, synthesis, auditor engines, and knowledge store."""
    insights = {
        'forensics': None,
        'synthesis': None,
        'audit': None,
        'discoveries': None,
        'knowledge_store': None,
    }

    # Load forensics insights
    forensics_path = state_dir / 'forensics_insights.json'
    if forensics_path.exists():
        try:
            data = json.loads(forensics_path.read_text())
            insights['forensics'] = data
        except Exception:
            pass

    # Load synthesis report
    synthesis_path = state_dir / 'synthesis_report.json'
    if synthesis_path.exists():
        try:
            data = json.loads(synthesis_path.read_text())
            insights['synthesis'] = data
        except Exception:
            pass

    # Load assumption audit
    audit_path = state_dir / 'assumption_audit.json'
    if audit_path.exists():
        try:
            data = json.loads(audit_path.read_text())
            insights['audit'] = data
        except Exception:
            pass

    # Load iteration discoveries
    discoveries = load_iteration_discoveries(state_dir)
    if discoveries:
        insights['discoveries'] = discoveries

    # Load from knowledge store
    try:
        from amm_phase7_knowledge_store import KnowledgeStore
        ks = KnowledgeStore(str(state_dir))
        knowledge_output = ks.format_for_prompt()
        if knowledge_output:
            insights['knowledge_store'] = knowledge_output
    except ImportError:
        pass
    except Exception:
        pass

    return insights


def format_insights_section(insights: Dict) -> str:
    """Format loaded insights for inclusion in prompt."""
    sections = []

    # Forensics insights
    if insights.get('forensics'):
        f = insights['forensics']
        lines = ["### Simulation Forensics Insights"]

        if 'edge_curves' in f and f['edge_curves']:
            ec = f['edge_curves']
            lines.append(f"- **Edge Timing**: Early game {ec.get('early_game_pct', 0):.0f}%, "
                        f"Mid game {ec.get('mid_game_pct', 0):.0f}%, "
                        f"Late game {ec.get('late_game_pct', 0):.0f}%")

        if 'price_regimes' in f and f['price_regimes']:
            pr = f['price_regimes']
            ratio = pr.get('vol_edge_ratio', 1)
            if ratio > 1.3:
                lines.append(f"- **Volatility**: Strategy excels in high-vol ({ratio:.1f}x edge ratio)")
            elif ratio < 0.8:
                lines.append(f"- **Volatility**: Strategy struggles in high-vol ({ratio:.1f}x edge ratio)")

        if 'fee_timing' in f and f['fee_timing']:
            ft = f['fee_timing']
            lines.append(f"- **Fee Timing**: {ft.get('timing_interpretation', 'N/A')}")

        sections.append('\n'.join(lines))

    # Synthesis insights
    if insights.get('synthesis'):
        s = insights['synthesis']
        lines = ["### Cross-Strategy Synthesis"]

        # Top mechanisms
        if 'mechanism_performance' in s:
            top_mechs = sorted(
                s['mechanism_performance'].items(),
                key=lambda x: x[1].get('avg_edge', 0),
                reverse=True
            )[:3]
            if top_mechs:
                mech_str = ", ".join([f"{m[0]} ({m[1].get('avg_edge', 0):.0f} avg edge)" for m in top_mechs])
                lines.append(f"- **Top Mechanisms**: {mech_str}")

        # Synthesis candidates
        if 'synthesis_candidates' in s and s['synthesis_candidates']:
            candidate = s['synthesis_candidates'][0]
            mechs = " + ".join(candidate.get('mechanisms', []))
            lines.append(f"- **Untested Combo**: {mechs} (predicted ~{candidate.get('predicted_edge', 0):.0f} edge)")

        # Parameter insights
        if 'parameter_insights' in s:
            for mech, insight in list(s['parameter_insights'].items())[:2]:
                if 'recommendation' in insight:
                    lines.append(f"- **{mech}**: {insight['recommendation']}")

        sections.append('\n'.join(lines))

    # Audit insights
    if insights.get('audit'):
        a = insights['audit']
        lines = ["### Assumption Audit"]

        # List violations
        if 'tests' in a:
            violations = [
                (name, result) for name, result in a['tests'].items()
                if result.get('status') == 'VIOLATED'
            ]
            for name, result in violations[:2]:
                lines.append(f"- **VIOLATED**: {result.get('assumption', name)}")
                lines.append(f"  - {result.get('implication', 'N/A')}")

            # List weak assumptions
            weak = [
                (name, result) for name, result in a['tests'].items()
                if result.get('status') == 'WEAK'
            ]
            for name, result in weak[:2]:
                lines.append(f"- **WEAK**: {result.get('assumption', name)} (r={result.get('correlation', 0):.2f})")

        sections.append('\n'.join(lines))

    # Discoveries from previous iterations
    if insights.get('discoveries'):
        sections.insert(0, insights['discoveries'])

    # Knowledge store (parameter optima, mechanism ceilings, etc.)
    if insights.get('knowledge_store'):
        sections.append("### Persistent Knowledge Store\n" + insights['knowledge_store'])

    if not sections:
        return ""

    return "\n---\n\n## AI-Generated Insights\n\n" + "\n\n".join(sections) + "\n"


def format_recent_results(state: Dict) -> str:
    """Format last 5 test results for context"""
    recent = state['strategies_log'][-5:]

    if not recent:
        return "**No strategies tested yet.** This is the first iteration."

    lines = ["**Recent Test Results**:", ""]
    for entry in recent:
        name = entry.get('strategy_name', 'Unknown')
        status = str(entry.get("status") or "unknown")
        raw_edge = entry.get('final_edge', None)
        try:
            edge = float(raw_edge) if raw_edge is not None else None
        except (TypeError, ValueError):
            edge = None
        hyp_ids = entry.get('hypothesis_ids', [])

        if isinstance(hyp_ids, list):
            hyp_str = ','.join(hyp_ids) if hyp_ids else 'H-baseline'
        else:
            hyp_str = 'H-baseline'

        edge_str = f"{edge:.2f}" if edge is not None else "N/A"

        note_parts = []
        if status != "ok":
            note_parts.append(status)
            err = entry.get("error") if isinstance(entry.get("error"), dict) else {}
            stage = err.get("stage")
            if stage:
                note_parts.append(f"stage={stage}")
            msg = err.get("message")
            if msg:
                msg = str(msg).replace("\n", " ").strip()
                note_parts.append(f"msg={msg[:80]}")
        note = f" [{' | '.join(note_parts)}]" if note_parts else ""

        lines.append(f"- {name}: Edge {edge_str}{note} (Hypothesis: {hyp_str})")

    return '\n'.join(lines)

# ============================================================================
# PROMPT BUILDING
# ============================================================================

def build_prompt(
    iteration: int,
    state_dir: Path,
    output_path: Path,
    *,
    target_edge: float,
    max_runtime_seconds: int,
):
    """Build complete prompt for Codex"""
    state = load_state(state_dir)
    gaps = select_hypothesis_gaps(state)

    # Calculate time remaining
    elapsed = int(time.time()) - state['start_time']
    remaining = max(0, int(max_runtime_seconds) - elapsed)
    hours = remaining // 3600
    minutes = (remaining % 3600) // 60

    # Load AI-generated insights (from forensics, synthesis, auditor)
    insights = load_insights(state_dir)
    insights_section = format_insights_section(insights)

    # Build prompt from template
    prompt = PROMPT_TEMPLATE.format(
        current_target=target_edge,
        best_edge=state['best_edge'],
        iteration=iteration,
        hours=hours,
        minutes=minutes,
        recent_champions=format_recent_results(state),
        prioritized_hypotheses=format_hypothesis_gaps(gaps[:5]),
        primary_gap_target=gaps[0][1] if gaps else "Explore novel fee strategies"
    )

    # Inject insights section after "Hypothesis Gaps" section
    if insights_section:
        # Find the "Known Ceilings" section and insert before it
        known_ceilings_marker = "## Known Ceilings"
        if known_ceilings_marker in prompt:
            prompt = prompt.replace(
                known_ceilings_marker,
                insights_section + "\n" + known_ceilings_marker
            )
        else:
            # Fallback: append before the workflow section
            workflow_marker = "## Generation Workflow"
            if workflow_marker in prompt:
                prompt = prompt.replace(
                    workflow_marker,
                    insights_section + "\n" + workflow_marker
                )

    # Inject knowledge context section (from session harvester)
    knowledge_section = format_knowledge_section(state.get('knowledge_context', {}))
    if knowledge_section:
        # Insert after "Known Ceilings" if present, otherwise before "Generation Workflow"
        known_ceilings_marker = "## Known Ceilings"
        workflow_marker = "## Generation Workflow"

        if known_ceilings_marker in prompt:
            # Find where Known Ceilings section ends (next ## header or workflow)
            idx = prompt.find(known_ceilings_marker)
            rest = prompt[idx + len(known_ceilings_marker):]
            next_section = rest.find("\n## ")
            if next_section != -1:
                insert_point = idx + len(known_ceilings_marker) + next_section
                prompt = prompt[:insert_point] + "\n\n" + knowledge_section + prompt[insert_point:]
            elif workflow_marker in prompt:
                prompt = prompt.replace(workflow_marker, knowledge_section + "\n" + workflow_marker)
        elif workflow_marker in prompt:
            prompt = prompt.replace(workflow_marker, knowledge_section + "\n" + workflow_marker)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(prompt)
    print(f"Prompt built: {output_path}")
    if insights_section:
        print(f"  (includes AI-generated insights from forensics/synthesis/audit)")
    if knowledge_section:
        true_best = state.get('knowledge_context', {}).get('true_best_edge', 0)
        print(f"  (includes harvested knowledge: true best edge = {true_best:.2f})")

# ============================================================================
# MAIN
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="Build Phase 7 Codex prompt")
    parser.add_argument("--iteration", type=int, required=True, help="Current iteration number")
    parser.add_argument("--state-dir", required=True, help="Path to state directory")
    parser.add_argument("--output", required=True, help="Output path for prompt")
    parser.add_argument("--target-edge", type=float, default=527.0, help="Target edge to achieve (default: 527)")
    parser.add_argument(
        "--max-runtime-seconds",
        type=int,
        default=36000,
        help="Max runtime in seconds (default: 36000 = 10 hours)",
    )
    args = parser.parse_args()

    build_prompt(
        args.iteration,
        Path(args.state_dir),
        Path(args.output),
        target_edge=args.target_edge,
        max_runtime_seconds=args.max_runtime_seconds,
    )

if __name__ == "__main__":
    main()
