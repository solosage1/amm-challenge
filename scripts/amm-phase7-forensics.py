#!/usr/bin/env python3
"""
AMM Phase 7 Simulation Forensics Engine

Analyzes step-level simulation data to discover patterns that differentiate
high-performing strategies from low-performing ones. Generates actionable
insights for breakthrough strategy development.

Usage:
    python scripts/amm-phase7-forensics.py --state-dir .ralph-amm/phase7/state
    python scripts/amm-phase7-forensics.py --strategy strategy.sol --simulations 100
"""

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

try:
    import numpy as np
    NUMPY_AVAILABLE = True
except ImportError:
    NUMPY_AVAILABLE = False
    print("Warning: NumPy not available, forensics analysis will be limited", file=sys.stderr)

try:
    import pandas as pd
    PANDAS_AVAILABLE = True
except ImportError:
    PANDAS_AVAILABLE = False

# Add parent to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

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

import amm_sim_rs


def log(message: str, level: str = "INFO"):
    """Simple logging."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{level}] {message}")


def run_forensics_simulations(strategy_path: str, n_sims: int = 50) -> List:
    """Run simulations and return raw results with step data."""
    source = Path(strategy_path).read_text()
    compiler = SolidityCompiler()
    result = compiler.compile(source)

    if not result.success:
        raise ValueError(f"Compilation failed: {result.errors}")

    strategy = EVMStrategyAdapter(bytecode=result.bytecode, abi=result.abi)
    normalizer = load_vanilla_strategy()

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

    runner = MatchRunner(
        n_simulations=n_sims,
        config=config,
        n_workers=resolve_n_workers(),
        variance=BASELINE_VARIANCE,
    )

    match_result = runner.run_match(strategy, normalizer, store_results=True)
    return match_result.simulation_results


def compute_edge_curves(sim_results: List, strategy_name: str = "submission") -> Dict:
    """
    Compute per-step edge accumulation patterns.

    Returns:
        Dict with early/mid/late game edge breakdown and timing patterns.
    """
    if not NUMPY_AVAILABLE or not sim_results:
        return {}

    # Extract PnL series from each simulation
    edge_curves = []
    for sim in sim_results:
        if not hasattr(sim, 'steps') or not sim.steps:
            continue

        pnl_series = [step.pnls.get(strategy_name, 0) for step in sim.steps]
        if len(pnl_series) < 2:
            continue

        # Compute edge deltas (PnL changes per step)
        edge_deltas = [0] + [pnl_series[i] - pnl_series[i-1] for i in range(1, len(pnl_series))]
        edge_curves.append(edge_deltas)

    if not edge_curves:
        return {}

    # Normalize to same length
    min_len = min(len(c) for c in edge_curves)
    edge_curves = [c[:min_len] for c in edge_curves]

    avg_curve = np.mean(edge_curves, axis=0)
    cumulative = np.cumsum(avg_curve)
    total_edge = cumulative[-1] if len(cumulative) > 0 else 0

    # Define game phases (assuming 10000 steps)
    early_end = min(3000, min_len)
    mid_end = min(7000, min_len)

    early_edge = float(np.sum(avg_curve[:early_end]))
    mid_edge = float(np.sum(avg_curve[early_end:mid_end]))
    late_edge = float(np.sum(avg_curve[mid_end:]))

    return {
        "total_edge": float(total_edge),
        "early_game_edge": early_edge,
        "mid_game_edge": mid_edge,
        "late_game_edge": late_edge,
        "early_game_pct": early_edge / total_edge * 100 if total_edge != 0 else 0,
        "mid_game_pct": mid_edge / total_edge * 100 if total_edge != 0 else 0,
        "late_game_pct": late_edge / total_edge * 100 if total_edge != 0 else 0,
        "max_drawdown_step": int(np.argmin(cumulative)),
        "peak_edge_step": int(np.argmax(cumulative)),
        "n_simulations": len(edge_curves),
    }


def analyze_price_regimes(sim_results: List, strategy_name: str = "submission") -> Dict:
    """
    Analyze performance in high-vol vs low-vol regimes.

    Returns:
        Dict with edge breakdown by volatility regime.
    """
    if not NUMPY_AVAILABLE or not PANDAS_AVAILABLE or not sim_results:
        return {}

    high_vol_edges = []
    low_vol_edges = []

    for sim in sim_results:
        if not hasattr(sim, 'steps') or len(sim.steps) < 100:
            continue

        fair_prices = [step.fair_price for step in sim.steps]
        pnl_series = [step.pnls.get(strategy_name, 0) for step in sim.steps]

        # Compute log returns
        returns = np.diff(np.log(fair_prices))

        # Rolling volatility (50-step window)
        vol_series = pd.Series(returns).rolling(50, min_periods=10).std().values

        # Edge deltas
        edge_deltas = np.diff(pnl_series)

        # Align arrays (vol_series has NaN at start)
        valid_start = 50
        if len(vol_series) <= valid_start or len(edge_deltas) <= valid_start:
            continue

        vol_valid = vol_series[valid_start:]
        edge_valid = edge_deltas[valid_start-1:]  # -1 because diff reduces length

        # Handle length mismatch
        min_len = min(len(vol_valid), len(edge_valid))
        vol_valid = vol_valid[:min_len]
        edge_valid = edge_valid[:min_len]

        # Split by median volatility
        median_vol = np.nanmedian(vol_valid)
        high_vol_mask = vol_valid > median_vol

        if np.any(high_vol_mask):
            high_vol_edges.append(np.sum(edge_valid[high_vol_mask]))
        if np.any(~high_vol_mask):
            low_vol_edges.append(np.sum(edge_valid[~high_vol_mask]))

    if not high_vol_edges or not low_vol_edges:
        return {}

    return {
        "high_vol_avg_edge": float(np.mean(high_vol_edges)),
        "low_vol_avg_edge": float(np.mean(low_vol_edges)),
        "high_vol_std": float(np.std(high_vol_edges)),
        "low_vol_std": float(np.std(low_vol_edges)),
        "vol_edge_ratio": float(np.mean(high_vol_edges) / np.mean(low_vol_edges)) if np.mean(low_vol_edges) != 0 else 0,
        "n_simulations": len(high_vol_edges),
    }


def analyze_fee_timing(sim_results: List, strategy_name: str = "submission") -> Dict:
    """
    Analyze whether high fees correlate with high mispricing (correct timing).

    Returns:
        Dict with fee-mispricing correlation metrics.
    """
    if not NUMPY_AVAILABLE or not sim_results:
        return {}

    timing_scores = []

    for sim in sim_results:
        if not hasattr(sim, 'steps') or len(sim.steps) < 100:
            continue

        fees_list = []
        deviations = []

        for step in sim.steps:
            fee_tuple = step.fees.get(strategy_name, (0, 0))
            avg_fee = (fee_tuple[0] + fee_tuple[1]) / 2
            fees_list.append(avg_fee)

            spot = step.spot_prices.get(strategy_name, 0)
            fair = step.fair_price
            if fair > 0:
                deviation = abs(spot - fair) / fair
                deviations.append(deviation)
            else:
                deviations.append(0)

        if not fees_list or not deviations:
            continue

        fees_arr = np.array(fees_list)
        dev_arr = np.array(deviations)

        # Median split
        median_fee = np.median(fees_arr)
        high_fee_mask = fees_arr > median_fee

        high_fee_avg_dev = np.mean(dev_arr[high_fee_mask]) if np.any(high_fee_mask) else 0
        low_fee_avg_dev = np.mean(dev_arr[~high_fee_mask]) if np.any(~high_fee_mask) else 0

        # Timing correctness: high fees should align with high deviation
        timing_score = high_fee_avg_dev / low_fee_avg_dev if low_fee_avg_dev > 0 else 1
        timing_scores.append(timing_score)

    if not timing_scores:
        return {}

    avg_timing = float(np.mean(timing_scores))

    return {
        "avg_timing_correctness": avg_timing,
        "timing_std": float(np.std(timing_scores)),
        "timing_interpretation": (
            "GOOD: High fees align with high mispricing" if avg_timing > 1.3 else
            "MODERATE: Some timing alignment" if avg_timing > 1.0 else
            "POOR: High fees do NOT align with mispricing"
        ),
        "n_simulations": len(timing_scores),
    }


def analyze_arb_detection(sim_results: List, strategy_name: str = "submission") -> Dict:
    """
    Analyze how often price corrections (likely arb) occur and detection rate.

    Returns:
        Dict with arb detection patterns.
    """
    if not NUMPY_AVAILABLE or not sim_results:
        return {}

    correction_rates = []

    for sim in sim_results:
        if not hasattr(sim, 'steps') or len(sim.steps) < 10:
            continue

        corrections = 0
        for i in range(1, len(sim.steps)):
            prev_spot = sim.steps[i-1].spot_prices.get(strategy_name, 0)
            curr_spot = sim.steps[i].spot_prices.get(strategy_name, 0)
            fair = sim.steps[i].fair_price

            if prev_spot == 0 or fair == 0:
                continue

            prev_error = abs(prev_spot - fair) / fair
            curr_error = abs(curr_spot - fair) / fair

            # 10%+ error reduction suggests arb occurred
            if curr_error < prev_error * 0.9 and prev_error > 0.001:
                corrections += 1

        rate = corrections / (len(sim.steps) - 1)
        correction_rates.append(rate)

    if not correction_rates:
        return {}

    avg_rate = float(np.mean(correction_rates))

    return {
        "avg_correction_rate": avg_rate,
        "correction_rate_std": float(np.std(correction_rates)),
        "interpretation": (
            f"Arb corrects price {avg_rate*100:.1f}% of steps - " +
            ("reliable arb signal" if avg_rate > 0.6 else
             "partial arb signal, need fallback" if avg_rate > 0.3 else
             "unreliable arb signal")
        ),
        "n_simulations": len(correction_rates),
    }


def compare_top_bottom(sim_results: List, n_compare: int = 20) -> Dict:
    """
    Compare patterns between top and bottom performing simulations.

    Returns:
        Dict with comparative analysis.
    """
    if not NUMPY_AVAILABLE or len(sim_results) < n_compare * 2:
        return {}

    # Sort by edge
    sorted_sims = sorted(sim_results, key=lambda s: s.edges.get('submission', 0), reverse=True)
    top_sims = sorted_sims[:n_compare]
    bottom_sims = sorted_sims[-n_compare:]

    comparison = {}

    # Compare edge curves
    top_curves = compute_edge_curves(top_sims)
    bottom_curves = compute_edge_curves(bottom_sims)

    if top_curves and bottom_curves:
        comparison["edge_timing"] = {
            "top_early_pct": top_curves.get("early_game_pct", 0),
            "bottom_early_pct": bottom_curves.get("early_game_pct", 0),
            "insight": (
                "Top strategies front-load edge capture"
                if top_curves.get("early_game_pct", 0) > bottom_curves.get("early_game_pct", 0) + 10
                else "Edge timing similar between top/bottom"
            )
        }

    # Compare volatility performance
    top_vol = analyze_price_regimes(top_sims)
    bottom_vol = analyze_price_regimes(bottom_sims)

    if top_vol and bottom_vol:
        comparison["volatility"] = {
            "top_high_vol_edge": top_vol.get("high_vol_avg_edge", 0),
            "bottom_high_vol_edge": bottom_vol.get("high_vol_avg_edge", 0),
            "insight": (
                "Top strategies excel in high-vol regimes"
                if top_vol.get("high_vol_avg_edge", 0) > bottom_vol.get("high_vol_avg_edge", 0) * 1.5
                else "High-vol performance similar"
            )
        }

    # Compare fee timing
    top_timing = analyze_fee_timing(top_sims)
    bottom_timing = analyze_fee_timing(bottom_sims)

    if top_timing and bottom_timing:
        comparison["fee_timing"] = {
            "top_timing_score": top_timing.get("avg_timing_correctness", 0),
            "bottom_timing_score": bottom_timing.get("avg_timing_correctness", 0),
            "insight": (
                "Top strategies have better fee timing"
                if top_timing.get("avg_timing_correctness", 0) > bottom_timing.get("avg_timing_correctness", 0) * 1.2
                else "Fee timing similar"
            )
        }

    return comparison


def generate_forensics_report(analysis: Dict) -> str:
    """Generate markdown report from analysis results."""

    lines = ["## Simulation Forensics Insights\n"]

    # Edge timing patterns
    if "edge_curves" in analysis:
        ec = analysis["edge_curves"]
        lines.append("### Edge Timing Patterns")
        lines.append(f"- Early game (steps 0-3000): {ec.get('early_game_pct', 0):.1f}% of total edge")
        lines.append(f"- Mid game (steps 3000-7000): {ec.get('mid_game_pct', 0):.1f}% of total edge")
        lines.append(f"- Late game (steps 7000+): {ec.get('late_game_pct', 0):.1f}% of total edge")
        lines.append(f"- Peak edge at step: {ec.get('peak_edge_step', 'N/A')}")
        lines.append("")

    # Volatility analysis
    if "price_regimes" in analysis:
        pr = analysis["price_regimes"]
        lines.append("### Volatility Regime Performance")
        lines.append(f"- High-vol periods: {pr.get('high_vol_avg_edge', 0):.1f} avg edge")
        lines.append(f"- Low-vol periods: {pr.get('low_vol_avg_edge', 0):.1f} avg edge")
        ratio = pr.get('vol_edge_ratio', 1)
        if ratio > 1.5:
            lines.append(f"- **Insight**: Strategy excels in volatility ({ratio:.1f}x edge ratio)")
        elif ratio < 0.7:
            lines.append(f"- **Warning**: Strategy struggles in high-vol ({ratio:.1f}x edge ratio)")
        lines.append("")

    # Fee timing
    if "fee_timing" in analysis:
        ft = analysis["fee_timing"]
        lines.append("### Fee Timing Analysis")
        lines.append(f"- Timing correctness score: {ft.get('avg_timing_correctness', 0):.2f}")
        lines.append(f"- {ft.get('timing_interpretation', 'N/A')}")
        lines.append("")

    # Arb detection
    if "arb_detection" in analysis:
        ad = analysis["arb_detection"]
        lines.append("### Arbitrage Detection")
        lines.append(f"- Price corrections: {ad.get('avg_correction_rate', 0)*100:.1f}% of steps")
        lines.append(f"- {ad.get('interpretation', 'N/A')}")
        lines.append("")

    # Top vs bottom comparison
    if "comparison" in analysis:
        comp = analysis["comparison"]
        lines.append("### Top vs Bottom Strategy Comparison")
        for key, data in comp.items():
            if "insight" in data:
                lines.append(f"- **{key}**: {data['insight']}")
        lines.append("")

    # Actionable recommendations
    lines.append("### Recommended Actions")
    recommendations = generate_recommendations(analysis)
    for rec in recommendations:
        lines.append(f"- {rec}")

    return "\n".join(lines)


def generate_recommendations(analysis: Dict) -> List[str]:
    """Generate actionable recommendations from analysis."""
    recommendations = []

    # Check edge timing
    if "edge_curves" in analysis:
        early_pct = analysis["edge_curves"].get("early_game_pct", 50)
        if early_pct < 40:
            recommendations.append("Consider lower initial fees to capture more early retail volume")
        if early_pct > 70:
            recommendations.append("Early edge capture is strong; focus on mid/late game improvement")

    # Check volatility
    if "price_regimes" in analysis:
        ratio = analysis["price_regimes"].get("vol_edge_ratio", 1)
        if ratio < 0.8:
            recommendations.append("High-vol performance is weak; consider faster fair price updates or wider protection")
        if ratio > 2.0:
            recommendations.append("Strong high-vol performance; this is a key differentiator to preserve")

    # Check fee timing
    if "fee_timing" in analysis:
        timing = analysis["fee_timing"].get("avg_timing_correctness", 1)
        if timing < 1.0:
            recommendations.append("Fee timing is inverted; high fees do NOT align with mispricing - fix this")
        if timing < 1.2:
            recommendations.append("Fee timing can be improved; consider faster mispricing detection")

    # Check arb detection
    if "arb_detection" in analysis:
        rate = analysis["arb_detection"].get("avg_correction_rate", 0.5)
        if rate < 0.4:
            recommendations.append("Arb occurs infrequently; need fallback fair price method for no-arb steps")

    if not recommendations:
        recommendations.append("No critical issues detected; focus on parameter optimization")

    return recommendations


def run_forensics_analysis(strategy_path: Optional[str] = None,
                           sim_results: Optional[List] = None,
                           n_sims: int = 50) -> Dict:
    """
    Run complete forensics analysis.

    Args:
        strategy_path: Path to strategy .sol file (runs new simulations)
        sim_results: Pre-existing simulation results (skips running sims)
        n_sims: Number of simulations to run if strategy_path provided

    Returns:
        Complete analysis dict
    """
    if sim_results is None and strategy_path:
        log(f"Running {n_sims} simulations for forensics analysis...")
        sim_results = run_forensics_simulations(strategy_path, n_sims)

    if not sim_results:
        return {"error": "No simulation results available"}

    log(f"Analyzing {len(sim_results)} simulations...")

    analysis = {
        "timestamp": datetime.now().isoformat(),
        "n_simulations": len(sim_results),
    }

    # Run all analyses
    analysis["edge_curves"] = compute_edge_curves(sim_results)
    analysis["price_regimes"] = analyze_price_regimes(sim_results)
    analysis["fee_timing"] = analyze_fee_timing(sim_results)
    analysis["arb_detection"] = analyze_arb_detection(sim_results)
    analysis["comparison"] = compare_top_bottom(sim_results)

    # Generate report
    analysis["report"] = generate_forensics_report(analysis)

    return analysis


def main():
    parser = argparse.ArgumentParser(description="AMM Phase 7 Simulation Forensics Engine")
    parser.add_argument("--strategy", type=str, help="Path to strategy .sol file")
    parser.add_argument("--simulations", type=int, default=50, help="Number of simulations")
    parser.add_argument("--output", type=str, help="Output JSON file path")
    parser.add_argument("--report-only", action="store_true", help="Print report to stdout only")

    args = parser.parse_args()

    if not args.strategy:
        parser.error("--strategy is required")

    if not Path(args.strategy).exists():
        log(f"Strategy file not found: {args.strategy}", "ERROR")
        sys.exit(1)

    try:
        analysis = run_forensics_analysis(
            strategy_path=args.strategy,
            n_sims=args.simulations
        )

        if args.report_only:
            print(analysis.get("report", "No report generated"))
        else:
            if args.output:
                output_path = Path(args.output)
                # Remove report from JSON (keep it human-readable separately)
                json_analysis = {k: v for k, v in analysis.items() if k != "report"}
                output_path.write_text(json.dumps(json_analysis, indent=2))
                log(f"Analysis saved to {output_path}")

                # Also save report as .md
                report_path = output_path.with_suffix(".md")
                report_path.write_text(analysis.get("report", ""))
                log(f"Report saved to {report_path}")

            print("\n" + "="*60)
            print(analysis.get("report", "No report generated"))
            print("="*60 + "\n")

    except Exception as e:
        log(f"Forensics analysis failed: {e}", "ERROR")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
