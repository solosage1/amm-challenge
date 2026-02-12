#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any, Dict, List, Optional


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


def read_jsonl(path: Path) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    if not path.exists():
        return rows
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict):
            rows.append(obj)
    return rows


def parse_codex_metrics(codex_jsonl_path: Optional[str]) -> Dict[str, Any]:
    if not codex_jsonl_path:
        return {"reasoning_items": 0, "agent_messages": 0, "output_tokens": None, "input_tokens": None}
    rows = read_jsonl(Path(codex_jsonl_path))
    reasoning_items = 0
    agent_messages = 0
    output_tokens = None
    input_tokens = None
    for row in rows:
        if row.get("type") == "item.completed":
            item = row.get("item", {})
            if item.get("type") == "reasoning":
                reasoning_items += 1
            if item.get("type") == "agent_message":
                agent_messages += 1
        if row.get("type") == "turn.completed":
            usage = row.get("usage", {})
            output_tokens = usage.get("output_tokens")
            input_tokens = usage.get("input_tokens")
    return {
        "reasoning_items": reasoning_items,
        "agent_messages": agent_messages,
        "output_tokens": output_tokens,
        "input_tokens": input_tokens,
    }


def feature_flags(repo_root: Path, state_dir: Path) -> Dict[str, bool]:
    validation_py = repo_root / "scripts/simplified_loop_domains/validation.py"
    definitions_path = state_dir.parent / "config/mechanism_definitions.json"
    defs = load_json(definitions_path, {})
    directional = (
        defs.get("mechanisms", {})
        .get("directional_skew_and_stale_protection", {})
        .get("anchors", [])
    )
    directional_anchor_simplified = (
        isinstance(directional, list)
        and len(directional) == 1
        and isinstance(directional[0], dict)
        and "bidProtectSide" in str(directional[0].get("end", ""))
    )
    validation_text = validation_py.read_text() if validation_py.exists() else ""
    soft_validation_enabled = "soft_check:" in validation_text
    timer_file = state_dir / ".start_timestamp.txt"
    timer_reset_recent = False
    if timer_file.exists():
        try:
            start_ts = int(timer_file.read_text().strip())
            timer_reset_recent = (int(time.time()) - start_ts) < 3600
        except Exception:
            timer_reset_recent = False
    return {
        "directional_anchor_simplified": directional_anchor_simplified,
        "soft_validation_enabled": soft_validation_enabled,
        "timer_reset_recent": timer_reset_recent,
        "hypotheses_backlog_present": (state_dir / "hypotheses_backlog.json").exists(),
    }


def compute_reasoning_level(last_entry: Dict[str, Any], codex_metrics: Dict[str, Any]) -> str:
    status = str(last_entry.get("status", ""))
    if status == "llm_failed":
        return "low"
    reasoning_items = int(codex_metrics.get("reasoning_items") or 0)
    output_tokens = codex_metrics.get("output_tokens") or 0
    if reasoning_items >= 2 or output_tokens >= 3000:
        return "high"
    if reasoning_items >= 1 or output_tokens >= 1200:
        return "medium"
    return "low"


def sample(state_dir: Path, repo_root: Path, checkpoint_path: Path) -> Dict[str, Any]:
    stats = load_json(state_dir / "mechanism_stats.json", {})
    logs = read_jsonl(state_dir / "iteration_log.jsonl")
    total_iterations = int(stats.get("global", {}).get("total_iterations", 0) or 0)
    last_entry = logs[-1] if logs else {}
    codex_metrics = parse_codex_metrics(last_entry.get("codex_jsonl_path"))

    now = time.time()
    checkpoint = load_json(checkpoint_path, {})
    prev_ts = float(checkpoint.get("ts", now))
    prev_iters = int(checkpoint.get("total_iterations", total_iterations))
    dt = max(1.0, now - prev_ts)
    d_iters = max(0, total_iterations - prev_iters)
    iter_per_min = d_iters / (dt / 60.0)

    last_10 = logs[-10:]
    llm_failed_last_10 = sum(1 for row in last_10 if row.get("status") == "llm_failed")
    invalid_last_10 = sum(1 for row in last_10 if row.get("status") == "invalid")

    features = feature_flags(repo_root, state_dir)
    reasoning_level = compute_reasoning_level(last_entry, codex_metrics)
    efficiency = "good" if iter_per_min >= 0.15 and llm_failed_last_10 <= 5 else "poor"

    payload = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "total_iterations": total_iterations,
        "latest_iter": last_entry.get("iter"),
        "latest_status": last_entry.get("status"),
        "latest_mechanism": last_entry.get("mechanism"),
        "latest_hypothesis_id": (last_entry.get("iteration_policy") or {}).get("hypothesis_id"),
        "reasoning_level": reasoning_level,
        "efficiency_level": efficiency,
        "iter_per_min_over_window": round(iter_per_min, 4),
        "llm_failed_last_10": llm_failed_last_10,
        "invalid_last_10": invalid_last_10,
        "reasoning_items_last_codex": codex_metrics.get("reasoning_items"),
        "agent_messages_last_codex": codex_metrics.get("agent_messages"),
        "output_tokens_last_codex": codex_metrics.get("output_tokens"),
        "input_tokens_last_codex": codex_metrics.get("input_tokens"),
        "feature_usage": features,
    }
    checkpoint_path.write_text(json.dumps({"ts": now, "total_iterations": total_iterations}))
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description="5-minute loop quality monitor")
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--interval-sec", type=int, default=300)
    parser.add_argument("--out-file", default="")
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()

    state_dir = Path(args.state_dir).resolve()
    repo_root = Path(__file__).resolve().parents[1]
    out_file = Path(args.out_file).resolve() if args.out_file else (state_dir / "loop_quality_checks.jsonl")
    checkpoint_path = state_dir / ".loop_quality_monitor_checkpoint.json"

    while True:
        payload = sample(state_dir, repo_root, checkpoint_path)
        line = json.dumps(payload, sort_keys=True)
        with out_file.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
        print(line, flush=True)
        if args.once:
            return 0
        time.sleep(max(1, args.interval_sec))


if __name__ == "__main__":
    raise SystemExit(main())
