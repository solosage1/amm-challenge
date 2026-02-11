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
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from statistics import median
from typing import Any, Dict, List, Optional, Tuple


SCHEMA_VERSION = "1.0"
SEVERE_FAILURE_DELTA = -0.8
DEFAULT_COOLDOWN_ITERS = 4


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


def build_candidates(signals: Dict[str, Any], priors: Dict[str, Any], iteration: int) -> List[Candidate]:
    p = safe_float(signals.get("plateau_strength")) or 0.0
    b = safe_float(signals.get("brittleness_strength")) or 0.0
    s = safe_float(signals.get("sweep_failure_strength")) or 0.0

    prior_adj = {}
    for key in (
        "regime_state_transition_search",
        "adaptive_undercut_search",
        "robustness_repair_search",
        "parallel_parameter_beam",
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
            rationale="If sweep throughput is bottlenecked, parallel beams can improve search efficiency.",
            expected_uplift=clamp(2.5 + 0.25 * s + prior_adj["parallel_parameter_beam"]),
            confidence=6.0,
            time_to_signal=9.0,
            complexity=4.0,
            overfit_risk=6.0,
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
    rollout_path = state_dir / ".autoloop_rollout_state.json"

    entries = loop_entries(load_json(strategies_log_path, []))
    priors = load_json(priors_path, {})
    if not isinstance(priors, dict):
        priors = {}

    signals = analyze_signals(entries, args.window_size)
    candidates = build_candidates(signals, priors, int(args.iteration))
    top = candidates[0]

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
        "selected_opportunity": {
            "id": top.id,
            "rationale": top.rationale,
            "expected_uplift": round(top.expected_uplift, 3),
            "confidence": round(top.confidence, 3),
            "weighted_score": top.weighted_score,
        },
        "policy": {
            "promotion_requires_repeats": 3,
            "family_kill_first_4_below_reference_by": 0.8,
            "family_cooldown_iterations_on_severe_failure": DEFAULT_COOLDOWN_ITERS,
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
        f"selected={top.id}"
    )
    if not plan_payload["non_regression_ok"]:
        print(
            "[opp-engine] non-regression gate warning: "
            + "; ".join(plan_payload["non_regression_reasons"])
        )
    if rollout.get("rollback_triggered"):
        print(f"[opp-engine] rollback_triggered: {rollout.get('rollback_reason')}")

    return 0


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

    final_edge = safe_float(result_payload.get("final_edge"))
    final_score = safe_float(result_payload.get("final_score"))
    reference = safe_float(plan.get("reference_best_edge")) or 0.0
    promotion = safe_float(((plan.get("search_plan") or {}).get("promotion_criteria") or {}).get("median_delta_vs_reference"))
    delta = (final_edge - reference) if final_edge is not None else None

    validated = None
    if delta is not None and promotion is not None:
        validated = bool(delta >= promotion)
    severe_failure = bool(delta is not None and delta <= SEVERE_FAILURE_DELTA)

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
        "selected_opportunity": ((plan.get("selected_opportunity") or {}).get("id")),
        "expected_uplift": safe_float((plan.get("selected_opportunity") or {}).get("expected_uplift")),
        "reference_best_edge": reference,
        "final_edge": final_edge,
        "final_score": final_score,
        "delta_vs_reference": delta,
        "validated": validated,
        "severe_failure": severe_failure,
    }
    history.append(entry)
    atomic_write_json(history_path, history)

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
            },
        )
        if validated is True:
            bucket["successes"] = int(bucket.get("successes", 0)) + 1
            # Clear cooldown after validated recovery.
            bucket["cooldown_until_iteration"] = 0
            bucket["cooldown_reason"] = None
            bucket["status"] = "ACTIVE"
        elif validated is False:
            bucket["failures"] = int(bucket.get("failures", 0)) + 1
        else:
            bucket["neutral"] = int(bucket.get("neutral", 0)) + 1
        if severe_failure:
            bucket["severe_failures"] = int(bucket.get("severe_failures", 0)) + 1
            cooldown_until = int(args.iteration) + DEFAULT_COOLDOWN_ITERS
            bucket["cooldown_until_iteration"] = max(
                int(bucket.get("cooldown_until_iteration", 0) or 0),
                cooldown_until,
            )
            bucket["cooldown_reason"] = (
                f"severe failure: delta {delta:.2f} <= {SEVERE_FAILURE_DELTA:.2f}"
            )
            bucket["status"] = "FAILED"
            bucket["failed_at_iteration"] = int(args.iteration)
        atomic_write_json(priors_path, priors)

    print(
        f"[opp-engine] recorded outcome iteration={args.iteration} "
        f"opportunity={entry.get('selected_opportunity')} validated={validated} "
        f"severe_failure={severe_failure}"
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
    p_eval.add_argument("--ranking-out")
    p_eval.add_argument("--plan-out")

    p_rec = sub.add_parser("record", help="Record plan outcome and update priors")
    p_rec.add_argument("--state-dir", required=True)
    p_rec.add_argument("--iteration", required=True, type=int)
    p_rec.add_argument("--status", required=True)
    p_rec.add_argument("--plan-file", required=True)
    p_rec.add_argument("--result-file")

    args = parser.parse_args()
    if args.command == "evaluate":
        return evaluate(args)
    if args.command == "record":
        return record(args)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
