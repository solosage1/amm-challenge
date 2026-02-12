#!/usr/bin/env python3
"""
Read-only shadow selector for the legacy opportunity engine.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def append_jsonl(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        handle.write(json.dumps(payload) + "\n")


def run_shadow_selection(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    snapshot_dir = Path(args.snapshot_dir) if args.snapshot_dir else (state_dir / "migration_snapshot")
    output_path = Path(args.output) if args.output else (state_dir / "shadow_selections.jsonl")

    required = [
        snapshot_dir / ".opportunity_priors.json",
        snapshot_dir / ".opportunity_history.json",
    ]
    for path in required:
        if not path.exists():
            raise FileNotFoundError(f"missing snapshot file: {path}")

    with tempfile.TemporaryDirectory(prefix="shadow_selector_") as temp_dir_name:
        temp_dir = Path(temp_dir_name)
        # Copy frozen state as read-only baseline for temporary evaluation.
        (temp_dir / ".opportunity_priors.json").write_text((snapshot_dir / ".opportunity_priors.json").read_text())
        (temp_dir / ".opportunity_history.json").write_text((snapshot_dir / ".opportunity_history.json").read_text())

        if (snapshot_dir / ".best_edge.txt").exists():
            (temp_dir / ".best_edge.txt").write_text((snapshot_dir / ".best_edge.txt").read_text())
        else:
            (temp_dir / ".best_edge.txt").write_text("0.0\n")

        # Minimal sidecar files expected by evaluate path.
        (temp_dir / ".strategies_log.json").write_text("[]\n")
        (temp_dir / ".autoloop_rollout_state.json").write_text(
            json.dumps(
                {
                    "successful_iterations": 0,
                    "failed_iterations": 0,
                    "median_runtime_seconds": 0,
                    "guardrail_failures": 0,
                    "state_write_failures": 0,
                    "schema_breakages": 0,
                }
            )
        )

        plan_out = temp_dir / "shadow_plan.json"
        ranking_out = temp_dir / "shadow_ranking.json"
        cmd = [
            str(args.python_exe),
            str(args.engine_script),
            "evaluate",
            "--state-dir",
            str(temp_dir),
            "--iteration",
            str(args.iteration),
            "--enabled",
            "--plan-out",
            str(plan_out),
            "--ranking-out",
            str(ranking_out),
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            payload = {
                "iter": int(args.iteration),
                "ts": utc_now_iso(),
                "status": "error",
                "error": f"shadow_engine_failed:{proc.returncode}",
                "stderr_tail": proc.stderr[-500:] if proc.stderr else "",
            }
            append_jsonl(output_path, payload)
            print(json.dumps(payload, indent=2))
            return proc.returncode

        ranking = json.loads(ranking_out.read_text())
        ranked = ranking.get("ranked_opportunities", [])
        top = ranked[0] if ranked else {}
        payload = {
            "iter": int(args.iteration),
            "ts": utc_now_iso(),
            "status": "ok",
            "would_select": top.get("id"),
            "would_subfamily": top.get("recommended_subfamily"),
            "family_class": top.get("family_class"),
            "score": top.get("weighted_score"),
            "engine_script": str(args.engine_script),
            "snapshot_dir": str(snapshot_dir),
        }
        append_jsonl(output_path, payload)
        print(json.dumps(payload, indent=2))
        return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Read-only shadow selector for legacy opportunity engine")
    parser.add_argument("--state-dir", default=".ralph-amm/phase7/state")
    parser.add_argument("--snapshot-dir")
    parser.add_argument("--output")
    parser.add_argument("--iteration", required=True, type=int)
    parser.add_argument("--python-exe", default="python3")
    parser.add_argument("--engine-script", default="scripts/amm-phase7-opportunity-engine.py")
    parser.set_defaults(func=run_shadow_selection)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
