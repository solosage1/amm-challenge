#!/usr/bin/env python3
"""
Phase 7 Opportunity Engine

Incremental autonomous-loop upgrade:
- Discover high-leverage opportunity families from state/log signals
- Generate machine-readable search plans per iteration
- Enforce shadow/canary rollout with non-regression gates and rollback
- Record plan outcomes for iterative learning priors
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from statistics import median
from typing import Any, Dict, List, Optional, Tuple


SCHEMA_VERSION = "1.0"
SEVERE_FAILURE_DELTA = -0.8
DEFAULT_COOLDOWN_ITERS = 4
DEFAULT_NO_UPLIFT_EPSILON = 0.02
DEFAULT_NO_UPLIFT_STREAK_THRESHOLD = 3
DEFAULT_NOVELTY_LOOKBACK = 6
DEFAULT_NOVELTY_PENALTY = 1.0
DEFAULT_EXPLORE_LOOKBACK = 4
DEFAULT_EXPLORE_REPEAT_CLASSES = {"undercut_sweep", "gating_adaptive"}
DEFAULT_EXPLORE_TARGET_CLASSES = {"gamma_formula", "asymmetric", "ema_smoothing"}
DEFAULT_BREAKTHROUGH_TIE_EPSILON = 0.10
DEFAULT_SEVERE_SUBFAMILY_FAILURE_THRESHOLD = 2
DEFAULT_GATES_FALLBACK_POLLS = 8
DEFAULT_GATES_FALLBACK_POLL_SECONDS = 0.25

FAMILY_CLASS_BY_ID = {
    "adaptive_undercut_search": "undercut_sweep",
    "regime_state_transition_search": "gating_adaptive",
    "parallel_parameter_beam": "gating_adaptive",
    "robustness_repair_search": "ema_smoothing",
    "gamma_formula_search": "gamma_formula",
    "ema_smoothing_search": "ema_smoothing",
    "asymmetric_bid_ask_search": "asymmetric",
}

SUBFAMILY_CATALOG_BY_ID = {
    "adaptive_undercut_search": [
        "plain_undercut",
        "mispricing_gate",
        "step_aware_undercut",
        "flow_burst_memory",
    ],
    "regime_state_transition_search": [
        "light_state_machine",
        "heavy_state_machine",
    ],
    "parallel_parameter_beam": ["parameter_beam"],
    "robustness_repair_search": ["spread_stabilizer"],
    "gamma_formula_search": ["gamma_transform"],
    "ema_smoothing_search": ["ema_smoothing"],
    "asymmetric_bid_ask_search": ["bid_ask_asymmetry"],
}


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


def atomic_write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    tmp.replace(path)


def safe_float(value: Any) -> Optional[float]:
    try:
        if value is None:
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


def clamp(v: float, low: float = 0.0, high: float = 10.0) -> float:
    return max(low, min(high, v))


def family_class(opportunity_id: str) -> str:
    return FAMILY_CLASS_BY_ID.get(opportunity_id, "unknown")


def parse_csv_set(value: Optional[str]) -> set[str]:
    if not value:
        return set()
    return {x.strip() for x in str(value).split(",") if x.strip()}


def opportunity_subfamilies(opportunity_id: str) -> List[str]:
    vals = SUBFAMILY_CATALOG_BY_ID.get(opportunity_id)
    if isinstance(vals, list) and vals:
        return list(vals)
    return ["default"]


def default_subfamily_for_opportunity(opportunity_id: str) -> str:
    return opportunity_subfamilies(opportunity_id)[0]


def parse_subfamily_overrides(value: Optional[str]) -> Dict[str, str]:
    out: Dict[str, str] = {}
    raw = (value or "").strip()
    if not raw:
        return out
    for token in raw.split(","):
        tok = token.strip()
        if not tok:
            continue
        if ":" in tok:
            opp, sub = tok.split(":", 1)
            opp = opp.strip()
            sub = sub.strip()
            if opp and sub:
                out[opp] = sub
        elif tok:
            out["*"] = tok
    return out


def parse_subfamily_from_strategy_name(opportunity_id: str, strategy_name: str) -> Optional[str]:
    name = str(strategy_name or "").strip().lower()
    if not name:
        return None
    stem = Path(name).stem
    stem = re.sub(r"_(v|l|r)\d+$", "", stem)

    if opportunity_id == "adaptive_undercut_search":
        if any(tok in stem for tok in ("burst", "bgate", "flow")):
            return "flow_burst_memory"
        if "step" in stem:
            return "step_aware_undercut"
        if any(tok in stem for tok in ("gate", "mode", "regime", "def")):
            return "mispricing_gate"
        if any(tok in stem for tok in ("u", "undercut", "band")):
            return "plain_undercut"
    elif opportunity_id == "regime_state_transition_search":
        if any(tok in stem for tok in ("light", "_l", "lite")):
            return "light_state_machine"
        return "heavy_state_machine"
    elif opportunity_id == "gamma_formula_search":
        return "gamma_transform"
    elif opportunity_id == "ema_smoothing_search":
        return "ema_smoothing"
    elif opportunity_id == "asymmetric_bid_ask_search":
        return "bid_ask_asymmetry"
    elif opportunity_id == "parallel_parameter_beam":
        return "parameter_beam"
    elif opportunity_id == "robustness_repair_search":
        return "spread_stabilizer"

    return None


def subfamily_stats_bucket(priors: Dict[str, Any], opportunity_id: str, subfamily: str) -> Dict[str, Any]:
    opp_bucket = priors.get(opportunity_id)
    if not isinstance(opp_bucket, dict):
        return {}
    sub_map = opp_bucket.get("subfamilies")
    if not isinstance(sub_map, dict):
        return {}
    sub_bucket = sub_map.get(subfamily)
    if not isinstance(sub_bucket, dict):
        return {}
    return sub_bucket


def has_untried_subfamily(priors: Dict[str, Any], opportunity_id: str) -> bool:
    catalog = opportunity_subfamilies(opportunity_id)
    for subfamily in catalog:
        sb = subfamily_stats_bucket(priors, opportunity_id, subfamily)
        attempts = int(sb.get("attempts", 0) or 0)
        if attempts <= 0:
            return True
    return False


def choose_subfamily_for_opportunity(
    *,
    opportunity_id: str,
    priors: Dict[str, Any],
    history: List[Dict[str, Any]],
    iteration: int,
    no_uplift_epsilon: float,
    subfamily_overrides: Dict[str, str],
) -> Tuple[str, str]:
    catalog = opportunity_subfamilies(opportunity_id)
    if not catalog:
        return "default", "default_catalog"

    override = (
        subfamily_overrides.get(opportunity_id)
        or subfamily_overrides.get("*")
        or ""
    )
    if override and override in catalog:
        return override, f"manual_override:{override}"

    recent = recent_executed_history(history, max(8, len(catalog) * 3))
    recent_subfamily_no_uplift: Dict[str, int] = {}
    for entry in recent:
        if str(entry.get("selected_opportunity") or "") != opportunity_id:
            continue
        sub = str(entry.get("selected_subfamily") or "").strip()
        if not sub:
            continue
        flag = delta_is_no_uplift(entry, no_uplift_epsilon)
        if flag is True:
            recent_subfamily_no_uplift[sub] = recent_subfamily_no_uplift.get(sub, 0) + 1

    scored: List[Tuple[float, str, str]] = []
    for sub in catalog:
        sb = subfamily_stats_bucket(priors, opportunity_id, sub)
        attempts = int(sb.get("attempts", 0) or 0)
        successes = int(sb.get("successes", 0) or 0)
        failures = int(sb.get("failures", 0) or 0)
        non_uplift_streak = int(sb.get("non_uplift_streak", 0) or 0)
        cooldown_until = int(sb.get("cooldown_until_iteration", 0) or 0)
        last_attempt = int(sb.get("last_attempt_iteration", 0) or 0)
        probe_hits = int(sb.get("breakthrough_probe_hits", 0) or 0)

        score = 0.0
        reasons: List[str] = []
        if attempts <= 0:
            score += 4.0
            reasons.append("untried")
        if last_attempt > 0 and int(iteration) > last_attempt:
            gap = int(iteration) - last_attempt
            score += min(2.0, gap / 4.0)
        score += 0.75 * float(successes)
        score -= 0.30 * float(failures)
        score -= min(3.0, 0.8 * float(non_uplift_streak))
        if recent_subfamily_no_uplift.get(sub, 0) >= 2:
            score -= 1.5
            reasons.append("recent_no_uplift")
        if cooldown_until >= int(iteration):
            score -= 5.0
            reasons.append(f"cooldown_until_{cooldown_until}")
        if probe_hits > 0:
            score += 1.0
            reasons.append("probe_confirm")

        tie_seed = int(hashlib.sha256(f"{iteration}:{opportunity_id}:{sub}".encode("utf-8")).hexdigest()[:8], 16)
        score += (tie_seed % 1000) * 1e-6
        scored.append((score, sub, ",".join(reasons) if reasons else "balanced"))

    scored.sort(key=lambda x: (-x[0], x[1]))
    best_score, best_sub, best_reason = scored[0]
    if all(int(subfamily_stats_bucket(priors, opportunity_id, s).get("cooldown_until_iteration", 0) or 0) >= int(iteration) for s in catalog):
        return best_sub, f"all_subfamilies_cooldown_select_best:{best_reason}"
    return best_sub, f"policy_select:{best_reason}|score={best_score:.3f}"


def loop_entries(strategies_log: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for e in strategies_log:
        if not isinstance(e, dict):
            continue
        if e.get("source") == "codex_session":
            continue
        out.append(e)
    out.sort(key=lambda x: (int(x.get("iteration", 0) or 0), str(x.get("timestamp", ""))))
    return out


def deterministic_canary(iteration: int, pct: int) -> bool:
    pct = max(0, min(100, int(pct)))
    if pct <= 0:
        return False
    if pct >= 100:
        return True
    digest = hashlib.sha256(str(iteration).encode("utf-8")).hexdigest()
    bucket = int(digest[:8], 16) % 100
    return bucket < pct


def result_payload_from_entry(entry: Dict[str, Any]) -> Dict[str, Any]:
    ap = entry.get("artifact_paths") if isinstance(entry.get("artifact_paths"), dict) else {}
    result_path = Path(str(ap.get("result_path", "")))
    if result_path.exists():
        data = load_json(result_path, {})
        if isinstance(data, dict):
            return data
    return {}


def collect_runtime_seconds(entries: List[Dict[str, Any]]) -> List[float]:
    runtimes: List[float] = []
    for e in entries:
        if e.get("status") != "ok":
            continue
        payload = result_payload_from_entry(e)
        runtime = safe_float((payload.get("runtime") or {}).get("total_seconds"))
        if runtime is not None:
            runtimes.append(runtime)
    return runtimes


def collect_edges(entries: List[Dict[str, Any]]) -> List[float]:
    edges: List[float] = []
    for e in entries:
        if e.get("status") != "ok":
            continue
        v = safe_float(e.get("final_edge"))
        if v is not None:
            edges.append(v)
    return edges


def collect_spreads(entries: List[Dict[str, Any]]) -> List[float]:
    spreads: List[float] = []
    for e in entries:
        if e.get("status") != "ok":
            continue
        payload = result_payload_from_entry(e)
        spread = safe_float(((payload.get("testing") or {}).get("regime_tests") or {}).get("spread"))
        if spread is not None:
            spreads.append(spread)
    return spreads


def success_rate(entries: List[Dict[str, Any]]) -> float:
    if not entries:
        return 1.0
    ok = sum(1 for e in entries if e.get("status") == "ok")
    return ok / len(entries)


def median_or_none(values: List[float]) -> Optional[float]:
    if not values:
        return None
    return float(median(values))


def analyze_signals(entries: List[Dict[str, Any]], window_size: int) -> Dict[str, Any]:
    recent = entries[-max(1, window_size):]
    recent_ok = [e for e in recent if e.get("status") == "ok"]
    edges = collect_edges(recent_ok)
    spreads = collect_spreads(recent_ok)

    plateau_strength = 0.0
    if len(edges) >= 5:
        span = max(edges) - min(edges)
        slope = (edges[-1] - edges[0]) / max(1, len(edges) - 1)
        span_term = clamp((2.0 - span) / 2.0, 0.0, 1.0)
        slope_term = clamp((0.15 - max(0.0, slope)) / 0.15, 0.0, 1.0)
        plateau_strength = clamp((0.6 * span_term + 0.4 * slope_term) * 10.0, 0.0, 10.0)

    brittleness_strength = 0.0
    if spreads:
        med_spread = median(spreads)
        max_spread = max(spreads)
        med_term = clamp((med_spread - 35.0) / 30.0, 0.0, 1.0)
        max_term = clamp((max_spread - 50.0) / 30.0, 0.0, 1.0)
        brittleness_strength = clamp((0.5 * med_term + 0.5 * max_term) * 10.0, 0.0, 10.0)

    sweep_like = 0
    sweep_improving = 0
    best_so_far = None
    for e in recent_ok:
        name = str(e.get("strategy_name", "")).lower()
        edge = safe_float(e.get("final_edge"))
        if edge is None:
            continue
        if any(tok in name for tok in ("sweep", "_t", "buf", "jump")):
            sweep_like += 1
            if best_so_far is None or edge > best_so_far + 0.5:
                sweep_improving += 1
        if best_so_far is None or edge > best_so_far:
            best_so_far = edge

    sweep_failure_strength = 0.0
    if sweep_like >= 4:
        success_frac = sweep_improving / max(1, sweep_like)
        sweep_failure_strength = clamp((1.0 - success_frac) * 10.0, 0.0, 10.0)

    return {
        "window_size": len(recent),
        "ok_count": len(recent_ok),
        "success_rate": success_rate(recent),
        "median_runtime_seconds": median_or_none(collect_runtime_seconds(recent)),
        "guardrail_failures": sum(
            1
            for e in recent
            if isinstance(e.get("error"), dict) and e.get("error", {}).get("stage") == "knowledge_guardrail"
        ),
        "plateau_strength": round(plateau_strength, 3),
        "brittleness_strength": round(brittleness_strength, 3),
        "sweep_failure_strength": round(sweep_failure_strength, 3),
    }


@dataclass
class Candidate:
    id: str
    family_class: str
    rationale: str
    expected_uplift: float
    confidence: float
    time_to_signal: float
    complexity: float
    overfit_risk: float
    weighted_score: float


def weighted_score(uplift: float, confidence: float, time_to_signal: float, complexity: float, overfit_risk: float) -> float:
    # Weights from user prompt:
    # uplift 35%, confidence 25%, time-to-signal 15%, complexity (lower better) 10%, overfit risk (lower better) 15%
    score = (
        0.35 * clamp(uplift)
        + 0.25 * clamp(confidence)
        + 0.15 * clamp(time_to_signal)
        + 0.10 * clamp(10.0 - complexity)
        + 0.15 * clamp(10.0 - overfit_risk)
    )
    return round(score * 10.0, 3)  # 0..100 scale


def recent_executed_history(history: List[Dict[str, Any]], lookback: int) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for entry in history:
        if not isinstance(entry, dict):
            continue
        if not bool(entry.get("execute_this_iteration", False)):
            continue
        out.append(entry)
    out.sort(
        key=lambda x: (
            int(x.get("iteration", 0) or 0),
            str(x.get("recorded_at") or ""),
        )
    )
    return out[-max(1, int(lookback)) :]


def delta_is_no_uplift(entry: Dict[str, Any], epsilon: float) -> Optional[bool]:
    delta = safe_float(entry.get("delta_vs_reference"))
    if delta is None:
        return None
    return bool(delta <= epsilon)


def summarize_history_by_opportunity(
    history: List[Dict[str, Any]],
    lookback: int,
    no_uplift_epsilon: float,
) -> Dict[str, Dict[str, int]]:
    summary: Dict[str, Dict[str, int]] = {}
    for entry in recent_executed_history(history, lookback):
        opp = entry.get("selected_opportunity")
        if not isinstance(opp, str) or not opp:
            continue
        bucket = summary.setdefault(opp, {"attempts": 0, "uplift": 0, "no_uplift": 0, "unknown": 0})
        bucket["attempts"] += 1
        flag = delta_is_no_uplift(entry, no_uplift_epsilon)
        if flag is None:
            bucket["unknown"] += 1
        elif flag:
            bucket["no_uplift"] += 1
        else:
            bucket["uplift"] += 1
    return summary


def should_force_orthogonal(
    history: List[Dict[str, Any]],
    lookback: int,
    no_uplift_epsilon: float,
    repeat_classes: set[str],
) -> bool:
    recent = recent_executed_history(history, lookback)
    if len(recent) < max(1, int(lookback)):
        return False
    for entry in recent:
        opp = entry.get("selected_opportunity")
        if not isinstance(opp, str) or not opp:
            return False
        if family_class(opp) not in repeat_classes:
            return False
        flag = delta_is_no_uplift(entry, no_uplift_epsilon)
        if flag is not True:
            return False
    return True


def build_candidates(
    signals: Dict[str, Any],
    priors: Dict[str, Any],
    history: List[Dict[str, Any]],
    iteration: int,
    *,
    novelty_lookback: int,
    novelty_penalty: float,
    no_uplift_epsilon: float,
) -> List[Candidate]:
    p = safe_float(signals.get("plateau_strength")) or 0.0
    b = safe_float(signals.get("brittleness_strength")) or 0.0
    s = safe_float(signals.get("sweep_failure_strength")) or 0.0

    history_summary = summarize_history_by_opportunity(
        history=history,
        lookback=novelty_lookback,
        no_uplift_epsilon=no_uplift_epsilon,
    )

    prior_adj = {}
    for key in (
        "regime_state_transition_search",
        "adaptive_undercut_search",
        "robustness_repair_search",
        "parallel_parameter_beam",
        "gamma_formula_search",
        "ema_smoothing_search",
        "asymmetric_bid_ask_search",
    ):
        prior = priors.get(key, {})
        succ = int(prior.get("successes", 0) or 0)
        fail = int(prior.get("failures", 0) or 0)
        denom = max(1, succ + fail)
        prior_adj[key] = ((succ / denom) - 0.5) * 1.5  # -0.75..+0.75

    cands: List[Candidate] = []
    cands.append(
        Candidate(
            id="regime_state_transition_search",
            family_class=family_class("regime_state_transition_search"),
            rationale="Plateau/brittleness suggest structure-level transition logic is under-optimized.",
            expected_uplift=clamp(5.5 + 0.30 * p + 0.10 * b + prior_adj["regime_state_transition_search"]),
            confidence=clamp(5.0 + 0.25 * p + prior_adj["regime_state_transition_search"]),
            time_to_signal=6.0,
            complexity=6.0,
            overfit_risk=clamp(5.0 + 0.20 * b),
            weighted_score=0.0,
        )
    )
    cands.append(
        Candidate(
            id="adaptive_undercut_search",
            family_class=family_class("adaptive_undercut_search"),
            rationale="Undercut signal is strong; prefer lightweight regime-aware undercut before heavy state-machine logic.",
            expected_uplift=clamp(4.8 + 0.20 * p + 0.10 * s + prior_adj["adaptive_undercut_search"]),
            confidence=clamp(6.0 + 0.15 * p + prior_adj["adaptive_undercut_search"]),
            time_to_signal=8.0,
            complexity=3.0,
            overfit_risk=4.0,
            weighted_score=0.0,
        )
    )
    cands.append(
        Candidate(
            id="robustness_repair_search",
            family_class=family_class("robustness_repair_search"),
            rationale="Spread instability indicates robust-score improvements may unlock reliable gains.",
            expected_uplift=clamp(3.5 + 0.35 * b + prior_adj["robustness_repair_search"]),
            confidence=clamp(4.5 + 0.30 * b + prior_adj["robustness_repair_search"]),
            time_to_signal=7.0,
            complexity=5.0,
            overfit_risk=3.0,
            weighted_score=0.0,
        )
    )
    cands.append(
        Candidate(
            id="parallel_parameter_beam",
            family_class=family_class("parallel_parameter_beam"),
            rationale="If sweep throughput is bottlenecked, parallel beams can improve search efficiency.",
            expected_uplift=clamp(2.5 + 0.25 * s + prior_adj["parallel_parameter_beam"]),
            confidence=6.0,
            time_to_signal=9.0,
            complexity=4.0,
            overfit_risk=6.0,
            weighted_score=0.0,
        )
    )
    cands.append(
        Candidate(
            id="gamma_formula_search",
            family_class=family_class("gamma_formula_search"),
            rationale="Local sweep stagnation suggests changing competitive/protective gamma math itself.",
            expected_uplift=clamp(4.2 + 0.25 * p + 0.15 * b + prior_adj["gamma_formula_search"]),
            confidence=clamp(4.6 + 0.20 * p + prior_adj["gamma_formula_search"]),
            time_to_signal=6.5,
            complexity=7.0,
            overfit_risk=4.0,
            weighted_score=0.0,
        )
    )
    cands.append(
        Candidate(
            id="ema_smoothing_search",
            family_class=family_class("ema_smoothing_search"),
            rationale="Fair-value smoothing/jump-limiter dynamics are likely under-tuned near the local optimum.",
            expected_uplift=clamp(3.8 + 0.20 * p + 0.30 * b + prior_adj["ema_smoothing_search"]),
            confidence=clamp(4.8 + 0.20 * b + prior_adj["ema_smoothing_search"]),
            time_to_signal=7.0,
            complexity=5.0,
            overfit_risk=3.5,
            weighted_score=0.0,
        )
    )
    cands.append(
        Candidate(
            id="asymmetric_bid_ask_search",
            family_class=family_class("asymmetric_bid_ask_search"),
            rationale="Directional asymmetry can create edge where symmetric undercut sweeps plateau.",
            expected_uplift=clamp(4.0 + 0.20 * p + 0.20 * s + prior_adj["asymmetric_bid_ask_search"]),
            confidence=clamp(4.7 + 0.15 * p + prior_adj["asymmetric_bid_ask_search"]),
            time_to_signal=7.5,
            complexity=6.0,
            overfit_risk=4.2,
            weighted_score=0.0,
        )
    )

    for c in cands:
        prior = priors.get(c.id, {}) if isinstance(priors.get(c.id), dict) else {}
        cooldown_until = int(prior.get("cooldown_until_iteration", 0) or 0)
        if cooldown_until >= int(iteration):
            remaining = cooldown_until - int(iteration) + 1
            c.expected_uplift = clamp(c.expected_uplift - 3.0)
            c.confidence = clamp(c.confidence - 4.0)
            c.rationale = (
                f"{c.rationale} [cooldown active: {remaining} iteration(s), until {cooldown_until}]"
            )

        # Apply novelty penalty when repeated recent attempts produced no uplift.
        h = history_summary.get(c.id, {})
        attempts = int(h.get("attempts", 0) or 0)
        no_uplift = int(h.get("no_uplift", 0) or 0)
        if attempts >= 2 and no_uplift >= 2:
            if has_untried_subfamily(priors, c.id):
                c.rationale = (
                    f"{c.rationale} [novelty hold: {no_uplift}/{attempts} no-uplift attempts, "
                    "but untried subfamily remains]"
                )
            else:
                penalty = min(3.0, float(novelty_penalty) * float(no_uplift))
                c.expected_uplift = clamp(c.expected_uplift - 0.5 * penalty)
                c.confidence = clamp(c.confidence - penalty)
                c.rationale = (
                    f"{c.rationale} [novelty penalty: {penalty:.2f}; "
                    f"{no_uplift}/{attempts} recent attempts had no uplift]"
                )

        c.weighted_score = weighted_score(
            c.expected_uplift, c.confidence, c.time_to_signal, c.complexity, c.overfit_risk
        )

    cands.sort(key=lambda x: (-x.weighted_score, x.id))
    return cands


def default_plan_template(opportunity_id: str, target_edge: float, reference_best: float) -> Dict[str, Any]:
    if opportunity_id == "regime_state_transition_search":
        return {
            "frozen_core": [
                "gamma^2 competitive anchoring",
                "strict protective-side buffer",
                "mild timestamp-aware tightening in tight regime",
            ],
            "mutation_dimensions": [
                "lightweight mode gate over mispricing first (avoid heavy inventory/cooldown coupling)",
                "3-state mode machine (NORMAL/DEFENSIVE/RECOVERY) only if lightweight gate passes",
                "entry/exit hysteresis thresholds",
                "cooldown lengths",
                "inventory-trigger thresholds",
                "mispricing-trigger thresholds",
                "competitive_undercut_bps (8-12) by mode",
            ],
            "run_budget": {"variants": 10, "parallel_workers": 4, "authoritative_sims": 1000},
            "promotion_criteria": {
                "median_delta_vs_reference": 3.0,
                "worst_case_delta_vs_reference": 1.0,
                "required_repeats": 3,
            },
            "kill_criteria": {
                "first_run_delta_below": -1.0,
                "max_allowed_spread": 60.0,
                "abort_family_if_first_4_below_reference_by": 0.8,
                "abort_family_if_batch_best_below_reference_by": 0.5,
            },
            "fallback_strategy": {"action": "retain_champion", "strategy_edge": reference_best},
        }
    if opportunity_id == "adaptive_undercut_search":
        return {
            "frozen_core": [
                "gamma^2 competitive anchoring",
                "strict protective-side buffer",
                "single-step fair update logic",
            ],
            "mutation_dimensions": [
                "competitive_undercut_bps sweep (8-13)",
                "tight_band_bps sweep (24-29)",
                "minimal 2-state mispricing gate (NORMAL/DEFENSIVE)",
                "protective_buffer_bps sweep (0-2)",
            ],
            "run_budget": {"variants": 10, "parallel_workers": 4, "authoritative_sims": 1000},
            "promotion_criteria": {
                "median_delta_vs_reference": 0.3,
                "required_repeats": 3,
                "max_spread": 55.0,
            },
            "kill_criteria": {
                "abort_family_if_first_4_below_reference_by": 0.8,
                "abort_family_if_batch_best_below_reference_by": 0.5,
                "first_run_delta_below": -1.0,
            },
            "fallback_strategy": {"action": "retain_champion", "strategy_edge": reference_best},
        }
    if opportunity_id == "gamma_formula_search":
        return {
            "frozen_core": [
                "tight-band control path",
                "single-step fair update cadence",
                "authoritative 1000-sim validation",
            ],
            "mutation_dimensions": [
                "gamma^2 -> gamma^k competitive anchor variants",
                "protective-side inversion math variants",
                "piecewise gamma transforms by mispricing bucket",
                "small undercut invariants while formula changes",
            ],
            "run_budget": {"variants": 8, "parallel_workers": 4, "authoritative_sims": 1000},
            "promotion_criteria": {
                "median_delta_vs_reference": 0.25,
                "required_repeats": 3,
                "max_spread": 55.0,
            },
            "kill_criteria": {
                "abort_family_if_first_4_below_reference_by": 0.8,
                "abort_family_if_batch_best_below_reference_by": 0.5,
                "first_run_delta_below": -1.0,
            },
            "fallback_strategy": {"action": "retain_champion", "strategy_edge": reference_best},
        }
    if opportunity_id == "ema_smoothing_search":
        return {
            "frozen_core": [
                "gamma^2 competitive anchoring",
                "protective-side buffer defaults",
            ],
            "mutation_dimensions": [
                "fair-price EMA alpha (slow/medium/fast)",
                "jump limiter cap and asymmetry by side",
                "timestamp-step weighting and stabilization logic",
            ],
            "run_budget": {"variants": 8, "parallel_workers": 4, "authoritative_sims": 1000},
            "promotion_criteria": {
                "median_delta_vs_reference": 0.25,
                "required_repeats": 3,
                "max_spread": 50.0,
            },
            "kill_criteria": {
                "abort_family_if_first_4_below_reference_by": 0.8,
                "abort_family_if_batch_best_below_reference_by": 0.5,
                "first_run_delta_below": -1.0,
            },
            "fallback_strategy": {"action": "retain_champion", "strategy_edge": reference_best},
        }
    if opportunity_id == "asymmetric_bid_ask_search":
        return {
            "frozen_core": [
                "fair-value inference pipeline",
                "protective-side safety constraints",
            ],
            "mutation_dimensions": [
                "bid/ask fee asymmetry under identical mispricing",
                "asymmetric undercut ladders by flow type",
                "directional hysteresis on side-specific quotes",
            ],
            "run_budget": {"variants": 10, "parallel_workers": 4, "authoritative_sims": 1000},
            "promotion_criteria": {
                "median_delta_vs_reference": 0.25,
                "required_repeats": 3,
                "max_spread": 55.0,
            },
            "kill_criteria": {
                "abort_family_if_first_4_below_reference_by": 0.8,
                "abort_family_if_batch_best_below_reference_by": 0.5,
                "first_run_delta_below": -1.0,
            },
            "fallback_strategy": {"action": "retain_champion", "strategy_edge": reference_best},
        }
    if opportunity_id == "robustness_repair_search":
        return {
            "frozen_core": ["current best edge mechanics"],
            "mutation_dimensions": [
                "spread-aware dampers",
                "regime-specific fee caps",
                "risk-sensitive transition hysteresis",
            ],
            "run_budget": {"variants": 8, "parallel_workers": 3, "authoritative_sims": 1000},
            "promotion_criteria": {
                "median_delta_vs_reference": 2.0,
                "required_repeats": 3,
                "max_spread": 50.0,
            },
            "kill_criteria": {
                "first_run_delta_below": -1.0,
                "abort_family_if_first_4_below_reference_by": 0.8,
            },
        }
    return {
        "frozen_core": ["existing champion mechanics"],
        "mutation_dimensions": [
            "parallelized parameter beams",
            "coarse-to-fine threshold sweeps",
            "early elimination rules",
        ],
        "run_budget": {"variants": 12, "parallel_workers": 6, "authoritative_sims": 1000},
        "promotion_criteria": {"median_delta_vs_reference": 1.5, "required_repeats": 3},
        "kill_criteria": {
            "first_run_delta_below": -1.0,
            "abort_family_if_first_4_below_reference_by": 0.8,
        },
    }


def update_rollout_state(
    rollout: Dict[str, Any],
    *,
    enabled: bool,
    iteration: int,
    shadow_iters: int,
    canary_pct: int,
    nonreg_window: int,
    entries: List[Dict[str, Any]],
) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    if not isinstance(rollout, dict):
        rollout = {}
    rollout.setdefault("schema_version", SCHEMA_VERSION)
    rollout.setdefault("started_iteration", None)
    rollout.setdefault("feature_enabled", False)
    rollout.setdefault("mode", "off")
    rollout.setdefault("shadow_completed", 0)
    rollout.setdefault("canary_executed", 0)
    rollout.setdefault("baseline_metrics", None)
    rollout.setdefault("non_regression_fail_streak", 0)
    rollout.setdefault("rollback_triggered", False)
    rollout.setdefault("rollback_reason", None)
    rollout.setdefault("last_updated", None)

    rollout["feature_enabled"] = bool(enabled)
    nonreg = {"ok": True, "reasons": [], "current": None, "baseline": rollout.get("baseline_metrics")}

    if not enabled:
        rollout["mode"] = "off"
        rollout["last_updated"] = utc_now_iso()
        return rollout, {"mode": "off", "execute": False, "nonreg": nonreg}

    if rollout.get("started_iteration") is None:
        rollout["started_iteration"] = int(iteration)
        baseline_window = entries[-max(1, nonreg_window):]
        rollout["baseline_metrics"] = {
            "success_rate": success_rate(baseline_window),
            "median_runtime_seconds": median_or_none(collect_runtime_seconds(baseline_window)),
            "guardrail_failures": 0,
            "window_size": len(baseline_window),
            "captured_at_iteration": int(iteration),
        }

    current_window = entries[-max(1, nonreg_window):]
    curr_success = success_rate(current_window)
    curr_runtime = median_or_none(collect_runtime_seconds(current_window))
    curr_guardrail_failures = sum(
        1
        for e in current_window
        if isinstance(e.get("error"), dict) and e.get("error", {}).get("stage") == "knowledge_guardrail"
    )
    current_metrics = {
        "success_rate": curr_success,
        "median_runtime_seconds": curr_runtime,
        "guardrail_failures": curr_guardrail_failures,
        "window_size": len(current_window),
    }
    nonreg["current"] = current_metrics

    baseline = rollout.get("baseline_metrics") or {}
    base_success = safe_float(baseline.get("success_rate"))
    base_runtime = safe_float(baseline.get("median_runtime_seconds"))

    reasons: List[str] = []
    if curr_guardrail_failures > 0:
        reasons.append(f"guardrail_failures={curr_guardrail_failures} > 0")
    if base_success is not None and curr_success < (base_success - 0.02):
        reasons.append(
            f"success_rate_drop={base_success - curr_success:.4f} exceeds 0.02 threshold"
        )
    if base_runtime is not None and curr_runtime is not None and curr_runtime > (base_runtime * 1.10):
        reasons.append(
            f"median_runtime_increase={(curr_runtime / base_runtime - 1.0):.4f} exceeds 10%"
        )

    if reasons:
        rollout["non_regression_fail_streak"] = int(rollout.get("non_regression_fail_streak", 0)) + 1
    else:
        rollout["non_regression_fail_streak"] = 0

    if int(rollout.get("non_regression_fail_streak", 0)) >= 3:
        rollout["rollback_triggered"] = True
        rollout["rollback_reason"] = "; ".join(reasons) if reasons else "non-regression gate failures"

    started = int(rollout.get("started_iteration", iteration))
    shadow_progress = int(iteration) - started + 1
    mode = "shadow"
    execute = False

    if rollout.get("rollback_triggered"):
        mode = "rolled_back"
        execute = False
    elif shadow_progress <= int(shadow_iters):
        mode = "shadow"
        execute = False
    else:
        mode = "canary"
        execute = deterministic_canary(int(iteration), int(canary_pct))

    if mode == "shadow":
        rollout["shadow_completed"] = int(rollout.get("shadow_completed", 0)) + 1
    if mode == "canary" and execute:
        rollout["canary_executed"] = int(rollout.get("canary_executed", 0)) + 1

    rollout["mode"] = mode
    rollout["last_updated"] = utc_now_iso()

    nonreg["ok"] = len(reasons) == 0
    nonreg["reasons"] = reasons
    return rollout, {"mode": mode, "execute": execute, "nonreg": nonreg}


def evaluate(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)

    strategies_log_path = state_dir / ".strategies_log.json"
    priors_path = state_dir / ".opportunity_priors.json"
    history_path = state_dir / ".opportunity_history.json"
    rollout_path = state_dir / ".autoloop_rollout_state.json"

    entries = loop_entries(load_json(strategies_log_path, []))
    priors = load_json(priors_path, {})
    if not isinstance(priors, dict):
        priors = {}
    history = load_json(history_path, [])
    if not isinstance(history, list):
        history = []

    signals = analyze_signals(entries, args.window_size)
    candidates = build_candidates(
        signals,
        priors,
        history,
        int(args.iteration),
        novelty_lookback=int(args.novelty_lookback),
        novelty_penalty=float(args.novelty_penalty),
        no_uplift_epsilon=float(args.no_uplift_epsilon),
    )
    top = candidates[0]
    selection_reason = "top_weighted_score"
    exploration_forced = False
    subfamily_overrides = parse_subfamily_overrides(args.subfamily_override)

    repeat_classes = parse_csv_set(args.explore_repeat_classes) or set(DEFAULT_EXPLORE_REPEAT_CLASSES)
    target_classes = parse_csv_set(args.explore_target_classes) or set(DEFAULT_EXPLORE_TARGET_CLASSES)
    if bool(args.explore_quota_enable) and should_force_orthogonal(
        history=history,
        lookback=int(args.explore_lookback),
        no_uplift_epsilon=float(args.no_uplift_epsilon),
        repeat_classes=repeat_classes,
    ):
        forced = None
        for candidate in candidates:
            if candidate.family_class in target_classes:
                forced = candidate
                break
        if forced is None:
            for candidate in candidates:
                if candidate.family_class not in repeat_classes:
                    forced = candidate
                    break
        if forced is not None and forced.id != top.id:
            top = forced
            exploration_forced = True
            selection_reason = (
                f"forced_orthogonal_exploration: recent no-uplift retries in classes "
                f"{sorted(repeat_classes)}"
            )

    candidate_subfamilies: Dict[str, Dict[str, str]] = {}
    for c in candidates:
        selected_subfamily, selected_subfamily_reason = choose_subfamily_for_opportunity(
            opportunity_id=c.id,
            priors=priors,
            history=history,
            iteration=int(args.iteration),
            no_uplift_epsilon=float(args.no_uplift_epsilon),
            subfamily_overrides=subfamily_overrides,
        )
        candidate_subfamilies[c.id] = {
            "subfamily": selected_subfamily,
            "reason": selected_subfamily_reason,
        }

    selected_subfamily = candidate_subfamilies.get(top.id, {}).get(
        "subfamily",
        default_subfamily_for_opportunity(top.id),
    )
    selected_subfamily_reason = candidate_subfamilies.get(top.id, {}).get(
        "reason",
        "default_subfamily",
    )

    best_edge_ref = 0.0
    best_edge_path = state_dir / ".best_edge.txt"
    if best_edge_path.exists():
        best_edge_ref = safe_float(best_edge_path.read_text().strip()) or 0.0

    rollout, rollout_decision = update_rollout_state(
        load_json(rollout_path, {}),
        enabled=bool(args.enabled),
        iteration=int(args.iteration),
        shadow_iters=int(args.shadow_iters),
        canary_pct=int(args.canary_pct),
        nonreg_window=int(args.window_size),
        entries=entries,
    )

    ranking_payload = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": utc_now_iso(),
        "iteration": int(args.iteration),
        "signals": signals,
        "weights": {
            "expected_uplift": 0.35,
            "confidence": 0.25,
            "time_to_signal": 0.15,
            "complexity_inverse": 0.10,
            "overfit_risk_inverse": 0.15,
        },
        "ranked_opportunities": [
            {
                "id": c.id,
                "family_class": c.family_class,
                "recommended_subfamily": candidate_subfamilies.get(c.id, {}).get(
                    "subfamily",
                    default_subfamily_for_opportunity(c.id),
                ),
                "recommended_subfamily_reason": candidate_subfamilies.get(c.id, {}).get(
                    "reason",
                    "default_subfamily",
                ),
                "rationale": c.rationale,
                "expected_uplift": round(c.expected_uplift, 3),
                "confidence": round(c.confidence, 3),
                "time_to_signal": round(c.time_to_signal, 3),
                "complexity": round(c.complexity, 3),
                "overfit_risk": round(c.overfit_risk, 3),
                "weighted_score": c.weighted_score,
            }
            for c in candidates
        ],
    }

    plan_template = default_plan_template(top.id, target_edge=args.target_edge, reference_best=best_edge_ref)
    if isinstance(plan_template, dict):
        plan_template.setdefault("subfamily_focus", selected_subfamily)
        plan_template.setdefault("subfamily_focus_reason", selected_subfamily_reason)
    plan_payload = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": utc_now_iso(),
        "iteration": int(args.iteration),
        "mode": rollout_decision["mode"],
        "execute_this_iteration": bool(rollout_decision["execute"]),
        "non_regression_ok": bool(rollout_decision["nonreg"]["ok"]),
        "non_regression_reasons": rollout_decision["nonreg"]["reasons"],
        "rollout_state": {
            "started_iteration": rollout.get("started_iteration"),
            "shadow_completed": rollout.get("shadow_completed"),
            "canary_executed": rollout.get("canary_executed"),
            "rollback_triggered": rollout.get("rollback_triggered"),
            "rollback_reason": rollout.get("rollback_reason"),
        },
        "target_edge": float(args.target_edge),
        "reference_best_edge": float(best_edge_ref),
        "selection_reason": selection_reason,
        "exploration_forced": bool(exploration_forced),
        "selected_opportunity": {
            "id": top.id,
            "family_class": top.family_class,
            "subfamily": selected_subfamily,
            "subfamily_reason": selected_subfamily_reason,
            "rationale": top.rationale,
            "expected_uplift": round(top.expected_uplift, 3),
            "confidence": round(top.confidence, 3),
            "weighted_score": top.weighted_score,
        },
        "policy": {
            "promotion_requires_repeats": 3,
            "family_kill_first_4_below_reference_by": 0.8,
            "family_cooldown_iterations_on_severe_failure": DEFAULT_COOLDOWN_ITERS,
            "no_uplift_epsilon": float(args.no_uplift_epsilon),
            "no_uplift_streak_threshold": int(args.no_uplift_streak_threshold),
            "no_uplift_cooldown_iters": int(args.no_uplift_cooldown_iters),
            "novelty_lookback": int(args.novelty_lookback),
            "novelty_penalty": float(args.novelty_penalty),
            "explore_quota_enabled": bool(args.explore_quota_enable),
            "explore_lookback": int(args.explore_lookback),
            "explore_repeat_classes": sorted(repeat_classes),
            "explore_target_classes": sorted(target_classes),
            "subfamily_override": str(args.subfamily_override or ""),
            "breakthrough_tie_epsilon": float(args.breakthrough_tie_epsilon),
            "severe_subfamily_failure_threshold": int(args.severe_subfamily_failure_threshold),
        },
        "ranked_opportunities": ranking_payload["ranked_opportunities"],
        "search_plan": plan_template,
    }

    # If rollback is triggered, force non-execution regardless of canary bucket.
    if rollout.get("rollback_triggered"):
        plan_payload["execute_this_iteration"] = False

    ranking_path = Path(args.ranking_out) if args.ranking_out else (state_dir / f"opportunity_rankings_iter{int(args.iteration)}.json")
    plan_path = Path(args.plan_out) if args.plan_out else (state_dir / f"autoplan_iter{int(args.iteration)}.json")

    atomic_write_json(ranking_path, ranking_payload)
    atomic_write_json(plan_path, plan_payload)
    atomic_write_json(rollout_path, rollout)
    atomic_write_json(state_dir / ".autoplan_active.json", plan_payload)

    print(f"[opp-engine] wrote ranking: {ranking_path}")
    print(f"[opp-engine] wrote plan: {plan_path}")
    print(
        f"[opp-engine] mode={plan_payload['mode']} "
        f"execute_this_iteration={plan_payload['execute_this_iteration']} "
        f"selected={top.id} class={top.family_class} "
        f"subfamily={selected_subfamily} "
        f"forced_exploration={exploration_forced}"
    )
    if not plan_payload["non_regression_ok"]:
        print(
            "[opp-engine] non-regression gate warning: "
            + "; ".join(plan_payload["non_regression_reasons"])
        )
    if rollout.get("rollback_triggered"):
        print(f"[opp-engine] rollback_triggered: {rollout.get('rollback_reason')}")

    return 0


def latest_family_fallback_from_gates(
    gates_state_path: Path,
    iteration: int,
) -> Dict[str, Any]:
    if not gates_state_path.exists():
        return {}
    gates = load_json(gates_state_path, {})
    if not isinstance(gates, dict):
        return {}
    it = ((gates.get("iterations") or {}).get(str(int(iteration))))
    if not isinstance(it, dict):
        return {}

    families = it.get("families") or {}
    if isinstance(families, dict) and families:
        rows: List[Tuple[str, str, str, float, int]] = []
        for run_id, rec in families.items():
            if not isinstance(rec, dict):
                continue
            edge = safe_float(rec.get("best_edge"))
            if edge is None:
                continue
            completed_at = str(rec.get("completed_at") or rec.get("updated_at") or "")
            status = str(rec.get("status") or "")
            completed_count = int(rec.get("completed_count", 0) or 0)
            rows.append((completed_at, str(run_id), status, edge, completed_count))
        if rows:
            rows.sort()
            completed_at, run_id, status, edge, completed_count = rows[-1]
            best_strategy = None
            observed = it.get("observed_edges")
            if isinstance(observed, list):
                candidates: List[Tuple[float, str]] = []
                for row in observed:
                    if not isinstance(row, dict):
                        continue
                    row_edge = safe_float(row.get("edge"))
                    strategy = str(row.get("strategy") or "").strip()
                    if row_edge is None or not strategy:
                        continue
                    if abs(row_edge - edge) < 1e-9:
                        candidates.append((row_edge, strategy))
                if candidates:
                    # Prefer file-backed strategy names when available.
                    candidates.sort(key=lambda t: (t[1].endswith(".sol"), t[1]), reverse=True)
                    best_strategy = candidates[0][1]
            return {
                "edge": edge,
                "source": "execution_gates_family_end",
                "run_id": run_id,
                "family_status": status,
                "family_completed_count": completed_count,
                "family_completed_at": completed_at,
                "best_strategy": best_strategy,
            }

    batch = it.get("batch") if isinstance(it.get("batch"), dict) else {}
    batch_edge = safe_float(batch.get("best_edge"))
    if batch_edge is not None:
        return {
            "edge": batch_edge,
            "source": "execution_gates_batch_best",
            "batch_count": int(batch.get("count", 0) or 0),
        }
    return {}


def latest_edge_from_strategies_log(
    strategies_log_path: Path,
    iteration: int,
) -> Dict[str, Any]:
    if not strategies_log_path.exists():
        return {}
    data = load_json(strategies_log_path, [])
    if not isinstance(data, list):
        return {}
    rows: List[Tuple[str, float, str]] = []
    for entry in data:
        if not isinstance(entry, dict):
            continue
        if int(entry.get("iteration", 0) or 0) != int(iteration):
            continue
        status = str(entry.get("status") or "")
        if status != "ok":
            continue
        edge = safe_float(entry.get("final_edge"))
        if edge is None:
            continue
        strategy_name = str(entry.get("strategy_name") or "")
        ts = str(entry.get("timestamp") or "")
        rows.append((ts, edge, strategy_name))
    if not rows:
        return {}
    rows.sort()
    ts, edge, strategy_name = rows[-1]
    return {
        "edge": edge,
        "source": "strategies_log_ok",
        "recorded_at": ts,
        "best_strategy": strategy_name or None,
    }


def resolve_fallback_edge(
    *,
    state_dir: Path,
    gates_state_path: Path,
    iteration: int,
    polls: int,
    poll_seconds: float,
) -> Dict[str, Any]:
    if polls < 1:
        polls = 1
    for i in range(polls):
        gate = latest_family_fallback_from_gates(gates_state_path=gates_state_path, iteration=iteration)
        if safe_float(gate.get("edge")) is not None:
            return gate
        if i + 1 < polls and poll_seconds > 0:
            time.sleep(poll_seconds)

    log_fb = latest_edge_from_strategies_log(
        strategies_log_path=state_dir / ".strategies_log.json",
        iteration=iteration,
    )
    if safe_float(log_fb.get("edge")) is not None:
        return log_fb
    return {}


def record(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    plan_path = Path(args.plan_file)
    if not plan_path.exists():
        print(f"[opp-engine] no plan file to record: {plan_path}")
        return 0

    plan = load_json(plan_path, {})
    if not isinstance(plan, dict):
        print(f"[opp-engine] invalid plan JSON: {plan_path}")
        return 0

    result_payload: Dict[str, Any] = {}
    if args.result_file:
        rp = Path(args.result_file)
        if rp.exists():
            result_payload = load_json(rp, {})
            if not isinstance(result_payload, dict):
                result_payload = {}

    selected_opp = ((plan.get("selected_opportunity") or {}).get("id"))
    selected_family_class = family_class(selected_opp) if isinstance(selected_opp, str) else "unknown"
    selected_subfamily = str((plan.get("selected_opportunity") or {}).get("subfamily") or "").strip()
    if not selected_subfamily and isinstance(selected_opp, str):
        selected_subfamily = default_subfamily_for_opportunity(selected_opp)
    selected_subfamily_reason = str(
        (plan.get("selected_opportunity") or {}).get("subfamily_reason") or "default_subfamily"
    )
    final_edge = safe_float(result_payload.get("final_edge"))
    final_score = safe_float(result_payload.get("final_score"))
    strategy_name = str(result_payload.get("strategy_name") or "").strip()
    edge_source = "result_file"
    edge_fallback_metadata: Dict[str, Any] = {}

    if final_edge is None and bool(args.use_gate_family_fallback):
        fallback = resolve_fallback_edge(
            state_dir=state_dir,
            gates_state_path=Path(args.gates_state_file),
            iteration=int(args.iteration),
            polls=int(args.gates_fallback_polls),
            poll_seconds=float(args.gates_fallback_poll_seconds),
        )
        fallback_edge = safe_float(fallback.get("edge"))
        if fallback_edge is not None:
            final_edge = fallback_edge
            edge_source = str(fallback.get("source") or "execution_gates")
            edge_fallback_metadata = fallback
            if not strategy_name:
                strategy_name = str(fallback.get("best_strategy") or "").strip()

    if final_edge is None:
        edge_source = "missing"

    reference = safe_float(plan.get("reference_best_edge")) or 0.0
    promotion = safe_float(((plan.get("search_plan") or {}).get("promotion_criteria") or {}).get("median_delta_vs_reference"))
    delta = (final_edge - reference) if final_edge is not None else None
    no_uplift: Optional[bool]
    if delta is None:
        no_uplift = None
    else:
        no_uplift = bool(delta <= float(args.no_uplift_epsilon))

    validated = None
    if delta is not None and promotion is not None:
        validated = bool(delta >= promotion)
    severe_failure = bool(delta is not None and delta <= SEVERE_FAILURE_DELTA)

    inferred_subfamily: Optional[str] = None
    if isinstance(selected_opp, str) and selected_opp:
        inferred_subfamily = parse_subfamily_from_strategy_name(selected_opp, strategy_name)
    final_subfamily = inferred_subfamily or selected_subfamily or "default"
    subfamily_confidence = "planned"
    if inferred_subfamily and selected_subfamily and inferred_subfamily == selected_subfamily:
        subfamily_confidence = "inferred_match"
    elif inferred_subfamily and selected_subfamily and inferred_subfamily != selected_subfamily:
        subfamily_confidence = "inferred_override"
    elif inferred_subfamily:
        subfamily_confidence = "inferred_only"

    history_path = state_dir / ".opportunity_history.json"
    history = load_json(history_path, [])
    if not isinstance(history, list):
        history = []

    entry = {
        "schema_version": SCHEMA_VERSION,
        "recorded_at": utc_now_iso(),
        "iteration": int(args.iteration),
        "status": args.status,
        "plan_file": str(plan_path),
        "mode": plan.get("mode"),
        "execute_this_iteration": bool(plan.get("execute_this_iteration", False)),
        "selected_opportunity": selected_opp,
        "selected_family_class": selected_family_class,
        "selected_subfamily": selected_subfamily,
        "selected_subfamily_reason": selected_subfamily_reason,
        "final_subfamily": final_subfamily,
        "subfamily_confidence": subfamily_confidence,
        "expected_uplift": safe_float((plan.get("selected_opportunity") or {}).get("expected_uplift")),
        "reference_best_edge": reference,
        "final_edge": final_edge,
        "edge_source": edge_source,
        "edge_fallback": edge_fallback_metadata or None,
        "final_score": final_score,
        "strategy_name": strategy_name or None,
        "delta_vs_reference": delta,
        "no_uplift": no_uplift,
        "validated": validated,
        "severe_failure": severe_failure,
    }
    priors_path = state_dir / ".opportunity_priors.json"
    priors = load_json(priors_path, {})
    if not isinstance(priors, dict):
        priors = {}
    opp = entry.get("selected_opportunity")
    if isinstance(opp, str) and opp:
        bucket = priors.setdefault(
            opp,
            {
                "successes": 0,
                "failures": 0,
                "neutral": 0,
                "severe_failures": 0,
                "cooldown_until_iteration": 0,
                "cooldown_reason": None,
                "non_uplift_streak": 0,
                "no_uplift_outcomes": 0,
                "last_uplift_iteration": None,
                "subfamilies": {},
            },
        )
        sub_key = entry.get("final_subfamily") or entry.get("selected_subfamily") or default_subfamily_for_opportunity(opp)
        if not isinstance(sub_key, str) or not sub_key:
            sub_key = default_subfamily_for_opportunity(opp)
        sub_map = bucket.setdefault("subfamilies", {})
        if not isinstance(sub_map, dict):
            sub_map = {}
            bucket["subfamilies"] = sub_map
        sub_bucket = sub_map.setdefault(
            sub_key,
            {
                "attempts": 0,
                "successes": 0,
                "failures": 0,
                "neutral": 0,
                "severe_failures": 0,
                "cooldown_until_iteration": 0,
                "cooldown_reason": None,
                "non_uplift_streak": 0,
                "no_uplift_outcomes": 0,
                "last_uplift_iteration": None,
                "last_attempt_iteration": None,
                "breakthrough_probe_hits": 0,
            },
        )
        if not isinstance(sub_bucket, dict):
            sub_bucket = {}
            sub_map[sub_key] = sub_bucket
        sub_bucket.setdefault("attempts", 0)
        sub_bucket.setdefault("successes", 0)
        sub_bucket.setdefault("failures", 0)
        sub_bucket.setdefault("neutral", 0)
        sub_bucket.setdefault("severe_failures", 0)
        sub_bucket.setdefault("cooldown_until_iteration", 0)
        sub_bucket.setdefault("cooldown_reason", None)
        sub_bucket.setdefault("non_uplift_streak", 0)
        sub_bucket.setdefault("no_uplift_outcomes", 0)
        sub_bucket.setdefault("last_uplift_iteration", None)
        sub_bucket.setdefault("last_attempt_iteration", None)
        sub_bucket.setdefault("breakthrough_probe_hits", 0)

        prior_attempts = int(sub_bucket.get("attempts", 0) or 0)
        sub_bucket["attempts"] = prior_attempts + 1
        sub_bucket["last_attempt_iteration"] = int(args.iteration)
        bucket["last_selected_subfamily"] = sub_key

        breakthrough_probe = False
        breakthrough_reason = None
        if prior_attempts == 0 and delta is not None:
            tie_eps = float(args.breakthrough_tie_epsilon)
            near_tie = bool(delta >= (-1.0 * tie_eps))
            robust_near_tie = bool(final_score is not None and final_score >= (reference - tie_eps))
            if near_tie or robust_near_tie:
                breakthrough_probe = True
                breakthrough_reason = (
                    f"novel_subfamily_probe: delta={delta:.4f}, tie_epsilon={tie_eps:.4f}, "
                    f"robust_near_tie={robust_near_tie}"
                )
                sub_bucket["breakthrough_probe_hits"] = int(sub_bucket.get("breakthrough_probe_hits", 0) or 0) + 1
                entry["breakthrough_probe"] = True
                entry["breakthrough_probe_reason"] = breakthrough_reason

        if validated is True:
            bucket["successes"] = int(bucket.get("successes", 0)) + 1
            # Clear cooldown after validated recovery.
            bucket["cooldown_until_iteration"] = 0
            bucket["cooldown_reason"] = None
            bucket["last_uplift_iteration"] = int(args.iteration)
            bucket["status"] = "ACTIVE"
            sub_bucket["successes"] = int(sub_bucket.get("successes", 0)) + 1
            sub_bucket["cooldown_until_iteration"] = 0
            sub_bucket["cooldown_reason"] = None
            sub_bucket["non_uplift_streak"] = 0
            sub_bucket["last_uplift_iteration"] = int(args.iteration)
            sub_bucket["status"] = "ACTIVE"
        elif validated is False:
            bucket["failures"] = int(bucket.get("failures", 0)) + 1
            sub_bucket["failures"] = int(sub_bucket.get("failures", 0)) + 1
        else:
            bucket["neutral"] = int(bucket.get("neutral", 0)) + 1
            sub_bucket["neutral"] = int(sub_bucket.get("neutral", 0)) + 1

        if delta is not None and delta > float(args.no_uplift_epsilon):
            sub_bucket["non_uplift_streak"] = 0
            sub_bucket["last_uplift_iteration"] = int(args.iteration)
            reason = str(sub_bucket.get("cooldown_reason") or "")
            if reason.startswith("no uplift streak:"):
                sub_bucket["cooldown_until_iteration"] = 0
                sub_bucket["cooldown_reason"] = None
                if str(sub_bucket.get("status") or "").upper() == "COOLDOWN":
                    sub_bucket["status"] = "ACTIVE"
        elif no_uplift is True and not breakthrough_probe:
            sub_bucket["no_uplift_outcomes"] = int(sub_bucket.get("no_uplift_outcomes", 0) or 0) + 1
            streak = int(sub_bucket.get("non_uplift_streak", 0) or 0) + 1
            sub_bucket["non_uplift_streak"] = streak
            if streak >= int(args.no_uplift_streak_threshold):
                cooldown_until = int(args.iteration) + int(args.no_uplift_cooldown_iters)
                sub_bucket["cooldown_until_iteration"] = max(
                    int(sub_bucket.get("cooldown_until_iteration", 0) or 0),
                    cooldown_until,
                )
                sub_bucket["cooldown_reason"] = (
                    f"no uplift streak: {streak} consecutive outcomes with "
                    f"delta <= {float(args.no_uplift_epsilon):.2f}"
                )
                if str(sub_bucket.get("status") or "").upper() not in {"FAILED"}:
                    sub_bucket["status"] = "COOLDOWN"

        if severe_failure:
            bucket["severe_failures"] = int(bucket.get("severe_failures", 0)) + 1
            sub_bucket["severe_failures"] = int(sub_bucket.get("severe_failures", 0)) + 1
            sub_cooldown_until = int(args.iteration) + DEFAULT_COOLDOWN_ITERS
            sub_bucket["cooldown_until_iteration"] = max(
                int(sub_bucket.get("cooldown_until_iteration", 0) or 0),
                sub_cooldown_until,
            )
            sub_bucket["cooldown_reason"] = (
                f"severe failure: delta {delta:.2f} <= {SEVERE_FAILURE_DELTA:.2f}"
            )
            sub_bucket["status"] = "FAILED"
            sub_bucket["failed_at_iteration"] = int(args.iteration)

            severe_subfamilies = 0
            for _, sb in sub_map.items():
                if not isinstance(sb, dict):
                    continue
                if int(sb.get("severe_failures", 0) or 0) > 0:
                    severe_subfamilies += 1
            if severe_subfamilies >= int(args.severe_subfamily_failure_threshold):
                cooldown_until = int(args.iteration) + DEFAULT_COOLDOWN_ITERS
                bucket["cooldown_until_iteration"] = max(
                    int(bucket.get("cooldown_until_iteration", 0) or 0),
                    cooldown_until,
                )
                bucket["cooldown_reason"] = (
                    f"multi-subfamily severe failures: {severe_subfamilies} >= "
                    f"{int(args.severe_subfamily_failure_threshold)}"
                )
                bucket["status"] = "FAILED"
                bucket["failed_at_iteration"] = int(args.iteration)

        # Aggregate opportunity-level indicators from subfamilies without suppressing novel branches.
        sub_streaks = [
            int(sb.get("non_uplift_streak", 0) or 0)
            for sb in sub_map.values()
            if isinstance(sb, dict)
        ]
        if sub_streaks:
            bucket["non_uplift_streak"] = max(sub_streaks)
        bucket["no_uplift_outcomes"] = sum(
            int((sb.get("no_uplift_outcomes", 0) or 0))
            for sb in sub_map.values()
            if isinstance(sb, dict)
        )
        atomic_write_json(priors_path, priors)

    history.append(entry)
    atomic_write_json(history_path, history)

    print(
        f"[opp-engine] recorded outcome iteration={args.iteration} "
        f"opportunity={entry.get('selected_opportunity')} validated={validated} "
        f"no_uplift={no_uplift} severe_failure={severe_failure} "
        f"subfamily={entry.get('final_subfamily')} edge_source={edge_source}"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Phase 7 opportunity engine")
    sub = parser.add_subparsers(dest="command", required=True)

    p_eval = sub.add_parser("evaluate", help="Discover opportunities and generate auto-plan")
    p_eval.add_argument("--state-dir", required=True)
    p_eval.add_argument("--iteration", required=True, type=int)
    p_eval.add_argument("--target-edge", type=float, default=527.0)
    p_eval.add_argument("--enabled", action="store_true", help="Enable rollout logic")
    p_eval.add_argument("--shadow-iters", type=int, default=20)
    p_eval.add_argument("--canary-pct", type=int, default=20)
    p_eval.add_argument("--window-size", type=int, default=20)
    p_eval.add_argument("--no-uplift-epsilon", type=float, default=DEFAULT_NO_UPLIFT_EPSILON)
    p_eval.add_argument("--no-uplift-streak-threshold", type=int, default=DEFAULT_NO_UPLIFT_STREAK_THRESHOLD)
    p_eval.add_argument("--no-uplift-cooldown-iters", type=int, default=DEFAULT_COOLDOWN_ITERS)
    p_eval.add_argument("--novelty-lookback", type=int, default=DEFAULT_NOVELTY_LOOKBACK)
    p_eval.add_argument("--novelty-penalty", type=float, default=DEFAULT_NOVELTY_PENALTY)
    p_eval.add_argument("--explore-lookback", type=int, default=DEFAULT_EXPLORE_LOOKBACK)
    p_eval.add_argument(
        "--explore-repeat-classes",
        default=",".join(sorted(DEFAULT_EXPLORE_REPEAT_CLASSES)),
    )
    p_eval.add_argument(
        "--explore-target-classes",
        default=",".join(sorted(DEFAULT_EXPLORE_TARGET_CLASSES)),
    )
    p_eval.add_argument("--subfamily-override", default="")
    p_eval.add_argument("--breakthrough-tie-epsilon", type=float, default=DEFAULT_BREAKTHROUGH_TIE_EPSILON)
    p_eval.add_argument(
        "--severe-subfamily-failure-threshold",
        type=int,
        default=DEFAULT_SEVERE_SUBFAMILY_FAILURE_THRESHOLD,
    )
    p_eval.set_defaults(explore_quota_enable=True)
    p_eval.add_argument("--explore-quota-enable", dest="explore_quota_enable", action="store_true")
    p_eval.add_argument("--explore-quota-disable", dest="explore_quota_enable", action="store_false")
    p_eval.add_argument("--ranking-out")
    p_eval.add_argument("--plan-out")

    p_rec = sub.add_parser("record", help="Record plan outcome and update priors")
    p_rec.add_argument("--state-dir", required=True)
    p_rec.add_argument("--iteration", required=True, type=int)
    p_rec.add_argument("--status", required=True)
    p_rec.add_argument("--plan-file", required=True)
    p_rec.add_argument("--result-file")
    p_rec.add_argument("--no-uplift-epsilon", type=float, default=DEFAULT_NO_UPLIFT_EPSILON)
    p_rec.add_argument("--no-uplift-streak-threshold", type=int, default=DEFAULT_NO_UPLIFT_STREAK_THRESHOLD)
    p_rec.add_argument("--no-uplift-cooldown-iters", type=int, default=DEFAULT_COOLDOWN_ITERS)
    p_rec.add_argument("--gates-state-file", default="")
    p_rec.add_argument("--breakthrough-tie-epsilon", type=float, default=DEFAULT_BREAKTHROUGH_TIE_EPSILON)
    p_rec.add_argument(
        "--severe-subfamily-failure-threshold",
        type=int,
        default=DEFAULT_SEVERE_SUBFAMILY_FAILURE_THRESHOLD,
    )
    p_rec.add_argument("--gates-fallback-polls", type=int, default=DEFAULT_GATES_FALLBACK_POLLS)
    p_rec.add_argument("--gates-fallback-poll-seconds", type=float, default=DEFAULT_GATES_FALLBACK_POLL_SECONDS)
    p_rec.set_defaults(use_gate_family_fallback=True)
    p_rec.add_argument("--use-gate-family-fallback", dest="use_gate_family_fallback", action="store_true")
    p_rec.add_argument("--disable-gate-family-fallback", dest="use_gate_family_fallback", action="store_false")

    args = parser.parse_args()
    if args.command == "evaluate":
        return evaluate(args)
    if args.command == "record":
        return record(args)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
