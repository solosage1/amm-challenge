#!/usr/bin/env python3
"""
AMM Phase 7 Report Generator
Generates comprehensive final report with analysis
"""

import argparse
import json
import time
from pathlib import Path
from typing import Dict, List

# ============================================================================
# REPORT GENERATION
# ============================================================================

def _coerce_float(value):
    try:
        if value is None:
            return None
        return float(value)
    except (TypeError, ValueError):
        return None

def _is_ok_entry(entry: Dict) -> bool:
    status = entry.get("status")
    edge = _coerce_float(entry.get("final_edge"))
    if status is None:
        return edge is not None
    return status == "ok" and edge is not None

def _edge_or_zero(entry: Dict) -> float:
    v = _coerce_float(entry.get("final_edge"))
    return v if v is not None else 0.0

def load_state(state_dir: Path) -> Dict:
    """Load Phase 7 state for reporting"""
    state = {
        'iteration_count': int((state_dir / '.iteration_count.txt').read_text().strip()),
        'best_edge': float((state_dir / '.best_edge.txt').read_text().strip()),
        'start_time': int((state_dir / '.start_timestamp.txt').read_text().strip()),
        'strategies_log': [],
        'templates_created': []
    }

    # Load logs
    strategies_file = state_dir / '.strategies_log.json'
    if strategies_file.exists():
        try:
            state['strategies_log'] = json.loads(strategies_file.read_text())
        except json.JSONDecodeError:
            pass

    templates_file = state_dir / '.templates_created.json'
    if templates_file.exists():
        try:
            state['templates_created'] = json.loads(templates_file.read_text())
        except json.JSONDecodeError:
            pass

    return state

def format_duration(seconds: int) -> str:
    """Format duration as human-readable string"""
    hours = seconds // 3600
    minutes = (seconds % 3600) // 60
    secs = seconds % 60
    return f"{hours}h {minutes}m {secs}s"

def analyze_hypothesis_coverage(strategies_log: List[Dict]) -> Dict:
    """Analyze which hypotheses were explored"""
    coverage = {}
    for strategy in strategies_log:
        hyp_ids = strategy.get('hypothesis_ids', [])
        if isinstance(hyp_ids, list):
            for hyp_id in hyp_ids:
                if hyp_id not in coverage:
                    coverage[hyp_id] = {'count': 0, 'best_edge': 0}
                coverage[hyp_id]['count'] += 1
                edge = _coerce_float(strategy.get('final_edge'))
                if edge is not None and edge > coverage[hyp_id]['best_edge']:
                    coverage[hyp_id]['best_edge'] = float(edge)
    return coverage

def generate_report(state_dir: Path, output_path: Path):
    """Generate comprehensive Phase 7 final report"""
    state = load_state(state_dir)

    # Calculate metrics
    elapsed = int(time.time()) - state['start_time']
    total_iterations = state['iteration_count']
    final_best = state['best_edge']
    strategies_tested = len(state['strategies_log'])
    templates_created = len(state['templates_created'])

    # Success rates
    ok_strategies = [s for s in state['strategies_log'] if isinstance(s, dict) and _is_ok_entry(s)]
    success_rate = (len(ok_strategies) / max(1, strategies_tested)) * 100

    # Best strategies
    top_strategies = sorted(ok_strategies, key=_edge_or_zero, reverse=True)[:10]

    # Hypothesis coverage
    hypothesis_coverage = analyze_hypothesis_coverage(state['strategies_log'])

    # Build report
    report_lines = [
        "# Phase 7 Final Report: AI-Powered Strategy Exploration",
        "",
        f"**Generated**: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"**Runtime**: {format_duration(elapsed)}",
        "",
        "---",
        "",
        "## Executive Summary",
        "",
        f"- **Total Iterations**: {total_iterations}",
        f"- **Strategies Tested**: {strategies_tested}",
        f"- **Success Rate**: {success_rate:.1f}%",
        f"- **Final Best Edge**: {final_best:.2f}",
        f"- **Templates Created**: {templates_created}",
        f"- **Starting Baseline**: 374.56 (Phase 1 best)",
        f"- **Improvement**: {final_best - 374.56:+.2f} points",
        "",
        "### Target Achievement",
        "",
    ]

    if final_best >= 527:
        report_lines.append(f"✅ **COMPETITIVE TARGET ACHIEVED!** Edge {final_best:.2f} >= 527")
    elif final_best >= 400:
        report_lines.append(f"✅ **BASELINE TARGET ACHIEVED!** Edge {final_best:.2f} >= 400")
    else:
        gap = 400 - final_best
        report_lines.append(f"⚠️ **Target not achieved.** Gap to 400: {gap:.2f} points")

    report_lines.extend([
        "",
        "---",
        "",
        "## Top 10 Strategies",
        "",
    ])

    if top_strategies:
        for i, strategy in enumerate(top_strategies[:10], 1):
            name = strategy.get('strategy_name', 'Unknown')
            edge = _edge_or_zero(strategy)
            hyp_ids = strategy.get('hypothesis_ids', [])
            hyp_str = ', '.join(hyp_ids) if isinstance(hyp_ids, list) and hyp_ids else 'H-baseline'

            report_lines.append(f"{i}. **{name}**: Edge {edge:.2f} ({hyp_str})")
    else:
        report_lines.append("No successful strategies recorded yet.")

    report_lines.extend([
        "",
        "---",
        "",
        "## Hypothesis Coverage Analysis",
        "",
    ])

    if hypothesis_coverage:
        report_lines.append("| Hypothesis | Strategies Tested | Best Edge |")
        report_lines.append("|------------|------------------|-----------|")
        for hyp_id in sorted(hypothesis_coverage.keys()):
            count = hypothesis_coverage[hyp_id]['count']
            best_edge = hypothesis_coverage[hyp_id]['best_edge']
            report_lines.append(f"| {hyp_id} | {count} | {best_edge:.2f} |")
    else:
        report_lines.append("No hypothesis data available.")

    report_lines.extend([
        "",
        "---",
        "",
        "## Templates Extracted",
        "",
    ])

    if state['templates_created']:
        for template in state['templates_created']:
            name = template.get('template_name', 'Unknown')
            source = template.get('source_strategy', 'Unknown')
            edge = template.get('source_edge', 0)
            params = template.get('parameters_count', 0)

            report_lines.append(f"- **{name}**")
            report_lines.append(f"  - Source: {source} (Edge {edge:.2f})")
            report_lines.append(f"  - Parameters: {params}")
            report_lines.append("")
    else:
        report_lines.append("No templates created during this run.")

    report_lines.extend([
        "",
        "---",
        "",
        "## Performance Analysis",
        "",
        f"- **Average Edge** (successful): {sum(_edge_or_zero(s) for s in ok_strategies) / max(1, len(ok_strategies)):.2f}",
        f"- **Iteration Rate**: {total_iterations / max(1, elapsed / 60):.2f} iter/min",
        f"- **Time per Strategy**: {elapsed / max(1, strategies_tested):.1f}s average",
        "",
        "---",
        "",
        "## Recommendations",
        "",
    ])

    # Generate recommendations based on results
    if final_best >= 527:
        report_lines.extend([
            "✅ **Competitive threshold achieved!**",
            "- Submit the best strategy to the competition",
            "- Run robustness checks across seed batches",
            "- Document the winning strategy pattern",
            ""
        ])
    elif final_best >= 400:
        report_lines.extend([
            "✓ **Baseline target achieved but not competitive yet.**",
            "- Consider running Phase 7 for another 10 hours",
            "- Focus on top-performing hypothesis patterns",
            f"- Current gap to competitive: {527 - final_best:.2f} points",
            ""
        ])
    else:
        report_lines.extend([
            "⚠️ **Target not achieved.**",
            "- Review generated strategies for common failure patterns",
            "- Consider refining the prompt template",
            "- May need to increase template threshold or adjust search strategy",
            f"- Gap to baseline target: {400 - final_best:.2f} points",
            ""
        ])

    if templates_created > 0:
        report_lines.extend([
            f"📝 **{templates_created} templates created for future use**",
            "- These can be used in template-based exploration (Phases 1-6)",
            "- Review templates for novel patterns",
            ""
        ])

    report_lines.extend([
        "---",
        "",
        "## Next Steps",
        "",
        "1. Review top-performing strategies in detail",
        "2. Run robustness checks on champion strategy",
        "3. Analyze hypothesis coverage for gaps",
        "4. Consider parameter optimization on best templates",
        "5. Document findings in research notes",
        "",
        "---",
        "",
        f"**Report generated by**: `amm-phase7-report-generator.py`",
        f"**State directory**: `{state_dir}`",
        ""
    ])

    # Write report
    report_text = '\n'.join(report_lines)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(report_text)

    print(f"✓ Report generated: {output_path}")
    return 0

# ============================================================================
# MAIN
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="Generate Phase 7 final report")
    parser.add_argument("--state-dir", required=True, help="Path to state directory")
    parser.add_argument("--output", required=True, help="Output path for report")
    args = parser.parse_args()

    return generate_report(Path(args.state_dir), Path(args.output))

if __name__ == "__main__":
    import sys
    sys.exit(main())
