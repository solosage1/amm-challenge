#!/usr/bin/env python3
"""
Simplified Phase 7 loop: champion-centric mechanism modification.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Set, Tuple


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


from .history import (
    archive_champion,
    champion_history_list,
    champion_history_revert,
    champion_history_show,
    get_champion_by_sequence,
    load_champion_history_manifest,
)
from .policy import (
    _safe_probability,
    apply_iteration_policy_decision,
    extract_iteration_policy_metadata,
    format_iteration_policy_hints,
)
from .shared import append_jsonl, atomic_write_json, atomic_write_text, load_json, parse_get_name, utc_now_iso
from .validation import (
    resolve_mechanism_spans,
    validate_candidate,
)


SCHEMA_VERSION = "2.0"
DEFAULT_EXPLORATION_C = 0.5
DEFAULT_IMPROVEMENT_THRESHOLD = 0.02
DEFAULT_MAX_RETRIES_ON_INVALID = 2
DEFAULT_WILDCARD_FREQUENCY = 10
DEFAULT_ROLLBACK_CONSECUTIVE_INVALID = 3
DEFAULT_ROLLBACK_SEVERE_REGRESSION = -0.5
DEFAULT_ROLLBACK_CUMULATIVE_LOSS = -1.0
DEFAULT_ROLLBACK_WINDOW = 10
ROLLBACK_SPINE_STRATEGY_FILE = ".rollback_spine_strategy.sol"
ROLLBACK_SPINE_EDGE_FILE = ".rollback_spine_edge.txt"
ROLLBACK_SPINE_META_FILE = ".rollback_spine_meta.json"
ROLLBACK_RESTORE_MODES = ("history_then_spine", "history_only", "spine_only", "snapshot_only")
DEFAULT_ROLLBACK_RESTORE_MODE_RAW = os.environ.get("ROLLBACK_RESTORE_MODE", "history_then_spine").strip().lower()
DEFAULT_ROLLBACK_RESTORE_MODE = (
    DEFAULT_ROLLBACK_RESTORE_MODE_RAW
    if DEFAULT_ROLLBACK_RESTORE_MODE_RAW in ROLLBACK_RESTORE_MODES
    else "history_then_spine"
)
DEFAULT_ROLLBACK_ALLOW_SNAPSHOT_FALLBACK = (
    os.environ.get("ROLLBACK_ALLOW_SNAPSHOT_FALLBACK", "0").strip().lower() in {"1", "true", "yes", "on"}
)
DEFAULT_LLM_COMMAND = os.environ.get("CODEX_CLI", "codex")
DEFAULT_LLM_MODEL = os.environ.get("CODEX_MODEL", "")
DEFAULT_LLM_TIMEOUT_MINUTES = env_float("CODEX_TIMEOUT_MINUTES", 25.0)
DEFAULT_LLM_MAX_OUTPUT_TOKENS = env_int("CODEX_MAX_OUTPUT_TOKENS", 8000)
DEFAULT_POLICY_EVOLUTION_FREQUENCY = 5
DEFAULT_SEED_OFFSETS = "0,10000"
DEFAULT_BOOTSTRAP_SEED_OFFSETS = "0,10000"

# Test failure retry configuration
# Each entry maps a failure type to its detection patterns, retry limit, and prompt modifier
TEST_FAILURE_CATALOG = {
    "gas_error": {
        "patterns": [
            "out of gas",
            "outofgas",
            "gas limit",
            "exceeded gas",
        ],
        "max_retries": 1,
        "prompt_modifier": "_build_gas_optimized_prompt",
        "description": "EVM gas limit exceeded during execution",
    },
    # Future expansion examples (disabled for now with max_retries=0):
    "timeout_error": {
        "patterns": [
            "timeout",
            "timed out",
            "execution timeout",
        ],
        "max_retries": 0,  # Disabled for now
        "prompt_modifier": "_build_timeout_optimized_prompt",
        "description": "Test execution timeout",
    },
    "simulation_error": {
        "patterns": [
            "numerical instability",
            "simulation diverged",
            "invalid price",
        ],
        "max_retries": 0,  # Disabled for now
        "prompt_modifier": "_build_simulation_optimized_prompt",
        "description": "Simulation numerical issues",
    },
}

def _get_retry_limit(failure_type: str) -> int:
    """
    Get retry limit for a failure type, checking env var override first.

    Environment variable overrides:
    - RETRY_GAS_ERROR=2 would override gas_error max_retries to 2
    - RETRY_TIMEOUT_ERROR=1 would enable timeout retries

    Args:
        failure_type: The failure type key from TEST_FAILURE_CATALOG

    Returns:
        The retry limit (0 means no retries)
    """
    env_key = f"RETRY_{failure_type.upper()}"
    env_val = os.environ.get(env_key)
    if env_val is not None:
        try:
            return int(env_val)
        except ValueError:
            pass
    return TEST_FAILURE_CATALOG.get(failure_type, {}).get("max_retries", 0)

DEFAULT_PROMOTION_STD_PENALTY = 0.5
DEFAULT_HYPOTHESES_FILENAME = "hypotheses_backlog.json"
DEFAULT_HYPOTHESIS_RECENT_WINDOW = 20
DEFAULT_HYPOTHESIS_NEAR_DUP_DELTA = 0.01
DEFAULT_TENETS_FILE = ".ralph-amm/phase7/docs/HYPOTHESIS_SELECTION_TENETS.md"
DEFAULT_TENET_EVOLUTION_FREQUENCY = 20
DEFAULT_SELECTION_TOP_K = 5
DEFAULT_SELECTION_RECENT_FAILURES = 8
DEFAULT_TENET_META_STATE_FILE = "tenet_meta_state.json"
DEFAULT_HYPOTHESIS_SELECTION_LOG = "hypothesis_selection_log.jsonl"
DEFAULT_TENET_EVOLUTION_LOG = "tenet_evolution_log.jsonl"
DEFAULT_PROMPTS_DIR = ".ralph-amm/phase7/prompts"
DEFAULT_PROMPT_TEMPLATE_HYPOTHESIS_GENERATION = "hypothesis_generation.txt"
DEFAULT_PROMPT_TEMPLATE_TENET_SELECTION = "tenet_guided_selection.txt"
DEFAULT_PROMPT_TEMPLATE_TENET_EVOLUTION = "tenet_evolution.txt"
SYSTEM_RANDOM = random.SystemRandom()
DEFAULT_BOOTSTRAP_CANDIDATES = [
    ".ralph-amm/research/forks/shl0k28/strategies/Strategy.sol",
    ".ralph-amm/research/forks/MacroWang001/strategies/yq-v2_523.sol",
]
BOOTSTRAP_BACKUP_FILES = (
    ".best_strategy.sol",
    ".best_edge.txt",
    "mechanism_stats.json",
    "iteration_log.jsonl",
    "policy_evolution_log.jsonl",
    "policy_evolution_state.json",
    "shadow_selections.jsonl",
)
BOOTSTRAP_RESET_FILES = (
    "mechanism_stats.json",
    "iteration_log.jsonl",
    "policy_evolution_log.jsonl",
    "policy_evolution_state.json",
    "shadow_selections.jsonl",
)

# Champion history constants
DEFAULT_CHAMPION_HISTORY_MAX = 10
CHAMPION_HISTORY_DIR = ".champion_history"
CHAMPION_HISTORY_MANIFEST = "manifest.json"

DEFAULT_ITERATION_POLICY_COOLDOWN_SPAN = env_int("ITERATION_POLICY_COOLDOWN_SPAN", 6)
DEFAULT_ITERATION_POLICY_MIN_CONFIDENCE = env_float("ITERATION_POLICY_MIN_CONFIDENCE", 0.7)

# Regression gate: reject candidates with catastrophic regression
DEFAULT_SEVERE_REGRESSION_GATE = env_float("SEVERE_REGRESSION_GATE", -5.0)

ITERATION_GOVERNOR_BLOCK = """
## ITERATION GOVERNOR (REASONING FIRST)
- Optimize expected champion improvement per unit time, not exhaustive local sweep coverage.
- Reassess ceiling probability and expected value every 4-6 experiments.
- If further local exploration has low expected value, emit a pivot/ceiling decision with confidence.
""".strip()

ITERATION_POLICY_METADATA_BLOCK = """
### REQUIRED METADATA COMMENT
Include exactly one single-line Solidity comment near the top of the contract:
`// ITERATION_POLICY {"decision":"continue|pivot|ceiling_reached","hypothesis_id":"id_or_null","confidence":0.0-1.0,"ceiling_probability":0.0-1.0,"ev_next_5":float,"best_delta_seen":float,"reason":"short rationale","next_mechanism":"name_or_null"}`
""".strip()

PROMPT_COMMON_PRIORS = """
## PRIORS
- Preserve the estimator spine, slot layout, and public interfaces.
- Refactor with helpers only when needed for compileability.
""".strip()

PROMPT_COMMON_DONT_PURSUE = """
## DO NOT PURSUE
- Regime FSM/ladders, continuation-hazard rebates, offside gating
- PI/control-loop feedback, Bayesian arb probability blending
- First-trade-only recentering or high-gain noisy feedback states
""".strip()

PROMPT_COMMON_CONTRACT_CONSTRAINTS = """
3. Output a complete, compilable Solidity contract
4. Keep contract declaration as `contract Strategy`
5. Set getName() return value to "{variant_name}"
6. Keep interface compatibility (afterInitialize, afterSwap, getName)
""".strip()

PROMPT_COMMON_HYPOTHESIS_EXECUTION = """
- Choose exactly one hypothesis_id from the shortlist below and set it in ITERATION_POLICY.hypothesis_id.
- If a Selected Hypothesis is provided, treat it as authoritative and implement that hypothesis id.
- Use scorecard feedback to balance exploration (untested/low-tries) and exploitation (higher average/best uplift).
- Treat eff_priority as the primary shortlist score; raw priority alone is not sufficient.
- Prefer the smallest code change that cleanly tests the selected hypothesis.
- Penalize lock-in: if repeat_streak is high, or steps_since_last is small with non-positive recent_mean_delta, prefer a different hypothesis.
- Treat soft_nochange as failed experiment quality; avoid reselecting unless you can name a concrete new code lever.
- Treat near_dup_nonpos=1 as stagnation evidence unless you can explain why the next edit is materially different.
- In ITERATION_POLICY.reason, cite at least one shortlist metric (e.g., eff_priority, recent_mean_delta, repeat_streak, steps_since_last).
""".strip()

PROMPT_COMMON_OUTPUT_FORMAT = """
## OUTPUT FORMAT
Return ONLY the complete Solidity code. No explanations before or after.
""".strip()

HYPOTHESIS_GENERATION_TEMPLATE_FALLBACK = """
## LLM REASONING REQUIREMENTS
- Ground your edit in at least one tenet from the tenet list.
- Use robust promotion metric context (primary_edge/promotion_edge), not alternate score views.
- If a selected hypothesis id is provided, do not switch to a different hypothesis id.
- In ITERATION_POLICY.reason, cite one metric and one tenet by number.
""".strip()

TENET_GUIDED_SELECTION_PROMPT_FALLBACK = """
You are selecting one hypothesis for the next AMM iteration.

Return STRICT JSON only:
{
  "selected_hypothesis_id": "string",
  "confidence": 0.0,
  "tenet_alignment": [{"tenet": "T1", "alignment": "aligned|neutral|misaligned", "note": "short"}],
  "tenet_tensions": ["short note about a real tenet tradeoff"],
  "reasoning": "short rationale referencing multiple decisive tenets and at least one metric",
  "evidence_iteration_ids": [1, 2]
}

Mechanism: {{MECHANISM_NAME}}
Tenets:
{{TENETS_BLOCK}}

Evidence snapshot:
{{EVIDENCE_SNAPSHOT}}

Candidates (best first):
{{CANDIDATES_JSON}}

Rules:
- Select exactly one candidate id from the provided candidate list.
- Evaluate the entire tenet set, not a single tenet.
- tenet_alignment must include one row for each tenet id (T1..TN) exactly once.
- If tenets conflict, record the conflict in tenet_tensions and explain your tradeoff in reasoning.
""".strip()

TENET_EVOLUTION_PROMPT_FALLBACK = """
You are reviewing recent AMM optimization evidence and proposing one tenet update.

Return STRICT JSON only:
{
  "proposal_type": "ADD|MODIFY|DELETE|NO_CHANGE",
  "affected_tenet": 0,
  "current_text": "optional",
  "proposed_text": "optional",
  "reasoning": "short rationale",
  "expected_impact": "short impact",
  "evidence_iteration_ids": [1, 2]
}

Current tenets:
{{TENETS_BLOCK}}

Evidence snapshot:
{{EVIDENCE_SNAPSHOT}}

Recent window results:
{{WINDOW_RESULTS_JSON}}
""".strip()

JSON_REPAIR_PROMPT_TEMPLATE = """
Return ONLY valid JSON object. No markdown, no prose.

Schema reminder:
{{SCHEMA_HINT}}

Your invalid response was:
{{BROKEN_RESPONSE}}
""".strip()


PROMPT_TEMPLATE = """
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

### Hypothesis Shortlist (LLM Selection Required)
{hypothesis_shortlist}

### Selected Hypothesis (Pre-Selection)
{selected_hypothesis_block}

### Tenets
{tenets_block}

### Evidence Snapshot
{evidence_snapshot_block}

{generation_requirements_block}

{priors_block}

{dont_pursue_block}

{iteration_governor_block}

### Mechanism-Specific Policy Hints
{iteration_policy_hints}

{iteration_policy_metadata_block}

## CONSTRAINTS
1. ONLY modify code related to {mechanism_name}
2. Keep all other mechanisms unchanged:
{other_mechanisms}
{common_contract_constraints}

{output_format_block}
""".strip()


WILDCARD_PROMPT_TEMPLATE = """
You are improving an AMM fee strategy with a broad structural change.

## CURRENT CHAMPION CODE
```solidity
{champion_code}
```

## YOUR TASK
Propose a complete contract revision that can modify any mechanism if it improves expected edge.

### Tenets
{tenets_block}

### Evidence Snapshot
{evidence_snapshot_block}

{generation_requirements_block}

{dont_pursue_block}

{iteration_governor_block}

{iteration_policy_metadata_block}

## CONSTRAINTS
1. Output a complete, compilable Solidity contract
2. Keep contract declaration as `contract Strategy`
3. Set getName() return value to "{variant_name}"
4. Keep interface compatibility (afterInitialize, afterSwap, getName)
5. Include basic structural sanity checks in reasoning: bounded fees, coherent spread behavior, no pathological liquidity collapse.

{output_format_block}
""".strip()


# ============================================================================
# Synergy Iteration Functions
# ============================================================================


def parse_seed_offsets(raw: str) -> List[int]:
    offsets: List[int] = []
    for token in str(raw).split(","):
        value = token.strip()
        if not value:
            continue
        try:
            parsed = int(value)
        except ValueError:
            continue
        if parsed < 0:
            continue
        if parsed > 10000:
            continue
        offsets.append(parsed)
    if not offsets:
        return [0]
    deduped = sorted(set(offsets))
    return deduped


def authoritative_tries(rec: Dict[str, Any]) -> int:
    if "tries_authoritative" in rec:
        return int(rec.get("tries_authoritative", 0) or 0)
    return int(rec.get("tries", 0) or 0)


def select_with_ucb(
    records: Dict[str, Dict[str, Any]],
    exploration_c: float,
    rng: random.Random,
    tries_getter: Callable[[Dict[str, Any]], int],
) -> str:
    if not records:
        return ""
    total_tries = sum(max(0, int(tries_getter(rec))) for rec in records.values())
    if total_tries == 0:
        return rng.choice(list(records.keys()))
    untried = [name for name, rec in records.items() if int(tries_getter(rec)) == 0]
    if untried:
        return rng.choice(untried)
    best_name = ""
    best_score = float("-inf")
    for name, rec in records.items():
        tries = int(tries_getter(rec))
        if tries <= 0:
            continue
        total_uplift = float(rec.get("total_uplift", 0.0) or 0.0)
        exploit = total_uplift / tries
        explore = exploration_c * math.sqrt(math.log(max(2, total_tries)) / tries)
        score = exploit + explore
        if score > best_score:
            best_score = score
            best_name = name
    if best_name:
        return best_name
    return rng.choice(list(records.keys()))


def is_authoritative_log_entry(entry: Dict[str, Any]) -> bool:
    if "authoritative_eval" in entry:
        return bool(entry.get("authoritative_eval"))
    if "promotable" in entry:
        return bool(entry.get("promotable"))
    if "screen_only_eval" in entry:
        return not bool(entry.get("screen_only_eval"))
    evaluation = entry.get("evaluation")
    if isinstance(evaluation, dict):
        if "promotable" in evaluation:
            return bool(evaluation.get("promotable"))
        if "screen_only" in evaluation:
            return not bool(evaluation.get("screen_only"))
    return True



def format_parameters(params: Dict[str, Any]) -> str:
    rows = []
    for key, value in params.items():
        rows.append(f"- {key}: {value}")
    return "\n".join(rows) if rows else "- (none)"


def format_directions(directions: Sequence[str]) -> str:
    rows = []
    for item in directions:
        rows.append(f"- {item}")
    return "\n".join(rows) if rows else "- (none)"


def hypotheses_for_mechanism(
    hypotheses: Sequence[Dict[str, Any]],
    mechanism_name: str,
) -> List[Dict[str, Any]]:
    target = str(mechanism_name or "").strip()
    if not target:
        return []
    return [
        hypothesis
        for hypothesis in hypotheses
        if isinstance(hypothesis, dict) and str(hypothesis.get("mechanism", "")).strip() == target
    ]


def _hypothesis_id_from_log_entry(entry: Dict[str, Any]) -> str:
    hypothesis = entry.get("hypothesis")
    if isinstance(hypothesis, dict):
        hypothesis_id = str(hypothesis.get("id", "")).strip()
        if hypothesis_id:
            return hypothesis_id
    iteration_policy = entry.get("iteration_policy")
    if isinstance(iteration_policy, dict):
        hypothesis_id = str(iteration_policy.get("hypothesis_id", "")).strip()
        if hypothesis_id:
            return hypothesis_id
    return ""


def summarize_hypothesis_recent_history(
    log_entries: Sequence[Dict[str, Any]],
    mechanism_name: str,
    window: int = DEFAULT_HYPOTHESIS_RECENT_WINDOW,
) -> Dict[str, Any]:
    mechanism = str(mechanism_name or "").strip()
    if not mechanism or not log_entries:
        return {
            "window": max(1, int(window)),
            "total_recent": 0,
            "unique_recent": 0,
            "top_recent_id": None,
            "top_recent_count": 0,
            "records": {},
        }

    mechanism_rows: List[Tuple[Dict[str, Any], str]] = []
    for entry in log_entries:
        if not isinstance(entry, dict):
            continue
        if str(entry.get("mechanism", "")).strip() != mechanism:
            continue
        hypothesis_id = _hypothesis_id_from_log_entry(entry)
        if not hypothesis_id:
            continue
        mechanism_rows.append((entry, hypothesis_id))

    window_size = max(1, int(window))
    recent_rows = mechanism_rows[-window_size:]
    records: Dict[str, Dict[str, Any]] = {}
    soft_warning = f"soft_check:target mechanism '{mechanism}' was not modified"
    for step_idx, (entry, hypothesis_id) in enumerate(recent_rows, start=1):
        rec = records.setdefault(
            hypothesis_id,
            {
                "recent_count": 0,
                "delta_values": [],
                "recent_mean_delta": None,
                "last_delta": None,
                "last_two_delta_diff": None,
                "near_duplicate_nonpositive": 0,
                "soft_nochange": 0,
                "repeat_streak": 0,
                "steps_since_last": window_size,
                "last_seen_step": 0,
            },
        )
        rec["recent_count"] = int(rec.get("recent_count", 0)) + 1
        rec["last_seen_step"] = step_idx

        delta_raw = entry.get("delta")
        if delta_raw is not None:
            delta_value = _float_value(delta_raw, default=0.0)
            delta_values = rec.get("delta_values")
            if isinstance(delta_values, list):
                delta_values.append(delta_value)
            rec["last_delta"] = delta_value

        warnings = entry.get("validation_warnings")
        if isinstance(warnings, list) and soft_warning in warnings:
            rec["soft_nochange"] = int(rec.get("soft_nochange", 0)) + 1

    top_recent_id = None
    top_recent_count = 0
    latest_step = len(recent_rows)
    for hypothesis_id, rec in records.items():
        delta_values = rec.get("delta_values")
        if isinstance(delta_values, list) and delta_values:
            rec["recent_mean_delta"] = sum(delta_values) / len(delta_values)
            if len(delta_values) >= 2:
                prev_delta = _float_value(delta_values[-2], default=0.0)
                last_delta = _float_value(delta_values[-1], default=0.0)
                last_two_delta_diff = abs(last_delta - prev_delta)
                rec["last_two_delta_diff"] = last_two_delta_diff
                if (
                    last_delta <= 0.0
                    and prev_delta <= 0.0
                    and last_two_delta_diff <= DEFAULT_HYPOTHESIS_NEAR_DUP_DELTA
                ):
                    rec["near_duplicate_nonpositive"] = 1
        last_seen_step = _int_value(rec.get("last_seen_step", 0), default=0)
        if last_seen_step > 0 and latest_step > 0:
            rec["steps_since_last"] = max(0, latest_step - last_seen_step)
        rec.pop("last_seen_step", None)
        count = int(rec.get("recent_count", 0))
        if count > top_recent_count:
            top_recent_count = count
            top_recent_id = hypothesis_id

    repeat_streak = 0
    if recent_rows:
        latest_id = recent_rows[-1][1]
        for _entry, hypothesis_id in reversed(recent_rows):
            if hypothesis_id != latest_id:
                break
            repeat_streak += 1
        if latest_id in records:
            records[latest_id]["repeat_streak"] = repeat_streak

    return {
        "window": window_size,
        "total_recent": len(recent_rows),
        "unique_recent": len(records),
        "top_recent_id": top_recent_id,
        "top_recent_count": top_recent_count,
        "records": records,
    }


def format_hypothesis_shortlist(
    shortlist: Sequence[Dict[str, Any]],
    hypothesis_tracker: Optional[Dict[str, Any]],
    hypothesis_recent: Optional[Dict[str, Any]] = None,
) -> str:
    if not shortlist:
        return "- (none for this mechanism)"

    tracker = hypothesis_tracker if isinstance(hypothesis_tracker, dict) else {}
    records = tracker.get("records") if isinstance(tracker.get("records"), dict) else {}
    recent = hypothesis_recent if isinstance(hypothesis_recent, dict) else {}
    recent_records = recent.get("records") if isinstance(recent.get("records"), dict) else {}
    rows: List[str] = []
    for hypothesis in shortlist:
        hypothesis_id = str(hypothesis.get("id", "")).strip()
        statement = str(hypothesis.get("hypothesis", "")).strip()
        expected_signal = str(hypothesis.get("expected_signal", "")).strip()
        priority = _float_value(hypothesis.get("priority", 1.0), default=1.0)
        rec = records.get(hypothesis_id) if isinstance(records, dict) else {}
        rec_dict = rec if isinstance(rec, dict) else {}
        tries = _int_value(rec_dict.get("tries", 0), default=0)
        auth_tries = _int_value(rec_dict.get("tries_authoritative", 0), default=0)
        total_uplift = _float_value(rec_dict.get("total_uplift", 0.0), default=0.0)
        mean_uplift = total_uplift / auth_tries if auth_tries > 0 else 0.0
        best_delta = rec_dict.get("best_delta")
        if best_delta is None:
            best_delta_text = "n/a"
        else:
            best_delta_text = f"{_float_value(best_delta, default=0.0):+.4f}"
        recent_rec = recent_records.get(hypothesis_id) if isinstance(recent_records, dict) else {}
        recent_dict = recent_rec if isinstance(recent_rec, dict) else {}
        recent_count = _int_value(recent_dict.get("recent_count", 0), default=0)
        repeat_streak = _int_value(recent_dict.get("repeat_streak", 0), default=0)
        steps_since_last = _int_value(recent_dict.get("steps_since_last", DEFAULT_HYPOTHESIS_RECENT_WINDOW), default=DEFAULT_HYPOTHESIS_RECENT_WINDOW)
        soft_nochange = _int_value(recent_dict.get("soft_nochange", 0), default=0)
        near_dup_nonpos = _int_value(recent_dict.get("near_duplicate_nonpositive", 0), default=0)
        recent_mean_raw = recent_dict.get("recent_mean_delta")
        recent_mean_text = "n/a" if recent_mean_raw is None else f"{_float_value(recent_mean_raw, default=0.0):+.4f}"
        last_delta_raw = recent_dict.get("last_delta")
        last_delta_text = "n/a" if last_delta_raw is None else f"{_float_value(last_delta_raw, default=0.0):+.4f}"
        last_two_diff_raw = recent_dict.get("last_two_delta_diff")
        last_two_diff_text = "n/a" if last_two_diff_raw is None else f"{_float_value(last_two_diff_raw, default=0.0):.4f}"
        recent_mean_value = _float_value(recent_mean_raw, default=0.0) if recent_mean_raw is not None else None
        exploration_bonus = 0.0
        if tries <= 0:
            exploration_bonus = 0.08
        elif tries == 1:
            exploration_bonus = 0.05
        elif tries == 2:
            exploration_bonus = 0.02

        evidence_penalty = 0.0
        if recent_count >= 2 and recent_mean_value is not None and recent_mean_value <= 0.0:
            evidence_penalty += 0.10
        if recent_count > 0 and steps_since_last <= 2:
            evidence_penalty += 0.06
        if near_dup_nonpos > 0:
            evidence_penalty += 0.12
        if soft_nochange > 0:
            evidence_penalty += min(0.16, 0.04 * soft_nochange)

        eff_priority = max(0.0, min(1.0, priority + exploration_bonus - evidence_penalty))
        risk_flags: List[str] = []
        if recent_count >= 2 and recent_mean_value is not None and recent_mean_value <= 0.0:
            risk_flags.append("nonpos_recent")
        if recent_count > 0 and steps_since_last <= 2:
            risk_flags.append("recent_reuse")
        if near_dup_nonpos > 0:
            risk_flags.append("near_dup_nonpos")
        if soft_nochange > 0:
            risk_flags.append("soft_nochange")
        risk_text = "|".join(risk_flags) if risk_flags else "none"
        expected_fragment = f" expected_signal={expected_signal}" if expected_signal else ""
        rows.append(
            "- "
            f"id={hypothesis_id} "
            f"priority={priority:.3f} "
            f"eff_priority={eff_priority:.3f} "
            f"exploration_bonus={exploration_bonus:+.3f} "
            f"evidence_penalty={evidence_penalty:+.3f} "
            f"tries={tries} "
            f"mean_delta={mean_uplift:+.4f} "
            f"best_delta={best_delta_text} "
            f"recent_n={recent_count} "
            f"recent_mean_delta={recent_mean_text} "
            f"last_delta={last_delta_text} "
            f"last_two_delta_diff={last_two_diff_text} "
            f"steps_since_last={steps_since_last} "
            f"repeat_streak={repeat_streak} "
            f"soft_nochange={soft_nochange} "
            f"near_dup_nonpos={near_dup_nonpos} "
            f"risk_flags={risk_text} "
            f"hypothesis={statement}{expected_fragment}"
        )

    total = _int_value(tracker.get("total", 0), default=0)
    tested = _int_value(tracker.get("completed_count", 0), default=0)
    pending = max(0, total - tested)
    rows.append(f"- backlog_progress: tested={tested} pending={pending} total={total}")

    recent_total = _int_value(recent.get("total_recent", 0), default=0)
    if recent_total > 0:
        recent_window = _int_value(recent.get("window", DEFAULT_HYPOTHESIS_RECENT_WINDOW), default=DEFAULT_HYPOTHESIS_RECENT_WINDOW)
        unique_recent = _int_value(recent.get("unique_recent", 0), default=0)
        top_recent_id = str(recent.get("top_recent_id") or "").strip() or "n/a"
        top_recent_count = _int_value(recent.get("top_recent_count", 0), default=0)
        rows.append(
            f"- mechanism_recent_window: last={recent_total} window={recent_window} "
            f"unique_hypotheses={unique_recent} top_recent={top_recent_id}:{top_recent_count}"
        )
        concentration_threshold = max(3, int(math.ceil(recent_total * 0.4)))
        if top_recent_id != "n/a" and top_recent_count >= concentration_threshold:
            rows.append(
                f"- selection_warning: repeated focus on id={top_recent_id} ({top_recent_count}/{recent_total} recent picks); "
                "prefer a fresh hypothesis with higher eff_priority unless you can name a materially different lever."
            )

    rows.extend(PROMPT_COMMON_HYPOTHESIS_EXECUTION.splitlines())
    return "\n".join(rows)


def load_prompt_asset(path: Path, fallback: str) -> str:
    if path.exists():
        try:
            text = path.read_text().strip()
            if text:
                return text
        except OSError:
            pass
    return fallback


def render_template(template: str, values: Dict[str, str]) -> str:
    rendered = str(template)
    for key, value in values.items():
        rendered = rendered.replace(f"{{{{{key}}}}}", str(value))
    return rendered


def _truncate_text(value: str, limit: int) -> str:
    text = str(value or "").strip()
    if len(text) <= limit:
        return text
    if limit <= 3:
        return text[:limit]
    return text[: limit - 3] + "..."


def parse_tenets(tenets_path: Path) -> Dict[str, Any]:
    if not tenets_path.exists():
        return {
            "path": str(tenets_path),
            "raw_text": "",
            "tenets": [],
            "source": "missing",
        }

    raw_text = tenets_path.read_text()
    machine_tenets: List[Dict[str, Any]] = []

    fenced_match = re.search(r"```TENETS_JSON\s*(.*?)```", raw_text, re.DOTALL | re.IGNORECASE)
    if fenced_match:
        block = fenced_match.group(1).strip()
        try:
            parsed = json.loads(block)
        except json.JSONDecodeError:
            parsed = None
        if isinstance(parsed, dict):
            items = parsed.get("tenets")
            if isinstance(items, list):
                for idx, item in enumerate(items, start=1):
                    if isinstance(item, dict):
                        text = str(item.get("text", "")).strip()
                        if not text:
                            continue
                        identifier = str(item.get("id", f"T{idx}")).strip() or f"T{idx}"
                        machine_tenets.append(
                            {
                                "id": identifier,
                                "index": _int_value(item.get("index", idx), default=idx),
                                "text": text,
                            }
                        )
                    else:
                        text = str(item).strip()
                        if not text:
                            continue
                        machine_tenets.append({"id": f"T{idx}", "index": idx, "text": text})
        elif isinstance(parsed, list):
            for idx, item in enumerate(parsed, start=1):
                if isinstance(item, dict):
                    text = str(item.get("text", "")).strip()
                    if not text:
                        continue
                    identifier = str(item.get("id", f"T{idx}")).strip() or f"T{idx}"
                    machine_tenets.append(
                        {
                            "id": identifier,
                            "index": _int_value(item.get("index", idx), default=idx),
                            "text": text,
                        }
                    )
                else:
                    text = str(item).strip()
                    if not text:
                        continue
                    machine_tenets.append({"id": f"T{idx}", "index": idx, "text": text})

    parsed_tenets: List[Dict[str, Any]] = []
    if machine_tenets:
        parsed_tenets = sorted(machine_tenets, key=lambda item: _int_value(item.get("index", 0), default=0))
        source = "tenets_json"
    else:
        for line in raw_text.splitlines():
            match = re.match(r"^\s*(\d+)\.\s+(.+?)\s*$", line)
            if not match:
                continue
            index = _int_value(match.group(1), default=0)
            if index <= 0:
                continue
            text = match.group(2).strip()
            if not text:
                continue
            parsed_tenets.append({"id": f"T{index}", "index": index, "text": text})
        source = "numbered_markdown"

    return {
        "path": str(tenets_path),
        "raw_text": raw_text,
        "tenets": parsed_tenets,
        "source": source,
    }


def format_tenets_block(tenets_payload: Dict[str, Any]) -> str:
    tenets = tenets_payload.get("tenets")
    if not isinstance(tenets, list) or not tenets:
        return "- (no tenets loaded)"
    rows: List[str] = []
    for tenet in tenets:
        if not isinstance(tenet, dict):
            continue
        tenet_id = str(tenet.get("id", "")).strip() or f"T{_int_value(tenet.get('index', 0), default=0)}"
        text = str(tenet.get("text", "")).strip()
        if not text:
            continue
        rows.append(f"- {tenet_id}: {text}")
    return "\n".join(rows) if rows else "- (no tenets loaded)"


def sync_tenet_meta_state(
    tenet_meta: Dict[str, Any],
    tenets_payload: Dict[str, Any],
    iteration: int,
) -> Dict[str, Any]:
    current = tenet_meta if isinstance(tenet_meta, dict) else {}
    records = current.get("tenets")
    if not isinstance(records, dict):
        records = {}
    tenets = tenets_payload.get("tenets")
    if isinstance(tenets, list):
        for tenet in tenets:
            if not isinstance(tenet, dict):
                continue
            tenet_id = str(tenet.get("id", "")).strip()
            if not tenet_id:
                continue
            text = str(tenet.get("text", "")).strip()
            rec = records.get(tenet_id)
            if not isinstance(rec, dict):
                rec = {}
            rec.setdefault("support_count", 0)
            rec.setdefault("conflict_count", 0)
            rec.setdefault("neutral_count", 0)
            rec.setdefault("last_evidence_ids", [])
            rec.setdefault("last_updated_iter", int(iteration))
            rec["text"] = text
            records[tenet_id] = rec
    current["tenets"] = records
    current["updated_at"] = utc_now_iso()
    current["schema_version"] = 1
    return current


def _parse_evidence_iteration_ids(payload: Dict[str, Any]) -> List[int]:
    ids: List[int] = []
    values = payload.get("evidence_iteration_ids")
    if not isinstance(values, list):
        return ids
    for value in values:
        parsed = _int_value(value, default=-1)
        if parsed >= 0:
            ids.append(parsed)
    return ids


def _extract_tenet_ids(tenets_payload: Optional[Dict[str, Any]]) -> List[str]:
    if not isinstance(tenets_payload, dict):
        return []
    rows = tenets_payload.get("tenets")
    if not isinstance(rows, list):
        return []
    ordered: List[str] = []
    seen: Set[str] = set()
    for row in rows:
        if not isinstance(row, dict):
            continue
        tenet_id = str(row.get("id", "")).strip()
        if not tenet_id or tenet_id in seen:
            continue
        seen.add(tenet_id)
        ordered.append(tenet_id)
    return ordered


def _parse_tenet_tensions(payload: Dict[str, Any], limit: int = 6) -> List[str]:
    values = payload.get("tenet_tensions")
    if not isinstance(values, list):
        return []
    tensions: List[str] = []
    max_items = max(1, int(limit))
    for value in values:
        if isinstance(value, dict):
            text = str(value.get("note", "") or value.get("text", "")).strip()
        else:
            text = str(value).strip()
        if not text:
            continue
        tensions.append(_truncate_text(text, 220))
        if len(tensions) >= max_items:
            break
    return tensions


def _normalize_tenet_alignment(
    raw_rows: Any,
    expected_tenet_ids: Sequence[str],
) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    allowed = {"aligned", "neutral", "misaligned"}
    expected = [str(tenet_id).strip() for tenet_id in expected_tenet_ids if str(tenet_id).strip()]
    expected_set = set(expected)
    llm_rows = raw_rows if isinstance(raw_rows, list) else []

    parsed: List[Dict[str, Any]] = []
    seen_ids: Set[str] = set()
    unknown_ids: List[str] = []
    for row in llm_rows:
        if not isinstance(row, dict):
            continue
        tenet_id = str(row.get("tenet", "")).strip()
        if not tenet_id or tenet_id in seen_ids:
            continue
        alignment = str(row.get("alignment", "")).strip().lower()
        if alignment not in allowed:
            alignment = "neutral"
        note = _truncate_text(str(row.get("note", "")).strip(), 220)
        parsed.append({"tenet": tenet_id, "alignment": alignment, "note": note})
        seen_ids.add(tenet_id)
        if expected_set and tenet_id not in expected_set:
            unknown_ids.append(tenet_id)

    if not expected:
        return parsed, {
            "expected_count": 0,
            "covered_count": len(parsed),
            "missing_tenet_ids": [],
            "unknown_tenet_ids": unknown_ids,
        }

    by_id = {str(row.get("tenet", "")).strip(): row for row in parsed if isinstance(row, dict)}
    normalized: List[Dict[str, Any]] = []
    missing_ids: List[str] = []
    covered_count = 0
    for tenet_id in expected:
        row = by_id.get(tenet_id)
        if row is None:
            normalized.append(
                {
                    "tenet": tenet_id,
                    "alignment": "neutral",
                    "note": "llm_omitted_alignment",
                    "auto_filled": True,
                }
            )
            missing_ids.append(tenet_id)
            continue
        covered_count += 1
        normalized.append(row)

    return normalized, {
        "expected_count": len(expected),
        "covered_count": covered_count,
        "missing_tenet_ids": missing_ids,
        "unknown_tenet_ids": unknown_ids,
    }


def update_tenet_meta_from_selection(
    tenet_meta: Dict[str, Any],
    selection_payload: Dict[str, Any],
    iteration: int,
) -> None:
    records = tenet_meta.get("tenets")
    if not isinstance(records, dict):
        return
    alignments = selection_payload.get("tenet_alignment")
    evidence_ids = _parse_evidence_iteration_ids(selection_payload)
    if not isinstance(alignments, list):
        return
    for row in alignments:
        if not isinstance(row, dict):
            continue
        tenet_id = str(row.get("tenet", "")).strip()
        if not tenet_id:
            continue
        rec = records.get(tenet_id)
        if not isinstance(rec, dict):
            continue
        if bool(row.get("auto_filled", False)):
            rec["last_evidence_ids"] = evidence_ids[:12]
            rec["last_updated_iter"] = int(iteration)
            continue
        alignment = str(row.get("alignment", "")).strip().lower()
        if alignment == "aligned":
            rec["support_count"] = _int_value(rec.get("support_count", 0), default=0) + 1
        elif alignment == "misaligned":
            rec["conflict_count"] = _int_value(rec.get("conflict_count", 0), default=0) + 1
        elif alignment == "neutral":
            rec["neutral_count"] = _int_value(rec.get("neutral_count", 0), default=0) + 1
        rec["last_evidence_ids"] = evidence_ids[:12]
        rec["last_updated_iter"] = int(iteration)


def update_tenet_meta_from_proposal(
    tenet_meta: Dict[str, Any],
    proposal: Dict[str, Any],
    iteration: int,
    applied: bool,
) -> None:
    if not applied:
        return
    records = tenet_meta.get("tenets")
    if not isinstance(records, dict):
        return
    tenet_idx = _int_value(proposal.get("affected_tenet"), default=0)
    if tenet_idx <= 0:
        return
    tenet_id = f"T{tenet_idx}"
    rec = records.get(tenet_id)
    if not isinstance(rec, dict):
        rec = {
            "support_count": 0,
            "conflict_count": 0,
            "neutral_count": 0,
            "last_evidence_ids": [],
        }
    proposed_text = str(proposal.get("proposed_text", "")).strip()
    if proposed_text:
        rec["text"] = proposed_text
    rec["last_evidence_ids"] = _parse_evidence_iteration_ids(proposal)[:12]
    rec["last_updated_iter"] = int(iteration)
    records[tenet_id] = rec


def extract_recent_failures(
    log_entries: Sequence[Dict[str, Any]],
    limit: int = DEFAULT_SELECTION_RECENT_FAILURES,
) -> List[Dict[str, Any]]:
    failures: List[Dict[str, Any]] = []
    for entry in reversed(log_entries):
        if not isinstance(entry, dict):
            continue
        status = str(entry.get("status", "")).strip()
        delta = entry.get("delta")
        is_failure = status in {"invalid", "llm_failed", "compile_failed", "regression_rejected"}
        if not is_failure and delta is not None:
            is_failure = _float_value(delta, default=0.0) <= -0.05
        if not is_failure:
            continue
        hypothesis_id = _hypothesis_id_from_log_entry(entry)
        failures.append(
            {
                "iter": _int_value(entry.get("iter", 0), default=0),
                "status": status or "unknown",
                "mechanism": str(entry.get("mechanism", "")).strip(),
                "hypothesis_id": hypothesis_id or None,
                "edge": entry.get("edge"),
                "delta": entry.get("delta"),
                "reason": str(entry.get("reason", "")).strip() or None,
            }
        )
        if len(failures) >= max(1, int(limit)):
            break
    return list(reversed(failures))


def summarize_mechanism_concentration(
    log_entries: Sequence[Dict[str, Any]],
    window: int = 30,
) -> Dict[str, Any]:
    rows = [entry for entry in log_entries if isinstance(entry, dict)]
    recent = rows[-max(1, int(window)) :]
    counts: Dict[str, int] = {}
    for entry in recent:
        mechanism_name = str(entry.get("mechanism", "")).strip()
        if not mechanism_name:
            continue
        counts[mechanism_name] = counts.get(mechanism_name, 0) + 1
    sorted_counts = sorted(counts.items(), key=lambda item: item[1], reverse=True)
    top = [{"mechanism": key, "count": value} for key, value in sorted_counts[:5]]
    return {
        "window": len(recent),
        "top": top,
    }


def build_evidence_snapshot(
    stats: Dict[str, Any],
    log_entries: Sequence[Dict[str, Any]],
    mechanism_name: str,
    seed_offsets: Sequence[int],
    shortlist_size: int,
    tenet_meta: Optional[Dict[str, Any]] = None,
) -> str:
    champion = stats.get("champion") if isinstance(stats.get("champion"), dict) else {}
    champion_edge = _float_value(champion.get("edge", 0.0), default=0.0)
    champion_name = str(champion.get("name", "unknown_champion")).strip() or "unknown_champion"
    concentration = summarize_mechanism_concentration(log_entries)
    failures = extract_recent_failures(log_entries, limit=DEFAULT_SELECTION_RECENT_FAILURES)
    mechanisms = stats.get("mechanisms") if isinstance(stats.get("mechanisms"), dict) else {}
    mechanism_stats = mechanisms.get(mechanism_name) if isinstance(mechanisms, dict) else {}
    mechanism_stats = mechanism_stats if isinstance(mechanism_stats, dict) else {}

    offset_list = [int(offset) for offset in seed_offsets]
    max_seed_offset = max(offset_list) if offset_list else 0
    concentration_text = ", ".join(
        f"{row['mechanism']}:{row['count']}" for row in concentration.get("top", []) if isinstance(row, dict)
    ) or "n/a"
    rows: List[str] = [
        f"- champion: name={champion_name} robust_edge={champion_edge:.4f}",
        f"- active_seed_offsets: {','.join(str(value) for value in offset_list)} max_seed_offset={max_seed_offset}",
    ]
    if mechanism_name == "cross_mechanism":
        rows.append("- mechanism_summary (LLM selects mechanism + hypothesis):")
        all_mechs = stats.get("mechanisms", {})
        for mname in sorted(all_mechs.keys()):
            mstats = all_mechs.get(mname)
            if not isinstance(mstats, dict):
                continue
            m_tries = _int_value(mstats.get("tries_authoritative", mstats.get("tries", 0)), default=0)
            m_successes = _int_value(mstats.get("successes", 0), default=0)
            m_best = _float_value(mstats.get("best_delta", 0.0), default=0.0)
            m_last = str(mstats.get("last_tried", "never"))[:19]
            rows.append(
                f"    {mname}: tries={m_tries} successes={m_successes} "
                f"best_delta={m_best:+.4f} last_tried={m_last}"
            )
    else:
        rows.append(
            f"- mechanism_focus: target={mechanism_name} shortlist_size={int(shortlist_size)} "
            f"tries={_int_value(mechanism_stats.get('tries_authoritative', mechanism_stats.get('tries', 0)), default=0)} "
            f"best_delta={_float_value(mechanism_stats.get('best_delta', 0.0), default=0.0):+.4f}"
        )
    rows.append(
        f"- concentration_last_{_int_value(concentration.get('window', 0), default=0)}: {concentration_text}"
    )
    if failures:
        rows.append("- recent_failures:")
        for failure in failures:
            rows.append(
                f"  - iter={failure.get('iter')} mechanism={failure.get('mechanism')} "
                f"status={failure.get('status')} edge={failure.get('edge')} delta={failure.get('delta')} "
                f"reason={failure.get('reason') or 'n/a'}"
            )
    else:
        rows.append("- recent_failures: none")
    if tenet_meta and isinstance(tenet_meta.get("tenets"), dict):
        gap_rows: List[str] = []
        for tid, tdata in sorted(tenet_meta["tenets"].items(), key=lambda x: x[0]):
            if not isinstance(tdata, dict):
                continue
            support = int(tdata.get("support_count", 0) or 0)
            conflict = int(tdata.get("conflict_count", 0) or 0)
            neutral = int(tdata.get("neutral_count", 0) or 0)
            total = support + conflict + neutral
            if total > 0 and support == 0:
                label = "NEVER_TESTED"
            elif support <= 5 and neutral >= support * 3:
                label = "under_explored"
            elif conflict >= 2:
                label = "active_tension"
            else:
                continue
            text_snip = str(tdata.get("text", ""))[:80]
            gap_rows.append(
                f"  - {tid}: support={support} conflict={conflict} neutral={neutral} "
                f"({label}) \"{text_snip}\""
            )
        if gap_rows:
            rows.append("- tenet_coverage_gaps:")
            rows.extend(gap_rows)
    return "\n".join(rows)


def score_hypothesis_candidate(
    hypothesis: Dict[str, Any],
    hypothesis_tracker: Optional[Dict[str, Any]],
    hypothesis_recent: Optional[Dict[str, Any]],
) -> Dict[str, Any]:
    tracker = hypothesis_tracker if isinstance(hypothesis_tracker, dict) else {}
    tracker_records = tracker.get("records") if isinstance(tracker.get("records"), dict) else {}
    recent = hypothesis_recent if isinstance(hypothesis_recent, dict) else {}
    recent_records = recent.get("records") if isinstance(recent.get("records"), dict) else {}

    hypothesis_id = str(hypothesis.get("id", "")).strip()
    priority = _float_value(hypothesis.get("priority", 1.0), default=1.0)
    rec = tracker_records.get(hypothesis_id) if isinstance(tracker_records, dict) else {}
    rec_dict = rec if isinstance(rec, dict) else {}
    tries = _int_value(rec_dict.get("tries", 0), default=0)
    auth_tries = _int_value(rec_dict.get("tries_authoritative", 0), default=0)
    total_uplift = _float_value(rec_dict.get("total_uplift", 0.0), default=0.0)
    mean_delta = total_uplift / auth_tries if auth_tries > 0 else 0.0
    best_delta = rec_dict.get("best_delta")
    recent_rec = recent_records.get(hypothesis_id) if isinstance(recent_records, dict) else {}
    recent_dict = recent_rec if isinstance(recent_rec, dict) else {}
    recent_count = _int_value(recent_dict.get("recent_count", 0), default=0)
    recent_mean_raw = recent_dict.get("recent_mean_delta")
    recent_mean = _float_value(recent_mean_raw, default=0.0) if recent_mean_raw is not None else None
    repeat_streak = _int_value(recent_dict.get("repeat_streak", 0), default=0)
    steps_since_last = _int_value(
        recent_dict.get("steps_since_last", DEFAULT_HYPOTHESIS_RECENT_WINDOW),
        default=DEFAULT_HYPOTHESIS_RECENT_WINDOW,
    )
    soft_nochange = _int_value(recent_dict.get("soft_nochange", 0), default=0)
    near_dup_nonpos = _int_value(recent_dict.get("near_duplicate_nonpositive", 0), default=0)

    exploration_bonus = 0.0
    if tries <= 0:
        exploration_bonus = 0.08
    elif tries == 1:
        exploration_bonus = 0.05
    elif tries == 2:
        exploration_bonus = 0.02

    evidence_penalty = 0.0
    if recent_count >= 2 and recent_mean is not None and recent_mean <= 0.0:
        evidence_penalty += 0.10
    if recent_count > 0 and steps_since_last <= 2:
        evidence_penalty += 0.06
    if near_dup_nonpos > 0:
        evidence_penalty += 0.12
    if soft_nochange > 0:
        evidence_penalty += min(0.16, 0.04 * soft_nochange)

    eff_priority = max(0.0, min(1.0, priority + exploration_bonus - evidence_penalty))
    return {
        "id": hypothesis_id,
        "mechanism": str(hypothesis.get("mechanism", "")).strip(),
        "hypothesis": str(hypothesis.get("hypothesis", "")).strip(),
        "expected_signal": str(hypothesis.get("expected_signal", "")).strip(),
        "priority": priority,
        "eff_priority": eff_priority,
        "exploration_bonus": exploration_bonus,
        "evidence_penalty": evidence_penalty,
        "tries": tries,
        "mean_delta": mean_delta,
        "best_delta": _float_value(best_delta, default=0.0) if best_delta is not None else None,
        "recent_count": recent_count,
        "recent_mean_delta": recent_mean,
        "repeat_streak": repeat_streak,
        "steps_since_last": steps_since_last,
        "soft_nochange": soft_nochange,
        "near_dup_nonpos": near_dup_nonpos,
    }


def rank_hypothesis_candidates(
    shortlist: Sequence[Dict[str, Any]],
    hypothesis_tracker: Optional[Dict[str, Any]],
    hypothesis_recent: Optional[Dict[str, Any]],
    top_k: int = DEFAULT_SELECTION_TOP_K,
) -> List[Dict[str, Any]]:
    scored = [
        score_hypothesis_candidate(hypothesis, hypothesis_tracker, hypothesis_recent)
        for hypothesis in shortlist
        if isinstance(hypothesis, dict)
    ]
    scored.sort(
        key=lambda row: (
            _float_value(row.get("eff_priority", 0.0), default=0.0),
            _float_value(row.get("priority", 0.0), default=0.0),
            -_int_value(row.get("tries", 0), default=0),
        ),
        reverse=True,
    )
    return scored[: max(1, int(top_k))]


def format_selected_hypothesis_block(
    selected_hypothesis: Optional[Dict[str, Any]],
    selection_summary: Optional[Dict[str, Any]],
) -> str:
    if not isinstance(selected_hypothesis, dict):
        return "- none"
    hypothesis_id = str(selected_hypothesis.get("id", "")).strip()
    mechanism = str(selected_hypothesis.get("mechanism", "")).strip()
    statement = str(selected_hypothesis.get("hypothesis", "")).strip()
    summary = selection_summary if isinstance(selection_summary, dict) else {}
    reason = str(summary.get("reasoning", "")).strip()
    confidence = _safe_probability(summary.get("confidence"))
    conf_text = "n/a" if confidence is None else f"{confidence:.2f}"
    reason_text = _truncate_text(reason, 220) if reason else "n/a"
    return (
        f"- id={hypothesis_id} mechanism={mechanism} confidence={conf_text} "
        f"reason={reason_text} hypothesis={statement}"
    )


def run_llm_json_step(
    prompt_text: str,
    prompt_path: Path,
    artifact_prefix: Path,
    llm_command: str,
    llm_model: str,
    llm_timeout_minutes: float,
    llm_max_output_tokens: int,
    llm_disable_shell_tool: bool,
    schema_hint: str,
) -> Tuple[Optional[Dict[str, Any]], Optional[str], Dict[str, str]]:
    atomic_write_text(prompt_path, f"{prompt_text}\n")
    response_text, error, artifacts = run_llm_exec(
        prompt_path=prompt_path,
        artifact_prefix=artifact_prefix,
        llm_command=llm_command,
        llm_model=llm_model,
        llm_timeout_minutes=llm_timeout_minutes,
        llm_max_output_tokens=llm_max_output_tokens,
        llm_disable_shell_tool=llm_disable_shell_tool,
        attempt=0,
    )
    if response_text is None:
        return None, error or "llm_json_failed", artifacts
    payload = extract_json_payload_from_response(response_text)
    if payload is not None:
        return payload, None, artifacts

    repair_prompt = render_template(
        JSON_REPAIR_PROMPT_TEMPLATE,
        {
            "SCHEMA_HINT": schema_hint,
            "BROKEN_RESPONSE": _truncate_text(response_text, 3500),
        },
    )
    repair_prompt_path = prompt_path.with_name(f"{prompt_path.stem}_repair{prompt_path.suffix}")
    atomic_write_text(repair_prompt_path, f"{repair_prompt}\n")
    repair_response, repair_error, repair_artifacts = run_llm_exec(
        prompt_path=repair_prompt_path,
        artifact_prefix=artifact_prefix.with_name(f"{artifact_prefix.name}_repair"),
        llm_command=llm_command,
        llm_model=llm_model,
        llm_timeout_minutes=llm_timeout_minutes,
        llm_max_output_tokens=llm_max_output_tokens,
        llm_disable_shell_tool=llm_disable_shell_tool,
        attempt=1,
    )
    merged_artifacts = dict(artifacts)
    for key, value in repair_artifacts.items():
        merged_artifacts[f"repair_{key}"] = value
    if repair_response is None:
        return None, repair_error or "llm_json_repair_failed", merged_artifacts
    repair_payload = extract_json_payload_from_response(repair_response)
    if repair_payload is None:
        return None, "llm_json_parse_failed_after_repair", merged_artifacts
    return repair_payload, None, merged_artifacts


def select_hypothesis_with_llm(
    iteration: int,
    mechanism_name: str,
    shortlist: Sequence[Dict[str, Any]],
    hypothesis_tracker: Optional[Dict[str, Any]],
    hypothesis_recent: Optional[Dict[str, Any]],
    tenets_payload: Optional[Dict[str, Any]],
    tenets_block: str,
    evidence_snapshot: str,
    prompts_dir: Path,
    llm_command: str,
    llm_model: str,
    llm_timeout_minutes: float,
    llm_max_output_tokens: int,
    llm_disable_shell_tool: bool,
    candidate_dir: Path,
    enabled: bool,
    top_k: int,
) -> Tuple[Optional[Dict[str, Any]], Dict[str, Any], Dict[str, str]]:
    shortlist_rows = [hypothesis for hypothesis in shortlist if isinstance(hypothesis, dict)]
    if not shortlist_rows:
        return None, {"status": "no_candidates", "iteration": iteration}, {}

    ranked = rank_hypothesis_candidates(
        shortlist=shortlist_rows,
        hypothesis_tracker=hypothesis_tracker,
        hypothesis_recent=hypothesis_recent,
        top_k=top_k,
    )
    fallback_id = str(ranked[0].get("id", "")).strip() if ranked else ""
    hypothesis_map = {str(hypothesis.get("id", "")).strip(): hypothesis for hypothesis in shortlist_rows}
    fallback_hypothesis = hypothesis_map.get(fallback_id) if fallback_id else shortlist_rows[0]
    tenet_ids = _extract_tenet_ids(tenets_payload)
    summary: Dict[str, Any] = {
        "status": "fallback",
        "iteration": iteration,
        "mechanism": mechanism_name,
        "fallback_hypothesis_id": str(fallback_hypothesis.get("id", "")).strip(),
        "reason": "selection_disabled" if not enabled else "llm_not_run",
        "confidence": None,
        "tenet_tensions": [],
        "reasoning": None,
        "evidence_iteration_ids": [],
        "tenet_coverage": {
            "expected_count": len(tenet_ids),
            "covered_count": 0,
            "missing_tenet_ids": list(tenet_ids),
            "unknown_tenet_ids": [],
        },
    }
    if not enabled:
        return fallback_hypothesis, summary, {}

    candidates_payload = json.dumps(ranked, indent=2)
    template_path = prompts_dir / DEFAULT_PROMPT_TEMPLATE_TENET_SELECTION
    template_text = load_prompt_asset(template_path, TENET_GUIDED_SELECTION_PROMPT_FALLBACK)
    prompt_text = render_template(
        template_text,
        {
            "MECHANISM_NAME": mechanism_name,
            "TENETS_BLOCK": tenets_block,
            "EVIDENCE_SNAPSHOT": evidence_snapshot,
            "CANDIDATES_JSON": candidates_payload,
        },
    )
    prompt_path = candidate_dir / f"iter_{iteration}_{mechanism_name}_tenet_selection.prompt.md"
    artifact_prefix = candidate_dir / f"iter_{iteration}_{mechanism_name}_tenet_selection"
    payload, error, artifacts = run_llm_json_step(
        prompt_text=prompt_text,
        prompt_path=prompt_path,
        artifact_prefix=artifact_prefix,
        llm_command=llm_command,
        llm_model=llm_model,
        llm_timeout_minutes=llm_timeout_minutes,
        llm_max_output_tokens=llm_max_output_tokens,
        llm_disable_shell_tool=llm_disable_shell_tool,
        schema_hint='{"selected_hypothesis_id":"id","confidence":0.0,"tenet_alignment":[],"tenet_tensions":["text"],"reasoning":"text","evidence_iteration_ids":[1]}',
    )
    if payload is None:
        summary["reason"] = error or "selection_llm_failed"
        return fallback_hypothesis, summary, artifacts

    selected_id = str(payload.get("selected_hypothesis_id", "")).strip()
    selected_hypothesis = hypothesis_map.get(selected_id)
    if selected_hypothesis is None:
        summary["reason"] = "selection_id_not_in_candidates"
        summary["llm_selected_hypothesis_id"] = selected_id or None
        return fallback_hypothesis, summary, artifacts

    normalized_alignment, alignment_coverage = _normalize_tenet_alignment(
        payload.get("tenet_alignment"),
        tenet_ids,
    )
    summary = {
        "status": "selected",
        "iteration": iteration,
        "mechanism": mechanism_name,
        "selected_hypothesis_id": selected_id,
        "confidence": _safe_probability(payload.get("confidence")),
        "tenet_alignment": normalized_alignment,
        "tenet_tensions": _parse_tenet_tensions(payload),
        "reasoning": str(payload.get("reasoning", "")).strip(),
        "evidence_iteration_ids": _parse_evidence_iteration_ids(payload),
        "tenet_coverage": alignment_coverage,
        "fallback_hypothesis_id": str(fallback_hypothesis.get("id", "")).strip(),
    }
    return selected_hypothesis, summary, artifacts


def apply_tenet_proposal(
    tenets_path: Path,
    proposal: Dict[str, Any],
    iteration: int,
) -> Tuple[bool, str]:
    if not tenets_path.exists():
        return False, "tenets_file_missing"
    proposal_type = str(proposal.get("proposal_type", "")).strip().upper()
    if proposal_type not in {"ADD", "MODIFY", "DELETE"}:
        return False, "proposal_not_applicable"
    affected_tenet = _int_value(proposal.get("affected_tenet"), default=0)
    proposed_text = str(proposal.get("proposed_text", "")).strip()

    lines = tenets_path.read_text().splitlines()
    number_pattern = re.compile(r"^\s*(\d+)\.\s+(.+?)\s*$")
    numbered_indices: Dict[int, int] = {}
    for idx, line in enumerate(lines):
        match = number_pattern.match(line)
        if not match:
            continue
        tenet_idx = _int_value(match.group(1), default=0)
        if tenet_idx > 0 and tenet_idx not in numbered_indices:
            numbered_indices[tenet_idx] = idx

    if proposal_type == "MODIFY":
        if affected_tenet <= 0 or affected_tenet not in numbered_indices or not proposed_text:
            return False, "invalid_modify_target"
        lines[numbered_indices[affected_tenet]] = f"{affected_tenet}. {proposed_text}"
    elif proposal_type == "DELETE":
        if affected_tenet <= 0 or affected_tenet not in numbered_indices:
            return False, "invalid_delete_target"
        delete_idx = numbered_indices[affected_tenet]
        lines.pop(delete_idx)
    elif proposal_type == "ADD":
        if not proposed_text:
            return False, "invalid_add_text"
        next_idx = max(numbered_indices.keys(), default=0) + 1
        insert_after = max(numbered_indices.values(), default=-1)
        insert_at = insert_after + 1
        lines.insert(insert_at, f"{next_idx}. {proposed_text}")
        affected_tenet = next_idx

    if not any(line.strip() == "## Change Log" for line in lines):
        lines.extend(["", "## Change Log", ""])
    else:
        lines.append("")
    change_title = f"### Iteration {iteration} - Tenet {affected_tenet} {proposal_type.title()}"
    evidence = ", ".join(str(value) for value in _parse_evidence_iteration_ids(proposal)) or "n/a"
    expected_impact = str(proposal.get("expected_impact", "")).strip() or "n/a"
    lines.extend(
        [
            change_title,
            f"**Evidence**: {evidence}",
            f"**Change**: {proposal_type}",
            f"**Expected Impact**: {expected_impact}",
            "",
        ]
    )
    atomic_write_text(tenets_path, "\n".join(lines).rstrip() + "\n")
    return True, "applied"


def run_tenet_evolution(
    iteration: int,
    enabled: bool,
    frequency: int,
    tenets_payload: Dict[str, Any],
    evidence_snapshot: str,
    log_entries: Sequence[Dict[str, Any]],
    prompts_dir: Path,
    llm_command: str,
    llm_model: str,
    llm_timeout_minutes: float,
    llm_max_output_tokens: int,
    llm_disable_shell_tool: bool,
    prompt_dir: Path,
    tenets_path: Path,
    auto_apply: bool,
    force_once: bool = False,
) -> Tuple[Optional[Dict[str, Any]], Dict[str, str]]:
    if not enabled:
        return None, {}
    if not force_once and (frequency <= 0 or iteration % frequency != 0):
        return None, {}

    window_size = max(1, int(frequency)) if frequency > 0 else DEFAULT_TENET_EVOLUTION_FREQUENCY
    window_rows = list(log_entries)[-window_size:]
    compact_window: List[Dict[str, Any]] = []
    for entry in window_rows:
        if not isinstance(entry, dict):
            continue
        compact_window.append(
            {
                "iter": _int_value(entry.get("iter", 0), default=0),
                "status": str(entry.get("status", "")).strip(),
                "mechanism": str(entry.get("mechanism", "")).strip(),
                "delta": entry.get("delta"),
                "edge": entry.get("edge"),
                "hypothesis_id": _hypothesis_id_from_log_entry(entry) or None,
            }
        )

    template_path = prompts_dir / DEFAULT_PROMPT_TEMPLATE_TENET_EVOLUTION
    template_text = load_prompt_asset(template_path, TENET_EVOLUTION_PROMPT_FALLBACK)
    prompt_text = render_template(
        template_text,
        {
            "TENETS_BLOCK": format_tenets_block(tenets_payload),
            "EVIDENCE_SNAPSHOT": evidence_snapshot,
            "WINDOW_RESULTS_JSON": json.dumps(compact_window, indent=2),
        },
    )
    prompt_path = prompt_dir / f"iter_{iteration}_tenet_evolution.prompt.md"
    artifact_prefix = prompt_dir / f"iter_{iteration}_tenet_evolution"
    payload, error, artifacts = run_llm_json_step(
        prompt_text=prompt_text,
        prompt_path=prompt_path,
        artifact_prefix=artifact_prefix,
        llm_command=llm_command,
        llm_model=llm_model,
        llm_timeout_minutes=llm_timeout_minutes,
        llm_max_output_tokens=llm_max_output_tokens,
        llm_disable_shell_tool=llm_disable_shell_tool,
        schema_hint='{"proposal_type":"NO_CHANGE","affected_tenet":0,"proposed_text":"","reasoning":"","expected_impact":"","evidence_iteration_ids":[1]}',
    )
    if payload is None:
        return {
            "status": "failed",
            "iteration": iteration,
            "reason": error or "tenet_evolution_failed",
            "auto_apply": bool(auto_apply),
        }, artifacts

    proposal_type = str(payload.get("proposal_type", "")).strip().upper()
    proposal = {
        "status": "proposed",
        "iteration": iteration,
        "proposal_type": proposal_type or "NO_CHANGE",
        "affected_tenet": _int_value(payload.get("affected_tenet"), default=0),
        "current_text": str(payload.get("current_text", "")).strip() or None,
        "proposed_text": str(payload.get("proposed_text", "")).strip() or None,
        "reasoning": str(payload.get("reasoning", "")).strip() or None,
        "expected_impact": str(payload.get("expected_impact", "")).strip() or None,
        "evidence_iteration_ids": _parse_evidence_iteration_ids(payload),
        "auto_apply": bool(auto_apply),
        "applied": False,
        "apply_result": None,
    }
    if auto_apply and proposal_type in {"ADD", "MODIFY", "DELETE"}:
        applied, apply_result = apply_tenet_proposal(tenets_path, payload, iteration)
        proposal["applied"] = bool(applied)
        proposal["apply_result"] = apply_result
    return proposal, artifacts


def parse_hypothesis_items(payload: Any) -> List[Dict[str, Any]]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        for key in ("hypotheses", "items", "backlog"):
            value = payload.get(key)
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict)]
    return []


def normalize_hypothesis_item(
    hypothesis: Dict[str, Any],
    fallback_idx: int,
    mechanisms: Dict[str, Any],
) -> Optional[Dict[str, Any]]:
    mechanism = str(hypothesis.get("mechanism", "")).strip()
    if mechanism not in mechanisms:
        return None

    hypothesis_id = str(hypothesis.get("id", "")).strip()
    if not hypothesis_id:
        hypothesis_id = f"HYP_{mechanism}_{fallback_idx}"

    statement = str(hypothesis.get("hypothesis", "")).strip()
    expected_signal = str(hypothesis.get("expected_signal", "")).strip()
    if not statement:
        return None

    try:
        priority = float(hypothesis.get("priority", 1.0))
    except (TypeError, ValueError):
        priority = 1.0
    if priority <= 0.0:
        priority = 0.1

    normalized = {
        "id": hypothesis_id,
        "mechanism": mechanism,
        "hypothesis": statement,
        "expected_signal": expected_signal,
        "priority": priority,
    }
    tags = hypothesis.get("tags")
    if isinstance(tags, list):
        cleaned_tags = [str(tag).strip() for tag in tags if str(tag).strip()]
        if cleaned_tags:
            normalized["tags"] = cleaned_tags
    return normalized


def load_hypothesis_catalog(
    definitions: Dict[str, Any],
    hypotheses_path: Path,
    mechanisms: Dict[str, Any],
) -> List[Dict[str, Any]]:
    combined: List[Dict[str, Any]] = []
    combined.extend(parse_hypothesis_items(definitions.get("hypotheses")))

    if hypotheses_path.exists():
        file_payload = load_json(hypotheses_path, {})
        combined.extend(parse_hypothesis_items(file_payload))

    normalized: List[Dict[str, Any]] = []
    seen_ids: set[str] = set()
    for idx, item in enumerate(combined, start=1):
        hypothesis = normalize_hypothesis_item(item, idx, mechanisms)
        if hypothesis is None:
            continue
        hypothesis_id = str(hypothesis["id"])
        if hypothesis_id in seen_ids:
            hypothesis["id"] = f"{hypothesis_id}_{idx}"
            hypothesis_id = str(hypothesis["id"])
        seen_ids.add(hypothesis_id)
        normalized.append(hypothesis)
    return normalized


def default_hypothesis_stats() -> Dict[str, Any]:
    return {
        "tries": 0,
        "tries_authoritative": 0,
        "successes": 0,
        "total_uplift": 0.0,
        "best_delta": None,
        "last_tried": None,
    }


def sync_stats_hypotheses(stats: Dict[str, Any], hypotheses: Sequence[Dict[str, Any]]) -> bool:
    changed = False
    bucket = stats.get("hypotheses")
    if not isinstance(bucket, dict):
        bucket = {}
        stats["hypotheses"] = bucket
        changed = True

    records = bucket.get("records")
    if not isinstance(records, dict):
        records = {}
        bucket["records"] = records
        changed = True

    active_ids = {str(hypothesis.get("id", "")) for hypothesis in hypotheses if str(hypothesis.get("id", ""))}
    for hypothesis_id in active_ids:
        rec = records.get(hypothesis_id)
        if not isinstance(rec, dict):
            records[hypothesis_id] = default_hypothesis_stats()
            changed = True
            continue
        # Backfill missing keys for older records.
        defaults = default_hypothesis_stats()
        for key, value in defaults.items():
            if key not in rec:
                rec[key] = value
                changed = True
        tries_authoritative = _int_value(rec.get("tries_authoritative", rec.get("tries", 0)), default=0)
        if _int_value(rec.get("tries", 0), default=0) != tries_authoritative:
            rec["tries"] = tries_authoritative
            changed = True

    for stale_id in list(records.keys()):
        if stale_id not in active_ids:
            records.pop(stale_id, None)
            changed = True

    completed = sum(1 for rec in records.values() if _int_value(rec.get("tries", 0), default=0) > 0)
    if _int_value(bucket.get("completed_count", 0), default=0) != completed:
        bucket["completed_count"] = completed
        changed = True
    if _int_value(bucket.get("total", 0), default=0) != len(active_ids):
        bucket["total"] = len(active_ids)
        changed = True
    if "last_selected_id" not in bucket:
        bucket["last_selected_id"] = None
        changed = True

    return changed


def hypothesis_log_payload(hypothesis_focus: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    if not isinstance(hypothesis_focus, dict):
        return None
    payload = {
        "id": str(hypothesis_focus.get("id", "")).strip(),
        "mechanism": str(hypothesis_focus.get("mechanism", "")).strip(),
        "hypothesis": str(hypothesis_focus.get("hypothesis", "")).strip(),
        "expected_signal": str(hypothesis_focus.get("expected_signal", "")).strip(),
    }
    if not payload["id"] or not payload["mechanism"] or not payload["hypothesis"]:
        return None
    return payload


def resolve_selected_hypothesis(
    iteration_policy_metadata: Optional[Dict[str, Any]],
    shortlist: Sequence[Dict[str, Any]],
) -> Optional[Dict[str, Any]]:
    if not isinstance(iteration_policy_metadata, dict):
        return None
    selected_id = str(iteration_policy_metadata.get("hypothesis_id", "")).strip()
    if not selected_id:
        return None
    for hypothesis in shortlist:
        if str(hypothesis.get("id", "")).strip() == selected_id:
            return hypothesis
    return None


def update_hypothesis_stats(
    stats: Dict[str, Any],
    hypothesis_focus: Optional[Dict[str, Any]],
    delta: float,
    authoritative_eval: bool,
    improvement_threshold: float,
) -> None:
    payload = hypothesis_log_payload(hypothesis_focus)
    if payload is None:
        return

    bucket = stats.get("hypotheses")
    if not isinstance(bucket, dict):
        return
    records = bucket.get("records")
    if not isinstance(records, dict):
        return
    hypothesis_id = str(payload["id"])
    rec = records.get(hypothesis_id)
    if not isinstance(rec, dict):
        rec = default_hypothesis_stats()
        records[hypothesis_id] = rec

    rec["tries"] = _int_value(rec.get("tries", 0), default=0) + 1
    if authoritative_eval:
        rec["tries_authoritative"] = _int_value(rec.get("tries_authoritative", 0), default=0) + 1
        rec["total_uplift"] = _float_value(rec.get("total_uplift", 0.0), default=0.0) + float(delta)
        if float(delta) > float(improvement_threshold):
            rec["successes"] = _int_value(rec.get("successes", 0), default=0) + 1
        best_delta = rec.get("best_delta")
        if best_delta is None or float(delta) > _float_value(best_delta):
            rec["best_delta"] = float(delta)
    rec["last_tried"] = utc_now_iso()
    bucket["last_selected_id"] = hypothesis_id
    bucket["completed_count"] = sum(
        1 for record in records.values() if _int_value((record or {}).get("tries", 0), default=0) > 0
    )


def _json_out(payload: Dict[str, Any]) -> str:
    return json.dumps(payload, indent=2)


def _int_value(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _float_value(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _get_nested(mapping: Dict[str, Any], keys: Sequence[str], default: Any) -> Any:
    current: Any = mapping
    for key in keys:
        if not isinstance(current, dict):
            return default
        if key not in current:
            return default
        current = current[key]
    return current


def _get_int(mapping: Dict[str, Any], *keys: str, default: int = 0) -> int:
    return _int_value(_get_nested(mapping, keys, default), default=default)


def _get_float(mapping: Dict[str, Any], *keys: str, default: float = 0.0) -> float:
    return _float_value(_get_nested(mapping, keys, default), default=default)


def _increment_mechanism_counter(
    stats: Dict[str, Any],
    mechanism_name: str,
    key: str,
    amount: int = 1,
) -> None:
    mechanisms = stats.get("mechanisms")
    if not isinstance(mechanisms, dict):
        return
    rec = mechanisms.get(mechanism_name)
    if not isinstance(rec, dict):
        return
    rec[key] = _int_value(rec.get(key, 0), default=0) + amount


def _iteration_policy_config(mechanism_policy: Any) -> Tuple[int, float]:
    policy_cfg = mechanism_policy.get("iteration_policy", {}) if isinstance(mechanism_policy, dict) else {}
    cooldown_span = DEFAULT_ITERATION_POLICY_COOLDOWN_SPAN
    min_confidence = DEFAULT_ITERATION_POLICY_MIN_CONFIDENCE
    if isinstance(policy_cfg, dict):
        try:
            cooldown_span = int(policy_cfg.get("cooldown_span", cooldown_span))
        except (TypeError, ValueError):
            cooldown_span = DEFAULT_ITERATION_POLICY_COOLDOWN_SPAN
        parsed_confidence = _safe_probability(policy_cfg.get("min_confidence"))
        if parsed_confidence is not None:
            min_confidence = parsed_confidence
    return cooldown_span, min_confidence


def _apply_iteration_policy(
    mechanism_stats: Dict[str, Any],
    mechanism_policy: Any,
    policy_metadata: Optional[Dict[str, Any]],
    iteration: int,
) -> None:
    cooldown_span, min_confidence = _iteration_policy_config(mechanism_policy)
    apply_iteration_policy_decision(
        mechanism_stats=mechanism_stats,
        policy_metadata=policy_metadata,
        iteration=iteration,
        cooldown_span=cooldown_span,
        min_confidence=min_confidence,
    )


def select_mechanism(
    mechanisms: Dict[str, Dict[str, Any]],
    exploration_c: float,
    rng: random.Random,
    current_iteration: Optional[int] = None,
) -> str:
    eligible_names = list(mechanisms.keys())
    if current_iteration is not None:
        cooled = [
            name
            for name, rec in mechanisms.items()
            if int(rec.get("cooldown_until_iter", 0) or 0) >= int(current_iteration)
        ]
        active = [name for name in eligible_names if name not in cooled]
        if active:
            eligible_names = active

    eligible_records = {name: mechanisms[name] for name in eligible_names}
    return select_with_ucb(
        records=eligible_records,
        exploration_c=exploration_c,
        rng=rng,
        tries_getter=authoritative_tries,
    )


def should_run_wildcard(iteration: int, stats: Dict[str, Any], wildcard_frequency: int) -> bool:
    if wildcard_frequency > 0 and iteration % wildcard_frequency == 0:
        return True
    mechanisms = stats.get("mechanisms", {})
    if not mechanisms:
        return False
    all_tried = all(authoritative_tries(v) >= 3 for v in mechanisms.values())
    none_successful = all(int(v.get("successes", 0) or 0) == 0 for v in mechanisms.values())
    return bool(all_tried and none_successful)


def build_prompt(
    champion_code: str,
    mechanism_name: str,
    mechanism_info: Dict[str, Any],
    other_mechanisms: Sequence[str],
    variant_name: str,
    hypothesis_shortlist: Sequence[Dict[str, Any]] = (),
    hypothesis_tracker: Optional[Dict[str, Any]] = None,
    hypothesis_recent: Optional[Dict[str, Any]] = None,
    selected_hypothesis_block: str = "- none",
    tenets_block: str = "- (no tenets loaded)",
    evidence_snapshot_block: str = "- (no evidence snapshot)",
    generation_requirements_block: str = HYPOTHESIS_GENERATION_TEMPLATE_FALLBACK,
) -> str:
    return PROMPT_TEMPLATE.format(
        champion_code=champion_code,
        mechanism_name=mechanism_name,
        current_implementation=str(mechanism_info.get("current_implementation", "")),
        code_location=str(mechanism_info.get("code_location", "")),
        parameters_formatted=format_parameters(dict(mechanism_info.get("parameters", {}))),
        modification_directions=format_directions(list(mechanism_info.get("modification_directions", []))),
        hypothesis_shortlist=format_hypothesis_shortlist(
            hypothesis_shortlist,
            hypothesis_tracker,
            hypothesis_recent=hypothesis_recent,
        ),
        selected_hypothesis_block=selected_hypothesis_block,
        tenets_block=tenets_block,
        evidence_snapshot_block=evidence_snapshot_block,
        generation_requirements_block=generation_requirements_block,
        priors_block=PROMPT_COMMON_PRIORS,
        dont_pursue_block=PROMPT_COMMON_DONT_PURSUE,
        iteration_governor_block=ITERATION_GOVERNOR_BLOCK,
        iteration_policy_hints=format_iteration_policy_hints(mechanism_info),
        iteration_policy_metadata_block=ITERATION_POLICY_METADATA_BLOCK,
        other_mechanisms=", ".join(other_mechanisms),
        common_contract_constraints=PROMPT_COMMON_CONTRACT_CONSTRAINTS.format(variant_name=variant_name),
        output_format_block=PROMPT_COMMON_OUTPUT_FORMAT,
        variant_name=variant_name,
    )


def build_wildcard_prompt(
    champion_code: str,
    variant_name: str,
    tenets_block: str = "- (no tenets loaded)",
    evidence_snapshot_block: str = "- (no evidence snapshot)",
    generation_requirements_block: str = HYPOTHESIS_GENERATION_TEMPLATE_FALLBACK,
) -> str:
    return WILDCARD_PROMPT_TEMPLATE.format(
        champion_code=champion_code,
        tenets_block=tenets_block,
        evidence_snapshot_block=evidence_snapshot_block,
        generation_requirements_block=generation_requirements_block,
        dont_pursue_block=PROMPT_COMMON_DONT_PURSUE,
        iteration_governor_block=ITERATION_GOVERNOR_BLOCK,
        iteration_policy_metadata_block=ITERATION_POLICY_METADATA_BLOCK,
        output_format_block=PROMPT_COMMON_OUTPUT_FORMAT,
        variant_name=variant_name,
    )


def generate_mock_candidate(
    champion_code: str,
    mechanism_name: str,
    mechanism_info: Dict[str, Any],
    iteration: int,
) -> str:
    spans = resolve_mechanism_spans(champion_code, mechanism_info)
    if not spans:
        return champion_code + f"\n// mock mutation iter={iteration} mechanism={mechanism_name}\n"

    first_line = spans[0][0]
    lines = champion_code.splitlines()
    idx = max(0, min(len(lines), first_line - 1))
    marker = f"// mock mutation iter={iteration} mechanism={mechanism_name}"
    if lines:
        lines[idx] = f"{lines[idx]} {marker}".rstrip()
    else:
        lines = [marker]
    mutated = "\n".join(lines) + "\n"
    mutated = re.sub(
        r'return\s+"([^"]+)";',
        f'return "{mechanism_name}_mod_v{iteration}";',
        mutated,
        count=1,
    )
    return mutated


def extract_solidity_from_response(response_text: str) -> Optional[str]:
    text = response_text.strip()
    if not text:
        return None

    revised = re.search(
        r"---REVISED_IMPLEMENTATION---\s*```(?:solidity|sol)?\s*(.*?)\s*```",
        text,
        re.DOTALL | re.IGNORECASE,
    )
    if revised:
        payload = revised.group(1).strip()
        if payload:
            return payload + "\n"

    fenced_blocks = re.findall(
        r"```(?:solidity|sol)?\s*(.*?)\s*```",
        text,
        re.DOTALL | re.IGNORECASE,
    )
    if fenced_blocks:
        def score(block: str) -> Tuple[int, int]:
            points = 0
            if "contract Strategy" in block:
                points += 4
            if "pragma solidity" in block:
                points += 2
            if "afterSwap" in block:
                points += 1
            return points, len(block)

        candidate = max(fenced_blocks, key=score).strip()
        if candidate:
            return candidate + "\n"

    pragma_idx = text.find("pragma solidity")
    contract_idx = text.find("contract Strategy")
    if pragma_idx >= 0:
        candidate = text[pragma_idx:].strip()
        return candidate + "\n" if candidate else None
    if contract_idx >= 0:
        candidate = text[contract_idx:].strip()
        return candidate + "\n" if candidate else None
    return None


def generate_candidate_with_llm(
    prompt_path: Path,
    artifact_prefix: Path,
    llm_command: str,
    llm_model: str,
    llm_timeout_minutes: float,
    llm_max_output_tokens: int,
    llm_disable_shell_tool: bool,
    attempt: int = 0,
) -> Tuple[Optional[str], Optional[str], Dict[str, str]]:
    response_text, error, artifacts = run_llm_exec(
        prompt_path=prompt_path,
        artifact_prefix=artifact_prefix,
        llm_command=llm_command,
        llm_model=llm_model,
        llm_timeout_minutes=llm_timeout_minutes,
        llm_max_output_tokens=llm_max_output_tokens,
        llm_disable_shell_tool=llm_disable_shell_tool,
        attempt=attempt,
    )
    if response_text is None:
        return None, error or "llm_failed", artifacts
    candidate = extract_solidity_from_response(response_text)
    if not candidate:
        return None, "llm_extract_failed", artifacts
    return candidate, None, artifacts


def extract_json_payload_from_response(response_text: str) -> Optional[Dict[str, Any]]:
    text = response_text.strip()
    if not text:
        return None

    fenced_blocks = re.findall(r"```(?:json)?\s*(.*?)\s*```", text, re.DOTALL | re.IGNORECASE)
    candidates = fenced_blocks + [text]
    for block in candidates:
        snippet = block.strip()
        if not snippet:
            continue
        try:
            payload = json.loads(snippet)
            if isinstance(payload, dict):
                return payload
        except json.JSONDecodeError:
            start = snippet.find("{")
            end = snippet.rfind("}")
            if start >= 0 and end > start:
                fragment = snippet[start : end + 1]
                try:
                    payload = json.loads(fragment)
                    if isinstance(payload, dict):
                        return payload
                except json.JSONDecodeError:
                    continue
    return None


def run_llm_exec(
    prompt_path: Path,
    artifact_prefix: Path,
    llm_command: str,
    llm_model: str,
    llm_timeout_minutes: float,
    llm_max_output_tokens: int,
    llm_disable_shell_tool: bool,
    attempt: int = 0,
) -> Tuple[Optional[str], Optional[str], Dict[str, str]]:
    suffix = "" if attempt <= 0 else f"_retry{attempt}"
    stem = artifact_prefix.name
    codex_jsonl_path = artifact_prefix.with_name(f"{stem}{suffix}.codex.jsonl")
    codex_stderr_path = artifact_prefix.with_name(f"{stem}{suffix}.codex.stderr")
    codex_last_msg_path = artifact_prefix.with_name(f"{stem}{suffix}.codex.last_message.md")
    artifacts = {
        "codex_jsonl_path": str(codex_jsonl_path),
        "codex_stderr_path": str(codex_stderr_path),
        "codex_last_message_path": str(codex_last_msg_path),
    }

    parts = shlex.split(llm_command)
    if not parts:
        return None, "llm_command_empty", artifacts
    executable = parts[0]
    if shutil.which(executable) is None and not Path(executable).exists():
        return None, f"llm_command_not_found:{executable}", artifacts

    cmd = [
        *parts,
        "exec",
        "--json",
        "--config",
        f"max_output_tokens={int(llm_max_output_tokens)}",
        "--output-last-message",
        str(codex_last_msg_path),
    ]
    if llm_disable_shell_tool:
        cmd += ["--disable", "shell_tool"]
    if llm_model:
        cmd += ["--model", llm_model]
    cmd.append("-")

    timeout_seconds = max(60, int(float(llm_timeout_minutes) * 60))
    prompt_text = prompt_path.read_text()
    codex_jsonl_path.parent.mkdir(parents=True, exist_ok=True)
    if codex_last_msg_path.exists():
        codex_last_msg_path.unlink()

    try:
        with codex_jsonl_path.open("w") as stdout_handle, codex_stderr_path.open("w") as stderr_handle:
            proc = subprocess.run(
                cmd,
                input=prompt_text,
                stdout=stdout_handle,
                stderr=stderr_handle,
                text=True,
                timeout=timeout_seconds,
                check=False,
            )
    except subprocess.TimeoutExpired:
        # Attempt recovery from last_message.md if it exists with valid content
        if codex_last_msg_path.exists():
            try:
                response_text = codex_last_msg_path.read_text()
                if response_text.strip():
                    artifacts["timeout_recovered"] = "true"
                    return response_text, None, artifacts
            except OSError:
                pass
        return None, f"llm_timeout_after_minutes={llm_timeout_minutes}", artifacts
    except OSError as exc:
        return None, f"llm_exec_oserror:{exc}", artifacts

    if proc.returncode != 0:
        stderr_tail = ""
        if codex_stderr_path.exists():
            lines = codex_stderr_path.read_text(errors="ignore").strip().splitlines()
            if lines:
                stderr_tail = lines[-1][:400]
        reason = f"llm_exit_code={proc.returncode}"
        if stderr_tail:
            reason = f"{reason}:{stderr_tail}"
        return None, reason, artifacts

    if not codex_last_msg_path.exists():
        return None, "llm_missing_last_message", artifacts
    response_text = codex_last_msg_path.read_text()
    return response_text, None, artifacts


def default_mechanism_stats() -> Dict[str, Any]:
    return {
        "tries": 0,
        "tries_authoritative": 0,
        "successes": 0,
        "total_uplift": 0.0,
        "invalid_count": 0,
        "compile_fail_count": 0,
        "last_tried": None,
        "best_delta": None,
        "cooldown_until_iter": 0,
        "last_policy_decision": None,
        "last_policy_confidence": None,
        "last_policy_ceiling_probability": None,
        "last_policy_reason": None,
        "last_policy_next_mechanism": None,
    }


def sync_stats_mechanisms(stats: Dict[str, Any], definitions: Dict[str, Any]) -> bool:
    changed = False
    stats_mechanisms = stats.setdefault("mechanisms", {})
    if not isinstance(stats_mechanisms, dict):
        stats["mechanisms"] = {}
        stats_mechanisms = stats["mechanisms"]
        changed = True

    definition_mechanisms = definitions.get("mechanisms", {})
    if not isinstance(definition_mechanisms, dict):
        return changed

    for mechanism_name in definition_mechanisms.keys():
        if mechanism_name not in stats_mechanisms or not isinstance(stats_mechanisms[mechanism_name], dict):
            stats_mechanisms[mechanism_name] = default_mechanism_stats()
            changed = True
            continue
        rec = stats_mechanisms[mechanism_name]
        if "tries_authoritative" not in rec:
            rec["tries_authoritative"] = int(rec.get("tries", 0) or 0)
            changed = True
        mirror = int(rec.get("tries_authoritative", 0) or 0)
        if int(rec.get("tries", 0) or 0) != mirror:
            rec["tries"] = mirror
            changed = True
        if "cooldown_until_iter" not in rec:
            rec["cooldown_until_iter"] = 0
            changed = True
        if "last_policy_decision" not in rec:
            rec["last_policy_decision"] = None
            changed = True
        if "last_policy_confidence" not in rec:
            rec["last_policy_confidence"] = None
            changed = True
        if "last_policy_ceiling_probability" not in rec:
            rec["last_policy_ceiling_probability"] = None
            changed = True
        if "last_policy_reason" not in rec:
            rec["last_policy_reason"] = None
            changed = True
        if "last_policy_next_mechanism" not in rec:
            rec["last_policy_next_mechanism"] = None
            changed = True

    for stale_name in list(stats_mechanisms.keys()):
        if stale_name not in definition_mechanisms:
            stats_mechanisms.pop(stale_name, None)
            changed = True

    return changed


def write_definitions_with_optional_mirror(path: Path, payload: Dict[str, Any]) -> None:
    atomic_write_json(path, payload)
    suffix = path.suffix.lower()
    if suffix == ".json":
        mirror = path.with_suffix(".yaml")
        if mirror.exists():
            atomic_write_json(mirror, payload)
    elif suffix in {".yaml", ".yml"}:
        mirror = path.with_suffix(".json")
        if mirror.exists():
            atomic_write_json(mirror, payload)


def evaluate_with_pipeline(
    candidate_path: Path,
    result_path: Path,
    python_exe: str,
    screen_sims: int,
    seed_offsets: str,
    promotion_std_penalty: float,
) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    offsets = parse_seed_offsets(seed_offsets)
    seed_results: List[Dict[str, Any]] = []
    scores: List[float] = []
    authoritative_count = 0
    result_paths: List[str] = []
    regime_summary: Optional[Dict[str, Any]] = None

    for idx, seed_offset in enumerate(offsets):
        current_result_path = result_path
        if len(offsets) > 1:
            current_result_path = result_path.with_name(
                f"{result_path.stem}.seed_{seed_offset}{result_path.suffix}"
            )

        cmd = [
            python_exe,
            "scripts/amm-test-pipeline.py",
            str(candidate_path),
            "--output",
            str(current_result_path),
            "--screen-sims",
            str(screen_sims),
            "--seed-offset",
            str(seed_offset),
        ]
        repo_root = Path(__file__).resolve().parents[2]
        env = os.environ.copy()
        existing_pythonpath = env.get("PYTHONPATH", "")
        env["PYTHONPATH"] = str(repo_root) if not existing_pythonpath else f"{repo_root}:{existing_pythonpath}"
        proc = subprocess.run(cmd, capture_output=True, text=True, cwd=str(repo_root), env=env)
        if proc.returncode != 0:
            stderr_lines = (proc.stderr or proc.stdout or "").strip().splitlines()
            detail = stderr_lines[-1][:180] if stderr_lines else "unknown_error"
            return None, f"pipeline_failed:{proc.returncode}:seed_offset={seed_offset}:{detail}"

        result = load_json(current_result_path, {})
        testing = result.get("testing", {}) if isinstance(result, dict) else {}
        final_edge = result.get("final_edge") if isinstance(result, dict) else None
        final_score = result.get("final_score") if isinstance(result, dict) else None
        edge_screen = testing.get("edge_screen") if isinstance(testing, dict) else None

        if final_score is None and final_edge is not None:
            final_score = final_edge
        if final_score is None and edge_screen is not None:
            final_score = edge_screen

        if final_score is None:
            return None, f"pipeline_no_edge:seed_offset={seed_offset}"

        score = float(final_score)
        scores.append(score)
        authoritative = final_edge is not None
        if authoritative:
            authoritative_count += 1

        entry: Dict[str, Any] = {
            "seed_offset": seed_offset,
            "result_path": str(current_result_path),
            "score": score,
            "screen_edge": float(edge_screen) if edge_screen is not None else None,
            "final_edge": float(final_edge) if final_edge is not None else None,
            "final_score": float(final_score),
            "screen_only": not authoritative,
        }
        seed_results.append(entry)
        result_paths.append(str(current_result_path))

        # Extract regime summary from first authoritative result
        if authoritative and regime_summary is None:
            regime_tests = testing.get("regime_tests")
            if isinstance(regime_tests, dict):
                regime_summary = {
                    "weakest_regime": regime_tests.get("weakest_regime"),
                    "weakest_edge": regime_tests.get("weakest_edge"),
                    "spread": regime_tests.get("spread"),
                    "spread_warning": bool(regime_tests.get("spread_warning")),
                }

    mean_score = sum(scores) / len(scores)
    variance = 0.0
    if len(scores) > 1:
        variance = sum((value - mean_score) ** 2 for value in scores) / len(scores)
    std_score = math.sqrt(variance)
    robust_score = mean_score - max(0.0, float(promotion_std_penalty)) * std_score
    all_authoritative = authoritative_count == len(seed_results)
    primary_edge = robust_score if all_authoritative else mean_score
    promotion_edge = robust_score if all_authoritative else None

    return {
        "primary_edge": float(primary_edge),
        "promotion_edge": float(promotion_edge) if promotion_edge is not None else None,
        "promotable": bool(all_authoritative),
        "screen_only": not bool(all_authoritative),
        "mean_score": float(mean_score),
        "std_score": float(std_score),
        "robust_score": float(robust_score),
        "authoritative_count": authoritative_count,
        "seed_count": len(seed_results),
        "seed_offsets": offsets,
        "seed_results": seed_results,
        "result_paths": result_paths,
        "regime_summary": regime_summary,
    }, None



def load_definitions(path: Path) -> Dict[str, Any]:
    raw = path.read_text()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        if path.suffix.lower() not in {".yaml", ".yml"}:
            raise
        try:
            import yaml  # type: ignore
        except ImportError as exc:
            raise ValueError(
                f"YAML definitions require PyYAML, or provide JSON definitions: {path}"
            ) from exc
        data = yaml.safe_load(raw)
    if not isinstance(data, dict):
        raise ValueError(f"invalid mechanism definitions format: {path}")
    return data


def initialize_stats(
    state_dir: Path,
    definitions: Dict[str, Any],
    exploration_c: float,
    improvement_threshold: float,
    max_retries_on_invalid: int,
    wildcard_frequency: int,
) -> Dict[str, Any]:
    champion_code = (state_dir / ".best_strategy.sol").read_text()
    champion_edge = float((state_dir / ".best_edge.txt").read_text().strip())
    champion_name = parse_get_name(champion_code) or "unknown_champion"
    ensure_rollback_spine(
        state_dir=state_dir,
        champion_code=champion_code,
        champion_edge=champion_edge,
        reason="initialize_stats",
    )
    mechanisms = {}
    for mechanism_name in definitions.get("mechanisms", {}).keys():
        mechanisms[mechanism_name] = default_mechanism_stats()
    return {
        "schema_version": SCHEMA_VERSION,
        "champion": {
            "name": champion_name,
            "edge": champion_edge,
            "baseline_edge": champion_edge,
            "promoted_at": utc_now_iso(),
        },
        "mechanisms": mechanisms,
        "global": {
            "total_iterations": 0,
            "total_champion_updates": 0,
            "exploration_constant": exploration_c,
            "improvement_threshold": improvement_threshold,
            "max_retries_on_invalid": max_retries_on_invalid,
            "wildcard_frequency": wildcard_frequency,
            "rollback_triggered": False,
            "rollback_reason": None,
            "consecutive_invalid": 0,
        },
    }


def load_or_init_stats(
    stats_path: Path,
    state_dir: Path,
    definitions: Dict[str, Any],
    exploration_c: float,
    improvement_threshold: float,
    max_retries_on_invalid: int,
    wildcard_frequency: int,
) -> Dict[str, Any]:
    existing = load_json(stats_path, {})
    if isinstance(existing, dict) and existing.get("mechanisms"):
        return existing
    stats = initialize_stats(
        state_dir=state_dir,
        definitions=definitions,
        exploration_c=exploration_c,
        improvement_threshold=improvement_threshold,
        max_retries_on_invalid=max_retries_on_invalid,
        wildcard_frequency=wildcard_frequency,
    )
    atomic_write_json(stats_path, stats)
    return stats


def load_champion(state_dir: Path) -> Tuple[str, float, str]:
    code = (state_dir / ".best_strategy.sol").read_text()
    edge = float((state_dir / ".best_edge.txt").read_text().strip())
    name = parse_get_name(code) or "unknown_champion"
    return code, edge, name


def as_float(value: Any) -> Optional[float]:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def write_rollback_spine(
    state_dir: Path,
    code: str,
    edge: float,
    source: str,
    reason: str,
) -> Dict[str, Any]:
    edge_value = float(edge)
    name = parse_get_name(code) or "unknown_champion"
    atomic_write_text(state_dir / ROLLBACK_SPINE_STRATEGY_FILE, code)
    atomic_write_text(state_dir / ROLLBACK_SPINE_EDGE_FILE, f"{edge_value:.2f}\n")
    payload = {
        "ts": utc_now_iso(),
        "source": str(source),
        "reason": str(reason),
        "name": name,
        "edge": edge_value,
    }
    atomic_write_json(state_dir / ROLLBACK_SPINE_META_FILE, payload)
    return payload


def load_rollback_spine(state_dir: Path) -> Optional[Dict[str, Any]]:
    strategy_path = state_dir / ROLLBACK_SPINE_STRATEGY_FILE
    edge_path = state_dir / ROLLBACK_SPINE_EDGE_FILE
    if not strategy_path.exists() or not edge_path.exists():
        return None
    edge_value = as_float(edge_path.read_text().strip())
    if edge_value is None:
        return None
    code = strategy_path.read_text()
    name = parse_get_name(code) or "unknown_champion"
    meta = load_json(state_dir / ROLLBACK_SPINE_META_FILE, {})
    return {
        "source": "spine",
        "code": code,
        "edge": edge_value,
        "name": str(meta.get("name", name)),
        "meta": meta if isinstance(meta, dict) else {},
    }


def ensure_rollback_spine(
    state_dir: Path,
    champion_code: Optional[str] = None,
    champion_edge: Optional[float] = None,
    reason: str = "auto_ensure",
) -> Optional[Dict[str, Any]]:
    existing = load_rollback_spine(state_dir)
    if existing is not None:
        return existing
    if champion_code is None or champion_edge is None:
        try:
            champion_code, champion_edge, _ = load_champion(state_dir)
        except OSError:
            return None
        except ValueError:
            return None
    return write_rollback_spine(
        state_dir=state_dir,
        code=champion_code,
        edge=float(champion_edge),
        source="auto_init",
        reason=reason,
    )


def load_history_rollback_target(state_dir: Path) -> Optional[Dict[str, Any]]:
    manifest = load_champion_history_manifest(state_dir)
    champions = manifest.get("champions", [])
    if not isinstance(champions, list) or not champions:
        return None
    latest = champions[-1]
    sequence = int(latest.get("sequence_number", 0) or 0)
    if sequence <= 0:
        return None
    resolved = get_champion_by_sequence(state_dir, sequence)
    if resolved is None:
        return None
    code, metadata = resolved
    edge_value = as_float(metadata.get("edge"))
    if edge_value is None:
        edge_value = as_float(latest.get("edge"))
    if edge_value is None:
        return None
    name = str(metadata.get("name") or latest.get("name") or parse_get_name(code) or "unknown_champion")
    return {
        "source": f"history:{sequence}",
        "code": code,
        "edge": edge_value,
        "name": name,
    }


def load_snapshot_rollback_target(state_dir: Path) -> Optional[Dict[str, Any]]:
    snapshot_dir = state_dir / "migration_snapshot"
    strategy_path = snapshot_dir / ".best_strategy.sol"
    edge_path = snapshot_dir / ".best_edge.txt"
    if not strategy_path.exists() or not edge_path.exists():
        return None
    edge_value = as_float(edge_path.read_text().strip())
    if edge_value is None:
        return None
    code = strategy_path.read_text()
    name = parse_get_name(code) or "unknown_champion"
    return {
        "source": "snapshot",
        "code": code,
        "edge": edge_value,
        "name": name,
    }


def resolve_rollback_target(
    state_dir: Path,
    restore_mode: str,
    allow_snapshot_fallback: bool,
) -> Optional[Dict[str, Any]]:
    mode = str(restore_mode or DEFAULT_ROLLBACK_RESTORE_MODE).strip().lower()
    if mode not in ROLLBACK_RESTORE_MODES:
        mode = DEFAULT_ROLLBACK_RESTORE_MODE

    resolver_order: List[Callable[[Path], Optional[Dict[str, Any]]]]
    if mode == "snapshot_only":
        resolver_order = [load_snapshot_rollback_target]
    elif mode == "spine_only":
        resolver_order = [load_rollback_spine]
    elif mode == "history_only":
        resolver_order = [load_history_rollback_target]
    else:
        resolver_order = [load_history_rollback_target, load_rollback_spine]

    for resolver in resolver_order:
        target = resolver(state_dir)
        if target is not None:
            return target

    if allow_snapshot_fallback and mode != "snapshot_only":
        return load_snapshot_rollback_target(state_dir)
    return None


def update_rollback_status(
    stats: Dict[str, Any],
    log_entries: List[Dict[str, Any]],
    consecutive_invalid_threshold: int,
    severe_regression_threshold: float,
    cumulative_loss_threshold: float,
    cumulative_window: int,
) -> Optional[str]:
    consecutive_invalid = 0
    for entry in reversed(log_entries):
        if bool(entry.get("valid", False)):
            break
        consecutive_invalid += 1
    stats["global"]["consecutive_invalid"] = consecutive_invalid

    reason: Optional[str] = None
    if consecutive_invalid >= consecutive_invalid_threshold:
        reason = f"consecutive_invalid>={consecutive_invalid_threshold}"

    def rollback_delta(entry: Dict[str, Any]) -> Optional[float]:
        before = as_float(entry.get("champion_edge_before"))
        promotion_edge = as_float(entry.get("promotion_edge"))
        if before is not None and promotion_edge is not None:
            return promotion_edge - before
        edge = as_float(entry.get("edge"))
        if before is not None and edge is not None:
            return edge - before
        return as_float(entry.get("delta"))

    def is_promoted_entry(entry: Dict[str, Any]) -> bool:
        if "promoted" in entry:
            return bool(entry.get("promoted"))
        if not is_authoritative_log_entry(entry):
            return False
        delta = rollback_delta(entry)
        return bool(delta is not None and delta > 0.0)

    rollback_entries = [
        delta
        for entry in log_entries
        if bool(entry.get("valid", False))
        and is_authoritative_log_entry(entry)
        and is_promoted_entry(entry)
        for delta in [rollback_delta(entry)]
        if delta is not None
    ]

    if rollback_entries:
        latest_delta = rollback_entries[-1]
        if latest_delta <= severe_regression_threshold:
            reason = f"severe_regression<={severe_regression_threshold}"

    recent = rollback_entries[-cumulative_window:]
    cumulative = sum(recent)
    if len(recent) == cumulative_window and cumulative <= cumulative_loss_threshold:
        reason = f"cumulative_loss_{cumulative_window}<={cumulative_loss_threshold}"

    champion_edge = float(stats.get("champion", {}).get("edge", 0.0) or 0.0)
    baseline_edge = float(stats.get("champion", {}).get("baseline_edge", champion_edge) or champion_edge)
    if champion_edge < baseline_edge:
        reason = "champion_destroyed"

    if reason:
        stats["global"]["rollback_triggered"] = True
        stats["global"]["rollback_reason"] = reason
        return reason
    stats["global"]["rollback_triggered"] = False
    stats["global"]["rollback_reason"] = None
    return None


def perform_rollback(
    state_dir: Path,
    reason: str,
    archive_only: bool,
    restore_mode: str = DEFAULT_ROLLBACK_RESTORE_MODE,
    allow_snapshot_fallback: bool = DEFAULT_ROLLBACK_ALLOW_SNAPSHOT_FALLBACK,
) -> Dict[str, Any]:
    archive_dir = state_dir / ".archive"
    archive_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")

    moved: List[str] = []
    for name in ("mechanism_stats.json", "iteration_log.jsonl", "shadow_selections.jsonl"):
        src = state_dir / name
        if src.exists():
            dst = archive_dir / f"{name}.failed_{stamp}"
            shutil.move(str(src), str(dst))
            moved.append(str(dst))

    restored: List[str] = []
    restore_source = "none"
    restore_name = "unknown_champion"
    restore_edge: Optional[float] = None
    if not archive_only:
        target = resolve_rollback_target(
            state_dir=state_dir,
            restore_mode=restore_mode,
            allow_snapshot_fallback=allow_snapshot_fallback,
        )
        if target is not None:
            restore_source = str(target.get("source", "unknown"))
            restore_name = str(target.get("name", "unknown_champion"))
            restore_edge = float(target.get("edge", 0.0))
            atomic_write_text(state_dir / ".best_strategy.sol", str(target.get("code", "")))
            atomic_write_text(state_dir / ".best_edge.txt", f"{restore_edge:.2f}\n")
            restored.extend(
                [
                    str(state_dir / ".best_strategy.sol"),
                    str(state_dir / ".best_edge.txt"),
                ]
            )
            write_rollback_spine(
                state_dir=state_dir,
                code=str(target.get("code", "")),
                edge=restore_edge,
                source="rollback_restore",
                reason=reason,
            )

    with (archive_dir / "rollback_log.txt").open("a") as handle:
        handle.write(
            f"{utc_now_iso()} reason={reason} moved={moved} restored={restored} "
            f"restore_mode={restore_mode} allow_snapshot_fallback={allow_snapshot_fallback} "
            f"restore_source={restore_source} restore_name={restore_name} restore_edge={restore_edge}\n"
        )

    return {
        "reason": reason,
        "moved": moved,
        "restored": restored,
        "restore_mode": restore_mode,
        "allow_snapshot_fallback": bool(allow_snapshot_fallback),
        "restore_source": restore_source,
        "restored_name": restore_name,
        "restored_edge": restore_edge,
    }


def read_iteration_log(path: Path) -> List[Dict[str, Any]]:
    if not path.exists():
        return []
    rows: List[Dict[str, Any]] = []
    with path.open() as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                payload = json.loads(stripped)
                if isinstance(payload, dict):
                    rows.append(payload)
            except json.JSONDecodeError:
                continue
    return rows


def read_last_jsonl_entry(path: Path) -> Optional[Dict[str, Any]]:
    if not path.exists():
        return None
    last_payload: Optional[Dict[str, Any]] = None
    with path.open() as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                payload = json.loads(stripped)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict):
                last_payload = payload
    return last_payload


def bootstrap_champion(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    definitions_path = Path(args.definitions)

    source_values = list(getattr(args, "from_paths", []) or [])
    if not source_values:
        source_values = list(DEFAULT_BOOTSTRAP_CANDIDATES)
    source_paths = [Path(value) for value in source_values]

    missing_sources = [str(path) for path in source_paths if not path.exists()]
    if missing_sources:
        print(_json_out({"status": "bootstrap_failed", "reason": "missing_sources", "sources": missing_sources}))
        return 1

    eval_dir = state_dir / "bootstrap_eval"
    eval_dir.mkdir(parents=True, exist_ok=True)
    seed_offsets = args.seed_offsets
    evaluations: List[Dict[str, Any]] = []
    winners: List[Dict[str, Any]] = []

    for index, source_path in enumerate(source_paths):
        result_path = eval_dir / f"{source_path.stem}.result.json"
        summary, error = evaluate_with_pipeline(
            candidate_path=source_path,
            result_path=result_path,
            python_exe=args.python_exe,
            screen_sims=args.screen_sims,
            seed_offsets=seed_offsets,
            promotion_std_penalty=args.promotion_std_penalty,
        )
        row: Dict[str, Any] = {
            "source": str(source_path),
            "error": error,
        }
        if summary:
            row.update(summary)
            promotable = bool(summary.get("promotable", False))
            promotion_edge = summary.get("promotion_edge")
            if promotable and promotion_edge is not None:
                winners.append(
                    {
                        "source": str(source_path),
                        "objective": float(promotion_edge),
                        "promotable": promotable,
                        "index": index,
                        "summary": summary,
                    }
                )
        evaluations.append(row)

    if not winners:
        print(
            _json_out(
                {
                    "status": "bootstrap_failed",
                    "reason": "no_authoritative_candidates",
                    "evaluations": evaluations,
                }
            )
        )
        return 1

    winners.sort(key=lambda item: (1 if item["promotable"] else 0, item["objective"]), reverse=True)
    chosen = winners[0]
    chosen_source = Path(chosen["source"])
    chosen_summary = dict(chosen["summary"])
    chosen_edge = chosen_summary.get("promotion_edge")
    if chosen_edge is None:
        print(_json_out({"status": "bootstrap_failed", "reason": "winner_missing_edge", "winner": chosen}))
        return 1
    chosen_edge_value = float(chosen_edge)

    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    archive_dir = state_dir / ".archive" / f"bootstrap_{stamp}"
    archive_dir.mkdir(parents=True, exist_ok=True)
    backed_up: List[str] = []

    for name in BOOTSTRAP_BACKUP_FILES:
        path = state_dir / name
        if path.exists():
            backup = archive_dir / path.name
            shutil.copy2(path, backup)
            backed_up.append(str(backup))

    atomic_write_text(state_dir / ".best_strategy.sol", chosen_source.read_text())
    atomic_write_text(state_dir / ".best_edge.txt", f"{chosen_edge_value:.2f}\n")
    write_rollback_spine(
        state_dir=state_dir,
        code=chosen_source.read_text(),
        edge=chosen_edge_value,
        source="bootstrap",
        reason="bootstrap_complete",
    )

    install_definitions = Path(args.install_definitions)
    if install_definitions.exists():
        new_definitions = load_definitions(install_definitions)
        write_definitions_with_optional_mirror(definitions_path, new_definitions)

    for name in BOOTSTRAP_RESET_FILES:
        target = state_dir / name
        if target.exists():
            target.unlink()

    final_definitions = load_definitions(definitions_path)
    stats = initialize_stats(
        state_dir=state_dir,
        definitions=final_definitions,
        exploration_c=args.exploration_c,
        improvement_threshold=args.improvement_threshold,
        max_retries_on_invalid=args.max_retries_on_invalid,
        wildcard_frequency=args.wildcard_frequency,
    )
    atomic_write_json(state_dir / "mechanism_stats.json", stats)

    payload = {
        "status": "bootstrap_complete",
        "chosen_source": str(chosen_source),
        "chosen_edge": chosen_edge_value,
        "promotable": bool(chosen_summary.get("promotable", False)),
        "chosen_summary": chosen_summary,
        "seed_offsets": parse_seed_offsets(seed_offsets),
        "definitions_installed_from": str(install_definitions) if install_definitions.exists() else None,
        "definitions_path": str(definitions_path),
        "archive_dir": str(archive_dir),
        "backed_up": backed_up,
        "evaluations": evaluations,
    }
    print(_json_out(payload))
    return 0


def finalize_iteration_entry(
    state_dir: Path,
    log_path: Path,
    stats_path: Path,
    stats: Dict[str, Any],
    entry: Dict[str, Any],
    args: argparse.Namespace,
    default_exit_code: int,
    apply_rollback_policy: bool = True,
) -> int:
    append_jsonl(log_path, entry)
    if apply_rollback_policy:
        logs = read_iteration_log(log_path)
        update_rollback_status(
            stats,
            logs,
            args.rollback_consecutive_invalid,
            args.rollback_severe_regression,
            args.rollback_cumulative_loss,
            args.rollback_window,
        )
    atomic_write_json(stats_path, stats)
    if apply_rollback_policy and bool(args.auto_rollback) and stats["global"].get("rollback_triggered"):
        rollback_meta = perform_rollback(
            state_dir=state_dir,
            reason=str(stats["global"]["rollback_reason"]),
            archive_only=False,
            restore_mode=str(getattr(args, "rollback_restore_mode", DEFAULT_ROLLBACK_RESTORE_MODE)),
            allow_snapshot_fallback=bool(
                getattr(args, "rollback_allow_snapshot_fallback", DEFAULT_ROLLBACK_ALLOW_SNAPSHOT_FALLBACK)
            ),
        )
        print(_json_out({"status": "rolled_back", **rollback_meta}))
        return 2
    print(_json_out(entry))
    return default_exit_code


def _setup_iteration_paths(state_dir: Path) -> Tuple[Path, Path, Path, Path]:
    stats_path = state_dir / "mechanism_stats.json"
    log_path = state_dir / "iteration_log.jsonl"
    prompt_dir = state_dir / "prompts_simplified"
    candidate_dir = state_dir / "candidates_simplified"
    prompt_dir.mkdir(parents=True, exist_ok=True)
    candidate_dir.mkdir(parents=True, exist_ok=True)
    return stats_path, log_path, prompt_dir, candidate_dir


def _select_iteration_mechanism(
    iteration: int,
    stats: Dict[str, Any],
    mechanisms: Dict[str, Any],
    exploration_c: float,
    wildcard_frequency: int,
    rng: random.Random,
) -> Tuple[str, bool]:
    wildcard = should_run_wildcard(iteration, stats, wildcard_frequency)
    candidate_pool = {name: rec for name, rec in stats["mechanisms"].items() if name in mechanisms}
    if not candidate_pool:
        candidate_pool = {name: default_mechanism_stats() for name in mechanisms.keys()}
        stats["mechanisms"] = candidate_pool
    if wildcard:
        return "wildcard", True
    return select_mechanism(candidate_pool, exploration_c, rng, current_iteration=iteration), False


def _build_iteration_prompt(
    champion_code: str,
    mechanism_name: str,
    mechanisms: Dict[str, Any],
    iteration: int,
    wildcard: bool,
    hypothesis_shortlist: Sequence[Dict[str, Any]],
    hypothesis_tracker: Optional[Dict[str, Any]],
    hypothesis_recent: Optional[Dict[str, Any]],
    selected_hypothesis_block: str,
    tenets_block: str,
    evidence_snapshot_block: str,
    generation_requirements_block: str,
) -> str:
    if wildcard:
        return build_wildcard_prompt(
            champion_code=champion_code,
            variant_name=f"wildcard_mod_v{iteration}",
            tenets_block=tenets_block,
            evidence_snapshot_block=evidence_snapshot_block,
            generation_requirements_block=generation_requirements_block,
        )
    mechanism_info = mechanisms[mechanism_name]
    return build_prompt(
        champion_code=champion_code,
        mechanism_name=mechanism_name,
        mechanism_info=mechanism_info,
        other_mechanisms=[name for name in mechanisms.keys() if name != mechanism_name],
        variant_name=f"{mechanism_name}_mod_v{iteration}",
        hypothesis_shortlist=hypothesis_shortlist,
        hypothesis_tracker=hypothesis_tracker,
        hypothesis_recent=hypothesis_recent,
        selected_hypothesis_block=selected_hypothesis_block,
        tenets_block=tenets_block,
        evidence_snapshot_block=evidence_snapshot_block,
        generation_requirements_block=generation_requirements_block,
    )


def _inject_retry_block(base_prompt: str, retry_block: str) -> str:
    """
    Helper to inject retry instructions before CONSTRAINTS section.

    Args:
        base_prompt: The original prompt text
        retry_block: The retry-specific instructions to inject

    Returns:
        Modified prompt with retry block injected
    """
    if "## CONSTRAINTS" in base_prompt:
        parts = base_prompt.split("## CONSTRAINTS", 1)
        return parts[0] + retry_block + "\n## CONSTRAINTS" + parts[1]
    return base_prompt + "\n\n" + retry_block


def _build_gas_optimized_prompt(
    base_prompt: str,
    failed_code: str,
    mechanism_name: str,
    wildcard: bool,
    failure_type: str,
    retry_attempt: int,
    max_retries: int,
) -> str:
    """
    Enhance prompt with gas optimization instructions for retry.

    Args:
        base_prompt: The original prompt text
        failed_code: The candidate code that exceeded gas limits
        mechanism_name: Name of the mechanism being modified
        wildcard: Whether this is a wildcard iteration
        failure_type: The failure type (should be "gas_error")
        retry_attempt: Current retry attempt number (1-indexed)
        max_retries: Maximum retries allowed for this failure type

    Returns:
        Modified prompt with gas optimization guidance
    """
    gas_block = """
## CRITICAL: GAS OPTIMIZATION REQUIRED

Previous candidate exceeded 250,000 gas limit. You MUST generate simpler code.

### Previous Failed Code:
```solidity
{failed_code}
```

### Gas Optimization Requirements:
1. **Reduce storage slots**: Minimize state variables (aim for 8-12 slots max)
2. **Simplify calculations**: Fewer operations, avoid expensive sqrt/exp
3. **Reduce memory allocation**: Minimize arrays and dynamic structures
4. **Optimize control flow**: Reduce branching, avoid nested loops
5. **Remove non-essential features**: Focus on core logic only

Target: 50-70% of previous complexity. Retry {retry}/{max_retries}.
""".format(
        failed_code=failed_code.strip(),
        retry=retry_attempt,
        max_retries=max_retries,
    )

    return _inject_retry_block(base_prompt, gas_block)


def _build_timeout_optimized_prompt(
    base_prompt: str,
    failed_code: str,
    mechanism_name: str,
    wildcard: bool,
    failure_type: str,
    retry_attempt: int,
    max_retries: int,
) -> str:
    """
    Enhance prompt with timeout optimization instructions (future expansion).

    Args:
        base_prompt: The original prompt text
        failed_code: The candidate code that timed out
        mechanism_name: Name of the mechanism being modified
        wildcard: Whether this is a wildcard iteration
        failure_type: The failure type (should be "timeout_error")
        retry_attempt: Current retry attempt number (1-indexed)
        max_retries: Maximum retries allowed for this failure type

    Returns:
        Modified prompt with timeout optimization guidance
    """
    timeout_block = """
## CRITICAL: EXECUTION TIMEOUT OPTIMIZATION REQUIRED

Previous candidate exceeded test execution time limit.

### Previous Failed Code:
```solidity
{failed_code}
```

### Optimization Requirements:
1. Reduce computational complexity in swap logic
2. Simplify price calculations
3. Remove unnecessary loops or iterations

Retry {retry}/{max_retries}.
""".format(
        failed_code=failed_code.strip(),
        retry=retry_attempt,
        max_retries=max_retries,
    )

    return _inject_retry_block(base_prompt, timeout_block)


def _build_simulation_optimized_prompt(
    base_prompt: str,
    failed_code: str,
    mechanism_name: str,
    wildcard: bool,
    failure_type: str,
    retry_attempt: int,
    max_retries: int,
) -> str:
    """
    Enhance prompt with simulation stability instructions (future expansion).

    Args:
        base_prompt: The original prompt text
        failed_code: The candidate code that caused simulation issues
        mechanism_name: Name of the mechanism being modified
        wildcard: Whether this is a wildcard iteration
        failure_type: The failure type (should be "simulation_error")
        retry_attempt: Current retry attempt number (1-indexed)
        max_retries: Maximum retries allowed for this failure type

    Returns:
        Modified prompt with simulation stability guidance
    """
    sim_block = """
## CRITICAL: SIMULATION STABILITY REQUIRED

Previous candidate caused numerical instability or invalid states.

### Previous Failed Code:
```solidity
{failed_code}
```

### Stability Requirements:
1. Add bounds checking on calculations
2. Prevent division by zero or near-zero values
3. Ensure prices stay within valid ranges
4. Validate intermediate results

Retry {retry}/{max_retries}.
""".format(
        failed_code=failed_code.strip(),
        retry=retry_attempt,
        max_retries=max_retries,
    )

    return _inject_retry_block(base_prompt, sim_block)


def _evaluate_iteration_candidate(
    args: argparse.Namespace,
    candidate_path: Path,
    result_path: Path,
    champion_edge: float,
    mechanism_name: str,
    iteration: int,
) -> Tuple[Optional[float], Optional[float], bool, bool, bool, Dict[str, Any], Optional[str]]:
    if bool(args.dry_run):
        delta = 0.0  # Dry-run always produces neutral delta
        candidate_edge = champion_edge + delta
        evaluation_summary: Dict[str, Any] = {
            "primary_edge": candidate_edge,
            "promotion_edge": None,
            "promotable": False,
            "screen_only": True,
            "seed_offsets": parse_seed_offsets(args.seed_offsets),
            "seed_results": [],
        }
        return candidate_edge, None, False, True, False, evaluation_summary, None

    evaluation_summary, eval_error = evaluate_with_pipeline(
        candidate_path=candidate_path,
        result_path=result_path,
        python_exe=args.python_exe,
        screen_sims=args.screen_sims,
        seed_offsets=args.seed_offsets,
        promotion_std_penalty=args.promotion_std_penalty,
    )
    if evaluation_summary is None:
        return None, None, False, False, False, {}, eval_error

    candidate_edge = _float_value(evaluation_summary.get("primary_edge"))
    promotion_raw = evaluation_summary.get("promotion_edge")
    promotion_edge = _float_value(promotion_raw) if promotion_raw is not None else None
    promotable = bool(evaluation_summary.get("promotable", False))
    screen_only_eval = bool(evaluation_summary.get("screen_only", False))
    authoritative_eval = promotable
    return candidate_edge, promotion_edge, promotable, screen_only_eval, authoritative_eval, evaluation_summary, eval_error


def _classify_test_failure(eval_error: Optional[str]) -> Optional[str]:
    """
    Classify a test failure error into a known failure type.

    Args:
        eval_error: The error string from evaluate_with_pipeline

    Returns:
        The failure type key from TEST_FAILURE_CATALOG, or None if unclassified
    """
    if not eval_error:
        return None

    error_lower = str(eval_error).lower()

    # Check each failure type's patterns
    for failure_type, config in TEST_FAILURE_CATALOG.items():
        patterns = config.get("patterns", [])
        if any(pattern in error_lower for pattern in patterns):
            return failure_type

    return None  # Unclassified failure


def run_iteration(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    stats_path, log_path, prompt_dir, candidate_dir = _setup_iteration_paths(state_dir)

    definitions = load_definitions(Path(args.definitions))
    stats = load_or_init_stats(
        stats_path=stats_path,
        state_dir=state_dir,
        definitions=definitions,
        exploration_c=args.exploration_c,
        improvement_threshold=args.improvement_threshold,
        max_retries_on_invalid=args.max_retries_on_invalid,
        wildcard_frequency=args.wildcard_frequency,
    )
    if sync_stats_mechanisms(stats, definitions):
        atomic_write_json(stats_path, stats)

    iteration = _get_int(stats, "global", "total_iterations") + 1
    seed_offsets_active = parse_seed_offsets(getattr(args, "seed_offsets", DEFAULT_SEED_OFFSETS))
    args.seed_offsets = ",".join(str(value) for value in seed_offsets_active)
    rng = random.Random(args.seed + iteration)

    champion_code, champion_edge, champion_name = load_champion(state_dir)
    ensure_rollback_spine(
        state_dir=state_dir,
        champion_code=champion_code,
        champion_edge=champion_edge,
        reason="run_iteration_preflight",
    )
    mechanisms = dict(definitions.get("mechanisms", {}))
    if not mechanisms:
        raise ValueError("definitions has no mechanisms")
    hypotheses_file_raw = str(getattr(args, "hypotheses_file", "") or "").strip()
    hypotheses_path = Path(hypotheses_file_raw) if hypotheses_file_raw else (state_dir / DEFAULT_HYPOTHESES_FILENAME)
    hypotheses = load_hypothesis_catalog(definitions, hypotheses_path, mechanisms)
    if sync_stats_hypotheses(stats, hypotheses):
        atomic_write_json(stats_path, stats)

    _, wildcard = _select_iteration_mechanism(
        iteration=iteration,
        stats=stats,
        mechanisms=mechanisms,
        exploration_c=args.exploration_c,
        wildcard_frequency=args.wildcard_frequency,
        rng=rng,
    )
    if not wildcard:
        # Cross-mechanism: pass ALL hypotheses, let LLM pick mechanism + hypothesis
        all_mechanism_names = set(mechanisms.keys())
        mechanism_hypotheses = [
            h for h in hypotheses
            if isinstance(h, dict) and str(h.get("mechanism", "")).strip() in all_mechanism_names
        ]
        mechanism_name = "cross_mechanism"
    else:
        mechanism_hypotheses = []
        mechanism_name = "wildcard"
    # Keep shortlist order non-deterministic to reduce anchoring bias in LLM selection.
    if len(mechanism_hypotheses) > 1:
        SYSTEM_RANDOM.shuffle(mechanism_hypotheses)
    existing_logs = read_iteration_log(log_path)
    # For cross-mechanism mode, pass None so untried hypotheses from starved mechanisms
    # get full exploration_bonus with zero evidence penalties in scoring.
    hypothesis_recent = None

    candidate_code = ""
    prompt_path = prompt_dir / f"iter_{iteration}_{mechanism_name.replace(':', '_')}.md"
    candidate_path = candidate_dir / f"iter_{iteration}_{mechanism_name.replace(':', '_')}.sol"
    llm_artifacts: Dict[str, str] = {}
    iteration_policy_metadata: Optional[Dict[str, Any]] = None
    selected_hypothesis: Optional[Dict[str, Any]] = None
    hypothesis_payload: Optional[Dict[str, Any]] = None
    selection_summary: Optional[Dict[str, Any]] = None
    tenet_evolution_summary: Optional[Dict[str, Any]] = None

    prompts_dir = Path(DEFAULT_PROMPTS_DIR)
    generation_requirements_template = load_prompt_asset(
        prompts_dir / DEFAULT_PROMPT_TEMPLATE_HYPOTHESIS_GENERATION,
        HYPOTHESIS_GENERATION_TEMPLATE_FALLBACK,
    )
    tenets_path = Path(getattr(args, "tenets_file", DEFAULT_TENETS_FILE))
    tenets_payload = parse_tenets(tenets_path)
    tenets_block = format_tenets_block(tenets_payload)
    tenet_meta_path = state_dir / DEFAULT_TENET_META_STATE_FILE
    tenet_meta_state = sync_tenet_meta_state(
        load_json(tenet_meta_path, {}),
        tenets_payload=tenets_payload,
        iteration=iteration,
    )
    evidence_snapshot = build_evidence_snapshot(
        stats=stats,
        log_entries=existing_logs,
        mechanism_name=mechanism_name,
        seed_offsets=seed_offsets_active,
        shortlist_size=len(mechanism_hypotheses),
        tenet_meta=tenet_meta_state,
    )
    selected_hypothesis_block = "- none"
    selection_log_path = state_dir / DEFAULT_HYPOTHESIS_SELECTION_LOG
    if not wildcard and mechanism_hypotheses:
        selected_hypothesis, selection_summary, selection_artifacts = select_hypothesis_with_llm(
            iteration=iteration,
            mechanism_name=mechanism_name,
            shortlist=mechanism_hypotheses,
            hypothesis_tracker=stats.get("hypotheses"),
            hypothesis_recent=hypothesis_recent,
            tenets_payload=tenets_payload,
            tenets_block=tenets_block,
            evidence_snapshot=evidence_snapshot,
            prompts_dir=prompts_dir,
            llm_command=args.llm_command,
            llm_model=args.llm_model,
            llm_timeout_minutes=args.llm_timeout_minutes,
            llm_max_output_tokens=args.llm_max_output_tokens,
            llm_disable_shell_tool=args.llm_disable_shell_tool,
            candidate_dir=candidate_dir,
            enabled=bool(getattr(args, "selection_llm_enabled", True)) and not bool(args.dry_run),
            top_k=10 if mechanism_name == "cross_mechanism" else getattr(args, "selection_top_k", DEFAULT_SELECTION_TOP_K),
        )
        selected_hypothesis_block = format_selected_hypothesis_block(selected_hypothesis, selection_summary)
        if isinstance(selection_summary, dict):
            append_jsonl(selection_log_path, selection_summary)
            update_tenet_meta_from_selection(
                tenet_meta=tenet_meta_state,
                selection_payload=selection_summary,
                iteration=iteration,
            )
        for key, value in selection_artifacts.items():
            llm_artifacts[f"selection_{key}"] = value
    elif wildcard:
        selection_summary = {
            "status": "wildcard_skip",
            "iteration": iteration,
            "mechanism": mechanism_name,
            "reason": "wildcard_iteration",
        }
        append_jsonl(selection_log_path, selection_summary)

    # Cross-mechanism: resolve actual mechanism from LLM-selected hypothesis
    if not wildcard and mechanism_name == "cross_mechanism":
        if selected_hypothesis:
            resolved_name = str(selected_hypothesis.get("mechanism", "")).strip()
            if resolved_name in mechanisms:
                mechanism_name = resolved_name
            else:
                mechanism_name = list(mechanisms.keys())[0]
        else:
            # Fallback: use UCB as before
            mechanism_name = select_mechanism(
                {name: rec for name, rec in stats["mechanisms"].items() if name in mechanisms},
                args.exploration_c, rng, current_iteration=iteration,
            )
        # Update file paths with resolved mechanism name
        prompt_path = prompt_dir / f"iter_{iteration}_{mechanism_name.replace(':', '_')}.md"
        candidate_path = candidate_dir / f"iter_{iteration}_{mechanism_name.replace(':', '_')}.sol"

    atomic_write_json(tenet_meta_path, tenet_meta_state)
    policy_state_path = state_dir / "policy_evolution_state.json"
    policy_state = load_json(policy_state_path, {})
    if not isinstance(policy_state, dict):
        policy_state = {}
    policy_state["tenet_system"] = {
        "enabled": True,
        "selection_llm_enabled": bool(getattr(args, "selection_llm_enabled", True)),
        "tenet_evolution_enabled": bool(getattr(args, "tenet_evolution_enabled", True)),
        "tenet_evolution_frequency": _int_value(
            getattr(args, "tenet_evolution_frequency", DEFAULT_TENET_EVOLUTION_FREQUENCY),
            default=DEFAULT_TENET_EVOLUTION_FREQUENCY,
        ),
        "tenet_auto_apply": bool(getattr(args, "tenet_auto_apply", False)),
        "tenets_file": str(tenets_path),
        "active_seed_offsets": seed_offsets_active,
        "max_seed_offset": max(seed_offsets_active) if seed_offsets_active else 0,
        "last_selection": selection_summary,
        "last_tenet_evolution": None,
        "last_updated_iter": iteration,
    }
    atomic_write_json(policy_state_path, policy_state)
    hypothesis_payload = hypothesis_log_payload(selected_hypothesis)

    prompt_text = _build_iteration_prompt(
        champion_code=champion_code,
        mechanism_name=mechanism_name,
        mechanisms=mechanisms,
        iteration=iteration,
        wildcard=wildcard,
        hypothesis_shortlist=mechanism_hypotheses,
        hypothesis_tracker=stats.get("hypotheses"),
        hypothesis_recent=hypothesis_recent,
        selected_hypothesis_block=selected_hypothesis_block,
        tenets_block=tenets_block,
        evidence_snapshot_block=evidence_snapshot,
        generation_requirements_block=generation_requirements_template,
    )
    atomic_write_text(prompt_path, f"{prompt_text}\n")

    if args.candidate_file:
        candidate_code = Path(args.candidate_file).read_text()
    elif args.dry_run:
        if wildcard:
            candidate_code = champion_code + f"\n// wildcard mutation iter={iteration}\n"
        else:
            mechanism_info = mechanisms[mechanism_name]
            candidate_code = generate_mock_candidate(
                champion_code=champion_code,
                mechanism_name=mechanism_name,
                mechanism_info=mechanism_info,
                iteration=iteration,
            )
    else:
        artifact_prefix = candidate_dir / f"iter_{iteration}_{mechanism_name}"
        candidate_code, llm_error, llm_artifacts = generate_candidate_with_llm(
            prompt_path=prompt_path,
            artifact_prefix=artifact_prefix,
            llm_command=args.llm_command,
            llm_model=args.llm_model,
            llm_timeout_minutes=args.llm_timeout_minutes,
            llm_max_output_tokens=args.llm_max_output_tokens,
            llm_disable_shell_tool=args.llm_disable_shell_tool,
            attempt=0,
        )
        if candidate_code is None:
            _increment_mechanism_counter(stats, mechanism_name, "invalid_count")
            stats["global"]["total_iterations"] = iteration
            entry = {
                "iter": iteration,
                "ts": utc_now_iso(),
                "status": "llm_failed",
                "mechanism": mechanism_name,
                "valid": False,
                "reason": llm_error or "llm_failed",
                "champion_edge_before": champion_edge,
                "prompt_path": str(prompt_path),
                "candidate_path": str(candidate_path),
            }
            if selection_summary:
                entry["tenet_selection"] = selection_summary
            if hypothesis_payload:
                entry["hypothesis"] = hypothesis_payload
            if llm_artifacts:
                entry.update(llm_artifacts)
            return finalize_iteration_entry(
                state_dir=state_dir,
                log_path=log_path,
                stats_path=stats_path,
                stats=stats,
                entry=entry,
                args=args,
                default_exit_code=1,
            )

    atomic_write_text(candidate_path, candidate_code)

    valid = True
    reason = "valid"
    validation_warnings: List[str] = []
    retries = args.max_retries_on_invalid
    if not wildcard:
        for attempt in range(retries + 1):
            valid, reason, validation_warnings = validate_candidate(
                champion_code, candidate_code, mechanism_name, definitions
            )
            if valid:
                # Log anchor drift warnings if any (soft notices, not blockers)
                if validation_warnings:
                    for warn in validation_warnings:
                        print(f"[validation_warning] {warn}", file=sys.stderr)
                break
            if attempt >= retries:
                break
            if args.candidate_file:
                break
            if args.dry_run:
                candidate_code = generate_mock_candidate(
                    champion_code=champion_code,
                    mechanism_name=mechanism_name,
                    mechanism_info=mechanisms[mechanism_name],
                    iteration=iteration + attempt + 1,
                )
            else:
                artifact_prefix = candidate_dir / f"iter_{iteration}_{mechanism_name}"
                candidate_code, llm_error, llm_artifacts = generate_candidate_with_llm(
                    prompt_path=prompt_path,
                    artifact_prefix=artifact_prefix,
                    llm_command=args.llm_command,
                    llm_model=args.llm_model,
                    llm_timeout_minutes=args.llm_timeout_minutes,
                    llm_max_output_tokens=args.llm_max_output_tokens,
                    llm_disable_shell_tool=args.llm_disable_shell_tool,
                    attempt=attempt + 1,
                )
                if candidate_code is None:
                    reason = llm_error or "llm_retry_failed"
                    break
            atomic_write_text(candidate_path, candidate_code)

    iteration_policy_metadata = extract_iteration_policy_metadata(candidate_code)
    selected_hypothesis_from_policy = resolve_selected_hypothesis(iteration_policy_metadata, mechanism_hypotheses)
    if selected_hypothesis is None:
        selected_hypothesis = selected_hypothesis_from_policy
    elif (
        selected_hypothesis_from_policy is not None
        and str(selected_hypothesis_from_policy.get("id", "")).strip()
        != str(selected_hypothesis.get("id", "")).strip()
    ):
        validation_warnings.append(
            "selection_lock_mismatch:selected="
            f"{str(selected_hypothesis.get('id', '')).strip()}"
            f":policy={str(selected_hypothesis_from_policy.get('id', '')).strip()}"
        )
    hypothesis_payload = hypothesis_log_payload(selected_hypothesis)

    if not valid:
        _increment_mechanism_counter(stats, mechanism_name, "invalid_count")
        stats["global"]["total_iterations"] = iteration
        entry = {
            "iter": iteration,
            "ts": utc_now_iso(),
            "status": "invalid",
            "mechanism": mechanism_name,
            "valid": False,
            "reason": reason,
            "champion_edge_before": champion_edge,
            "prompt_path": str(prompt_path),
            "candidate_path": str(candidate_path),
        }
        if selection_summary:
            entry["tenet_selection"] = selection_summary
        if hypothesis_payload:
            entry["hypothesis"] = hypothesis_payload
        if iteration_policy_metadata:
            entry["iteration_policy"] = iteration_policy_metadata
        if validation_warnings:
            entry["validation_warnings"] = validation_warnings
        if llm_artifacts:
            entry.update(llm_artifacts)
        return finalize_iteration_entry(
            state_dir=state_dir,
            log_path=log_path,
            stats_path=stats_path,
            stats=stats,
            entry=entry,
            args=args,
            default_exit_code=1,
        )

    result_path = candidate_dir / f"iter_{iteration}_{mechanism_name}.result.json"

    # Generic test failure retry logic
    retry_history = []  # Track all retry attempts: [(failure_type, attempt_num), ...]
    total_retry_attempt = 0
    current_failure_type = None
    failure_specific_retry_count = 0

    # Maximum total retries across all failure types (safety limit)
    MAX_TOTAL_RETRIES = 3

    for total_retry_attempt in range(MAX_TOTAL_RETRIES + 1):
        (
            candidate_edge,
            promotion_edge,
            promotable,
            screen_only_eval,
            authoritative_eval,
            evaluation_summary,
            eval_error,
        ) = _evaluate_iteration_candidate(
            args=args,
            candidate_path=candidate_path,
            result_path=result_path,
            champion_edge=champion_edge,
            mechanism_name=mechanism_name,
            iteration=iteration,
        )

        # Success - break out
        if candidate_edge is not None:
            break

        # Classify the failure type
        detected_failure_type = _classify_test_failure(eval_error)

        # Check if this is a new failure type or continuation of same type
        if detected_failure_type != current_failure_type:
            # New failure type - reset failure-specific counter
            current_failure_type = detected_failure_type
            failure_specific_retry_count = 0

        # Check if retry is available for this failure type
        if detected_failure_type is None:
            # Unclassified failure - no retry
            break

        max_retries_for_type = _get_retry_limit(detected_failure_type)

        if failure_specific_retry_count >= max_retries_for_type:
            # Exhausted retries for this specific failure type
            break

        # We have retry budget - attempt recovery
        failure_specific_retry_count += 1
        retry_history.append((detected_failure_type, failure_specific_retry_count))
        failure_config = TEST_FAILURE_CATALOG[detected_failure_type]

        print(
            f"[test_retry] Iteration {iteration}: {failure_config['description']}. "
            f"Retrying with {detected_failure_type} optimization "
            f"(attempt {failure_specific_retry_count}/{max_retries_for_type}, "
            f"total retries: {total_retry_attempt})...",
            file=sys.stderr,
        )

        # Skip retry in special modes
        if args.candidate_file or args.dry_run:
            print(
                f"[test_retry] Cannot retry in this mode. Skipping.",
                file=sys.stderr,
            )
            break

        # Read failed code
        failed_code = candidate_path.read_text(encoding="utf-8")

        # Get prompt modifier function name and call it
        prompt_modifier_name = failure_config["prompt_modifier"]
        prompt_modifier_fn = globals().get(prompt_modifier_name)

        if prompt_modifier_fn is None:
            print(
                f"[test_retry] Prompt modifier '{prompt_modifier_name}' not found. "
                f"Skipping retry.",
                file=sys.stderr,
            )
            break

        # Create optimized prompt using the appropriate modifier
        base_prompt = prompt_path.read_text(encoding="utf-8")
        optimized_prompt = prompt_modifier_fn(
            base_prompt=base_prompt,
            failed_code=failed_code,
            mechanism_name=mechanism_name,
            wildcard=wildcard,
            failure_type=detected_failure_type,
            retry_attempt=failure_specific_retry_count,
            max_retries=max_retries_for_type,
        )

        # Save retry prompt with failure type in filename
        retry_prompt_path = prompt_dir / (
            f"iter_{iteration}_{mechanism_name}_"
            f"{detected_failure_type}_retry{failure_specific_retry_count}.md"
        )
        atomic_write_text(retry_prompt_path, optimized_prompt)

        # Generate new candidate with optimized prompt
        artifact_prefix = candidate_dir / (
            f"iter_{iteration}_{mechanism_name}_{detected_failure_type}"
        )
        candidate_code, llm_error, llm_artifacts = generate_candidate_with_llm(
            prompt_path=retry_prompt_path,
            artifact_prefix=artifact_prefix,
            llm_command=args.llm_command,
            llm_model=args.llm_model,
            llm_timeout_minutes=args.llm_timeout_minutes,
            llm_max_output_tokens=args.llm_max_output_tokens,
            llm_disable_shell_tool=args.llm_disable_shell_tool,
            attempt=failure_specific_retry_count,
        )

        if candidate_code is None:
            print(
                f"[test_retry] LLM failed on {detected_failure_type} retry: {llm_error}",
                file=sys.stderr,
            )
            eval_error = f"retry_llm_failed:{detected_failure_type}:{llm_error}"
            break

        # Update candidate file
        atomic_write_text(candidate_path, candidate_code)

        # Re-extract policy metadata
        iteration_policy_metadata = extract_iteration_policy_metadata(candidate_code)
        selected_hypothesis_from_policy = resolve_selected_hypothesis(
            iteration_policy_metadata, mechanism_hypotheses
        )
        if selected_hypothesis is None:
            selected_hypothesis = selected_hypothesis_from_policy

        # Re-extract hypothesis payload for updated candidate
        hypothesis_payload = hypothesis_log_payload(selected_hypothesis)

        # Continue to retry evaluation
        continue

    # Handle failure after retries exhausted
    if candidate_edge is None:
        _increment_mechanism_counter(stats, mechanism_name, "compile_fail_count")
        _increment_mechanism_counter(stats, mechanism_name, "invalid_count")
        stats["global"]["total_iterations"] = iteration

        # Build failure reason with retry history
        failure_reason = eval_error or "evaluation_failed"
        if retry_history:
            retry_summary = ";".join([
                f"{ftype}:{count}" for ftype, count in retry_history
            ])
            failure_reason = f"retries_exhausted[{retry_summary}]:{failure_reason}"

        entry = {
            "iter": iteration,
            "ts": utc_now_iso(),
            "status": "compile_failed",
            "mechanism": mechanism_name,
            "valid": False,
            "reason": failure_reason,
            "champion_edge_before": champion_edge,
            "prompt_path": str(prompt_path),
            "candidate_path": str(candidate_path),
            "result_path": str(result_path),
        }
        if retry_history:
            entry["test_retries"] = {
                "total_attempts": total_retry_attempt,
                "retry_history": retry_history,
                "final_failure_type": current_failure_type,
            }
        if selection_summary:
            entry["tenet_selection"] = selection_summary
        if hypothesis_payload:
            entry["hypothesis"] = hypothesis_payload
        if evaluation_summary:
            entry["evaluation"] = evaluation_summary
        if iteration_policy_metadata:
            entry["iteration_policy"] = iteration_policy_metadata
        if llm_artifacts:
            entry.update(llm_artifacts)
        return finalize_iteration_entry(
            state_dir=state_dir,
            log_path=log_path,
            stats_path=stats_path,
            stats=stats,
            entry=entry,
            args=args,
            default_exit_code=1,
        )

    promotion_candidate = promotion_edge if promotion_edge is not None else candidate_edge
    delta = candidate_edge - champion_edge

    # Regression gate: reject candidates with catastrophic regression
    if delta < DEFAULT_SEVERE_REGRESSION_GATE:
        entry = {
            "iter": iteration,
            "ts": utc_now_iso(),
            "status": "regression_rejected",
            "mechanism": mechanism_name,
            "valid": True,
            "delta": delta,
            "edge": candidate_edge,
            "reason": f"severe_regression_delta={delta:.2f}",
            "champion_edge_before": champion_edge,
            "prompt_path": str(prompt_path),
            "candidate_path": str(candidate_path),
            "result_path": str(result_path),
            "wildcard": wildcard,
        }
        if retry_history:
            entry["test_retries"] = {
                "total_attempts": total_retry_attempt,
                "retry_history": retry_history,
            }
        if hypothesis_payload:
            entry["hypothesis"] = hypothesis_payload
        if selection_summary:
            entry["tenet_selection"] = selection_summary
        if iteration_policy_metadata:
            entry["iteration_policy"] = iteration_policy_metadata
        if evaluation_summary:
            entry["evaluation"] = evaluation_summary
        if llm_artifacts:
            entry.update(llm_artifacts)

        tenet_evolution_summary, tenet_evolution_artifacts = run_tenet_evolution(
            iteration=iteration,
            enabled=bool(getattr(args, "tenet_evolution_enabled", True))
            and (bool(getattr(args, "force_tenet_evolution_once", False)) or not bool(args.dry_run)),
            frequency=_int_value(
                getattr(args, "tenet_evolution_frequency", DEFAULT_TENET_EVOLUTION_FREQUENCY),
                default=DEFAULT_TENET_EVOLUTION_FREQUENCY,
            ),
            tenets_payload=tenets_payload,
            evidence_snapshot=build_evidence_snapshot(
                stats=stats,
                log_entries=list(existing_logs) + [entry],
                mechanism_name=mechanism_name,
                seed_offsets=seed_offsets_active,
                shortlist_size=len(mechanism_hypotheses),
            ),
            log_entries=list(existing_logs) + [entry],
            prompts_dir=prompts_dir,
            llm_command=args.llm_command,
            llm_model=args.llm_model,
            llm_timeout_minutes=args.llm_timeout_minutes,
            llm_max_output_tokens=args.llm_max_output_tokens,
            llm_disable_shell_tool=args.llm_disable_shell_tool,
            prompt_dir=prompt_dir,
            tenets_path=tenets_path,
            auto_apply=bool(getattr(args, "tenet_auto_apply", False)),
            force_once=bool(getattr(args, "force_tenet_evolution_once", False)),
        )
        if tenet_evolution_summary:
            append_jsonl(state_dir / DEFAULT_TENET_EVOLUTION_LOG, tenet_evolution_summary)
            entry["tenet_evolution"] = tenet_evolution_summary
            update_tenet_meta_from_proposal(
                tenet_meta=tenet_meta_state,
                proposal=tenet_evolution_summary,
                iteration=iteration,
                applied=bool(tenet_evolution_summary.get("applied", False)),
            )
        for key, value in tenet_evolution_artifacts.items():
            entry[f"tenet_evolution_{key}"] = value
        atomic_write_json(tenet_meta_path, tenet_meta_state)

        # Even though this evaluation is screen-only (non-promotable), it is still a strong negative signal.
        # Count it toward learning stats so selection/prompting does not repeatedly treat the same hypothesis
        # as "untested" after catastrophic regressions.
        if mechanism_name in stats["mechanisms"]:
            m = stats["mechanisms"][mechanism_name]
            mechanism_policy = mechanisms.get(mechanism_name, {})
            penalty_delta = float(max(delta, DEFAULT_SEVERE_REGRESSION_GATE))
            tries_authoritative = _int_value(m.get("tries_authoritative", m.get("tries", 0)), default=0) + 1
            m["tries_authoritative"] = tries_authoritative
            m["tries"] = tries_authoritative
            m["total_uplift"] = _float_value(m.get("total_uplift", 0.0), default=0.0) + penalty_delta
            prev_best = m.get("best_delta")
            if prev_best is None or float(delta) > _float_value(prev_best):
                m["best_delta"] = float(delta)
            m["last_tried"] = utc_now_iso()
            _apply_iteration_policy(
                mechanism_stats=m,
                mechanism_policy=mechanism_policy,
                policy_metadata=iteration_policy_metadata,
                iteration=iteration,
            )
        update_hypothesis_stats(
            stats=stats,
            hypothesis_focus=selected_hypothesis,
            delta=delta,
            authoritative_eval=True,
            improvement_threshold=args.improvement_threshold,
        )
        stats["global"]["total_iterations"] = iteration
        policy_state_path = state_dir / "policy_evolution_state.json"
        policy_state = load_json(policy_state_path, {})
        if not isinstance(policy_state, dict):
            policy_state = {}
        policy_state["tenet_system"] = {
            "enabled": True,
            "selection_llm_enabled": bool(getattr(args, "selection_llm_enabled", True)),
            "tenet_evolution_enabled": bool(getattr(args, "tenet_evolution_enabled", True)),
            "tenet_evolution_frequency": _int_value(
                getattr(args, "tenet_evolution_frequency", DEFAULT_TENET_EVOLUTION_FREQUENCY),
                default=DEFAULT_TENET_EVOLUTION_FREQUENCY,
            ),
            "tenet_auto_apply": bool(getattr(args, "tenet_auto_apply", False)),
            "tenets_file": str(tenets_path),
            "active_seed_offsets": seed_offsets_active,
            "max_seed_offset": max(seed_offsets_active) if seed_offsets_active else 0,
            "last_selection": selection_summary,
            "last_tenet_evolution": tenet_evolution_summary,
            "last_updated_iter": iteration,
        }
        atomic_write_json(policy_state_path, policy_state)
        return finalize_iteration_entry(
            state_dir=state_dir,
            log_path=log_path,
            stats_path=stats_path,
            stats=stats,
            entry=entry,
            args=args,
            default_exit_code=1,
            apply_rollback_policy=False,
        )

    promoted = False
    if authoritative_eval and promotion_candidate > champion_edge:
        # Archive outgoing champion to history before overwriting
        max_history = getattr(args, "champion_history_max", DEFAULT_CHAMPION_HISTORY_MAX)
        archive_champion(
            state_dir=state_dir,
            champion_code=champion_code,
            champion_edge=champion_edge,
            champion_name=champion_name,
            iteration=iteration,
            mechanism_name=mechanism_name,
            delta=delta,
            evaluation_summary=evaluation_summary,
            candidate_path=str(candidate_path) if candidate_path else None,
            max_history=max_history,
        )
        # Proceed with promotion
        atomic_write_text(state_dir / ".best_strategy.sol", candidate_code)
        atomic_write_text(state_dir / ".best_edge.txt", f"{promotion_candidate:.2f}\n")
        write_rollback_spine(
            state_dir=state_dir,
            code=candidate_code,
            edge=promotion_candidate,
            source="promotion",
            reason=f"iter_{iteration}:{mechanism_name}",
        )
        promoted = True
        stats["champion"]["edge"] = promotion_candidate
        stats["champion"]["name"] = parse_get_name(candidate_code) or f"iter_{iteration}_champion"
        stats["champion"]["promoted_at"] = utc_now_iso()
        stats["global"]["total_champion_updates"] = int(
            stats["global"].get("total_champion_updates", 0) or 0
        ) + 1
    else:
        stats["champion"]["name"] = champion_name
        stats["champion"]["edge"] = champion_edge

    # Update stats based on iteration type
    if mechanism_name in stats["mechanisms"]:
        m = stats["mechanisms"][mechanism_name]
        mechanism_policy = mechanisms.get(mechanism_name, {})
        tries_authoritative = _int_value(m.get("tries_authoritative", m.get("tries", 0)), default=0)
        if authoritative_eval:
            tries_authoritative += 1
            m["total_uplift"] = _float_value(m.get("total_uplift", 0.0), default=0.0) + delta
            if delta > args.improvement_threshold:
                m["successes"] = _int_value(m.get("successes", 0), default=0) + 1
            prev_best = m.get("best_delta")
            if prev_best is None or delta > _float_value(prev_best):
                m["best_delta"] = delta
        m["tries_authoritative"] = tries_authoritative
        m["tries"] = tries_authoritative
        m["last_tried"] = utc_now_iso()
        _apply_iteration_policy(
            mechanism_stats=m,
            mechanism_policy=mechanism_policy,
            policy_metadata=iteration_policy_metadata,
            iteration=iteration,
        )

    update_hypothesis_stats(
        stats=stats,
        hypothesis_focus=selected_hypothesis,
        delta=delta,
        authoritative_eval=authoritative_eval,
        improvement_threshold=args.improvement_threshold,
    )

    stats["global"]["total_iterations"] = iteration

    entry = {
        "iter": iteration,
        "ts": utc_now_iso(),
        "status": "complete",
        "mechanism": mechanism_name,
        "valid": True,
        "delta": delta,
        "edge": candidate_edge,
        "promotion_edge": promotion_candidate,
        "promoted": promoted,
        "promotable": promotable,
        "authoritative_eval": authoritative_eval,
        "evaluation_source": "dry_run" if bool(args.dry_run) else "pipeline",
        "screen_only_eval": screen_only_eval,
        "wildcard": wildcard,
        "champion_edge_before": champion_edge,
        "prompt_path": str(prompt_path),
        "candidate_path": str(candidate_path),
        "result_path": str(result_path),
    }
    if retry_history:
        entry["test_retries"] = {
            "total_attempts": total_retry_attempt,
            "retry_history": retry_history,
        }
    if selection_summary:
        entry["tenet_selection"] = selection_summary
    if hypothesis_payload:
        entry["hypothesis"] = hypothesis_payload
    if iteration_policy_metadata:
        entry["iteration_policy"] = iteration_policy_metadata
    if validation_warnings:
        entry["validation_warnings"] = validation_warnings
    if evaluation_summary:
        entry["evaluation"] = evaluation_summary
    if llm_artifacts:
        entry.update(llm_artifacts)

    tenet_evolution_summary, tenet_evolution_artifacts = run_tenet_evolution(
        iteration=iteration,
        enabled=bool(getattr(args, "tenet_evolution_enabled", True))
        and (bool(getattr(args, "force_tenet_evolution_once", False)) or not bool(args.dry_run)),
        frequency=_int_value(
            getattr(args, "tenet_evolution_frequency", DEFAULT_TENET_EVOLUTION_FREQUENCY),
            default=DEFAULT_TENET_EVOLUTION_FREQUENCY,
        ),
        tenets_payload=tenets_payload,
        evidence_snapshot=build_evidence_snapshot(
            stats=stats,
            log_entries=list(existing_logs) + [entry],
            mechanism_name=mechanism_name,
            seed_offsets=seed_offsets_active,
            shortlist_size=len(mechanism_hypotheses),
        ),
        log_entries=list(existing_logs) + [entry],
        prompts_dir=prompts_dir,
        llm_command=args.llm_command,
        llm_model=args.llm_model,
        llm_timeout_minutes=args.llm_timeout_minutes,
        llm_max_output_tokens=args.llm_max_output_tokens,
        llm_disable_shell_tool=args.llm_disable_shell_tool,
        prompt_dir=prompt_dir,
        tenets_path=tenets_path,
        auto_apply=bool(getattr(args, "tenet_auto_apply", False)),
        force_once=bool(getattr(args, "force_tenet_evolution_once", False)),
    )
    if tenet_evolution_summary:
        append_jsonl(state_dir / DEFAULT_TENET_EVOLUTION_LOG, tenet_evolution_summary)
        entry["tenet_evolution"] = tenet_evolution_summary
        update_tenet_meta_from_proposal(
            tenet_meta=tenet_meta_state,
            proposal=tenet_evolution_summary,
            iteration=iteration,
            applied=bool(tenet_evolution_summary.get("applied", False)),
        )
    for key, value in tenet_evolution_artifacts.items():
        entry[f"tenet_evolution_{key}"] = value

    atomic_write_json(tenet_meta_path, tenet_meta_state)
    policy_state_path = state_dir / "policy_evolution_state.json"
    policy_state = load_json(policy_state_path, {})
    if not isinstance(policy_state, dict):
        policy_state = {}
    policy_state["tenet_system"] = {
        "enabled": True,
        "selection_llm_enabled": bool(getattr(args, "selection_llm_enabled", True)),
        "tenet_evolution_enabled": bool(getattr(args, "tenet_evolution_enabled", True)),
        "tenet_evolution_frequency": _int_value(
            getattr(args, "tenet_evolution_frequency", DEFAULT_TENET_EVOLUTION_FREQUENCY),
            default=DEFAULT_TENET_EVOLUTION_FREQUENCY,
        ),
        "tenet_auto_apply": bool(getattr(args, "tenet_auto_apply", False)),
        "tenets_file": str(tenets_path),
        "active_seed_offsets": seed_offsets_active,
        "max_seed_offset": max(seed_offsets_active) if seed_offsets_active else 0,
        "last_selection": selection_summary,
        "last_tenet_evolution": tenet_evolution_summary,
        "last_updated_iter": iteration,
    }
    atomic_write_json(policy_state_path, policy_state)
    return finalize_iteration_entry(
        state_dir=state_dir,
        log_path=log_path,
        stats_path=stats_path,
        stats=stats,
        entry=entry,
        args=args,
        default_exit_code=0,
    )


def show_status(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    stats_path = state_dir / "mechanism_stats.json"
    log_path = state_dir / "iteration_log.jsonl"
    policy_state_path = state_dir / "policy_evolution_state.json"
    selection_log_path = state_dir / DEFAULT_HYPOTHESIS_SELECTION_LOG
    tenet_evolution_log_path = state_dir / DEFAULT_TENET_EVOLUTION_LOG
    tenet_meta_path = state_dir / DEFAULT_TENET_META_STATE_FILE
    stats = load_json(stats_path, {})
    logs = read_iteration_log(log_path)
    policy_state = load_json(policy_state_path, {})
    tenet_meta_state = load_json(tenet_meta_path, {})
    last_selection_entry = read_last_jsonl_entry(selection_log_path)
    last_tenet_evolution_entry = read_last_jsonl_entry(tenet_evolution_log_path)

    if not stats:
        print(_json_out({"status": "uninitialized", "state_dir": str(state_dir)}))
        return 0

    rollback_spine = load_rollback_spine(state_dir)
    tenet_system = policy_state.get("tenet_system") if isinstance(policy_state, dict) else {}
    tenet_system = tenet_system if isinstance(tenet_system, dict) else {}
    active_seed_offsets = tenet_system.get("active_seed_offsets")
    if isinstance(active_seed_offsets, list):
        seed_offsets = [_int_value(value, default=0) for value in active_seed_offsets]
        seed_offsets = [value for value in seed_offsets if 0 <= value <= 10000]
        if not seed_offsets:
            seed_offsets = parse_seed_offsets(DEFAULT_SEED_OFFSETS)
    else:
        seed_offsets = parse_seed_offsets(DEFAULT_SEED_OFFSETS)
    payload = {
        "state_dir": str(state_dir),
        "schema_version": stats.get("schema_version"),
        "champion": stats.get("champion", {}),
        "global": stats.get("global", {}),
        "mechanism_stats": stats.get("mechanisms", {}),
        "hypothesis_stats": stats.get("hypotheses", {}),
        "log_entries": len(logs),
        "last_entry": logs[-1] if logs else None,
        "policy_evolution": policy_state if isinstance(policy_state, dict) else {},
        "tenet_meta_state": tenet_meta_state if isinstance(tenet_meta_state, dict) else {},
        "last_hypothesis_selection": tenet_system.get("last_selection") or last_selection_entry,
        "last_tenet_evolution": tenet_system.get("last_tenet_evolution") or last_tenet_evolution_entry,
        "tenet_auto_apply": bool(tenet_system.get("tenet_auto_apply", False)),
        "active_seed_policy": {
            "offsets": seed_offsets,
            "max_seed_offset": max(seed_offsets) if seed_offsets else 0,
        },
        "rollback_spine": rollback_spine if rollback_spine is not None else {"present": False},
    }
    print(_json_out(payload))
    return 0


def run_loop(args: argparse.Namespace) -> int:
    count = args.iterations
    sleep_seconds = args.sleep_seconds
    for i in range(count):
        run_code = run_iteration(args)
        if run_code != 0 and not bool(args.continue_on_error):
            return run_code
        if bool(args.shadow_script):
            shadow_cmd = [args.python_exe, str(args.shadow_script), "--state-dir", str(args.state_dir)]
            if args.shadow_snapshot_dir:
                shadow_cmd += ["--snapshot-dir", str(args.shadow_snapshot_dir)]
            shadow_cmd += ["--iteration", str(i + 1)]
            subprocess.run(shadow_cmd, check=False)
        if i + 1 < count and sleep_seconds > 0:
            time.sleep(sleep_seconds)
    return 0


def rollback_check(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    stats_path = state_dir / "mechanism_stats.json"
    log_path = state_dir / "iteration_log.jsonl"
    stats = load_json(stats_path, {})
    if not stats:
        print(_json_out({"status": "uninitialized"}))
        return 0
    logs = read_iteration_log(log_path)
    reason = update_rollback_status(
        stats,
        logs,
        args.rollback_consecutive_invalid,
        args.rollback_severe_regression,
        args.rollback_cumulative_loss,
        args.rollback_window,
    )
    atomic_write_json(stats_path, stats)
    payload = {
        "rollback_triggered": bool(stats.get("global", {}).get("rollback_triggered")),
        "rollback_reason": stats.get("global", {}).get("rollback_reason"),
        "evaluated_reason": reason,
    }
    print(_json_out(payload))
    if bool(args.apply) and payload["rollback_triggered"]:
        meta = perform_rollback(
            state_dir=state_dir,
            reason=payload["rollback_reason"],
            archive_only=False,
            restore_mode=args.rollback_restore_mode,
            allow_snapshot_fallback=bool(args.rollback_allow_snapshot_fallback),
        )
        print(_json_out({"status": "rolled_back", **meta}))
    return 0


def force_rollback(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    meta = perform_rollback(
        state_dir=state_dir,
        reason=args.reason,
        archive_only=bool(args.archive_only),
        restore_mode=args.rollback_restore_mode,
        allow_snapshot_fallback=bool(args.rollback_allow_snapshot_fallback),
    )
    print(_json_out({"status": "rolled_back", **meta}))
    return 0


def pin_spine(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    code, edge, _name = load_champion(state_dir)
    payload = write_rollback_spine(
        state_dir=state_dir,
        code=code,
        edge=edge,
        source="manual_pin",
        reason=args.reason,
    )
    print(_json_out({"status": "spine_pinned", **payload}))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Simplified champion-centric Phase 7 loop")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_state_dir_arg(target: argparse.ArgumentParser) -> None:
        target.add_argument("--state-dir", default=".ralph-amm/phase7/state")

    def add_rollback_threshold_args(target: argparse.ArgumentParser) -> None:
        target.add_argument("--rollback-consecutive-invalid", type=int, default=DEFAULT_ROLLBACK_CONSECUTIVE_INVALID)
        target.add_argument("--rollback-severe-regression", type=float, default=DEFAULT_ROLLBACK_SEVERE_REGRESSION)
        target.add_argument("--rollback-cumulative-loss", type=float, default=DEFAULT_ROLLBACK_CUMULATIVE_LOSS)
        target.add_argument("--rollback-window", type=int, default=DEFAULT_ROLLBACK_WINDOW)

    def add_rollback_restore_args(target: argparse.ArgumentParser) -> None:
        target.add_argument(
            "--rollback-restore-mode",
            choices=list(ROLLBACK_RESTORE_MODES),
            default=DEFAULT_ROLLBACK_RESTORE_MODE,
        )
        target.add_argument(
            "--rollback-allow-snapshot-fallback",
            action="store_true",
            default=DEFAULT_ROLLBACK_ALLOW_SNAPSHOT_FALLBACK,
        )

    def add_common(run_parser: argparse.ArgumentParser) -> None:
        add_state_dir_arg(run_parser)
        run_parser.add_argument(
            "--definitions",
            default=".ralph-amm/phase7/config/mechanism_definitions.json",
        )
        for flag, arg_type, default in (
            ("--exploration-c", float, DEFAULT_EXPLORATION_C),
            ("--improvement-threshold", float, DEFAULT_IMPROVEMENT_THRESHOLD),
            ("--max-retries-on-invalid", int, DEFAULT_MAX_RETRIES_ON_INVALID),
            ("--wildcard-frequency", int, DEFAULT_WILDCARD_FREQUENCY),
        ):
            run_parser.add_argument(flag, type=arg_type, default=default)
        run_parser.add_argument(
            "--champion-history-max",
            type=int,
            default=DEFAULT_CHAMPION_HISTORY_MAX,
            help="Max champions to keep in history (0=unlimited)",
        )
        run_parser.add_argument("--seed", type=int, default=7)
        add_rollback_threshold_args(run_parser)
        add_rollback_restore_args(run_parser)
        run_parser.add_argument("--auto-rollback", action="store_true")
        for flag, arg_type, default in (("--python-exe", str, "auto"), ("--screen-sims", int, 100)):
            if arg_type is str:
                run_parser.add_argument(flag, default=default)
            else:
                run_parser.add_argument(flag, type=arg_type, default=default)
        run_parser.add_argument("--dry-run", action="store_true")
        run_parser.add_argument("--candidate-file")
        run_parser.add_argument("--llm-command", default=DEFAULT_LLM_COMMAND)
        run_parser.add_argument("--llm-model", default=DEFAULT_LLM_MODEL)
        run_parser.add_argument("--llm-timeout-minutes", type=float, default=DEFAULT_LLM_TIMEOUT_MINUTES)
        run_parser.add_argument("--llm-max-output-tokens", type=int, default=DEFAULT_LLM_MAX_OUTPUT_TOKENS)
        run_parser.add_argument("--llm-disable-shell-tool", action="store_true")
        run_parser.add_argument("--tenets-file", default=DEFAULT_TENETS_FILE)
        run_parser.add_argument(
            "--selection-llm-enabled",
            dest="selection_llm_enabled",
            action="store_true",
            default=True,
        )
        run_parser.add_argument(
            "--selection-llm-disabled",
            dest="selection_llm_enabled",
            action="store_false",
        )
        run_parser.add_argument("--selection-top-k", type=int, default=DEFAULT_SELECTION_TOP_K)
        run_parser.add_argument(
            "--tenet-evolution-enabled",
            dest="tenet_evolution_enabled",
            action="store_true",
            default=True,
        )
        run_parser.add_argument(
            "--tenet-evolution-disabled",
            dest="tenet_evolution_enabled",
            action="store_false",
        )
        run_parser.add_argument(
            "--tenet-evolution-frequency",
            type=int,
            default=DEFAULT_TENET_EVOLUTION_FREQUENCY,
        )
        run_parser.add_argument("--tenet-auto-apply", action="store_true")
        run_parser.add_argument(
            "--force-tenet-evolution-once",
            action="store_true",
            help="Force one tenet-evolution execution this run regardless of cadence.",
        )
        run_parser.add_argument(
            "--hypotheses-file",
            default="",
            help=(
                "Optional JSON hypothesis backlog file. "
                f"Defaults to <state-dir>/{DEFAULT_HYPOTHESES_FILENAME} when omitted."
            ),
        )
        run_parser.add_argument("--seed-offsets", default=DEFAULT_SEED_OFFSETS)
        run_parser.add_argument("--promotion-std-penalty", type=float, default=DEFAULT_PROMOTION_STD_PENALTY)

    run_once = sub.add_parser("run-once", help="Run one simplified loop iteration")
    add_common(run_once)
    run_once.set_defaults(func=run_iteration)

    run_many = sub.add_parser("run-loop", help="Run multiple simplified loop iterations")
    add_common(run_many)
    run_many.add_argument("--iterations", type=int, default=10)
    run_many.add_argument("--sleep-seconds", type=float, default=0.0)
    run_many.add_argument("--continue-on-error", action="store_true")
    run_many.add_argument("--shadow-script", default="scripts/shadow_selector.py")
    run_many.add_argument("--shadow-snapshot-dir")
    run_many.set_defaults(func=run_loop)

    status = sub.add_parser("status", help="Show simplified loop status")
    add_state_dir_arg(status)
    status.set_defaults(func=show_status)

    rollback_check_parser = sub.add_parser("rollback-check", help="Evaluate rollback triggers")
    add_state_dir_arg(rollback_check_parser)
    add_rollback_threshold_args(rollback_check_parser)
    add_rollback_restore_args(rollback_check_parser)
    rollback_check_parser.add_argument("--apply", action="store_true")
    rollback_check_parser.set_defaults(func=rollback_check)

    rollback_parser = sub.add_parser("rollback", help="Force rollback using configured restore target")
    add_state_dir_arg(rollback_parser)
    rollback_parser.add_argument("--reason", required=True)
    rollback_parser.add_argument("--archive-only", action="store_true")
    add_rollback_restore_args(rollback_parser)
    rollback_parser.set_defaults(func=force_rollback)

    pin_spine_parser = sub.add_parser("pin-spine", help="Pin rollback spine from current champion")
    add_state_dir_arg(pin_spine_parser)
    pin_spine_parser.add_argument("--reason", default="manual_pin")
    pin_spine_parser.set_defaults(func=pin_spine)

    # Champion history subcommand with sub-subcommands
    history_parser = sub.add_parser("champion-history", help="Manage champion history")
    history_sub = history_parser.add_subparsers(dest="history_command", required=True)

    history_list = history_sub.add_parser("list", help="List champions in history")
    add_state_dir_arg(history_list)
    history_list.add_argument("--json", action="store_true", help="Output as JSON")
    history_list.set_defaults(func=champion_history_list)

    history_show = history_sub.add_parser("show", help="Show champion details")
    add_state_dir_arg(history_show)
    history_show.add_argument("--sequence", type=int, required=True)
    history_show.set_defaults(func=champion_history_show)

    history_revert = history_sub.add_parser("revert", help="Revert to historical champion")
    add_state_dir_arg(history_revert)
    history_revert.add_argument("--sequence", type=int, required=True)
    history_revert.add_argument("--reason", required=True)
    history_revert.add_argument("--champion-history-max", type=int, default=DEFAULT_CHAMPION_HISTORY_MAX)
    history_revert.set_defaults(func=champion_history_revert)

    bootstrap = sub.add_parser("bootstrap", help="Evaluate candidate backbones and install winner")
    add_state_dir_arg(bootstrap)
    bootstrap.add_argument(
        "--definitions",
        default=".ralph-amm/phase7/config/mechanism_definitions.json",
    )
    bootstrap.add_argument(
        "--install-definitions",
        default=".ralph-amm/phase7/config/mechanism_definitions_bandshield.json",
    )
    bootstrap.add_argument("--from", dest="from_paths", action="append")
    bootstrap.add_argument("--python-exe", default="auto")
    bootstrap.add_argument("--screen-sims", type=int, default=200)
    bootstrap.add_argument("--seed-offsets", default=DEFAULT_BOOTSTRAP_SEED_OFFSETS)
    bootstrap.add_argument("--promotion-std-penalty", type=float, default=DEFAULT_PROMOTION_STD_PENALTY)
    for flag, arg_type, default in (
        ("--exploration-c", float, DEFAULT_EXPLORATION_C),
        ("--improvement-threshold", float, DEFAULT_IMPROVEMENT_THRESHOLD),
        ("--max-retries-on-invalid", int, DEFAULT_MAX_RETRIES_ON_INVALID),
        ("--wildcard-frequency", int, DEFAULT_WILDCARD_FREQUENCY),
    ):
        bootstrap.add_argument(flag, type=arg_type, default=default)
    bootstrap.add_argument(
        "--champion-history-max",
        type=int,
        default=DEFAULT_CHAMPION_HISTORY_MAX,
        help="Max champions to keep in history (0=unlimited)",
    )
    bootstrap.set_defaults(func=bootstrap_champion)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if hasattr(args, "python_exe"):
        if not args.python_exe or args.python_exe == "auto":
            args.python_exe = sys.executable
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
