#!/usr/bin/env python3
"""
AMM Phase 7 Assumption Auditor

Systematically tests implicit assumptions in the optimization loop.
Identifies violated assumptions that may be limiting performance.

Usage:
    python scripts/amm-phase7-auditor.py --state-dir .ralph-amm/phase7/state
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
    print("Warning: NumPy not available, assumption auditing will be limited", file=sys.stderr)

try:
    import pandas as pd
    PANDAS_AVAILABLE = True
except ImportError:
    PANDAS_AVAILABLE = False

# Add parent to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))


def log(message: str, level: str = "INFO"):
    """Simple logging."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{level}] {message}")


def load_strategies_log(state_dir: Path) -> List[Dict]:
    """Load strategies log from state directory."""
    log_path = state_dir / ".strategies_log.json"
    if not log_path.exists():
        log_path = state_dir / "strategies_log.json"

    if not log_path.exists():
        return []

    try:
        return json.loads(log_path.read_text())
    except Exception as e:
        log(f"Failed to load strategies log: {e}", "ERROR")
        return []


def test_fee_volume_assumption(strategies_log: List[Dict]) -> Dict:
    """
    Test: "Lower fees attract more retail volume"

    Returns:
        Dict with assumption test results.
    """
    if not NUMPY_AVAILABLE:
        return {"status": "SKIPPED", "reason": "NumPy not available"}

    data_points = []

    for entry in strategies_log:
        if entry.get("status") != "ok":
            continue

        metrics = entry.get("metrics_1000", entry.get("metrics", {}))
        if not metrics:
            continue

        avg_bid = metrics.get("submission_avg_bid_fee", 0)
        avg_ask = metrics.get("submission_avg_ask_fee", 0)
        retail_vol = metrics.get("submission_retail_volume", 0)

        if avg_bid > 0 or avg_ask > 0:
            avg_fee = (avg_bid + avg_ask) / 2
            data_points.append((avg_fee, retail_vol))

    if len(data_points) < 5:
        return {"status": "INSUFFICIENT_DATA", "n_samples": len(data_points)}

    fees = np.array([d[0] for d in data_points])
    volumes = np.array([d[1] for d in data_points])

    correlation = np.corrcoef(fees, volumes)[0, 1]

    # Determine status
    if correlation < -0.3:
        status = "SUPPORTED"
        interpretation = "Lower fees do attract more retail volume"
    elif correlation < 0:
        status = "WEAK"
        interpretation = "Weak negative correlation; fee impact on volume is limited"
    else:
        status = "VIOLATED"
        interpretation = "Assumption violated: higher fees may not reduce volume significantly"

    return {
        "assumption": "Lower fees attract more retail volume",
        "status": status,
        "correlation": float(correlation),
        "interpretation": interpretation,
        "n_samples": len(data_points),
        "implication": (
            "Focus on fee optimization for volume"
            if status == "SUPPORTED"
            else "Fee level matters less than expected; focus on other factors"
        ),
    }


def test_symmetry_assumption(strategies_log: List[Dict]) -> Dict:
    """
    Test: "Optimal fees are approximately symmetric (bidFee ≈ askFee)"

    Returns:
        Dict with assumption test results.
    """
    if not NUMPY_AVAILABLE:
        return {"status": "SKIPPED", "reason": "NumPy not available"}

    # Get top performers
    valid_entries = [
        e for e in strategies_log
        if e.get("status") == "ok" and e.get("final_edge", 0) > 350
    ]

    if len(valid_entries) < 5:
        return {"status": "INSUFFICIENT_DATA", "n_samples": len(valid_entries)}

    # Sort by edge and take top 20%
    sorted_entries = sorted(valid_entries, key=lambda x: x.get("final_edge", 0), reverse=True)
    top_count = max(5, len(sorted_entries) // 5)
    top_performers = sorted_entries[:top_count]

    asymmetries = []
    for entry in top_performers:
        metrics = entry.get("metrics_1000", entry.get("metrics", {}))
        if metrics:
            asymm = metrics.get("fee_asymmetry", 0)  # ask - bid
            asymmetries.append(asymm)

    if not asymmetries:
        return {"status": "INSUFFICIENT_DATA", "reason": "No fee asymmetry data"}

    avg_asymm = np.mean(asymmetries)
    std_asymm = np.std(asymmetries)

    # 3bps threshold for "approximately symmetric"
    threshold = 0.0003  # 3 bps in WAD

    if abs(avg_asymm) < threshold:
        status = "SUPPORTED"
        interpretation = "Top performers use approximately symmetric fees"
    else:
        status = "VIOLATED"
        direction = "higher ask" if avg_asymm > 0 else "higher bid"
        interpretation = f"Top performers use asymmetric fees ({direction} by {abs(avg_asymm)*10000:.1f} bps)"

    return {
        "assumption": "Optimal fees are approximately symmetric",
        "status": status,
        "avg_asymmetry_bps": float(avg_asymm * 10000),
        "std_asymmetry_bps": float(std_asymm * 10000),
        "interpretation": interpretation,
        "n_samples": len(asymmetries),
        "implication": (
            "Symmetric fee strategies are valid"
            if status == "SUPPORTED"
            else f"Consider {abs(avg_asymm)*10000:.1f} bps asymmetry favoring {'ask' if avg_asymm > 0 else 'bid'}"
        ),
    }


def test_edge_win_alignment(strategies_log: List[Dict]) -> Dict:
    """
    Test: "Higher edge correlates with more simulation wins"

    Returns:
        Dict with assumption test results.
    """
    if not NUMPY_AVAILABLE:
        return {"status": "SKIPPED", "reason": "NumPy not available"}

    data_points = []

    for entry in strategies_log:
        if entry.get("status") != "ok":
            continue

        edge = entry.get("final_edge", 0)
        metrics = entry.get("metrics_1000", entry.get("metrics", {}))

        if metrics and "wins" in metrics:
            wins = metrics["wins"]
            data_points.append((edge, wins))

    if len(data_points) < 5:
        return {"status": "INSUFFICIENT_DATA", "n_samples": len(data_points)}

    edges = np.array([d[0] for d in data_points])
    wins = np.array([d[1] for d in data_points])

    correlation = np.corrcoef(edges, wins)[0, 1]

    if correlation > 0.7:
        status = "SUPPORTED"
        interpretation = "Higher edge strongly correlates with more wins"
    elif correlation > 0.3:
        status = "WEAK"
        interpretation = "Moderate correlation between edge and wins"
    else:
        status = "VIOLATED"
        interpretation = "Edge and win rate are not well aligned"

    return {
        "assumption": "Higher edge = more simulation wins",
        "status": status,
        "correlation": float(correlation),
        "interpretation": interpretation,
        "n_samples": len(data_points),
        "implication": (
            "Optimizing for total edge is correct"
            if status == "SUPPORTED"
            else "Consider optimizing for consistency (win rate) in addition to total edge"
        ),
    }


def test_arb_volume_correlation(strategies_log: List[Dict]) -> Dict:
    """
    Test: "Lower arb volume correlates with higher edge"

    Returns:
        Dict with assumption test results.
    """
    if not NUMPY_AVAILABLE:
        return {"status": "SKIPPED", "reason": "NumPy not available"}

    data_points = []

    for entry in strategies_log:
        if entry.get("status") != "ok":
            continue

        edge = entry.get("final_edge", 0)
        metrics = entry.get("metrics_1000", entry.get("metrics", {}))

        if metrics:
            arb_vol = metrics.get("submission_arb_volume", 0)
            if arb_vol > 0:
                data_points.append((arb_vol, edge))

    if len(data_points) < 5:
        return {"status": "INSUFFICIENT_DATA", "n_samples": len(data_points)}

    arb_vols = np.array([d[0] for d in data_points])
    edges = np.array([d[1] for d in data_points])

    correlation = np.corrcoef(arb_vols, edges)[0, 1]

    if correlation < -0.3:
        status = "SUPPORTED"
        interpretation = "Lower arb volume does correlate with higher edge"
    elif correlation < 0:
        status = "WEAK"
        interpretation = "Weak negative correlation; arb reduction helps but isn't dominant"
    else:
        status = "VIOLATED"
        interpretation = "Assumption violated: arb volume reduction may not be the key to higher edge"

    return {
        "assumption": "Lower arb volume correlates with higher edge",
        "status": status,
        "correlation": float(correlation),
        "interpretation": interpretation,
        "n_samples": len(data_points),
        "implication": (
            "Arb protection strategies are valuable"
            if status == "SUPPORTED"
            else "Focus on retail capture may be more important than arb reduction"
        ),
    }


def test_retail_volume_edge_correlation(strategies_log: List[Dict]) -> Dict:
    """
    Test: "Higher retail volume correlates with higher edge"

    Returns:
        Dict with assumption test results.
    """
    if not NUMPY_AVAILABLE:
        return {"status": "SKIPPED", "reason": "NumPy not available"}

    data_points = []

    for entry in strategies_log:
        if entry.get("status") != "ok":
            continue

        edge = entry.get("final_edge", 0)
        metrics = entry.get("metrics_1000", entry.get("metrics", {}))

        if metrics:
            retail_vol = metrics.get("submission_retail_volume", 0)
            if retail_vol > 0:
                data_points.append((retail_vol, edge))

    if len(data_points) < 5:
        return {"status": "INSUFFICIENT_DATA", "n_samples": len(data_points)}

    retail_vols = np.array([d[0] for d in data_points])
    edges = np.array([d[1] for d in data_points])

    correlation = np.corrcoef(retail_vols, edges)[0, 1]

    if correlation > 0.5:
        status = "SUPPORTED"
        interpretation = "Higher retail volume strongly correlates with higher edge"
    elif correlation > 0.2:
        status = "WEAK"
        interpretation = "Moderate positive correlation; retail volume helps but isn't everything"
    else:
        status = "VIOLATED"
        interpretation = "Retail volume doesn't strongly predict edge; quality may matter more than quantity"

    return {
        "assumption": "Higher retail volume correlates with higher edge",
        "status": status,
        "correlation": float(correlation),
        "interpretation": interpretation,
        "n_samples": len(data_points),
        "implication": (
            "Maximizing retail capture is key"
            if status == "SUPPORTED"
            else "Focus on edge per trade (quality) rather than just volume"
        ),
    }


def test_initial_fee_impact(strategies_log: List[Dict]) -> Dict:
    """
    Test: "Initial fee level significantly impacts final edge"

    Analyzes whether strategies with different initial fees have different outcomes.
    """
    if not NUMPY_AVAILABLE:
        return {"status": "SKIPPED", "reason": "NumPy not available"}

    # This would require parsing strategy source code to extract initial fees
    # For now, we'll use average fees as a proxy

    data_points = []

    for entry in strategies_log:
        if entry.get("status") != "ok":
            continue

        edge = entry.get("final_edge", 0)
        metrics = entry.get("metrics_1000", entry.get("metrics", {}))

        if metrics:
            avg_bid = metrics.get("submission_avg_bid_fee", 0)
            avg_ask = metrics.get("submission_avg_ask_fee", 0)
            avg_fee = (avg_bid + avg_ask) / 2
            if avg_fee > 0:
                data_points.append((avg_fee, edge))

    if len(data_points) < 5:
        return {"status": "INSUFFICIENT_DATA", "n_samples": len(data_points)}

    fees = np.array([d[0] for d in data_points])
    edges = np.array([d[1] for d in data_points])

    # Find optimal fee range
    sorted_by_edge = sorted(data_points, key=lambda x: x[1], reverse=True)
    top_third = sorted_by_edge[:len(sorted_by_edge)//3 + 1]
    top_fees = [d[0] for d in top_third]

    optimal_range = (min(top_fees) * 10000, max(top_fees) * 10000)  # Convert to bps
    avg_optimal_fee = np.mean(top_fees) * 10000

    return {
        "assumption": "Fee level has optimal range",
        "status": "ANALYZED",
        "optimal_fee_range_bps": optimal_range,
        "avg_optimal_fee_bps": float(avg_optimal_fee),
        "interpretation": f"Top performers average {avg_optimal_fee:.1f} bps fees",
        "n_samples": len(data_points),
        "implication": f"Target fees around {avg_optimal_fee:.0f} bps (range: {optimal_range[0]:.0f}-{optimal_range[1]:.0f})",
    }


def generate_recommended_experiments(audit_results: Dict) -> List[Dict]:
    """Generate recommended experiments based on audit results."""
    experiments = []

    # Check for violated assumptions
    for test_name, result in audit_results.get("tests", {}).items():
        status = result.get("status", "")

        if status == "VIOLATED":
            if "symmetry" in test_name.lower():
                experiments.append({
                    "name": "Test asymmetric fee strategies",
                    "description": "Generate strategies with intentional bid/ask asymmetry",
                    "rationale": result.get("interpretation", "Symmetry assumption violated"),
                    "priority": "HIGH",
                })

            if "volume" in test_name.lower() and "retail" in test_name.lower():
                experiments.append({
                    "name": "Test edge-per-trade optimization",
                    "description": "Focus on maximizing edge per retail trade rather than volume",
                    "rationale": "Retail volume may not be the key driver",
                    "priority": "HIGH",
                })

        if status == "WEAK":
            if "arb" in test_name.lower():
                experiments.append({
                    "name": "Test retail-focused strategies",
                    "description": "Reduce emphasis on arb protection, increase retail attraction",
                    "rationale": "Arb reduction shows weak correlation with edge",
                    "priority": "MEDIUM",
                })

    # Always include some baseline experiments
    if not experiments:
        experiments.append({
            "name": "Parameter sensitivity analysis",
            "description": "Test variations of current best strategy parameters",
            "rationale": "Assumptions appear valid; focus on optimization",
            "priority": "MEDIUM",
        })

    return experiments


def run_assumption_audit(state_dir: Path) -> Dict:
    """
    Run complete assumption audit.

    Returns:
        Dict with all test results and recommendations.
    """
    strategies_log = load_strategies_log(state_dir)

    if not strategies_log:
        return {"error": "No strategies log found", "tests": {}}

    log(f"Auditing assumptions from {len(strategies_log)} strategy entries...")

    audit = {
        "timestamp": datetime.now().isoformat(),
        "n_strategies": len(strategies_log),
        "tests": {},
        "summary": {
            "supported": 0,
            "violated": 0,
            "weak": 0,
            "insufficient_data": 0,
        },
    }

    # Run all assumption tests
    test_functions = [
        ("fee_volume", test_fee_volume_assumption),
        ("symmetry", test_symmetry_assumption),
        ("edge_win_alignment", test_edge_win_alignment),
        ("arb_volume_correlation", test_arb_volume_correlation),
        ("retail_volume_correlation", test_retail_volume_edge_correlation),
        ("fee_level_impact", test_initial_fee_impact),
    ]

    for test_name, test_func in test_functions:
        try:
            result = test_func(strategies_log)
            audit["tests"][test_name] = result

            status = result.get("status", "UNKNOWN")
            if status == "SUPPORTED":
                audit["summary"]["supported"] += 1
            elif status == "VIOLATED":
                audit["summary"]["violated"] += 1
            elif status == "WEAK":
                audit["summary"]["weak"] += 1
            elif status == "INSUFFICIENT_DATA":
                audit["summary"]["insufficient_data"] += 1

        except Exception as e:
            log(f"Test {test_name} failed: {e}", "WARN")
            audit["tests"][test_name] = {"status": "ERROR", "error": str(e)}

    # Generate recommendations
    audit["recommended_experiments"] = generate_recommended_experiments(audit)

    return audit


def generate_audit_report(audit: Dict) -> str:
    """Generate markdown report from audit results."""

    lines = ["## Assumption Audit Report\n"]

    # Summary
    summary = audit.get("summary", {})
    lines.append("### Summary")
    lines.append(f"- Supported: {summary.get('supported', 0)}")
    lines.append(f"- Violated: {summary.get('violated', 0)}")
    lines.append(f"- Weak evidence: {summary.get('weak', 0)}")
    lines.append(f"- Insufficient data: {summary.get('insufficient_data', 0)}")
    lines.append("")

    # Detailed results table
    lines.append("### Tested Assumptions")
    lines.append("| Assumption | Status | Evidence | Implication |")
    lines.append("|------------|--------|----------|-------------|")

    for test_name, result in audit.get("tests", {}).items():
        assumption = result.get("assumption", test_name)
        status = result.get("status", "UNKNOWN")

        # Format evidence based on what's available
        if "correlation" in result:
            evidence = f"r={result['correlation']:.2f}"
        elif "avg_asymmetry_bps" in result:
            evidence = f"{result['avg_asymmetry_bps']:.1f} bps asymm"
        else:
            evidence = result.get("interpretation", "N/A")[:30]

        implication = result.get("implication", "N/A")[:50]

        lines.append(f"| {assumption[:40]} | **{status}** | {evidence} | {implication} |")

    lines.append("")

    # Key violations requiring attention
    violations = [
        (name, result) for name, result in audit.get("tests", {}).items()
        if result.get("status") == "VIOLATED"
    ]

    if violations:
        lines.append("### Key Violations Requiring Strategy Redesign")
        for name, result in violations:
            lines.append(f"\n**{result.get('assumption', name)}**")
            lines.append(f"- {result.get('interpretation', 'N/A')}")
            lines.append(f"- Action: {result.get('implication', 'N/A')}")
        lines.append("")

    # Recommended experiments
    experiments = audit.get("recommended_experiments", [])
    if experiments:
        lines.append("### Recommended Experiments")
        for exp in experiments:
            priority = exp.get("priority", "MEDIUM")
            lines.append(f"\n**[{priority}] {exp['name']}**")
            lines.append(f"- {exp['description']}")
            lines.append(f"- Rationale: {exp['rationale']}")
        lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="AMM Phase 7 Assumption Auditor")
    parser.add_argument("--state-dir", type=str, required=True, help="Path to state directory")
    parser.add_argument("--output", type=str, help="Output JSON file path")
    parser.add_argument("--report-only", action="store_true", help="Print report to stdout only")

    args = parser.parse_args()

    state_dir = Path(args.state_dir)
    if not state_dir.exists():
        log(f"State directory not found: {state_dir}", "ERROR")
        sys.exit(1)

    try:
        audit = run_assumption_audit(state_dir)

        # Generate report
        report = generate_audit_report(audit)
        audit["report"] = report

        if args.report_only:
            print(report)
        else:
            if args.output:
                output_path = Path(args.output)
                # Remove report from JSON
                json_audit = {k: v for k, v in audit.items() if k != "report"}
                output_path.write_text(json.dumps(json_audit, indent=2, default=str))
                log(f"Audit saved to {output_path}")

                # Save report as .md
                report_path = output_path.with_suffix(".md")
                report_path.write_text(report)
                log(f"Report saved to {report_path}")

            print("\n" + "="*60)
            print(report)
            print("="*60 + "\n")

        # Print summary
        summary = audit.get("summary", {})
        log(f"Audit complete: {summary.get('supported', 0)} supported, "
            f"{summary.get('violated', 0)} violated, {summary.get('weak', 0)} weak")

    except Exception as e:
        log(f"Assumption audit failed: {e}", "ERROR")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
