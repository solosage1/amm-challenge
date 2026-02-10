#!/usr/bin/env python3
"""
AMM Learning Engine
Tracks results, identifies patterns, and prioritizes future tests
"""

import argparse
import json
import os
import shutil
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List

# Import experiment logger
try:
    # Add scripts directory to path for imports
    sys.path.insert(0, os.path.dirname(__file__))
    from amm_experiment_logger import generate_experiment_log, parse_experiment_logs
    EXPERIMENT_LOGGER_AVAILABLE = True
except ImportError as e:
    EXPERIMENT_LOGGER_AVAILABLE = False


def log(message: str, level: str = "INFO"):
    """Simple logging."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{level}] {message}")


def record_result(result_path: str, state_dir: str = ".ralph-amm/state") -> None:
    """
    Append test result to historical log and update best if champion.

    Args:
        result_path: Path to latest test result JSON
        state_dir: Path to state directory
    """
    state_path = Path(state_dir)
    result = json.loads(Path(result_path).read_text())

    # Validate result structure
    if not result.get("success"):
        log("Result indicates failure, skipping record", "WARN")
        return

    # Load or initialize history
    history_path = state_path / ".strategies_tested.json"
    history = []
    if history_path.exists():
        try:
            history = json.loads(history_path.read_text())
        except json.JSONDecodeError:
            log("Failed to parse history, starting fresh", "WARN")
            history = []

    # Extract key metrics
    strategy_name = result.get("strategy_name", "unknown")
    final_edge = result.get("final_edge", 0.0)
    testing = result.get("testing", {})

    # Build history entry
    entry = {
        "id": strategy_name,
        "timestamp": result.get("timestamp", datetime.now().isoformat()),
        "strategy_path": result.get("strategy_path", ""),
        "edge_10": testing.get("edge_10"),
        "edge_100": testing.get("edge_100"),
        "edge_1000": testing.get("edge_1000"),
        "final_edge": final_edge,
        "runtime_seconds": result.get("runtime", {}).get("total_seconds", 0),
    }

    # Append to history
    history.append(entry)
    history_path.write_text(json.dumps(history, indent=2))
    log(f"Recorded result: {strategy_name} → Edge {final_edge:.2f}")

    # Update best if champion
    best_edge_path = state_path / ".best_edge_score.txt"
    current_best = 0.0
    if best_edge_path.exists():
        try:
            current_best = float(best_edge_path.read_text().strip())
        except ValueError:
            log("Failed to parse best edge, resetting to 0", "WARN")

    if final_edge > current_best:
        log(f"🏆 NEW CHAMPION! Edge {final_edge:.2f} beats {current_best:.2f}", "INFO")
        best_edge_path.write_text(str(final_edge))

        # Copy strategy to best
        strategy_path = Path(result.get("strategy_path", ""))
        if strategy_path.exists():
            best_strategy_path = state_path / ".best_strategy.sol"
            shutil.copy(strategy_path, best_strategy_path)
            log(f"  → Copied to {best_strategy_path}")

    # Generate experiment log (if applicable)
    if EXPERIMENT_LOGGER_AVAILABLE:
        try:
            exp_log = generate_experiment_log(result_path)
            if exp_log:
                log(f"📝 Generated experiment log: {exp_log}")
        except Exception as e:
            log(f"Failed to generate experiment log: {e}", "WARN")


def analyze_results(state_dir: str = ".ralph-amm/state", output_path: str | None = None) -> None:
    """
    Analyze historical results and generate insights.

    Args:
        state_dir: Path to state directory
        output_path: Optional path to write analysis report
    """
    state_path = Path(state_dir)
    history_path = state_path / ".strategies_tested.json"

    if not history_path.exists():
        log("No test history found", "WARN")
        return

    history = json.loads(history_path.read_text())

    if not history:
        log("Test history is empty", "WARN")
        return

    # Generate insights
    report = generate_analysis_report(history)

    # Print to console
    print("\n" + "=" * 60)
    print("AMM Strategy Analysis Report")
    print("=" * 60)
    print(report)
    print("=" * 60)

    # Write to file if requested
    if output_path:
        Path(output_path).write_text(report)
        log(f"Analysis written to {output_path}")


def generate_analysis_report(history: List[Dict[str, Any]]) -> str:
    """Generate detailed analysis report from test history."""
    lines = []

    # Summary stats
    total_tests = len(history)
    edges = [h["final_edge"] for h in history if h.get("final_edge")]
    best_edge = max(edges) if edges else 0
    worst_edge = min(edges) if edges else 0
    avg_edge = sum(edges) / len(edges) if edges else 0

    lines.append(f"\n📊 Summary Statistics")
    lines.append(f"  Total Strategies Tested: {total_tests}")
    lines.append(f"  Best Edge: {best_edge:.2f}")
    lines.append(f"  Worst Edge: {worst_edge:.2f}")
    lines.append(f"  Average Edge: {avg_edge:.2f}")

    # Top performers
    lines.append(f"\n🏆 Top 5 Performers")
    sorted_history = sorted(history, key=lambda h: h.get("final_edge", 0), reverse=True)
    for i, entry in enumerate(sorted_history[:5], 1):
        name = entry.get("id", "unknown")
        edge = entry.get("final_edge", 0)
        lines.append(f"  {i}. {name}: {edge:.2f} edge")

    # Bottom performers
    lines.append(f"\n⚠️  Bottom 5 Performers")
    for i, entry in enumerate(sorted_history[-5:][::-1], 1):
        name = entry.get("id", "unknown")
        edge = entry.get("final_edge", 0)
        lines.append(f"  {i}. {name}: {edge:.2f} edge")

    # Performance trend
    lines.append(f"\n📈 Performance Trend (Last 10)")
    recent = history[-10:]
    for entry in recent:
        name = entry.get("id", "unknown")
        edge = entry.get("final_edge", 0)
        timestamp = entry.get("timestamp", "")[:10]  # Date only
        lines.append(f"  {timestamp} | {name}: {edge:.2f}")

    # Runtime analysis
    runtimes = [h.get("runtime_seconds", 0) for h in history if h.get("runtime_seconds")]
    if runtimes:
        avg_runtime = sum(runtimes) / len(runtimes)
        total_runtime = sum(runtimes)
        lines.append(f"\n⏱️  Runtime Statistics")
        lines.append(f"  Average Runtime: {avg_runtime:.1f}s")
        lines.append(f"  Total Runtime: {total_runtime:.1f}s ({total_runtime / 60:.1f}m)")

    # Efficiency metrics
    lines.append(f"\n💡 Insights")
    if edges:
        improvement = best_edge - edges[0] if len(edges) > 0 else 0
        lines.append(f"  Improvement over first: {improvement:.2f} points ({improvement / edges[0] * 100:.1f}%)")

        recent_edges = edges[-5:] if len(edges) >= 5 else edges
        recent_improvement = max(recent_edges) - min(recent_edges)
        if recent_improvement < 1.0:
            lines.append(f"  ⚠️  Recent performance plateau detected (improvement: {recent_improvement:.2f})")

    return "\n".join(lines)


def show_status(state_dir: str = ".ralph-amm/state") -> None:
    """
    Display current loop status.

    Args:
        state_dir: Path to state directory
    """
    state_path = Path(state_dir)

    # Read best edge
    best_edge_path = state_path / ".best_edge_score.txt"
    best_edge = 0.0
    if best_edge_path.exists():
        try:
            best_edge = float(best_edge_path.read_text().strip())
        except ValueError:
            pass

    # Read plan
    plan_path = state_path / "@strategy_plan.md"
    total_tasks = 0
    completed_tasks = 0
    if plan_path.exists():
        plan_text = plan_path.read_text()
        total_tasks = plan_text.count("- [ ]") + plan_text.count("- [x]")
        completed_tasks = plan_text.count("- [x]")

    # Read history
    history_path = state_path / ".strategies_tested.json"
    strategies_tested = 0
    if history_path.exists():
        try:
            history = json.loads(history_path.read_text())
            strategies_tested = len(history)
        except json.JSONDecodeError:
            pass

    # Display status
    print("\n" + "=" * 60)
    print("Ralph-AMM Status")
    print("=" * 60)
    print(f"  Best Edge: {best_edge:.2f}")
    print(f"  Target Edge: 400")
    print(f"  Gap: {400 - best_edge:.2f} points")
    print(f"  Progress: {completed_tasks} / {total_tasks} tasks ({completed_tasks / total_tasks * 100:.1f}%)")
    print(f"  Strategies Tested: {strategies_tested}")
    print("=" * 60)


def analyze_hypotheses(experiments_dir: str = "research/experiments") -> None:
    """
    Analyze experiments grouped by hypothesis.

    Args:
        experiments_dir: Directory containing experiment logs
    """
    if not EXPERIMENT_LOGGER_AVAILABLE:
        log("Experiment logger not available, cannot analyze hypotheses", "ERROR")
        return

    experiments = parse_experiment_logs(experiments_dir)

    if not experiments:
        log("No experiment logs found", "WARN")
        return

    # Group by hypothesis
    by_hypothesis = defaultdict(list)
    for exp in experiments:
        # Handle hypothesis IDs like ["002", "006"] from "H-002-H-006"
        hyp_ids = exp.get('hypothesis_ids', [])
        if not hyp_ids:
            continue

        # Extract numeric parts and reconstruct H-XXX format
        for hyp_num in hyp_ids:
            if hyp_num:  # Skip empty strings
                hyp_id = f"H-{hyp_num}" if not hyp_num.startswith('H-') else hyp_num
                by_hypothesis[hyp_id].append(exp)

    # Calculate baseline statistics
    baseline_exps = by_hypothesis.get('H-baseline', [])
    baseline_edges = [e['edge_1000'] for e in baseline_exps if e.get('edge_1000')]
    baseline_mean = sum(baseline_edges) / len(baseline_edges) if baseline_edges else 0
    baseline_std = 0
    if len(baseline_edges) > 1:
        variance = sum((x - baseline_mean) ** 2 for x in baseline_edges) / (len(baseline_edges) - 1)
        baseline_std = variance ** 0.5

    # Display results
    print("\n" + "=" * 60)
    print("Hypothesis Analysis Report")
    print("=" * 60)

    # Show baseline first
    if baseline_exps:
        print(f"\n📊 H-baseline (Calibration)")
        print(f"  Experiments: {len(baseline_exps)}")
        print(f"  Mean Edge: {baseline_mean:.2f} (σ={baseline_std:.2f})")
        print(f"  Status: baseline")

    # Show other hypotheses
    for hyp_id in sorted(by_hypothesis.keys()):
        if hyp_id == 'H-baseline':
            continue

        exps = by_hypothesis[hyp_id]
        edges = [e['edge_1000'] for e in exps if e.get('edge_1000')]

        if not edges:
            continue

        exp_mean = sum(edges) / len(edges)
        exp_std = 0
        if len(edges) > 1:
            variance = sum((x - exp_mean) ** 2 for x in edges) / (len(edges) - 1)
            exp_std = variance ** 0.5

        improvement = exp_mean - baseline_mean

        # Determine status based on improvement
        if improvement > 5.0:
            status = "✅ supported"
        elif improvement > 0:
            status = "✓ marginal"
        elif improvement > -2.0:
            status = "≈ neutral"
        else:
            status = "✗ rejected"

        print(f"\n📊 {hyp_id}")
        print(f"  Experiments: {len(exps)}")
        print(f"  Mean Edge: {exp_mean:.2f} (σ={exp_std:.2f})")
        print(f"  vs Baseline: {improvement:+.2f} points")
        print(f"  Status: {status}")

    print("=" * 60)


def main():
    parser = argparse.ArgumentParser(
        description="AMM Learning Engine - Track and analyze strategy results",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Commands:
  record       Record a test result to history and update best
  analyze      Generate insights report from test history
  status       Display current loop status
  hypotheses   Analyze experiments grouped by hypothesis

Examples:
  # Record latest result
  python scripts/amm-learning-engine.py record \\
    --result .ralph-amm/state/last_result.json

  # Analyze all results
  python scripts/amm-learning-engine.py analyze

  # Show status
  python scripts/amm-learning-engine.py status

  # Analyze hypotheses
  python scripts/amm-learning-engine.py hypotheses
""",
    )

    parser.add_argument(
        "command",
        choices=["record", "analyze", "status", "hypotheses"],
        help="Command to execute",
    )
    parser.add_argument(
        "--result",
        help="Path to test result JSON (for record command)",
    )
    parser.add_argument(
        "--output",
        help="Path to write analysis report (for analyze command)",
    )
    parser.add_argument(
        "--state-dir",
        default=".ralph-amm/state",
        help="Path to state directory (default: .ralph-amm/state)",
    )

    args = parser.parse_args()

    # Execute command
    if args.command == "record":
        if not args.result:
            print("Error: --result is required for record command", file=sys.stderr)
            sys.exit(1)
        if not Path(args.result).exists():
            print(f"Error: Result file not found: {args.result}", file=sys.stderr)
            sys.exit(1)
        record_result(args.result, args.state_dir)

    elif args.command == "analyze":
        analyze_results(args.state_dir, args.output)

    elif args.command == "status":
        show_status(args.state_dir)

    elif args.command == "hypotheses":
        analyze_hypotheses()


if __name__ == "__main__":
    main()
