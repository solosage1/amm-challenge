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
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple


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
DEFAULT_SEED_OFFSETS = "0"
DEFAULT_BOOTSTRAP_SEED_OFFSETS = "0,10000,20000"
DEFAULT_PROMOTION_STD_PENALTY = 0.5
DEFAULT_HYPOTHESES_FILENAME = "hypotheses_backlog.json"
DEFAULT_HYPOTHESIS_RECENT_WINDOW = 20
DEFAULT_HYPOTHESIS_NEAR_DUP_DELTA = 0.01
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

{dont_pursue_block}

{iteration_governor_block}

{iteration_policy_metadata_block}

## CONSTRAINTS
1. Output a complete, compilable Solidity contract
2. Keep contract declaration as `contract Strategy`
3. Set getName() return value to "{variant_name}"
4. Keep interface compatibility (afterInitialize, afterSwap, getName)

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
            offsets.append(int(value))
        except ValueError:
            continue
    return offsets if offsets else [0]


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


def build_wildcard_prompt(champion_code: str, variant_name: str) -> str:
    return WILDCARD_PROMPT_TEMPLATE.format(
        champion_code=champion_code,
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
) -> str:
    if wildcard:
        return build_wildcard_prompt(
            champion_code=champion_code,
            variant_name=f"wildcard_mod_v{iteration}",
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
    )


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

    mechanism_name, wildcard = _select_iteration_mechanism(
        iteration=iteration,
        stats=stats,
        mechanisms=mechanisms,
        exploration_c=args.exploration_c,
        wildcard_frequency=args.wildcard_frequency,
        rng=rng,
    )
    mechanism_hypotheses = hypotheses_for_mechanism(hypotheses, mechanism_name) if not wildcard else []
    # Keep shortlist order non-deterministic to reduce anchoring bias in LLM selection.
    if len(mechanism_hypotheses) > 1:
        SYSTEM_RANDOM.shuffle(mechanism_hypotheses)
    existing_logs = read_iteration_log(log_path)
    hypothesis_recent = (
        summarize_hypothesis_recent_history(
            existing_logs,
            mechanism_name=mechanism_name,
            window=DEFAULT_HYPOTHESIS_RECENT_WINDOW,
        )
        if not wildcard
        else None
    )

    candidate_code = ""
    prompt_path = prompt_dir / f"iter_{iteration}_{mechanism_name.replace(':', '_')}.md"
    candidate_path = candidate_dir / f"iter_{iteration}_{mechanism_name.replace(':', '_')}.sol"
    llm_artifacts: Dict[str, str] = {}
    iteration_policy_metadata: Optional[Dict[str, Any]] = None
    selected_hypothesis: Optional[Dict[str, Any]] = None
    hypothesis_payload: Optional[Dict[str, Any]] = None

    prompt_text = _build_iteration_prompt(
        champion_code=champion_code,
        mechanism_name=mechanism_name,
        mechanisms=mechanisms,
        iteration=iteration,
        wildcard=wildcard,
        hypothesis_shortlist=mechanism_hypotheses,
        hypothesis_tracker=stats.get("hypotheses"),
        hypothesis_recent=hypothesis_recent,
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
    selected_hypothesis = resolve_selected_hypothesis(iteration_policy_metadata, mechanism_hypotheses)
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

    if candidate_edge is None:
        _increment_mechanism_counter(stats, mechanism_name, "compile_fail_count")
        _increment_mechanism_counter(stats, mechanism_name, "invalid_count")
        stats["global"]["total_iterations"] = iteration
        entry = {
            "iter": iteration,
            "ts": utc_now_iso(),
            "status": "compile_failed",
            "mechanism": mechanism_name,
            "valid": False,
            "reason": eval_error or "evaluation_failed",
            "champion_edge_before": champion_edge,
            "prompt_path": str(prompt_path),
            "candidate_path": str(candidate_path),
            "result_path": str(result_path),
        }
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
        if hypothesis_payload:
            entry["hypothesis"] = hypothesis_payload
        if iteration_policy_metadata:
            entry["iteration_policy"] = iteration_policy_metadata
        if evaluation_summary:
            entry["evaluation"] = evaluation_summary
        if llm_artifacts:
            entry.update(llm_artifacts)

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
    stats = load_json(stats_path, {})
    logs = read_iteration_log(log_path)
    policy_state = load_json(policy_state_path, {})

    if not stats:
        print(_json_out({"status": "uninitialized", "state_dir": str(state_dir)}))
        return 0

    rollback_spine = load_rollback_spine(state_dir)
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
