import argparse
import json
import importlib.util
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


def load_simplified_module():
    spec = importlib.util.spec_from_file_location("simplified_loop_module", SIMPLIFIED)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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


def test_anchor_boundaries_allow_validation_with_line_drift(tmp_path: Path) -> None:
    state = tmp_path / "state"
    state.mkdir(parents=True, exist_ok=True)
    champion = """pragma solidity ^0.8.24;

contract Strategy {
    uint256[8] public slots;

    function afterInitialize(uint256 initialX, uint256 initialY) external returns (uint256 bidFee, uint256 askFee) {
        initialX; initialY;
        slots[0] = type(uint256).max;
        slots[3] = 1;
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function afterSwap() external returns (uint256 bidFee, uint256 askFee) {
        uint256 spot = 1;
        uint256 fair = 1;
        uint256 mis = wdiv(absDiff(spot, fair), fair);
        uint256 tightBand = bpsToWad(25);
        if (mis <= tightBand) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
        }
        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function getName() external pure returns (string memory) { return "Base"; }
    function wdiv(uint256 a, uint256 b) internal pure returns (uint256) { return a / b; }
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) { return a > b ? a - b : b - a; }
    function bpsToWad(uint256 a) internal pure returns (uint256) { return a; }
    function clampFee(uint256 a) internal pure returns (uint256) { return a; }
}
"""
    (state / ".best_strategy.sol").write_text(champion)
    (state / ".best_edge.txt").write_text("508.80\n")

    definitions = tmp_path / "definitions.json"
    definitions.write_text(
        json.dumps(
            {
                "schema_version": "1.0",
                "champion_file": ".best_strategy.sol",
                "champion_edge": 508.80,
                "mechanisms": {
                    "flow_memory": {
                        "current_implementation": "anchor-driven test mechanism",
                        "code_location": "afterSwap lines 1-1",
                        "anchors": [
                            {
                                "start": "uint256 mis = wdiv(absDiff(spot, fair), fair);",
                                "end": "uint256 tightBand = bpsToWad(25);",
                            }
                        ],
                        "parameters": {},
                        "modification_directions": [],
                    }
                },
            }
        )
    )

    candidate = (
        champion.replace(
            "uint256[8] public slots;",
            "uint256[8] public slots;\n    // flow memory slot reserved",
        )
        .replace(
            "uint256 tightBand = bpsToWad(25);",
            "uint256 flowMemory = 0;\n        uint256 tightBand = bpsToWad(26);",
        )
    )
    candidate_path = tmp_path / "candidate_anchor.sol"
    candidate_path.write_text(candidate)

    proc = run_script(
        SIMPLIFIED,
        [
            "run-once",
            "--state-dir",
            str(state),
            "--definitions",
            str(definitions),
            "--candidate-file",
            str(candidate_path),
            "--dry-run",
        ],
        check=False,
    )
    assert proc.returncode == 0
    logs = [json.loads(line) for line in (state / "iteration_log.jsonl").read_text().strip().splitlines()]
    assert logs[-1]["status"] == "complete"
    assert logs[-1]["mechanism"] == "flow_memory"


def test_allowed_overlap_with_permits_configured_non_target_edits() -> None:
    module = load_simplified_module()
    champion = """pragma solidity ^0.8.24;

contract Strategy {
    function afterSwap() external returns (uint256 bidFee, uint256 askFee) {
        uint256 spot = 1;
        uint256 fair = 1;
        uint256 mis = wdiv(absDiff(spot, fair), fair);
        uint256 tightBand = bpsToWad(25);
        if (mis <= tightBand) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
        }
        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
    }

    function getName() external pure returns (string memory) { return "Base"; }
    function wdiv(uint256 a, uint256 b) internal pure returns (uint256) { return a / b; }
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) { return a > b ? a - b : b - a; }
    function bpsToWad(uint256 a) internal pure returns (uint256) { return a; }
    function clampFee(uint256 a) internal pure returns (uint256) { return a; }
}
"""
    candidate = (
        champion.replace("uint256 fair = 1;", "uint256 fair = 2;")
        .replace("uint256 tightBand = bpsToWad(25);", "uint256 tightBand = bpsToWad(26);")
    )
    definitions = {
        "mechanisms": {
            "fair_price_estimation": {
                "anchors": [
                    {"start": "uint256 spot = 1;", "end": "uint256 fair = 1;"}
                ]
            },
            "flow_memory": {
                "allowed_overlap_with": ["fair_price_estimation"],
                "anchors": [
                    {"start": "uint256 mis = wdiv(absDiff(spot, fair), fair);", "end": "uint256 tightBand = bpsToWad(25);"}
                ],
            },
        }
    }

    ok, reason = module.validate_candidate(champion, candidate, "flow_memory", definitions)
    assert ok is True
    assert reason == "valid"


def test_disallowed_overlap_still_fails() -> None:
    module = load_simplified_module()
    champion = """pragma solidity ^0.8.24;

contract Strategy {
    function afterSwap() external returns (uint256 bidFee, uint256 askFee) {
        uint256 spot = 1;
        uint256 fair = 1;
        uint256 mis = wdiv(absDiff(spot, fair), fair);
        uint256 tightBand = bpsToWad(25);
        if (mis <= tightBand) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
        }
        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
    }

    function getName() external pure returns (string memory) { return "Base"; }
    function wdiv(uint256 a, uint256 b) internal pure returns (uint256) { return a / b; }
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) { return a > b ? a - b : b - a; }
    function bpsToWad(uint256 a) internal pure returns (uint256) { return a; }
    function clampFee(uint256 a) internal pure returns (uint256) { return a; }
}
"""
    candidate = (
        champion.replace("uint256 fair = 1;", "uint256 fair = 2;")
        .replace("uint256 tightBand = bpsToWad(25);", "uint256 tightBand = bpsToWad(26);")
    )
    definitions = {
        "mechanisms": {
            "fair_price_estimation": {
                "anchors": [
                    {"start": "uint256 spot = 1;", "end": "uint256 fair = 1;"}
                ]
            },
            "flow_memory": {
                "allowed_overlap_with": [],
                "anchors": [
                    {"start": "uint256 mis = wdiv(absDiff(spot, fair), fair);", "end": "uint256 tightBand = bpsToWad(25);"}
                ],
            },
        }
    }

    ok, reason = module.validate_candidate(champion, candidate, "flow_memory", definitions)
    assert ok is False
    assert reason == "non-target mechanism 'fair_price_estimation' was modified"


def test_validate_policy_definitions_rejects_missing_existing_mechanisms() -> None:
    module = load_simplified_module()
    champion = """pragma solidity ^0.8.24;

contract Strategy {
    function afterSwap() external returns (uint256 bidFee, uint256 askFee) {
        uint256 spot = 1;
        uint256 fair = 1;
        uint256 mis = wdiv(absDiff(spot, fair), fair);
        uint256 tightBand = bpsToWad(25);
        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
    }
    function getName() external pure returns (string memory) { return "Base"; }
    function wdiv(uint256 a, uint256 b) internal pure returns (uint256) { return a / b; }
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) { return a > b ? a - b : b - a; }
    function bpsToWad(uint256 a) internal pure returns (uint256) { return a; }
    function clampFee(uint256 a) internal pure returns (uint256) { return a; }
}
"""
    current_defs = {
        "schema_version": "1.0",
        "champion_file": ".best_strategy.sol",
        "champion_edge": 508.80,
        "mechanisms": {
            "fair_price_estimation": {
                "anchors": [{"start": "uint256 spot = 1;", "end": "uint256 fair = 1;"}],
                "allowed_overlap_with": [],
            },
            "flow_memory": {
                "anchors": [{"start": "uint256 mis = wdiv(absDiff(spot, fair), fair);", "end": "uint256 tightBand = bpsToWad(25);"}],
                "allowed_overlap_with": [],
            },
        },
    }
    candidate_defs = {
        "schema_version": "1.0",
        "champion_file": ".best_strategy.sol",
        "champion_edge": 508.80,
        "mechanisms": {
            "flow_memory": {
                "anchors": [{"start": "uint256 mis = wdiv(absDiff(spot, fair), fair);", "end": "uint256 tightBand = bpsToWad(25);"}],
                "allowed_overlap_with": [],
            }
        },
    }

    valid, reason, report = module.validate_policy_definitions(candidate_defs, current_defs, champion)
    assert valid is False
    assert reason.startswith("missing_existing_mechanisms:")
    assert "fair_price_estimation" in report["missing_mechanisms"]


def test_shadow_score_policy_candidate_detects_rescue(tmp_path: Path) -> None:
    module = load_simplified_module()
    champion = """pragma solidity ^0.8.24;

contract Strategy {
    function afterSwap() external returns (uint256 bidFee, uint256 askFee) {
        uint256 spot = 1;
        uint256 fair = 1;
        uint256 mis = wdiv(absDiff(spot, fair), fair);
        uint256 tightBand = bpsToWad(25);
        if (mis <= tightBand) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
        }
        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
    }

    function getName() external pure returns (string memory) { return "Base"; }
    function wdiv(uint256 a, uint256 b) internal pure returns (uint256) { return a / b; }
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) { return a > b ? a - b : b - a; }
    function bpsToWad(uint256 a) internal pure returns (uint256) { return a; }
    function clampFee(uint256 a) internal pure returns (uint256) { return a; }
}
"""
    candidate = (
        champion.replace("uint256 fair = 1;", "uint256 fair = 2;")
        .replace("uint256 tightBand = bpsToWad(25);", "uint256 tightBand = bpsToWad(26);")
    )

    current_defs = {
        "mechanisms": {
            "fair_price_estimation": {
                "anchors": [{"start": "uint256 spot = 1;", "end": "uint256 fair = 1;"}],
                "allowed_overlap_with": [],
            },
            "flow_memory": {
                "anchors": [{"start": "uint256 mis = wdiv(absDiff(spot, fair), fair);", "end": "uint256 tightBand = bpsToWad(25);"}],
                "allowed_overlap_with": [],
            },
        }
    }
    candidate_defs = {
        "mechanisms": {
            "fair_price_estimation": {
                "anchors": [{"start": "uint256 spot = 1;", "end": "uint256 fair = 1;"}],
                "allowed_overlap_with": [],
            },
            "flow_memory": {
                "anchors": [{"start": "uint256 mis = wdiv(absDiff(spot, fair), fair);", "end": "uint256 tightBand = bpsToWad(25);"}],
                "allowed_overlap_with": ["fair_price_estimation"],
            },
        }
    }
    candidate_path = tmp_path / "tmp_shadow_candidate.sol"
    candidate_path.write_text(candidate)
    try:
        shadow = module.shadow_score_policy_candidate(
            champion_code=champion,
            current_definitions=current_defs,
            candidate_definitions=candidate_defs,
            log_entries=[{"mechanism": "flow_memory", "candidate_path": str(candidate_path)}],
            lookback=5,
        )
    finally:
        candidate_path.unlink(missing_ok=True)

    assert int(shadow["replayed_candidates"]) == 1
    assert int(shadow["rescued_validations"]) == 1
    assert int(shadow["regressed_validations"]) == 0


def test_maybe_run_policy_evolution_dry_run_records_state(tmp_path: Path) -> None:
    module = load_simplified_module()
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
            "17",
        ],
    )
    args = argparse.Namespace(
        state_dir=str(state),
        definitions=str(DEFINITIONS),
        dry_run=True,
        llm_command="codex",
        llm_model="",
        llm_timeout_minutes=1.0,
        llm_max_output_tokens=2000,
        llm_disable_shell_tool=False,
        policy_evolution_frequency=1,
    )
    entry = module.maybe_run_policy_evolution(args, completed_iteration=1)
    assert isinstance(entry, dict)
    assert entry["status"] == "policy_skipped_dry_run"
    assert (state / "policy_evolution_log.jsonl").exists()
    assert (state / "policy_evolution_state.json").exists()


def test_validate_candidate_avoids_false_failure_on_anchor_drift() -> None:
    module = load_simplified_module()
    champion = """pragma solidity ^0.8.24;

contract Strategy {
    function afterSwap() external returns (uint256 bidFee, uint256 askFee) {
        uint256 spot = 1;
        uint256 fair = 1;
        uint256 mis = wdiv(absDiff(spot, fair), fair);
        uint256 tightBand = bpsToWad(25);
        if (mis <= tightBand) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
        }
        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
    }
    function getName() external pure returns (string memory) { return "Base"; }
    function wdiv(uint256 a, uint256 b) internal pure returns (uint256) { return a / b; }
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) { return a > b ? a - b : b - a; }
    function bpsToWad(uint256 a) internal pure returns (uint256) { return a; }
    function clampFee(uint256 a) internal pure returns (uint256) { return a; }
}
"""
    candidate = champion.replace(
        "uint256 mis = wdiv(absDiff(spot, fair), fair);\n        uint256 tightBand = bpsToWad(25);\n        if (mis <= tightBand) {",
        "if (wdiv(absDiff(spot, fair), fair) <= _tightBandFromFlowMemory()) {",
    )
    candidate = candidate.replace(
        "function clampFee(uint256 a) internal pure returns (uint256) { return a; }",
        "function _tightBandFromFlowMemory() internal pure returns (uint256) { return bpsToWad(26); }\n    function clampFee(uint256 a) internal pure returns (uint256) { return a; }",
    )
    definitions = {
        "mechanisms": {
            "flow_memory": {
                "allowed_overlap_with": [],
                "anchors": [
                    {"start": "uint256 mis = wdiv(absDiff(spot, fair), fair);", "end": "uint256 tightBand = bpsToWad(25);"}
                ],
            },
            "tight_band_pricing": {
                "allowed_overlap_with": [],
                "anchors": [
                    {"start": "if (mis <= tightBand) {", "end": "askFee = bpsToWad(30);"}
                ],
            },
        }
    }

    ok, reason = module.validate_candidate(champion, candidate, "flow_memory", definitions)
    assert ok is True
    assert reason == "valid"


def test_parse_seed_offsets_handles_invalid_tokens() -> None:
    module = load_simplified_module()
    assert module.parse_seed_offsets("0, 10000,abc, ,20000") == [0, 10000, 20000]
    assert module.parse_seed_offsets("") == [0]


def test_evaluate_with_pipeline_accepts_screen_only_results(tmp_path: Path) -> None:
    module = load_simplified_module()
    candidate = tmp_path / "candidate.sol"
    candidate.write_text("pragma solidity ^0.8.24; contract Strategy {}")
    result_path = tmp_path / "result.json"

    class FakeProc:
        def __init__(self) -> None:
            self.returncode = 0
            self.stdout = ""
            self.stderr = ""

    original_run = module.subprocess.run
    try:
        def fake_run(cmd, capture_output=False, text=False):  # type: ignore[no-untyped-def]
            output_path = Path(cmd[cmd.index("--output") + 1])
            seed_offset = int(cmd[cmd.index("--seed-offset") + 1])
            payload = {
                "final_edge": None,
                "final_score": None,
                "testing": {"edge_screen": 510.0 + seed_offset / 100000.0},
            }
            output_path.write_text(json.dumps(payload))
            return FakeProc()

        module.subprocess.run = fake_run
        summary, error = module.evaluate_with_pipeline(
            candidate_path=candidate,
            result_path=result_path,
            python_exe="python3",
            screen_sims=200,
            seed_offsets="0,10000,20000",
            promotion_std_penalty=0.5,
        )
    finally:
        module.subprocess.run = original_run

    assert error is None
    assert summary is not None
    assert summary["screen_only"] is True
    assert summary["promotable"] is False
    assert int(summary["seed_count"]) == 3


def test_bootstrap_champion_selects_best_candidate(tmp_path: Path) -> None:
    module = load_simplified_module()
    state = tmp_path / "state"
    state.mkdir(parents=True, exist_ok=True)
    (state / ".best_strategy.sol").write_text("pragma solidity ^0.8.24; contract Strategy { function getName() external pure returns (string memory) { return \"old\"; } }")
    (state / ".best_edge.txt").write_text("500.00\n")

    definitions_path = tmp_path / "definitions.json"
    definitions_payload = {
        "schema_version": "1.0",
        "champion_file": ".best_strategy.sol",
        "champion_edge": 500.0,
        "mechanisms": {
            "fair_price_and_arb": {
                "current_implementation": "",
                "code_location": "x",
                "allowed_overlap_with": [],
                "anchors": [{"start": "pragma", "end": "contract Strategy"}],
                "parameters": {},
                "modification_directions": [],
            }
        },
    }
    definitions_path.write_text(json.dumps(definitions_payload))
    install_definitions = tmp_path / "definitions_bandshield.json"
    install_definitions.write_text(json.dumps(definitions_payload))

    source_a = tmp_path / "a.sol"
    source_b = tmp_path / "b.sol"
    source_a.write_text("pragma solidity ^0.8.24; contract Strategy { function getName() external pure returns (string memory) { return \"A\"; } }")
    source_b.write_text("pragma solidity ^0.8.24; contract Strategy { function getName() external pure returns (string memory) { return \"B\"; } }")

    original_eval = module.evaluate_with_pipeline
    try:
        def fake_eval(candidate_path, result_path, python_exe, screen_sims, seed_offsets, promotion_std_penalty):  # type: ignore[no-untyped-def]
            if str(candidate_path).endswith("a.sol"):
                return {
                    "primary_edge": 510.0,
                    "promotion_edge": 510.0,
                    "promotable": True,
                    "screen_only": False,
                    "seed_count": 3,
                    "seed_offsets": [0, 10000, 20000],
                    "seed_results": [],
                }, None
            return {
                "primary_edge": 520.0,
                "promotion_edge": 520.0,
                "promotable": True,
                "screen_only": False,
                "seed_count": 3,
                "seed_offsets": [0, 10000, 20000],
                "seed_results": [],
            }, None

        module.evaluate_with_pipeline = fake_eval
        args = argparse.Namespace(
            state_dir=str(state),
            definitions=str(definitions_path),
            from_paths=[str(source_a), str(source_b)],
            install_definitions=str(install_definitions),
            python_exe="python3",
            screen_sims=200,
            seed_offsets="0,10000,20000",
            promotion_std_penalty=0.5,
            exploration_c=0.5,
            improvement_threshold=0.02,
            max_retries_on_invalid=2,
            wildcard_frequency=10,
        )
        code = module.bootstrap_champion(args)
    finally:
        module.evaluate_with_pipeline = original_eval

    assert code == 0
    assert "return \"B\";" in (state / ".best_strategy.sol").read_text()
    assert (state / ".best_edge.txt").read_text().strip() == "520.00"
    assert (state / "mechanism_stats.json").exists()
