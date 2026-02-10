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


def run_pipeline(strategy_path: str, output_path: str, seed_offset: int = 0) -> int:
    """
    Run complete testing pipeline.

    Args:
        strategy_path: Path to strategy .sol file
        output_path: Path to write JSON results
        seed_offset: Seed offset for robustness testing (default: 0)

    Returns:
        Exit code (0 = success, 1+ = failure at various stages)
    """
    result = {
        "success": False,
        "strategy_path": strategy_path,
        "timestamp": datetime.now().isoformat(),
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

    # Step 5: Dev test (100 sims)
    log("Step 5: Running 100 simulations (development test)...")
    try:
        sim_start = time.time()
        edge_100 = run_simulations(strategy, n_sims=100, seed_offset=seed_offset)
        sim_duration = time.time() - sim_start

        result["testing"]["edge_100"] = edge_100
        result["runtime"]["dev_100_seconds"] = sim_duration
        log(f"  ✓ Dev test complete: Edge {edge_100:.2f} ({sim_duration:.1f}s)")

    except Exception as e:
        log(f"  ✗ Dev test failed: {e}", "ERROR")
        result["testing"]["dev_error"] = str(e)
        result["runtime"]["total_seconds"] = time.time() - start_time
        Path(output_path).write_text(json.dumps(result, indent=2))
        return 5

    # Step 6: Baseline (1000 sims) - conditional with enhanced metrics
    # IMPORTANT: Only 1000-sim results are authoritative for final_edge
    threshold = 375.0
    if edge_100 > threshold:
        log(f"Step 6: Running 1000 simulations (edge {edge_100:.2f} > {threshold} threshold)...")
        try:
            sim_start = time.time()
            edge_1000, match_result = run_simulations(strategy, n_sims=1000, store_results=True, seed_offset=seed_offset)
            sim_duration = time.time() - sim_start

            result["testing"]["edge_1000"] = edge_1000
            result["runtime"]["baseline_1000_seconds"] = sim_duration
            result["final_edge"] = edge_1000  # Only 1000-sim results set final_edge
            log(f"  ✓ Baseline complete: Edge {edge_1000:.2f} ({sim_duration:.1f}s)")

            # Extract detailed metrics
            log("  → Extracting detailed metrics...")
            detailed_metrics = extract_detailed_metrics(match_result)
            if detailed_metrics:
                result["testing"]["metrics_1000"] = detailed_metrics
                log(f"  ✓ Detailed metrics extracted (advantage: {detailed_metrics.get('edge_advantage', 0):.2f})")

        except Exception as e:
            log(f"  ✗ Baseline test failed: {e}", "ERROR")
            result["testing"]["baseline_error"] = str(e)
            # Don't set final_edge from 100-sim fallback - leave it unset
            result["final_edge"] = None
    else:
        log(f"  → Skipping 1000 sims (edge {edge_100:.2f} < {threshold} threshold)")
        # Don't set final_edge - only 1000-sim results are authoritative
        result["final_edge"] = None

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
    log(f"  Final Edge: {result['final_edge']:.2f}")
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

    args = parser.parse_args()

    # Verify strategy file exists
    if not Path(args.strategy).exists():
        print(f"Error: Strategy file not found: {args.strategy}", file=sys.stderr)
        sys.exit(1)

    # Ensure output directory exists
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)

    # Run pipeline
    exit_code = run_pipeline(args.strategy, args.output, seed_offset=args.seed_offset)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
