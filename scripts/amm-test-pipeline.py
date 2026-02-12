#!/usr/bin/env python3
"""
AMM Test Pipeline
Complete testing workflow: validation → compilation → simulation

Supports seed robustness testing via --seed-offset flag for testing
strategies across different random seed batches.

Usage:
    python scripts/amm-test-pipeline.py strategy.sol --output result.json
    python scripts/amm-test-pipeline.py strategy.sol --output result.json --seed-offset 1000
"""

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime
from decimal import Decimal
from pathlib import Path

from amm_competition.competition.config import (
    BASELINE_SETTINGS,
    BASELINE_VARIANCE,
    baseline_nominal_retail_rate,
    baseline_nominal_retail_size,
    baseline_nominal_sigma,
    resolve_n_workers,
)
from amm_competition.competition.match import HyperparameterVariance
from amm_competition.competition.match import MatchRunner
from amm_competition.evm.adapter import EVMStrategyAdapter
from amm_competition.evm.baseline import load_vanilla_strategy
from amm_competition.evm.compiler import SolidityCompiler
from amm_competition.evm.validator import SolidityValidator

import amm_sim_rs

try:
    import numpy as np
    NUMPY_AVAILABLE = True
except ImportError:
    NUMPY_AVAILABLE = False


def log(message: str, level: str = "INFO"):
    """Simple logging."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{level}] {message}")


def get_git_sha() -> str:
    """Get current git commit SHA (short form)."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
            cwd=Path(__file__).parent.parent
        )
        return result.stdout.strip() if result.returncode == 0 else "unknown"
    except Exception:
        return "unknown"


def check_git_dirty() -> bool:
    """Check if working directory has uncommitted changes."""
    try:
        result = subprocess.run(
            ["git", "status", "--porcelain"],
            capture_output=True,
            text=True,
            check=False,
            cwd=Path(__file__).parent.parent
        )
        return bool(result.stdout.strip()) if result.returncode == 0 else False
    except Exception:
        return False


def extract_hypothesis_from_plan(task_num: str, plan_path: str = ".ralph-amm/state/@strategy_plan.md") -> str:
    """
    Parse plan file to find task and extract Hypothesis: H-XXX line.

    Args:
        task_num: Task number like "1.1" or "2.3"
        plan_path: Path to strategy plan file

    Returns:
        Hypothesis ID(s) like "H-002" or "H-002,H-006", or "H-baseline" as fallback
    """
    try:
        plan = Path(plan_path).read_text()

        # Find task block (lines starting with "- [x]" or "- [ ]" followed by task number)
        pattern = rf"- \[[x ]\] {re.escape(task_num)}:.*?(?=^- \[|\Z)"
        match = re.search(pattern, plan, re.MULTILINE | re.DOTALL)

        if match:
            task_block = match.group(0)
            # Extract "Hypothesis: H-XXX,H-YYY"
            hyp_match = re.search(r"Hypothesis:\s*(H-[^,\n]+(?:,\s*H-[^,\n]+)*)", task_block)
            if hyp_match:
                # Clean up spaces
                hyp_ids = hyp_match.group(1)
                return ','.join([h.strip() for h in hyp_ids.split(',')])
    except Exception as e:
        log(f"Failed to extract hypothesis from plan: {e}", "WARN")

    return "H-baseline"  # fallback


def extract_detailed_metrics(match_result) -> dict:
    """
    Extract comprehensive metrics from MatchResult.simulation_results.

    Args:
        match_result: MatchResult object with simulation_results populated

    Returns:
        Dict with submission/normalizer edges, volumes, fees, percentiles
    """
    if not hasattr(match_result, 'simulation_results') or not match_result.simulation_results:
        return {}

    if not NUMPY_AVAILABLE:
        log("NumPy not available, skipping detailed metrics", "WARN")
        return {}

    try:
        # Extract per-simulation data
        edges_submission = [float(sr.edges.get('submission', 0)) for sr in match_result.simulation_results]
        edges_normalizer = [float(sr.edges.get('normalizer', 0)) for sr in match_result.simulation_results]

        retail_vols_sub = [float(sr.retail_volume_y.get('submission', 0)) for sr in match_result.simulation_results]
        retail_vols_norm = [float(sr.retail_volume_y.get('normalizer', 0)) for sr in match_result.simulation_results]

        arb_vols_sub = [float(sr.arb_volume_y.get('submission', 0)) for sr in match_result.simulation_results]
        arb_vols_norm = [float(sr.arb_volume_y.get('normalizer', 0)) for sr in match_result.simulation_results]

        # Extract fees (average_fees is a tuple of (bid_fee, ask_fee))
        fees_sub = [sr.average_fees.get('submission', (0, 0)) for sr in match_result.simulation_results]

        return {
            "submission_edge": float(np.mean(edges_submission)),
            "normalizer_edge": float(np.mean(edges_normalizer)),
            "edge_advantage": float(np.mean(edges_submission) - np.mean(edges_normalizer)),

            "submission_retail_volume": float(np.mean(retail_vols_sub)),
            "normalizer_retail_volume": float(np.mean(retail_vols_norm)),
            "retail_volume_advantage": float(np.mean(retail_vols_sub) - np.mean(retail_vols_norm)),

            "submission_arb_volume": float(np.mean(arb_vols_sub)),
            "normalizer_arb_volume": float(np.mean(arb_vols_norm)),
            "arb_volume_advantage": float(np.mean(arb_vols_sub) - np.mean(arb_vols_norm)),

            "submission_avg_bid_fee": float(np.mean([f[0] for f in fees_sub])),
            "submission_avg_ask_fee": float(np.mean([f[1] for f in fees_sub])),
            "fee_asymmetry": float(np.mean([f[1] - f[0] for f in fees_sub])),

            "edge_percentiles": {
                "p05": float(np.percentile(edges_submission, 5)),
                "p50": float(np.percentile(edges_submission, 50)),
                "p95": float(np.percentile(edges_submission, 95)),
            },

            "wins": match_result.wins_a,
            "losses": match_result.wins_b,
            "draws": match_result.draws,
        }
    except Exception as e:
        log(f"Failed to extract detailed metrics: {e}", "WARN")
        return {}


def run_simulations(strategy: EVMStrategyAdapter, n_sims: int, store_results: bool = False, seed_offset: int = 0):
    """
    Run n simulations and return average edge or detailed results.

    Args:
        strategy: EVMStrategyAdapter instance
        n_sims: Number of simulations to run
        store_results: If True, return (avg_edge, match_result), else just avg_edge
        seed_offset: Seed offset for robustness testing (default: 0)

    Returns:
        Average edge score (float), or tuple of (avg_edge, match_result) if store_results=True
    """
    config = amm_sim_rs.SimulationConfig(
        n_steps=BASELINE_SETTINGS.n_steps,
        initial_price=BASELINE_SETTINGS.initial_price,
        initial_x=BASELINE_SETTINGS.initial_x,
        initial_y=BASELINE_SETTINGS.initial_y,
        gbm_mu=BASELINE_SETTINGS.gbm_mu,
        gbm_sigma=baseline_nominal_sigma(),
        gbm_dt=BASELINE_SETTINGS.gbm_dt,
        retail_arrival_rate=baseline_nominal_retail_rate(),
        retail_mean_size=baseline_nominal_retail_size(),
        retail_size_sigma=BASELINE_SETTINGS.retail_size_sigma,
        retail_buy_prob=BASELINE_SETTINGS.retail_buy_prob,
        seed=None,
    )

    normalizer = load_vanilla_strategy()
    runner = MatchRunner(
        n_simulations=n_sims,
        config=config,
        n_workers=resolve_n_workers(),
        variance=BASELINE_VARIANCE,
        seed_offset=seed_offset,
    )

    result = runner.run_match(strategy, normalizer, store_results=store_results)
    avg_edge = float(result.total_edge_a / n_sims)

    if store_results:
        return avg_edge, result
    else:
        return avg_edge


def run_regime_simulations(
    strategy: EVMStrategyAdapter,
    n_sims: int,
    gbm_sigma: float = None,
    retail_rate: float = None,
    retail_size: float = None,
    seed_offset: int = 0,
) -> float:
    """
    Run simulations with specific regime parameters (no variance).

    Args:
        strategy: EVMStrategyAdapter instance
        n_sims: Number of simulations to run
        gbm_sigma: Override GBM sigma (volatility)
        retail_rate: Override retail arrival rate
        retail_size: Override retail mean size
        seed_offset: Seed offset for reproducibility

    Returns:
        Average edge score
    """
    # Use provided values or fall back to nominal
    sigma = gbm_sigma if gbm_sigma is not None else baseline_nominal_sigma()
    rate = retail_rate if retail_rate is not None else baseline_nominal_retail_rate()
    size = retail_size if retail_size is not None else baseline_nominal_retail_size()

    config = amm_sim_rs.SimulationConfig(
        n_steps=BASELINE_SETTINGS.n_steps,
        initial_price=BASELINE_SETTINGS.initial_price,
        initial_x=BASELINE_SETTINGS.initial_x,
        initial_y=BASELINE_SETTINGS.initial_y,
        gbm_mu=BASELINE_SETTINGS.gbm_mu,
        gbm_sigma=sigma,
        gbm_dt=BASELINE_SETTINGS.gbm_dt,
        retail_arrival_rate=rate,
        retail_mean_size=size,
        retail_size_sigma=BASELINE_SETTINGS.retail_size_sigma,
        retail_buy_prob=BASELINE_SETTINGS.retail_buy_prob,
        seed=None,
    )

    # No variance - test at exact regime point
    no_variance = HyperparameterVariance(
        retail_mean_size_min=size,
        retail_mean_size_max=size,
        vary_retail_mean_size=False,
        retail_arrival_rate_min=rate,
        retail_arrival_rate_max=rate,
        vary_retail_arrival_rate=False,
        gbm_sigma_min=sigma,
        gbm_sigma_max=sigma,
        vary_gbm_sigma=False,
    )

    normalizer = load_vanilla_strategy()
    runner = MatchRunner(
        n_simulations=n_sims,
        config=config,
        n_workers=resolve_n_workers(),
        variance=no_variance,
        seed_offset=seed_offset,
    )

    result = runner.run_match(strategy, normalizer, store_results=False)
    return float(result.total_edge_a / n_sims)


def run_regime_tests(strategy: EVMStrategyAdapter, n_sims: int = 100) -> dict:
    """
    Test strategy at 4 extreme regime corners to find weaknesses.

    Regimes tested:
    - high_vol: Maximum volatility (gbm_sigma = 0.001008)
    - low_vol: Minimum volatility (gbm_sigma = 0.000882)
    - high_retail: Maximum retail activity (rate=1.0, size=21)
    - low_retail: Minimum retail activity (rate=0.6, size=19)

    Args:
        strategy: EVMStrategyAdapter instance
        n_sims: Number of simulations per regime (default: 100)

    Returns:
        Dict with edge at each regime, spread, and weakness flags
    """
    # Extract regime bounds from config
    sigma_min = BASELINE_VARIANCE.gbm_sigma_min  # 0.000882
    sigma_max = BASELINE_VARIANCE.gbm_sigma_max  # 0.001008
    rate_min = BASELINE_VARIANCE.retail_arrival_rate_min  # 0.6
    rate_max = BASELINE_VARIANCE.retail_arrival_rate_max  # 1.0
    size_min = BASELINE_VARIANCE.retail_mean_size_min  # 19.0
    size_max = BASELINE_VARIANCE.retail_mean_size_max  # 21.0

    log("  Running regime tests at 4 extreme corners...")

    # High volatility
    log("    → Testing high volatility regime...")
    edge_high_vol = run_regime_simulations(
        strategy, n_sims, gbm_sigma=sigma_max
    )

    # Low volatility
    log("    → Testing low volatility regime...")
    edge_low_vol = run_regime_simulations(
        strategy, n_sims, gbm_sigma=sigma_min
    )

    # High retail activity
    log("    → Testing high retail regime...")
    edge_high_retail = run_regime_simulations(
        strategy, n_sims, retail_rate=rate_max, retail_size=size_max
    )

    # Low retail activity
    log("    → Testing low retail regime...")
    edge_low_retail = run_regime_simulations(
        strategy, n_sims, retail_rate=rate_min, retail_size=size_min
    )

    # Calculate spread and identify weaknesses
    edges = [edge_high_vol, edge_low_vol, edge_high_retail, edge_low_retail]
    edge_min = min(edges)
    edge_max = max(edges)
    spread = edge_max - edge_min

    # Identify which regime is weakest
    regime_names = ["high_vol", "low_vol", "high_retail", "low_retail"]
    weakest_idx = edges.index(edge_min)
    weakest_regime = regime_names[weakest_idx]

    result = {
        "high_vol": edge_high_vol,
        "low_vol": edge_low_vol,
        "high_retail": edge_high_retail,
        "low_retail": edge_low_retail,
        "spread": spread,
        "weakest_regime": weakest_regime,
        "weakest_edge": edge_min,
        "strongest_edge": edge_max,
        "spread_warning": spread > 50,  # Flag if spread is concerning
    }

    log(f"    ✓ Regime spread: {spread:.1f} (weakest: {weakest_regime} @ {edge_min:.1f})")

    return result


def run_baseline_1000_once(strategy: EVMStrategyAdapter, seed_offset: int) -> tuple:
    """
    Run one authoritative 1000-sim baseline batch for a specific seed offset.

    Returns:
        (edge_1000, match_result, duration_seconds)
    """
    sim_start = time.time()
    edge_1000, match_result = run_simulations(
        strategy,
        n_sims=1000,
        store_results=True,
        seed_offset=seed_offset,
    )
    sim_duration = time.time() - sim_start
    return edge_1000, match_result, sim_duration


def run_pipeline(
    strategy_path: str,
    output_path: str,
    seed_offset: int = 0,
    *,
    screen_sims: int = 200,
    screen_min_edge: float = 375.0,
    predicted_drop: float = -8.2,
    predicted_min_edge: float = 500.0,
    robust_free_spread: float = 50.0,
    robust_penalty_per_point: float = 0.02,
) -> int:
    """
    Run complete testing pipeline.

    Args:
        strategy_path: Path to strategy .sol file
        output_path: Path to write JSON results
        seed_offset: Seed offset for robustness testing (default: 0)
        screen_sims: Number of simulations for first-stage screening
        screen_min_edge: Minimum screening edge to consider 1000-sim test
        predicted_drop: Expected 200->1000 edge delta (typically negative)
        predicted_min_edge: Minimum predicted 1000-sim edge to run baseline
        robust_free_spread: Corner-spread ignored before robustness penalty applies
        robust_penalty_per_point: Penalty per point of spread above robust_free_spread

    Returns:
        Exit code (0 = success, 1+ = failure at various stages)
    """
    result = {
        "success": False,
        "strategy_path": strategy_path,
        "timestamp": datetime.now().isoformat(),
        "config": {
            "screen_sims": screen_sims,
            "screen_min_edge": screen_min_edge,
            "predicted_drop": predicted_drop,
            "predicted_min_edge": predicted_min_edge,
            "robust_free_spread": robust_free_spread,
            "robust_penalty_per_point": robust_penalty_per_point,
        },
        "validation": {},
        "compilation": {},
        "testing": {},
        "runtime": {},
    }

    start_time = time.time()

    # Step 1: Validate
    log("Step 1: Validating strategy...")
    try:
        source = Path(strategy_path).read_text()
        validator = SolidityValidator()
        validation = validator.validate(source)

        result["validation"] = {
            "valid": validation.valid,
            "errors": validation.errors or [],
            "warnings": validation.warnings or [],
        }

        if not validation.valid:
            log(f"  ✗ Validation failed: {validation.errors[0]}", "ERROR")
            result["runtime"]["total_seconds"] = time.time() - start_time
            Path(output_path).write_text(json.dumps(result, indent=2))
            return 1

        log("  ✓ Validation passed")

    except Exception as e:
        log(f"  ✗ Validation error: {e}", "ERROR")
        result["validation"]["error"] = str(e)
        result["runtime"]["total_seconds"] = time.time() - start_time
        Path(output_path).write_text(json.dumps(result, indent=2))
        return 1

    # Step 2: Compile
    log("Step 2: Compiling strategy...")
    try:
        compiler = SolidityCompiler()
        compilation = compiler.compile(source)

        result["compilation"] = {
            "success": compilation.success,
            "errors": compilation.errors or [],
            "warnings": compilation.warnings or [],
        }

        if not compilation.success:
            log(f"  ✗ Compilation failed: {compilation.errors[0]}", "ERROR")
            result["runtime"]["total_seconds"] = time.time() - start_time
            Path(output_path).write_text(json.dumps(result, indent=2))
            return 2

        log("  ✓ Compilation passed")

    except Exception as e:
        log(f"  ✗ Compilation error: {e}", "ERROR")
        result["compilation"]["error"] = str(e)
        result["runtime"]["total_seconds"] = time.time() - start_time
        Path(output_path).write_text(json.dumps(result, indent=2))
        return 2

    # Step 3: Deploy to EVM
    log("Step 3: Deploying to EVM...")
    try:
        strategy = EVMStrategyAdapter(
            bytecode=compilation.bytecode,
            abi=compilation.abi,
        )
        strategy_name = strategy.get_name()
        result["strategy_name"] = strategy_name
        log(f"  ✓ Strategy deployed: {strategy_name}")

    except Exception as e:
        log(f"  ✗ EVM deployment failed: {e}", "ERROR")
        result["testing"]["deployment_error"] = str(e)
        result["runtime"]["total_seconds"] = time.time() - start_time
        Path(output_path).write_text(json.dumps(result, indent=2))
        return 3

    # Step 4: Smoke test (10 sims)
    log("Step 4: Running 10 simulations (smoke test)...")
    try:
        sim_start = time.time()
        edge_10 = run_simulations(strategy, n_sims=10, seed_offset=seed_offset)
        sim_duration = time.time() - sim_start

        result["testing"]["edge_10"] = edge_10
        result["runtime"]["smoke_10_seconds"] = sim_duration
        log(f"  ✓ Smoke test complete: Edge {edge_10:.2f} ({sim_duration:.1f}s)")

    except Exception as e:
        log(f"  ✗ Smoke test failed: {e}", "ERROR")
        result["testing"]["smoke_error"] = str(e)
        result["runtime"]["total_seconds"] = time.time() - start_time
        Path(output_path).write_text(json.dumps(result, indent=2))
        return 4

    # Step 5: Screening test (default 200 sims)
    log(f"Step 5: Running {screen_sims} simulations (screening test)...")
    try:
        sim_start = time.time()
        edge_screen = run_simulations(strategy, n_sims=screen_sims, seed_offset=seed_offset)
        sim_duration = time.time() - sim_start

        # Keep edge_100 key for backward compatibility with existing consumers.
        result["testing"]["edge_100"] = edge_screen
        result["testing"]["edge_screen"] = edge_screen
        result["testing"]["screen_sims"] = screen_sims
        result["runtime"]["screen_seconds"] = sim_duration
        log(f"  ✓ Screening test complete: Edge {edge_screen:.2f} ({sim_duration:.1f}s)")

    except Exception as e:
        log(f"  ✗ Screening test failed: {e}", "ERROR")
        result["testing"]["screen_error"] = str(e)
        result["runtime"]["total_seconds"] = time.time() - start_time
        Path(output_path).write_text(json.dumps(result, indent=2))
        return 5

    # Step 6: Baseline (1000 sims) - staged gate from screening edge
    # IMPORTANT: Only 1000-sim results are authoritative for final_edge
    predicted_edge_1000 = edge_screen + predicted_drop
    gate_pass_screen = edge_screen >= screen_min_edge
    gate_pass_predicted = predicted_edge_1000 >= predicted_min_edge
    run_1000 = gate_pass_screen and gate_pass_predicted

    result["testing"]["predicted_edge_1000"] = predicted_edge_1000
    result["testing"]["gate"] = {
        "screen_sims": screen_sims,
        "screen_min_edge": screen_min_edge,
        "predicted_drop": predicted_drop,
        "predicted_min_edge": predicted_min_edge,
        "screen_pass": gate_pass_screen,
        "predicted_pass": gate_pass_predicted,
        "run_1000": run_1000,
    }

    if run_1000:
        log(
            f"Step 6: Running 1000 simulations "
            f"(screen={edge_screen:.2f}, predicted_1000={predicted_edge_1000:.2f})..."
        )
        try:
            baseline_offsets = [seed_offset]
            if seed_offset == 20000:
                baseline_offsets = [20000, 30000]
                log("  → Seed stabilization enabled for offset 20000: averaging 20000 and 30000")

            baseline_edges = []
            baseline_duration_total = 0.0
            first_match_result = None

            for baseline_offset in baseline_offsets:
                edge_1000_run, match_result_run, sim_duration = run_baseline_1000_once(
                    strategy,
                    seed_offset=baseline_offset,
                )
                baseline_edges.append(edge_1000_run)
                baseline_duration_total += sim_duration
                if first_match_result is None:
                    first_match_result = match_result_run
                log(
                    f"  ✓ Baseline run complete (seed_offset={baseline_offset}): "
                    f"Edge {edge_1000_run:.2f} ({sim_duration:.1f}s)"
                )

            edge_1000 = sum(baseline_edges) / len(baseline_edges)
            result["testing"]["edge_1000"] = edge_1000
            result["runtime"]["baseline_1000_seconds"] = baseline_duration_total
            result["final_edge"] = edge_1000  # Only 1000-sim results set final_edge
            log(
                f"  ✓ Baseline aggregate complete: Edge {edge_1000:.2f} "
                f"(runs={len(baseline_edges)}, total={baseline_duration_total:.1f}s)"
            )

            if len(baseline_offsets) > 1:
                result["testing"]["seed_stabilization"] = {
                    "enabled": True,
                    "method": "avg_two_1000sim_batches",
                    "target_seed_offset": seed_offset,
                    "offsets": baseline_offsets,
                    "edge_1000_runs": baseline_edges,
                    "edge_1000_avg": edge_1000,
                }

            # Extract detailed metrics
            log("  → Extracting detailed metrics...")
            detailed_metrics = extract_detailed_metrics(first_match_result)
            if detailed_metrics:
                result["testing"]["metrics_1000"] = detailed_metrics
                log(f"  ✓ Detailed metrics extracted (advantage: {detailed_metrics.get('edge_advantage', 0):.2f})")

            # Step 7: Regime tests (100 sims at each extreme)
            log("Step 7: Running regime tests (4 extreme corners)...")
            try:
                regime_start = time.time()
                regime_results = run_regime_tests(strategy, n_sims=100)
                regime_duration = time.time() - regime_start

                result["testing"]["regime_tests"] = regime_results
                result["runtime"]["regime_tests_seconds"] = regime_duration

                if regime_results["spread_warning"]:
                    log(f"  ⚠ Regime spread {regime_results['spread']:.1f} > 50 - consider regime-specific tuning", "WARN")
            except Exception as e:
                log(f"  ⚠ Regime tests failed (non-fatal): {e}", "WARN")
                result["testing"]["regime_tests_error"] = str(e)

            # Robustness-adjusted score for selection/champion logic.
            spread = None
            try:
                spread = float(result.get("testing", {}).get("regime_tests", {}).get("spread"))
            except Exception:
                spread = None

            penalty = 0.0
            if spread is not None:
                penalty = max(0.0, spread - robust_free_spread) * robust_penalty_per_point
            run_scores = [edge_run - penalty for edge_run in baseline_edges]
            final_score = sum(run_scores) / len(run_scores)
            result["final_score"] = final_score
            result["testing"]["robustness"] = {
                "base_edge_1000": edge_1000,
                "spread": spread,
                "free_spread": robust_free_spread,
                "penalty_per_point": robust_penalty_per_point,
                "penalty": penalty,
                "final_score": final_score,
            }
            if len(baseline_offsets) > 1:
                stabilization = result["testing"].get("seed_stabilization", {})
                if isinstance(stabilization, dict):
                    stabilization["final_score_runs"] = run_scores
                    stabilization["final_score_avg"] = final_score

        except Exception as e:
            log(f"  ✗ Baseline test failed: {e}", "ERROR")
            result["testing"]["baseline_error"] = str(e)
            # Don't set final_edge from 100-sim fallback - leave it unset
            result["final_edge"] = None
            result["final_score"] = None
    else:
        reasons = []
        if not gate_pass_screen:
            reasons.append(f"screen {edge_screen:.2f} < {screen_min_edge:.2f}")
        if not gate_pass_predicted:
            reasons.append(f"predicted_1000 {predicted_edge_1000:.2f} < {predicted_min_edge:.2f}")
        reason_text = "; ".join(reasons) if reasons else "gate not satisfied"
        log(f"  → Skipping 1000 sims ({reason_text})")
        # Don't set final_edge - only 1000-sim results are authoritative
        result["final_edge"] = None
        result["final_score"] = None

    # Add git SHA and hypothesis ID
    result["git_sha"] = get_git_sha()
    result["git_dirty"] = check_git_dirty()

    # Try to extract hypothesis ID from strategy plan if this looks like a generated strategy
    if ".ralph-amm/generated/strategy_" in strategy_path:
        # Extract task number from filename (e.g., strategy_003_task_1_3.sol -> "1.3")
        task_match = re.search(r'task_(\d+)_(\d+)', strategy_path)
        if task_match:
            task_num = f"{task_match.group(1)}.{task_match.group(2)}"
            hypothesis_id = extract_hypothesis_from_plan(task_num)
            result["hypothesis_id"] = hypothesis_id
            log(f"  → Hypothesis: {hypothesis_id}")

    # Success
    result["success"] = True
    result["runtime"]["total_seconds"] = time.time() - start_time
    Path(output_path).write_text(json.dumps(result, indent=2))

    log("=" * 60)
    log(f"Pipeline Complete: {strategy_name}")
    final_edge = result.get("final_edge")
    final_score = result.get("final_score")
    log(f"  Final Edge: {final_edge:.2f}" if final_edge is not None else "  Final Edge: N/A (no 1000-sim run)")
    if final_score is not None:
        log(f"  Final Score (robust): {final_score:.2f}")
    log(f"  Total Runtime: {result['runtime']['total_seconds']:.1f}s")
    log("=" * 60)

    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Run complete AMM strategy testing pipeline",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Test a generated strategy
  python scripts/amm-test-pipeline.py \\
    .ralph-amm/generated/strategy_001.sol \\
    --output .ralph-amm/state/last_result.json

  # Test StarterStrategy baseline
  python scripts/amm-test-pipeline.py \\
    contracts/src/StarterStrategy.sol \\
    --output /tmp/baseline_result.json
""",
    )

    parser.add_argument(
        "strategy",
        help="Path to strategy .sol file to test",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Path to write JSON result output",
    )
    parser.add_argument(
        "--seed-offset",
        type=int,
        default=0,
        help="Seed offset for robustness testing (default: 0 for standard seeds)",
    )
    parser.add_argument(
        "--screen-sims",
        type=int,
        default=200,
        help="Simulations for first-stage screening (default: 200)",
    )
    parser.add_argument(
        "--screen-min-edge",
        type=float,
        default=375.0,
        help="Minimum screening edge to consider 1000-sim run (default: 375.0)",
    )
    parser.add_argument(
        "--predicted-drop",
        type=float,
        default=-8.2,
        help="Expected edge delta from screen_sims to 1000 sims (default: -8.2)",
    )
    parser.add_argument(
        "--predicted-min-edge",
        type=float,
        default=500.0,
        help="Minimum predicted 1000-sim edge to run baseline (default: 500.0)",
    )
    parser.add_argument(
        "--robust-free-spread",
        type=float,
        default=50.0,
        help="Corner spread with zero robustness penalty (default: 50.0)",
    )
    parser.add_argument(
        "--robust-penalty-per-point",
        type=float,
        default=0.02,
        help="Penalty per spread point above free spread (default: 0.02)",
    )

    args = parser.parse_args()

    # Verify strategy file exists
    if not Path(args.strategy).exists():
        print(f"Error: Strategy file not found: {args.strategy}", file=sys.stderr)
        sys.exit(1)

    # Ensure output directory exists
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)

    # Run pipeline
    exit_code = run_pipeline(
        args.strategy,
        args.output,
        seed_offset=args.seed_offset,
        screen_sims=args.screen_sims,
        screen_min_edge=args.screen_min_edge,
        predicted_drop=args.predicted_drop,
        predicted_min_edge=args.predicted_min_edge,
        robust_free_spread=args.robust_free_spread,
        robust_penalty_per_point=args.robust_penalty_per_point,
    )
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
