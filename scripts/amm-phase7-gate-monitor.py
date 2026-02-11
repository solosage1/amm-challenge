#!/usr/bin/env python3
"""
Real-time execution gate monitor for Phase 7 Codex sessions.

Monitors Codex JSONL command outputs as they stream and enforces:
- Early family kill: first N authoritative (>= min sims) edges all below champion - delta.
- Batch failure tagging: batch best below champion - delta.

Writes a persistent audit trail into .execution_gates.json.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Tuple


EDGE_RE = re.compile(r"([A-Za-z0-9_]+)\s+Edge:\s*([+-]?[0-9]+(?:\.[0-9]+)?)")
SIMS_RE = re.compile(r"--simulations?\s+([0-9]+)")
PAR_SIM_RESULT_RE = re.compile(
    r"^PAR_SIM_RESULT\t([^\t]+)\t([^\t]+)\t([0-9]+)\t([0-9]+)$",
    re.MULTILINE,
)


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


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def terminate_pid(pid: int, grace_seconds: float = 3.0) -> Tuple[bool, str]:
    if not pid_alive(pid):
        return True, "already_exited"
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError as exc:
        return False, f"term_failed:{exc}"
    deadline = time.time() + grace_seconds
    while time.time() < deadline:
        if not pid_alive(pid):
            return True, "terminated"
        time.sleep(0.1)
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError as exc:
        if not pid_alive(pid):
            return True, "terminated_after_term"
        return False, f"kill_failed:{exc}"
    return True, "killed"


def ensure_iteration_record(
    data: Dict[str, Any],
    *,
    iteration: int,
    champion_baseline: float,
    min_sims: int,
    early_min_results: int,
    early_delta: float,
    batch_fail_delta: float,
) -> Dict[str, Any]:
    data.setdefault("schema_version", "1.0")
    data.setdefault("iterations", {})
    iterations = data["iterations"]
    key = str(iteration)
    if key not in iterations or not isinstance(iterations.get(key), dict):
        iterations[key] = {
            "iteration": int(iteration),
            "created_at": utc_now_iso(),
            "champion_baseline": float(champion_baseline),
            "authoritative_simulations": int(min_sims),
            "observed_edges": [],
            "observed_item_ids": [],
            "early_abort": {
                "enabled": True,
                "min_results": int(early_min_results),
                "delta_below_champion": float(early_delta),
                "triggered": False,
                "trigger_count": None,
                "trigger_reason": None,
                "triggered_at": None,
                "termination_result": None,
            },
            "batch": {
                "fail_delta_below_champion": float(batch_fail_delta),
                "count": 0,
                "best_edge": None,
                "failed": False,
                "fail_reason": None,
            },
            "status": "monitor_running",
            "updated_at": utc_now_iso(),
        }
    return iterations[key]


def extract_edge_items(item: Dict[str, Any], min_sims: int) -> List[Dict[str, Any]]:
    if item.get("type") != "command_execution" or item.get("status") != "completed":
        return []
    command = str(item.get("command") or "")
    output = str(item.get("aggregated_output") or "")
    results: List[Dict[str, Any]] = []

    # Primary path: direct amm-match invocations.
    if "amm-match run" in command:
        sims_match = SIMS_RE.search(command)
        sims = int(sims_match.group(1)) if sims_match else 10
        if sims < min_sims:
            return []
        matches = EDGE_RE.findall(output)
        if not matches:
            return []
        strategy, edge_raw = matches[-1]
        edge = float(edge_raw)
        results.append(
            {
                "timestamp": utc_now_iso(),
                "strategy": strategy,
                "edge": edge,
                "simulations": sims,
                "command": command[:240],
            }
        )
        return results

    # Helper path: run-parallel-sims emits machine-readable PAR_SIM_RESULT lines.
    if "run-parallel-sims.sh" in command:
        for strategy, edge_raw, sims_raw, status_raw in PAR_SIM_RESULT_RE.findall(output):
            try:
                sims = int(sims_raw)
                status = int(status_raw)
            except Exception:
                continue
            if sims < min_sims or status != 0:
                continue
            try:
                edge = float(edge_raw)
            except Exception:
                continue
            results.append(
                {
                    "timestamp": utc_now_iso(),
                    "strategy": strategy,
                    "edge": edge,
                    "simulations": sims,
                    "command": command[:240],
                }
            )
        return results

    return []


def update_batch_fields(it_record: Dict[str, Any], champion_baseline: float, batch_fail_delta: float) -> None:
    observed = it_record.get("observed_edges", [])
    batch = it_record.setdefault("batch", {})
    count = len(observed)
    best_edge = None
    if observed:
        best_edge = max(float(x.get("edge", float("-inf"))) for x in observed)
    batch["count"] = count
    batch["best_edge"] = None if best_edge is None else float(best_edge)
    if best_edge is None:
        batch["failed"] = False
        batch["fail_reason"] = None
    else:
        threshold = float(champion_baseline) - float(batch_fail_delta)
        failed = float(best_edge) < threshold
        batch["failed"] = bool(failed)
        batch["fail_reason"] = (
            f"batch best {best_edge:.2f} < champion {champion_baseline:.2f} - {batch_fail_delta:.2f}"
            if failed
            else None
        )


def early_abort_triggered(
    observed: List[Dict[str, Any]],
    champion_baseline: float,
    min_results: int,
    delta: float,
) -> Tuple[bool, str]:
    if len(observed) < min_results:
        return False, ""
    first = observed[:min_results]
    threshold = float(champion_baseline) - float(delta)
    if all(float(x.get("edge", 0.0)) < threshold for x in first):
        edges = ", ".join(f"{float(x['edge']):.2f}" for x in first)
        reason = (
            f"first {min_results} authoritative edges [{edges}] are all < "
            f"champion {champion_baseline:.2f} - {delta:.2f} ({threshold:.2f})"
        )
        return True, reason
    return False, ""


def parse_new_events(
    *,
    jsonl_path: Path,
    offset: int,
) -> Tuple[List[Dict[str, Any]], int]:
    if not jsonl_path.exists():
        return [], offset
    with jsonl_path.open("r", errors="replace") as f:
        f.seek(offset)
        chunk = f.read()
        new_offset = f.tell()
    events: List[Dict[str, Any]] = []
    for line in chunk.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events, new_offset


def main() -> int:
    parser = argparse.ArgumentParser(description="Monitor Codex JSONL and enforce real-time execution gates")
    parser.add_argument("--jsonl", required=True)
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--iteration", required=True, type=int)
    parser.add_argument("--codex-pid", required=True, type=int)
    parser.add_argument("--champion-baseline", required=True, type=float)
    parser.add_argument("--min-sims", type=int, default=1000)
    parser.add_argument("--early-enabled", action="store_true")
    parser.add_argument("--early-min-results", type=int, default=4)
    parser.add_argument("--early-delta", type=float, default=0.8)
    parser.add_argument("--batch-fail-delta", type=float, default=0.5)
    parser.add_argument("--poll-seconds", type=float, default=1.0)
    args = parser.parse_args()

    jsonl_path = Path(args.jsonl)
    state_path = Path(args.state_file)
    offset = 0

    state = load_json(state_path, {})
    if not isinstance(state, dict):
        state = {}

    it_record = ensure_iteration_record(
        state,
        iteration=args.iteration,
        champion_baseline=args.champion_baseline,
        min_sims=args.min_sims,
        early_min_results=args.early_min_results,
        early_delta=args.early_delta,
        batch_fail_delta=args.batch_fail_delta,
    )
    it_record["early_abort"]["enabled"] = bool(args.early_enabled)
    it_record["updated_at"] = utc_now_iso()
    state["last_updated"] = utc_now_iso()
    atomic_write_json(state_path, state)

    seen_ids = set(str(x) for x in it_record.get("observed_item_ids", []))
    observed = list(it_record.get("observed_edges", []))
    aborted = False

    while True:
        events, offset = parse_new_events(jsonl_path=jsonl_path, offset=offset)
        changed = False
        for event in events:
            if event.get("type") != "item.completed":
                continue
            item = event.get("item", {})
            item_id = str(item.get("id") or "")
            if not item_id or item_id in seen_ids:
                continue
            edge_items = extract_edge_items(item, args.min_sims)
            if not edge_items:
                continue
            seen_ids.add(item_id)
            observed.extend(edge_items)
            changed = True

        if changed:
            state = load_json(state_path, {})
            if not isinstance(state, dict):
                state = {}
            it_record = ensure_iteration_record(
                state,
                iteration=args.iteration,
                champion_baseline=args.champion_baseline,
                min_sims=args.min_sims,
                early_min_results=args.early_min_results,
                early_delta=args.early_delta,
                batch_fail_delta=args.batch_fail_delta,
            )
            it_record["observed_edges"] = observed
            it_record["observed_item_ids"] = sorted(seen_ids)
            update_batch_fields(it_record, args.champion_baseline, args.batch_fail_delta)

            if args.early_enabled and not bool(it_record.get("early_abort", {}).get("triggered")):
                triggered, reason = early_abort_triggered(
                    observed=observed,
                    champion_baseline=args.champion_baseline,
                    min_results=args.early_min_results,
                    delta=args.early_delta,
                )
                if triggered:
                    ok, termination = terminate_pid(args.codex_pid)
                    it_record["early_abort"]["triggered"] = True
                    it_record["early_abort"]["trigger_count"] = len(observed)
                    it_record["early_abort"]["trigger_reason"] = reason
                    it_record["early_abort"]["triggered_at"] = utc_now_iso()
                    it_record["early_abort"]["termination_result"] = termination if ok else f"failed:{termination}"
                    it_record["status"] = "early_aborted"
                    aborted = True

            it_record["updated_at"] = utc_now_iso()
            state["last_updated"] = utc_now_iso()
            atomic_write_json(state_path, state)

        if not pid_alive(args.codex_pid):
            break
        time.sleep(max(0.05, args.poll_seconds))

    # Finalize iteration state.
    state = load_json(state_path, {})
    if not isinstance(state, dict):
        state = {}
    it_record = ensure_iteration_record(
        state,
        iteration=args.iteration,
        champion_baseline=args.champion_baseline,
        min_sims=args.min_sims,
        early_min_results=args.early_min_results,
        early_delta=args.early_delta,
        batch_fail_delta=args.batch_fail_delta,
    )
    it_record["observed_edges"] = observed
    it_record["observed_item_ids"] = sorted(seen_ids)
    update_batch_fields(it_record, args.champion_baseline, args.batch_fail_delta)
    if aborted or bool(it_record.get("early_abort", {}).get("triggered")):
        it_record["status"] = "early_aborted"
    elif it_record.get("status") == "monitor_running":
        it_record["status"] = "completed"
    it_record["updated_at"] = utc_now_iso()
    state["last_updated"] = utc_now_iso()
    atomic_write_json(state_path, state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
