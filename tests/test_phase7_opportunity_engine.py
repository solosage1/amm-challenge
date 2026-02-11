import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "scripts" / "amm-phase7-opportunity-engine.py"


def run_engine(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(ENGINE), *args],
        check=True,
        text=True,
        capture_output=True,
    )


def write_json(path: Path, payload) -> None:
    path.write_text(json.dumps(payload))


def bootstrap_state(tmp_path: Path) -> None:
    write_json(tmp_path / ".strategies_log.json", [])
    write_json(tmp_path / ".opportunity_priors.json", {})
    write_json(tmp_path / ".opportunity_history.json", [])
    write_json(
        tmp_path / ".autoloop_rollout_state.json",
        {
            "successful_iterations": 0,
            "failed_iterations": 0,
            "median_runtime_seconds": 0,
            "guardrail_failures": 0,
            "state_write_failures": 0,
            "schema_breakages": 0,
        },
    )


def test_subfamily_cooldown_does_not_force_family_cooldown(tmp_path: Path) -> None:
    bootstrap_state(tmp_path)
    (tmp_path / ".best_edge.txt").write_text("508.25\n")

    for iteration in (30, 31, 32):
        run_engine(
            [
                "evaluate",
                "--state-dir",
                str(tmp_path),
                "--iteration",
                str(iteration),
                "--enabled",
                "--subfamily-override",
                "adaptive_undercut_search:mispricing_gate",
                "--plan-out",
                str(tmp_path / f"plan{iteration}.json"),
                "--ranking-out",
                str(tmp_path / f"rank{iteration}.json"),
            ]
        )
        write_json(
            tmp_path / f"result{iteration}.json",
            {"final_edge": 507.90, "strategy_name": f"gate2_v{iteration}"},
        )
        run_engine(
            [
                "record",
                "--state-dir",
                str(tmp_path),
                "--iteration",
                str(iteration),
                "--status",
                "ok",
                "--plan-file",
                str(tmp_path / f"plan{iteration}.json"),
                "--result-file",
                str(tmp_path / f"result{iteration}.json"),
            ]
        )

    priors = json.loads((tmp_path / ".opportunity_priors.json").read_text())
    opp = priors["adaptive_undercut_search"]
    sub = opp["subfamilies"]["mispricing_gate"]
    assert sub["non_uplift_streak"] >= 3
    assert int(sub["cooldown_until_iteration"]) > 32
    assert int(opp.get("cooldown_until_iteration", 0)) == 0


def test_novelty_penalty_is_held_when_untried_subfamily_exists(tmp_path: Path) -> None:
    bootstrap_state(tmp_path)
    write_json(
        tmp_path / ".opportunity_priors.json",
        {
            "adaptive_undercut_search": {
                "successes": 0,
                "failures": 0,
                "neutral": 0,
                "severe_failures": 0,
                "cooldown_until_iteration": 0,
                "cooldown_reason": None,
                "subfamilies": {
                    "mispricing_gate": {
                        "attempts": 3,
                        "successes": 0,
                        "failures": 3,
                        "neutral": 0,
                        "severe_failures": 0,
                        "cooldown_until_iteration": 0,
                        "cooldown_reason": None,
                        "non_uplift_streak": 3,
                        "no_uplift_outcomes": 3,
                        "last_attempt_iteration": 12,
                    }
                },
            }
        },
    )
    write_json(
        tmp_path / ".opportunity_history.json",
        [
            {
                "iteration": 10,
                "execute_this_iteration": True,
                "selected_opportunity": "adaptive_undercut_search",
                "selected_subfamily": "mispricing_gate",
                "delta_vs_reference": -0.50,
            },
            {
                "iteration": 11,
                "execute_this_iteration": True,
                "selected_opportunity": "adaptive_undercut_search",
                "selected_subfamily": "mispricing_gate",
                "delta_vs_reference": -0.60,
            },
        ],
    )

    run_engine(
        [
            "evaluate",
            "--state-dir",
            str(tmp_path),
            "--iteration",
            "13",
            "--enabled",
            "--plan-out",
            str(tmp_path / "plan.json"),
            "--ranking-out",
            str(tmp_path / "rank.json"),
        ]
    )
    ranking = json.loads((tmp_path / "rank.json").read_text())
    adaptive = next(x for x in ranking["ranked_opportunities"] if x["id"] == "adaptive_undercut_search")
    assert adaptive["recommended_subfamily"] == "plain_undercut"
    assert "novelty hold:" in adaptive["rationale"]
    assert "novelty penalty:" not in adaptive["rationale"]


def test_record_falls_back_to_execution_gate_family_edge(tmp_path: Path) -> None:
    bootstrap_state(tmp_path)
    (tmp_path / ".best_edge.txt").write_text("508.25\n")

    run_engine(
        [
            "evaluate",
            "--state-dir",
            str(tmp_path),
            "--iteration",
            "23",
            "--enabled",
            "--plan-out",
            str(tmp_path / "plan23.json"),
            "--ranking-out",
            str(tmp_path / "rank23.json"),
        ]
    )
    write_json(tmp_path / "result23.json", {"strategy_name": "bgate_v3"})
    write_json(
        tmp_path / "gates.json",
        {
            "iterations": {
                "23": {
                    "families": {
                        "runX": {
                            "best_edge": 507.91,
                            "status": "completed",
                            "completed_count": 8,
                            "completed_at": "2026-02-11T00:00:00Z",
                        }
                    },
                    "observed_edges": [{"strategy": "bgate_v3.sol", "edge": 507.91}],
                }
            }
        },
    )

    run_engine(
        [
            "record",
            "--state-dir",
            str(tmp_path),
            "--iteration",
            "23",
            "--status",
            "ok",
            "--plan-file",
            str(tmp_path / "plan23.json"),
            "--result-file",
            str(tmp_path / "result23.json"),
            "--gates-state-file",
            str(tmp_path / "gates.json"),
        ]
    )

    history = json.loads((tmp_path / ".opportunity_history.json").read_text())
    last = history[-1]
    assert float(last["final_edge"]) == 507.91
    assert last["edge_source"] == "execution_gates_family_end"
    assert (last.get("edge_fallback") or {}).get("best_strategy") == "bgate_v3.sol"
