import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SIMPLIFIED = ROOT / "scripts" / "simplified_loop.py"
SHADOW = ROOT / "scripts" / "shadow_selector.py"
DEFINITIONS = ROOT / ".ralph-amm" / "phase7" / "config" / "mechanism_definitions.json"
CHAMPION_SOURCE = ROOT / "iskewx_v11.sol"


def run_script(
    script: Path,
    args: list[str],
    cwd: Path | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(script), *args],
        check=check,
        text=True,
        capture_output=True,
        cwd=str(cwd or ROOT),
    )


def setup_state(tmp_path: Path) -> Path:
    state = tmp_path / "state"
    state.mkdir(parents=True, exist_ok=True)
    (state / ".best_strategy.sol").write_text(CHAMPION_SOURCE.read_text())
    (state / ".best_edge.txt").write_text("508.80\n")
    return state


def test_run_once_dry_run_creates_stats_and_log(tmp_path: Path) -> None:
    state = setup_state(tmp_path)
    run_script(
        SIMPLIFIED,
        [
            "run-once",
            "--state-dir",
            str(state),
            "--definitions",
            str(DEFINITIONS),
            "--dry-run",
            "--seed",
            "13",
        ],
    )
    stats = json.loads((state / "mechanism_stats.json").read_text())
    logs = (state / "iteration_log.jsonl").read_text().strip().splitlines()
    assert stats["schema_version"] == "2.0"
    assert int(stats["global"]["total_iterations"]) == 1
    assert len(logs) == 1
    entry = json.loads(logs[0])
    assert entry["status"] == "complete"
    assert entry["valid"] is True
    assert "mechanism" in entry


def test_invalid_candidate_increments_invalid_count(tmp_path: Path) -> None:
    state = setup_state(tmp_path)
    candidate = tmp_path / "candidate.sol"
    candidate.write_text(CHAMPION_SOURCE.read_text())
    proc = run_script(
        SIMPLIFIED,
        [
            "run-once",
            "--state-dir",
            str(state),
            "--definitions",
            str(DEFINITIONS),
            "--candidate-file",
            str(candidate),
        ],
        check=False,
    )
    assert proc.returncode == 1
    stats = json.loads((state / "mechanism_stats.json").read_text())
    invalid_total = sum(int(v.get("invalid_count", 0) or 0) for v in stats["mechanisms"].values())
    assert invalid_total == 1
    logs = [json.loads(line) for line in (state / "iteration_log.jsonl").read_text().strip().splitlines()]
    assert logs[-1]["status"] == "invalid"


def test_rollback_check_triggers_on_large_loss(tmp_path: Path) -> None:
    state = setup_state(tmp_path)
    run_script(
        SIMPLIFIED,
        [
            "run-once",
            "--state-dir",
            str(state),
            "--definitions",
            str(DEFINITIONS),
            "--dry-run",
            "--seed",
            "2",
        ],
    )
    # Inject a severe regression entry and verify rollback-check marks trigger.
    with (state / "iteration_log.jsonl").open("a") as handle:
        handle.write(
            json.dumps(
                {
                    "iter": 999,
                    "ts": "2026-02-11T00:00:00+00:00",
                    "status": "complete",
                    "mechanism": "flow_memory",
                    "valid": True,
                    "delta": -2.5,
                    "edge": 506.30,
                    "promoted": False,
                }
            )
            + "\n"
        )
    run_script(
        SIMPLIFIED,
        [
            "rollback-check",
            "--state-dir",
            str(state),
            "--rollback-window",
            "1",
            "--rollback-cumulative-loss",
            "-0.5",
            "--rollback-severe-regression",
            "-0.5",
        ],
    )
    stats = json.loads((state / "mechanism_stats.json").read_text())
    assert stats["global"]["rollback_triggered"] is True
    assert stats["global"]["rollback_reason"] in {
        "severe_regression<=-0.5",
        "cumulative_loss_1<=-0.5",
    }


def test_shadow_selector_is_read_only_against_snapshot(tmp_path: Path) -> None:
    state = tmp_path / "state"
    snapshot = state / "migration_snapshot"
    snapshot.mkdir(parents=True, exist_ok=True)

    priors = {"adaptive_undercut_search": {"attempts": 0, "subfamilies": {}}}
    history = []
    (snapshot / ".opportunity_priors.json").write_text(json.dumps(priors))
    (snapshot / ".opportunity_history.json").write_text(json.dumps(history))
    (snapshot / ".best_edge.txt").write_text("508.80\n")

    before_priors = (snapshot / ".opportunity_priors.json").read_text()
    before_history = (snapshot / ".opportunity_history.json").read_text()

    run_script(
        SHADOW,
        [
            "--state-dir",
            str(state),
            "--snapshot-dir",
            str(snapshot),
            "--iteration",
            "1",
            "--engine-script",
            str(ROOT / "scripts" / "amm-phase7-opportunity-engine.py"),
        ],
    )

    assert (state / "shadow_selections.jsonl").exists()
    rows = (state / "shadow_selections.jsonl").read_text().strip().splitlines()
    assert len(rows) == 1
    payload = json.loads(rows[0])
    assert payload["status"] == "ok"
    assert payload["iter"] == 1
    assert (snapshot / ".opportunity_priors.json").read_text() == before_priors
    assert (snapshot / ".opportunity_history.json").read_text() == before_history
