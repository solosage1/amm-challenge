#!/usr/bin/env python3
"""
AMM Phase 7 Regime Tester

Standalone tool for testing strategies at extreme parameter regimes.
Use this to identify weaknesses in champion strategies before submission.

Usage:
    python scripts/amm-phase7-regime-tester.py strategy.sol
    python scripts/amm-phase7-regime-tester.py strategy.sol --sims 200
    python scripts/amm-phase7-regime-tester.py strategy.sol --json output.json
"""

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

from amm_competition.competition.config import (
    BASELINE_SETTINGS,
    BASELINE_VARIANCE,
    baseline_nominal_retail_rate,
    baseline_nominal_retail_size,
    baseline_nominal_sigma,
    resolve_n_workers,
)
from amm_competition.competition.match import HyperparameterVariance, MatchRunner
from amm_competition.evm.adapter import EVMStrategyAdapter
from amm_competition.evm.baseline import load_vanilla_strategy
from amm_competition.evm.compiler import SolidityCompiler
from amm_competition.evm.validator import SolidityValidator

import amm_sim_rs


def log(message: str, level: str = "INFO"):
    """Simple logging."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{level}] {message}")


def compile_strategy(strategy_path: str) -> EVMStrategyAdapter:
    """Validate, compile, and deploy a strategy."""
    source = Path(strategy_path).read_text()

    # Validate
    validator = SolidityValidator()
    validation = validator.validate(source)
    if not validation.valid:
        raise ValueError(f"Validation failed: {validation.errors[0]}")

    # Compile
    compiler = SolidityCompiler()
    compilation = compiler.compile(source)
    if not compilation.success:
        raise ValueError(f"Compilation failed: {compilation.errors[0]}")

    # Deploy
    return EVMStrategyAdapter(
        bytecode=compilation.bytecode,
        abi=compilation.abi,
    )


def run_at_regime(
    strategy: EVMStrategyAdapter,
    n_sims: int,
    gbm_sigma: float = None,
    retail_rate: float = None,
    retail_size: float = None,
) -> dict:
    """
    Run simulations at a specific regime point.

    Returns dict with edge and parameters.
    """
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

    # No variance - fixed regime
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
        seed_offset=0,
    )

    result = runner.run_match(strategy, normalizer, store_results=False)
    avg_edge = float(result.total_edge_a / n_sims)

    return {
        "edge": avg_edge,
        "gbm_sigma": sigma,
        "retail_rate": rate,
        "retail_size": size,
    }


def run_full_regime_analysis(strategy: EVMStrategyAdapter, n_sims: int = 100) -> dict:
    """
    Run comprehensive regime analysis.

    Tests at:
    - Nominal (center point)
    - 4 extreme corners (high/low vol, high/low retail)
    - 4 single-dimension extremes
    """
    sigma_min = BASELINE_VARIANCE.gbm_sigma_min
    sigma_max = BASELINE_VARIANCE.gbm_sigma_max
    rate_min = BASELINE_VARIANCE.retail_arrival_rate_min
    rate_max = BASELINE_VARIANCE.retail_arrival_rate_max
    size_min = BASELINE_VARIANCE.retail_mean_size_min
    size_max = BASELINE_VARIANCE.retail_mean_size_max

    results = {}

    # Nominal
    log("Testing nominal (center) regime...")
    results["nominal"] = run_at_regime(strategy, n_sims)

    # Four corners
    log("Testing high volatility regime...")
    results["high_vol"] = run_at_regime(strategy, n_sims, gbm_sigma=sigma_max)

    log("Testing low volatility regime...")
    results["low_vol"] = run_at_regime(strategy, n_sims, gbm_sigma=sigma_min)

    log("Testing high retail regime...")
    results["high_retail"] = run_at_regime(
        strategy, n_sims, retail_rate=rate_max, retail_size=size_max
    )

    log("Testing low retail regime...")
    results["low_retail"] = run_at_regime(
        strategy, n_sims, retail_rate=rate_min, retail_size=size_min
    )

    # Calculate summary statistics
    corner_edges = [
        results["high_vol"]["edge"],
        results["low_vol"]["edge"],
        results["high_retail"]["edge"],
        results["low_retail"]["edge"],
    ]

    all_edges = corner_edges + [results["nominal"]["edge"]]

    results["summary"] = {
        "nominal_edge": results["nominal"]["edge"],
        "corner_min": min(corner_edges),
        "corner_max": max(corner_edges),
        "corner_spread": max(corner_edges) - min(corner_edges),
        "overall_min": min(all_edges),
        "overall_max": max(all_edges),
        "overall_spread": max(all_edges) - min(all_edges),
    }

    # Find weakest regime
    regime_names = ["high_vol", "low_vol", "high_retail", "low_retail"]
    weakest_idx = corner_edges.index(min(corner_edges))
    results["summary"]["weakest_regime"] = regime_names[weakest_idx]
    results["summary"]["spread_warning"] = results["summary"]["corner_spread"] > 50

    return results


def print_results(results: dict, strategy_name: str):
    """Print formatted results to console."""
    print("\n" + "=" * 70)
    print(f"REGIME ANALYSIS: {strategy_name}")
    print("=" * 70)

    print(f"\n{'Regime':<20} {'Edge':>10} {'Volatility':>12} {'Retail Rate':>12} {'Retail Size':>12}")
    print("-" * 70)

    for regime in ["nominal", "high_vol", "low_vol", "high_retail", "low_retail"]:
        r = results[regime]
        print(
            f"{regime:<20} {r['edge']:>10.2f} {r['gbm_sigma']:>12.6f} "
            f"{r['retail_rate']:>12.2f} {r['retail_size']:>12.1f}"
        )

    print("-" * 70)

    summary = results["summary"]
    print(f"\n{'Summary Statistics':}")
    print(f"  Nominal edge:     {summary['nominal_edge']:.2f}")
    print(f"  Corner spread:    {summary['corner_spread']:.2f} (min={summary['corner_min']:.2f}, max={summary['corner_max']:.2f})")
    print(f"  Weakest regime:   {summary['weakest_regime']}")

    if summary["spread_warning"]:
        print(f"\n  ⚠ WARNING: Corner spread {summary['corner_spread']:.1f} > 50")
        print(f"    Consider regime-specific parameter tuning for {summary['weakest_regime']}")

    print("=" * 70 + "\n")


def main():
    parser = argparse.ArgumentParser(
        description="Test AMM strategies at extreme parameter regimes",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Quick test with 50 sims per regime
  python scripts/amm-phase7-regime-tester.py \\
    .ralph-amm/phase7/champion/strategy_champion.sol --sims 50

  # Full analysis with JSON output
  python scripts/amm-phase7-regime-tester.py \\
    contracts/src/ArbOracleDualRegimeExact.sol \\
    --sims 200 --json regime_analysis.json

Regimes tested:
  - nominal:      Center of parameter space
  - high_vol:     Maximum volatility (sigma=0.001008)
  - low_vol:      Minimum volatility (sigma=0.000882)
  - high_retail:  Maximum retail activity (rate=1.0, size=21)
  - low_retail:   Minimum retail activity (rate=0.6, size=19)
""",
    )

    parser.add_argument(
        "strategy",
        help="Path to strategy .sol file",
    )
    parser.add_argument(
        "--sims",
        type=int,
        default=100,
        help="Number of simulations per regime (default: 100)",
    )
    parser.add_argument(
        "--json",
        metavar="FILE",
        help="Write results to JSON file",
    )

    args = parser.parse_args()

    # Verify strategy exists
    if not Path(args.strategy).exists():
        print(f"Error: Strategy file not found: {args.strategy}", file=sys.stderr)
        sys.exit(1)

    # Compile strategy
    log(f"Compiling strategy: {args.strategy}")
    try:
        strategy = compile_strategy(args.strategy)
        strategy_name = strategy.get_name()
        log(f"Strategy deployed: {strategy_name}")
    except Exception as e:
        print(f"Error: Failed to compile strategy: {e}", file=sys.stderr)
        sys.exit(1)

    # Run regime analysis
    log(f"Running regime analysis with {args.sims} simulations per regime...")
    results = run_full_regime_analysis(strategy, n_sims=args.sims)

    # Add metadata
    results["metadata"] = {
        "strategy_path": args.strategy,
        "strategy_name": strategy_name,
        "sims_per_regime": args.sims,
        "timestamp": datetime.now().isoformat(),
    }

    # Print results
    print_results(results, strategy_name)

    # Write JSON if requested
    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=2))
        log(f"Results written to: {args.json}")


if __name__ == "__main__":
    main()
