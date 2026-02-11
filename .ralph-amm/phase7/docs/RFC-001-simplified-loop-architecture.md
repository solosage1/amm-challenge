# RFC-001: Simplified Autonomous Loop Architecture

**Status:** Draft
**Author:** Claude (with human review)
**Created:** 2026-02-11
**Target Version:** Phase 7.1

---

## Executive Summary

This RFC proposes a fundamental simplification of the Phase 7 autonomous loop, replacing the current opportunity-catalog-based exploration system with a **champion-centric mechanism modification** approach.

**Key changes:**
- Replace 13 abstract opportunity families with 5-6 concrete champion mechanism components
- Remove subfamily tracking and conformance weighting (addressing 44% mismatch rate)
- Simplify selection from weighted multi-factor scoring to UCB1 bandit
- Reduce configuration parameters from 24 to 4
- Provide concrete modification prompts instead of abstract opportunity descriptions

**Expected outcomes:**
- 75% reduction in loop code complexity
- Near-elimination of conformance tracking issues
- More interpretable selection decisions
- Tighter feedback between modifications and outcomes

**Migration approach: Aggressive with easy reversal**
- **Day 1:** Implement and deploy as primary system
- **Snapshot:** Old system state frozen at cutover; shadow log tracks what it *would* select
- **Rollback:** Restore snapshot + restart old loop (<5 min)
- **Checkpoint:** Evaluate at iteration 10; rollback if not clearly better

---

## 1. Problem Statement

### 1.1 Current Architecture Overview

The existing Phase 7 loop operates as follows:

```
┌─────────────────────────────────────────────────────────────────┐
│  1. Load signals from state files                                │
│  2. Score 13 opportunity families using weighted formula         │
│  3. Select subfamily within chosen opportunity                   │
│  4. Generate abstract search plan                                │
│  5. Execute via LLM (writes Solidity strategy)                   │
│  6. Measure edge via Monte Carlo simulation                      │
│  7. Infer actual subfamily from strategy name                    │
│  8. Apply conformance weighting to learning update               │
│  9. Update priors, cooldowns, EWMA deltas                        │
│  10. Repeat                                                      │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 Identified Problems

#### Problem 1: Subfamily Conformance Failures (Critical)

**Data:** 4 of 9 recent iterations (44%) had subfamily mismatch:

| Iteration | Planned Subfamily | Actual Subfamily | Conformance |
|-----------|-------------------|------------------|-------------|
| 41 | exp3_adversarial_bandit | thompson_quote_arms | 0.0 |
| 42 | worst_case_regime_mix | ambiguity_set_penalty | 0.0 |
| 44 | impact_decay | microprice_imbalance | 0.1 |
| 37 | mispricing_gate | plain_undercut | 0.0 |

**Root cause:** The execution LLM interprets family-level guidance and makes autonomous subfamily choices. Subfamily distinctions are often conceptually similar (e.g., "impact_decay" vs "microprice_imbalance").

**Impact:** Learning is corrupted. The system learns about what the LLM happened to implement, not what was planned.

#### Problem 2: Excessive Configuration Complexity

Current tunable parameters:
```python
DEFAULT_COOLDOWN_ITERS = 4
DEFAULT_NO_UPLIFT_EPSILON = 0.02
DEFAULT_NO_UPLIFT_STREAK_THRESHOLD = 3
DEFAULT_NOVELTY_LOOKBACK = 6
DEFAULT_NOVELTY_PENALTY = 1.0
DEFAULT_EXPLORE_LOOKBACK = 4
DEFAULT_EXPLORE_MIN_NO_UPLIFT = 3
DEFAULT_EXPLORE_MIN_REPEAT_SHARE = 0.60
DEFAULT_EXPLORE_STALL_LOOKBACK = 10
DEFAULT_EXPLORE_STALL_MIN_NO_UPLIFT = 7
DEFAULT_SCORE_NOVELTY_WEIGHT = 0.55
DEFAULT_SCORE_BREAKTHROUGH_WEIGHT = 0.60
DEFAULT_SCORE_UNTRIED_BONUS = 4.0
DEFAULT_EWMA_ALPHA = 0.30
DEFAULT_CONFORMANCE_WEIGHT_MISMATCH = 0.10
# ... and more
```

These interact in non-obvious ways, making behavior hard to predict and debug.

#### Problem 3: Abstract Opportunity Descriptions

Current prompts describe opportunities abstractly:

> "Use surrogate-driven search (GP/TuRBO/multi-fidelity) to jump across non-local strategy manifolds instead of linear sweeps."

The LLM must interpret this and decide what code to write. This interpretation step introduces variance and drift from intended behavior.

#### Problem 4: Slow Progress Toward Target

- **Current champion:** 508.86 bps
- **Target:** 527.0 bps
- **Gap:** 18.14 bps (3.6%)
- **Recent rate:** ~0.02 bps/iteration
- **Projected iterations to target:** ~900

The incremental parameter-tuning approach cannot bridge this gap. The system needs mechanism-level innovation, not knob-turning.

#### Problem 5: State File Proliferation

Current state files:
- `.opportunity_priors.json` (274 lines, nested subfamily tracking)
- `.opportunity_history.json` (1116 lines, full iteration history)
- `opportunity_rankings_iter{N}.json` (one per iteration)
- `.execution_gates.json`
- `.knowledge_context.json`
- `knowledge_store.json`

This creates maintenance burden and makes debugging difficult.

---

## 2. Proposed Solution

### 2.1 Core Concept: Champion-Centric Mechanism Modification

Instead of exploring an abstract opportunity catalog, the new system:

1. **Analyzes** the current champion to identify its mechanism components
2. **Selects** one mechanism to modify using simple UCB1 bandit
3. **Prompts** the LLM with concrete modification instructions
4. **Measures** the result
5. **Updates** simple per-mechanism statistics

```
┌─────────────────────────────────────────────────────────────────┐
│                    PROPOSED SIMPLIFIED LOOP                      │
├─────────────────────────────────────────────────────────────────┤
│  1. LOAD champion code and mechanism statistics                  │
│  2. SELECT mechanism to modify (UCB1)                            │
│  3. GENERATE concrete modification prompt                        │
│  4. EXECUTE LLM generation                                       │
│  5. VALIDATE output modifies correct mechanism                   │
│  6. MEASURE edge via simulation                                  │
│  7. UPDATE mechanism statistics (tries, uplift)                  │
│  8. IF improvement > threshold: promote to champion              │
│  9. REPEAT                                                       │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Mechanism Decomposition of Current Champion

Analysis of `iskewx_v11.sol` identifies 5 modifiable mechanism components:

```yaml
mechanisms:
  fair_price_estimation:
    description: "How the strategy infers true asset value"
    current_implementation: "Jump-capped EWMA with gamma-inferred anchor"
    code_location: "lines 90-128 (afterSwap fair price update)"
    parameters:
      - BASE_ALPHA_NEW_PCT: 19
      - JUMP_UP_BPS: 400
      - JUMP_DOWN_BPS: 400
      - QUIET_ALPHA_NEW_PCT: 15
    modification_directions:
      - "Microprice-based estimation using order imbalance"
      - "VWAP-anchored with mean reversion"
      - "Regime-conditional alpha switching"
      - "Kalman filter state estimation"

  tight_band_pricing:
    description: "Fee logic when spot is near fair value"
    current_implementation: "Symmetric base fee with flow-memory tilt"
    code_location: "lines 165-186 (tight band branch)"
    parameters:
      - TIGHT_BAND_BPS: 26
      - TIGHT_FEE_CENTI_BPS: 2788
      - FLOW_MAX_TILT_BPS: 2
      - FLOW_DEADBAND_BPS: 6
    modification_directions:
      - "Inventory-aware spread widening"
      - "Volatility-conditional tightening"
      - "Queue-depth responsive fees"
      - "Time-of-day patterns"

  outer_regime_pricing:
    description: "Fee logic when significant mispricing detected"
    current_implementation: "Gamma-squared competitive matching with undercut"
    code_location: "lines 188-211 (outer regime branch)"
    parameters:
      - UNDERCUT_CENTI_BPS: 1000
      - BUFFER_CENTI_BPS: 35
    modification_directions:
      - "HJB-optimal spread control"
      - "Linear undercut with inventory penalty"
      - "Bandit-selected aggressiveness"
      - "Competitor-model-based response"

  flow_memory:
    description: "How the strategy tracks and responds to order flow"
    current_implementation: "Exponential decay with impulse capping"
    code_location: "lines 130-147 (flow score update)"
    parameters:
      - FLOW_ALPHA_PCT: 20
      - FLOW_DECAY_PCT: 95
      - FLOW_IMPULSE_CAP_BPS: 100
      - FLOW_CLAMP_BPS: 500
    modification_directions:
      - "Queue-position-based flow inference"
      - "Trade-size-weighted momentum"
      - "Regime-reset on large moves"
      - "Multi-timescale flow tracking"

  arbitrage_response:
    description: "How the strategy behaves after detecting arbitrage"
    current_implementation: "Post-arb fee cut for single timestamp"
    code_location: "lines 157-163, 213-217 (arb tagging and response)"
    parameters:
      - ARB_TAG_MIS_BPS: 32
      - POST_ARB_CUT_BPS: 2
    modification_directions:
      - "Gradual fee recovery curve"
      - "Direction-asymmetric response"
      - "Arb-frequency adaptive cut size"
      - "Predictive arb anticipation"
```

### 2.3 Selection Algorithm: UCB1

Replace the complex weighted scoring formula with UCB1 (Upper Confidence Bound):

```python
def select_mechanism(stats: Dict[str, MechanismStats]) -> str:
    """
    UCB1 selection balances exploitation (try what worked)
    with exploration (try what's under-sampled).

    Score = average_uplift + C * sqrt(ln(total_tries) / mechanism_tries)

    Where C is exploration constant (default: 0.5)
    """
    total_tries = sum(s.tries for s in stats.values())

    if total_tries == 0:
        return random.choice(list(stats.keys()))

    # Collect untried mechanisms and randomize to avoid dict-order bias
    untried = [name for name, s in stats.items() if s.tries == 0]
    if untried:
        return random.choice(untried)

    best_score = float('-inf')
    best_mechanism = None

    for name, s in stats.items():

        exploitation = s.total_uplift / s.tries
        exploration = EXPLORATION_C * math.sqrt(math.log(total_tries) / s.tries)
        score = exploitation + exploration

        if score > best_score:
            best_score = score
            best_mechanism = name

    return best_mechanism
```

**Why UCB1:**
- Mathematically principled (regret bounds)
- Single tunable parameter (exploration constant C)
- Naturally balances trying new things vs. exploiting known-good
- Transparent: selection reason is a single score

### 2.4 Prompt Structure

Replace abstract opportunity descriptions with concrete modification prompts:

````python
MODIFICATION_PROMPT_TEMPLATE = """
You are improving an AMM fee strategy by modifying ONE specific mechanism.

## CURRENT CHAMPION CODE
```solidity
{champion_code}
```

## YOUR TASK
Modify the **{mechanism_name}** mechanism to improve expected edge.

### Current Implementation
{current_implementation}

### Code Location
{code_location}

### Current Parameters
{parameters_formatted}

### Suggested Directions to Explore
{modification_directions}

## CONSTRAINTS
1. **ONLY modify code related to {mechanism_name}**
2. Keep all other mechanisms (listed below) unchanged:
{other_mechanisms}
3. Output a complete, compilable Solidity contract
4. The contract must be named `contract Strategy` (same as champion)
5. The `getName()` function must return `"{mechanism_name}_mod_v{version}"` for variant tracking
6. The contract must implement the same interface (afterInitialize, afterSwap, getName)

## OUTPUT FORMAT
Return ONLY the complete Solidity code. No explanations before or after.
"""
````

**Key differences from current prompts:**
- Specific code locations provided
- Explicit "do not modify" constraints
- Concrete parameter values shown
- Suggested directions are actionable, not abstract

### 2.5 Validation

Simple binary conformance check replaces complex conformance weighting:

```python
def validate_modification(
    original_code: str,
    modified_code: str,
    target_mechanism: str
) -> Tuple[bool, str]:
    """
    Check that the modification:
    1. Changed something in the target mechanism's code region
    2. Did not change other mechanism regions significantly

    Returns (is_valid, reason)
    """
    mechanisms = CHAMPION_MECHANISMS
    target_location = mechanisms[target_mechanism]["code_location"]

    # Parse both files, extract mechanism regions
    original_regions = extract_mechanism_regions(original_code)
    modified_regions = extract_mechanism_regions(modified_code)

    # Check target was modified
    if original_regions[target_mechanism] == modified_regions[target_mechanism]:
        return False, f"Target mechanism '{target_mechanism}' was not modified"

    # Check others were preserved
    for mech in mechanisms:
        if mech == target_mechanism:
            continue
        if original_regions[mech] != modified_regions[mech]:
            # Allow minor changes (whitespace, comments)
            if significant_diff(original_regions[mech], modified_regions[mech]):
                return False, f"Non-target mechanism '{mech}' was modified"

    return True, "Valid modification"
```

**On validation failure:** Regenerate with more explicit constraints, or skip iteration.

### 2.6 State Management

Replace 6+ opportunity-system state files with 2 new primary loop files (plus 1 migration shadow-log file; shared files like `knowledge_store.json` remain):

#### `mechanism_stats.json`
```json
{
  "schema_version": "2.0",
  "champion": {
    "name": "iskewx_v11",
    "edge": 508.86,
    "promoted_at": "2026-02-11T12:42:04Z"
  },
  "mechanisms": {
    "fair_price_estimation": {
      "tries": 5,
      "successes": 1,
      "total_uplift": 0.15,
      "invalid_count": 0,
      "last_tried": "2026-02-11T10:00:00Z",
      "best_delta": 0.13
    },
    "tight_band_pricing": {
      "tries": 3,
      "successes": 0,
      "total_uplift": -0.08,
      "invalid_count": 1,
      "last_tried": "2026-02-11T09:00:00Z",
      "best_delta": 0.0
    },
    "outer_regime_pricing": {
      "tries": 4,
      "successes": 1,
      "total_uplift": 0.22,
      "invalid_count": 0,
      "last_tried": "2026-02-11T11:00:00Z",
      "best_delta": 0.13
    },
    "flow_memory": {
      "tries": 2,
      "successes": 0,
      "total_uplift": 0.0,
      "invalid_count": 0,
      "last_tried": "2026-02-11T08:00:00Z",
      "best_delta": 0.0
    },
    "arbitrage_response": {
      "tries": 0,
      "successes": 0,
      "total_uplift": 0.0,
      "invalid_count": 0,
      "last_tried": null,
      "best_delta": null
    }
  },
  "global": {
    "total_iterations": 14,
    "total_champion_updates": 2,
    "exploration_constant": 0.5
  }
}
```

#### `iteration_log.jsonl` (append-only)
```json
{"iter": 1, "ts": "2026-02-11T08:00:00Z", "mechanism": "flow_memory", "delta": 0.0, "edge": 508.80, "valid": true}
{"iter": 2, "ts": "2026-02-11T08:30:00Z", "mechanism": "flow_memory", "delta": 0.0, "edge": 508.80, "valid": true}
{"iter": 3, "ts": "2026-02-11T09:00:00Z", "mechanism": "tight_band_pricing", "delta": -0.05, "edge": 508.75, "valid": true}
...
```

---

## 3. Configuration

### 3.1 Reduced Parameter Set

| Parameter | Default | Description |
|-----------|---------|-------------|
| `EXPLORATION_C` | 0.5 | UCB exploration constant |
| `IMPROVEMENT_THRESHOLD` | 0.02 | Minimum delta to count as success |
| `MAX_RETRIES_ON_INVALID` | 2 | Regeneration attempts on validation failure |
| `WILDCARD_FREQUENCY` | 10 | Every Nth iteration, try unconstrained generation |

### 3.2 Comparison to Current Configuration

| Aspect | Current | Proposed |
|--------|---------|----------|
| Selection parameters | 8 | 1 |
| Learning parameters | 4 | 1 |
| Cooldown parameters | 5 | 0 |
| Exploration parameters | 7 | 2 |
| **Total** | **24** | **4** |

---

## 4. Wildcard Iterations

To preserve ability to discover fundamentally new approaches:

````python
def should_run_wildcard(iteration: int, stats: dict) -> bool:
    """
    Run wildcard (unconstrained) generation when:
    1. Every WILDCARD_FREQUENCY iterations, OR
    2. All mechanisms have been tried 3+ times with no success
    """
    if iteration % WILDCARD_FREQUENCY == 0:
        return True

    all_tried = all(s["tries"] >= 3 for s in stats["mechanisms"].values())
    none_successful = all(s["successes"] == 0 for s in stats["mechanisms"].values())

    return all_tried and none_successful


def run_wildcard_iteration():
    """
    Unconstrained generation: ask LLM to propose any improvement.
    """
    prompt = f"""
    The current champion AMM strategy achieves {champion.edge} bps edge.
    Target is 527.0 bps.

    Current champion code:
    ```solidity
    {champion.code}
    ```

    Propose a NOVEL modification or entirely new approach that could
    significantly improve edge. You are not constrained to modifying
    existing mechanisms - you may restructure the strategy entirely.

    Output complete Solidity code.
    """
    return execute_llm_generation(prompt)
````

---

## 5. Migration Path

### Aggressive Rollout Strategy

Given the current system's conformance issues and plateau state, we prioritize speed over caution. At cutover, old-system state is frozen and a read-only shadow selector records what the old algorithm would choose, making reversal trivial.

### Day 1: Implement and Deploy

**Morning:**
1. Capture rollback snapshot in `.ralph-amm/phase7/state/migration_snapshot/` (`.opportunity_priors.json`, `.opportunity_history.json`, `.best_strategy.sol`, `.best_edge.txt`)
2. Implement `simplified_loop.py` (~200 lines)
3. Create `mechanism_definitions.yaml` from champion analysis
4. Initialize `mechanism_stats.json` with zeros
5. Test one iteration manually

**Afternoon:**
6. Deploy new loop as primary
7. Start `shadow_selector.py` in read-only mode (writes only `shadow_selections.jsonl`)
8. First 5 automated iterations under new system

### Day 2+: Monitor and Evaluate

**Success criteria (evaluated at iteration 10):**
- At least 1 champion improvement (any positive delta)
- Validation rate >90% (modifications target correct mechanism)
- No severe regressions (no -0.5 bps or worse)

**If criteria met:** Continue with new system, archive old state files at iteration 20.

**If criteria NOT met:** Execute rollback (see below).

---

## 6. Rollback Strategy

### Why Rollback Is Trivial

Old system state is **frozen at cutover** in `.ralph-amm/phase7/state/migration_snapshot/`:
- `.opportunity_priors.json`
- `.opportunity_history.json`
- `.best_strategy.sol`
- `.best_edge.txt`
- latest `opportunity_rankings_iter{N}.json` (optional, for audit)

The new system and shadow selector write to separate files:
- `mechanism_stats.json`
- `iteration_log.jsonl`
- `shadow_selections.jsonl`

**No shared mutable state.** Rollback restores exact pre-migration state by copying snapshot files back into `.ralph-amm/phase7/state/`.

### Rollback Triggers (Automatic)

Implement automatic rollback if ANY of these occur:

```python
ROLLBACK_TRIGGERS = {
    "consecutive_invalid": 3,      # 3 failed validations in a row
    "severe_regression": -0.5,     # Single iteration loses 0.5+ bps
    "cumulative_loss": -1.0,       # Total delta over 10 iterations
    "champion_destroyed": True,    # New champion worse than pre-migration
}
```

### Rollback Procedure (< 5 minutes)

```bash
# 1. Stop new loop
pkill -f simplified_loop.py

# 2. Restore frozen snapshot
STATE_DIR=".ralph-amm/phase7/state"
SNAPSHOT_DIR="$STATE_DIR/migration_snapshot"
cp "$SNAPSHOT_DIR/.opportunity_priors.json" "$STATE_DIR/.opportunity_priors.json"
cp "$SNAPSHOT_DIR/.opportunity_history.json" "$STATE_DIR/.opportunity_history.json"
cp "$SNAPSHOT_DIR/.best_strategy.sol" "$STATE_DIR/.best_strategy.sol"
cp "$SNAPSHOT_DIR/.best_edge.txt" "$STATE_DIR/.best_edge.txt"

# 3. Restart old loop
./scripts/amm-phase7-opportunity-engine.py --resume

# 4. Archive failed experiment artifacts
mv "$STATE_DIR/mechanism_stats.json" "$STATE_DIR/.archive/mechanism_stats_failed_$(date +%Y%m%d).json"
mv "$STATE_DIR/iteration_log.jsonl" "$STATE_DIR/.archive/iteration_log_failed_$(date +%Y%m%d).jsonl"
mv "$STATE_DIR/shadow_selections.jsonl" "$STATE_DIR/.archive/shadow_selections_failed_$(date +%Y%m%d).jsonl"

# 5. Log rollback reason
echo "Rollback at $(date): [REASON]" >> "$STATE_DIR/.archive/rollback_log.txt"
```

### Manual Rollback Decision Points

Even without automatic triggers, evaluate at:
- **Iteration 10:** Is average delta positive?
- **Iteration 20:** Has champion improved at least once?
- **Iteration 30:** Is new system outperforming old system's historical rate?

If answer is "no" at any checkpoint, consider rollback.

### Preserving Learnings on Rollback

Even if we rollback, capture insights:

```python
def on_rollback(reason: str):
    """Preserve learnings from failed experiment."""
    stats = load_json("mechanism_stats.json")

    insights = {
        "rollback_reason": reason,
        "iterations_run": stats["global"]["total_iterations"],
        "mechanism_deltas": {
            name: m["total_uplift"] / max(1, m["tries"])
            for name, m in stats["mechanisms"].items()
        },
        "best_modification_seen": find_best_modification(),
        "validation_failure_rate": calculate_validation_failures(),
    }

    # Feed back to old system as prior knowledge
    append_to_knowledge_store(insights)
```

---

## 7. Parallel Operation Details

### Shadow Log (What Old System Would Have Done)

```
┌─────────────────────────────────────────────────────────────────┐
│                     OPERATION MODEL                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  NEW SYSTEM (Primary)           OLD SYSTEM (Shadow Log)         │
│  ─────────────────────          ───────────────────────         │
│  simplified_loop.py             shadow_selector.py              │
│  mechanism_stats.json           shadow_selections.jsonl         │
│  iteration_log.jsonl            (state frozen at cutover)       │
│                                                                 │
│  EXECUTES strategies            LOGS what it WOULD select       │
│  Updates champion               No state updates                │
│                                                                 │
│  ↓                              ↓                               │
│  Simulation runs                Selection logged only           │
│  Results recorded               (for post-hoc comparison)       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Shadow Selector (Read-Only)

A lightweight script logs what the old system **would** select, without modifying state:

```python
# shadow_selector.py - read-only shadow mode
def log_shadow_selection(iteration: int):
    """Log what old system would select, without modifying any state."""
    # Load frozen state (read-only)
    priors = load_json(".opportunity_priors.json")  # frozen snapshot

    # Compute rankings using old algorithm
    rankings = compute_opportunity_rankings(priors, iteration)
    top_pick = rankings[0]

    # Append to shadow log (new file, doesn't touch old state)
    append_jsonl("shadow_selections.jsonl", {
        "iter": iteration,
        "would_select": top_pick["id"],
        "would_subfamily": top_pick["recommended_subfamily"],
        "score": top_pick["weighted_score"]
    })
```

This lets us compare: "What would the old system have tried?" vs "What did the new system try?"

### Comparison Metrics

After 10 iterations, compare:

| Metric | New System (Actual) | Old System (Shadow) |
|--------|---------------------|---------------------|
| Champion delta | +X.XX bps | (hypothetical) |
| Validation rate | XX% | N/A (no execution) |
| Selection diversity | X mechanisms tried | X opportunities tried |
| Would-have-matched | N/A | X/10 same as new |

If old system's shadow selections look more promising, that's evidence for rollback.

---

## 8. Risks and Mitigations

### Risk 1: Loss of Exploration Breadth
**Concern:** Current system can explore bayesian_optimization, adversarial_robustness, etc. - families unrelated to champion structure.

**Mitigation:**
- Wildcard iterations (every 10th) allow unconstrained exploration
- Mechanism modification directions include cross-family ideas (e.g., "HJB-optimal spread control" brings optimal_control into outer_regime)
- If all mechanisms plateau, system escalates to wildcard mode

### Risk 2: Mechanism Extraction Errors
**Concern:** Initial mechanism decomposition of champion may miss important code regions or draw boundaries incorrectly.

**Mitigation:**
- Manual review of mechanism boundaries before deployment
- Validation step checks that modifications stay in bounds
- Mechanism definitions are data (YAML/JSON), easily corrected

### Risk 3: Reduced Parallelism
**Concern:** Current system could explore multiple families in parallel. Proposed system is sequential.

**Mitigation:**
- Sequential is simpler to reason about and debug
- If parallelism needed, can spawn multiple modification attempts for same mechanism
- Iteration speed is bottlenecked by LLM generation and simulation, not selection

### Risk 4: Champion Lock-in
**Concern:** If champion has fundamental flaws, all modifications inherit them.

**Mitigation:**
- Wildcard iterations can propose structural changes
- If 20+ iterations yield no improvement, trigger "fresh start" mode
- Periodic human review of champion assumptions

---

## 9. Success Metrics

### Primary Metrics
| Metric | Current | Target | Measurement |
|--------|---------|--------|-------------|
| Conformance rate | 56% | >95% | `valid_modifications / total_iterations` |
| Selection interpretability | Low | High | Can explain why mechanism X was chosen in <10 words |
| Configuration complexity | 24 params | 4 params | Count of tunable parameters |
| Loop-owned state artifacts | 6+ | 3 | `mechanism_stats.json`, `iteration_log.jsonl`, `shadow_selections.jsonl` |
| Code lines (loop logic) | ~800 | ~200 | `wc -l` on loop implementation |

### Secondary Metrics
| Metric | Current | Target | Measurement |
|--------|---------|--------|-------------|
| Edge improvement rate | 0.02 bps/iter | 0.05 bps/iter | Rolling 20-iteration average |
| Debug time per issue | ~30 min | ~10 min | Developer estimate |
| New developer onboarding | ~2 hours | ~30 min | Time to understand loop logic |

---

## 10. Implementation Sketch

### 10.1 Core Loop (`simplified_loop.py`)

```python
#!/usr/bin/env python3
"""
Simplified autonomous loop: champion-centric mechanism modification.
"""

import json
import math
import random
from pathlib import Path
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Dict, Optional, Tuple

# Configuration
EXPLORATION_C = 0.5
IMPROVEMENT_THRESHOLD = 0.02
MAX_RETRIES_ON_INVALID = 2
WILDCARD_FREQUENCY = 10

STATE_DIR = Path(".ralph-amm/phase7/state")
STATS_FILE = STATE_DIR / "mechanism_stats.json"
LOG_FILE = STATE_DIR / "iteration_log.jsonl"


@dataclass
class Champion:
    name: str
    code: str
    edge: float


@dataclass
class MechanismStats:
    tries: int = 0
    successes: int = 0
    total_uplift: float = 0.0
    invalid_count: int = 0  # Track validation/compile failures per mechanism
    best_delta: Optional[float] = None


def load_stats() -> dict:
    if STATS_FILE.exists():
        return json.loads(STATS_FILE.read_text())
    return initialize_stats()


def save_stats(stats: dict) -> None:
    STATS_FILE.write_text(json.dumps(stats, indent=2))


def append_log(entry: dict) -> None:
    with LOG_FILE.open("a") as f:
        f.write(json.dumps(entry) + "\n")


def select_mechanism(stats: dict) -> str:
    """UCB1 selection over mechanisms."""
    mechanisms = stats["mechanisms"]
    total = sum(m["tries"] for m in mechanisms.values())

    if total == 0:
        return random.choice(list(mechanisms.keys()))

    # Randomize among untried to avoid dict-order bias
    untried = [name for name, m in mechanisms.items() if m["tries"] == 0]
    if untried:
        return random.choice(untried)

    best_score, best_mech = float("-inf"), None

    for name, m in mechanisms.items():

        exploit = m["total_uplift"] / m["tries"]
        explore = EXPLORATION_C * math.sqrt(math.log(total) / m["tries"])
        score = exploit + explore

        if score > best_score:
            best_score, best_mech = score, name

    return best_mech


def generate_prompt(champion: Champion, mechanism: str) -> str:
    """Generate concrete modification prompt."""
    info = MECHANISM_DEFINITIONS[mechanism]
    other_mechs = [m for m in MECHANISM_DEFINITIONS if m != mechanism]

    return MODIFICATION_PROMPT_TEMPLATE.format(
        champion_code=champion.code,
        mechanism_name=mechanism,
        current_implementation=info["current_implementation"],
        code_location=info["code_location"],
        parameters_formatted=format_parameters(info["parameters"]),
        modification_directions=format_directions(info["modification_directions"]),
        other_mechanisms=", ".join(other_mechs),
        version=get_next_version(mechanism)
    )


def run_iteration(iteration: int) -> dict:
    """Execute one iteration of the loop."""
    stats = load_stats()
    champion = load_champion()

    # Check for wildcard
    if should_run_wildcard(iteration, stats):
        return run_wildcard_iteration(iteration, stats, champion)

    # Select mechanism
    mechanism = select_mechanism(stats)

    # Generate and execute
    prompt = generate_prompt(champion, mechanism)
    candidate_code = execute_llm(prompt)

    # Validate
    valid, reason = validate_modification(champion.code, candidate_code, mechanism)

    if not valid:
        for retry in range(MAX_RETRIES_ON_INVALID):
            candidate_code = execute_llm(prompt + f"\n\nPREVIOUS ATTEMPT INVALID: {reason}")
            valid, reason = validate_modification(champion.code, candidate_code, mechanism)
            if valid:
                break

    if not valid:
        # Track invalid attempts per mechanism
        stats["mechanisms"][mechanism]["invalid_count"] += 1
        save_stats(stats)
        append_log({"iter": iteration, "mechanism": mechanism, "valid": False, "reason": reason})
        return {"status": "invalid", "mechanism": mechanism, "reason": reason}

    # Measure
    candidate_edge = run_simulation(candidate_code)
    delta = candidate_edge - champion.edge

    # Update stats
    m = stats["mechanisms"][mechanism]
    m["tries"] += 1
    m["total_uplift"] += delta
    m["last_tried"] = utc_now()

    if delta > IMPROVEMENT_THRESHOLD:
        m["successes"] += 1

    if m["best_delta"] is None or delta > m["best_delta"]:
        m["best_delta"] = delta

    # Promote if better
    promoted = False
    if candidate_edge > champion.edge:
        promote_champion(candidate_code, candidate_edge, mechanism)
        stats["champion"]["edge"] = candidate_edge
        stats["global"]["total_champion_updates"] += 1
        promoted = True

    stats["global"]["total_iterations"] += 1
    save_stats(stats)

    # Log
    entry = {
        "iter": iteration,
        "ts": utc_now(),
        "mechanism": mechanism,
        "delta": delta,
        "edge": candidate_edge,
        "valid": True,
        "promoted": promoted
    }
    append_log(entry)

    return {"status": "complete", **entry}


def main():
    """Main entry point."""
    stats = load_stats()
    iteration = stats["global"]["total_iterations"] + 1

    print(f"=== Iteration {iteration} ===")
    result = run_iteration(iteration)

    if result["status"] == "complete":
        print(f"Mechanism: {result['mechanism']}")
        print(f"Delta: {result['delta']:+.2f} bps")
        print(f"Edge: {result['edge']:.2f} bps")
        if result.get("promoted"):
            print(">>> NEW CHAMPION <<<")
    else:
        print(f"Invalid: {result['reason']}")


if __name__ == "__main__":
    main()
```

### 10.2 Mechanism Definitions (`mechanism_definitions.yaml`)

```yaml
# Champion mechanism decomposition
# Update this when champion changes

champion_file: iskewx_v11.sol
champion_edge: 508.86

mechanisms:
  fair_price_estimation:
    current_implementation: |
      Jump-capped EWMA with gamma-inferred anchor.
      On each new timestamp, infers fair price from spot and previous gamma,
      then applies EWMA smoothing with adaptive alpha based on mispricing magnitude.
      Jump caps prevent extreme price updates (±400 bps max).
    code_location: "afterSwap lines 84-128"
    parameters:
      BASE_ALPHA_NEW_PCT: 19
      QUIET_ALPHA_NEW_PCT: 15
      FAST_ALPHA_NEW_PCT: 19
      MAX_ALPHA_NEW_PCT: 19
      JUMP_UP_BPS: 400
      JUMP_DOWN_BPS: 400
      QUIET_MIS_BPS: 15
      FAST_MIS_BPS: 9999
    modification_directions:
      - "Use microprice (bid-ask midpoint weighted by queue sizes) instead of spot"
      - "Add VWAP anchor from recent trades"
      - "Regime-conditional alpha: higher in volatile periods"
      - "Kalman filter for smoother state estimation"
      - "Order-flow-weighted price inference"

  tight_band_pricing:
    current_implementation: |
      When mispricing is within TIGHT_BAND_BPS (26 bps), use symmetric base fee
      with small flow-memory tilt. Tilt is capped at ±2 bps and applies only
      when flow deviation exceeds deadband.
    code_location: "afterSwap lines 165-186"
    parameters:
      TIGHT_BAND_BPS: 26
      TIGHT_FEE_CENTI_BPS: 2788
      FLOW_MAX_TILT_BPS: 2
      FLOW_DEADBAND_BPS: 6
      FLOW_TILT_DIV: 9
    modification_directions:
      - "Inventory-aware spread: widen when inventory imbalanced"
      - "Volatility-conditional: tighten in low-vol, widen in high-vol"
      - "Queue-depth responsive: tighter when deep liquidity"
      - "Time-decay tilt: tilt effect decays within timestamp"

  outer_regime_pricing:
    current_implementation: |
      When mispricing exceeds tight band, use gamma-squared competitive matching.
      On the weak side (away from fair), undercut competitor by UNDERCUT_CENTI_BPS.
      On the strong side (toward fair), add protective buffer.
    code_location: "afterSwap lines 188-211"
    parameters:
      UNDERCUT_CENTI_BPS: 1000
      BUFFER_CENTI_BPS: 35
    modification_directions:
      - "HJB-optimal spread from inventory control theory"
      - "Linear undercut with inventory penalty term"
      - "Bandit-selected aggressiveness based on recent fill rates"
      - "Competitor-model: estimate competitor strategy and counter"
      - "Mispricing-proportional undercut (larger mispricing = more aggressive)"

  flow_memory:
    current_implementation: |
      Tracks net order flow as exponential moving average.
      Flow score centered at WAD (1e18), above = net buy pressure, below = net sell.
      Updates on each trade with impulse proportional to trade size.
      Decays toward neutral on new timestamps.
    code_location: "afterSwap lines 130-147"
    parameters:
      FLOW_ALPHA_PCT: 20
      FLOW_DECAY_PCT: 95
      FLOW_IMPULSE_CAP_BPS: 100
      FLOW_CLAMP_BPS: 500
    modification_directions:
      - "Queue-position inference: estimate flow from queue changes"
      - "Trade-size-weighted: large trades have outsized impact"
      - "Regime-reset: reset flow on large price moves (likely regime change)"
      - "Multi-timescale: track fast (1-tick) and slow (10-tick) flow separately"
      - "Signed volume: incorporate trade direction more strongly"

  arbitrage_response:
    current_implementation: |
      Tags timestamps where trade moves price toward fair by >32 bps as "arb".
      On arb-tagged timestamps, reduces both fees by 2 bps to capture more flow.
    code_location: "afterSwap lines 157-163 (tagging), 213-217 (response)"
    parameters:
      ARB_TAG_MIS_BPS: 32
      POST_ARB_CUT_BPS: 2
    modification_directions:
      - "Gradual recovery: cut fees, then slowly restore over N timestamps"
      - "Direction-asymmetric: different response for buy vs sell arbs"
      - "Arb-frequency adaptive: larger cuts if arbs are rare (valuable)"
      - "Predictive: anticipate arbs from order flow and pre-position"
      - "Size-proportional: larger arb trades get larger fee cuts"
```

---

## 11. Open Questions

1. **UCB1 reward scaling for unbounded deltas?**
   - Delta ranges widely (e.g., +0.02 to -2.08) which can dominate the exploration term
   - Options: bounded transform (tanh), Bernoulli reward (success/fail only), reset stats on champion promotion
   - Recommendation: Start with raw delta; add bounded transform if one mechanism accumulates outsized negative total

2. **Should mechanism boundaries be enforced syntactically or semantically?**
   - Syntactic: line numbers, function names
   - Semantic: AST analysis of what code does
   - Recommendation: Start syntactic, add semantic validation if needed

3. **How to handle champion replacement?**
   - Option A: Re-extract mechanisms from new champion
   - Option B: Keep mechanism definitions stable, update parameters only
   - Recommendation: Option A with manual review

4. **Should wildcard successes feed back into mechanism stats?**
   - If wildcard produces +0.5 bps via novel approach, how to attribute?
   - Recommendation: Log as "wildcard" mechanism, don't pollute other stats

5. **Multi-mechanism modifications?**
   - Some improvements may require coordinated changes (e.g., flow_memory + tight_band_pricing)
   - Recommendation: Phase 2 feature - start with single-mechanism only

---

## 12. Appendix: Comparison Summary

| Aspect | Current System | Proposed System |
|--------|----------------|-----------------|
| **Selection unit** | Abstract opportunity families | Concrete code mechanisms |
| **Selection algorithm** | Weighted multi-factor scoring | UCB1 bandit |
| **Subfamily tracking** | Yes (with 44% mismatch) | No |
| **Conformance handling** | EWMA-weighted learning | Binary validation |
| **Prompt style** | Abstract descriptions | Concrete code locations |
| **State complexity** | 6+ files, nested JSON | 3 loop-owned files (+ shared state), JSON/JSONL |
| **Config parameters** | 24 | 4 |
| **Exploration mechanism** | Untried family bonus | UCB exploration term + wildcard |
| **Learning feedback** | Indirect (inferred subfamily) | Direct (did this modification help?) |
| **Debugging** | "Why was X selected?" is complex | UCB score is single number |

---

## 13. Decision Request

This RFC requests approval for **immediate implementation and deployment**:

1. **Today:** Implement simplified loop and deploy as primary system
2. **Shadow log:** Old system state frozen; lightweight script logs what it *would* select
3. **Day 2:** Evaluate at iteration 10 against success criteria
4. **Rollback:** Automatic triggers + manual checkpoints ensure fast reversal (<5 min)

### Why Aggressive Rollout Is Low-Risk

| Concern | Mitigation |
|---------|------------|
| Lose progress | Old system state frozen at cutover; instant restore |
| Bad champion | Rollback restores pre-migration champion |
| Wasted iterations | At most 10 iterations before first checkpoint |
| Learning lost | Rollback procedure captures insights |

### Approval Checklist

- [ ] Mechanism decomposition reviewed (5 mechanisms identified correctly)
- [ ] Rollback triggers agreed (3 consecutive invalid, -0.5 severe, -1.0 cumulative)
- [ ] Shadow log approach understood (state frozen, read-only selection logging)
- [ ] **GO decision for Day 1 implementation**

---

*End of RFC-001*
