#!/usr/bin/env python3
"""
AMM Experiment Logger
Generates structured experiment documentation from test results
"""

import json
import re
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Optional


def get_next_experiment_id(experiments_dir: Path) -> str:
    """
    Scan experiments/ for E-### patterns and return next available ID.

    Args:
        experiments_dir: Path to research/experiments directory

    Returns:
        Next experiment ID like "E-001" or "E-012"
    """
    pattern = re.compile(r'E-(\d{3})')
    max_id = 0

    if not experiments_dir.exists():
        experiments_dir.mkdir(parents=True, exist_ok=True)
        return "E-001"

    for file in experiments_dir.glob('*.md'):
        if match := pattern.search(file.name):
            max_id = max(max_id, int(match.group(1)))

    return f"E-{max_id + 1:03d}"


def format_results_section(result: dict, metrics: dict) -> str:
    """
    Format the Results section of experiment log.

    Args:
        result: Full result JSON from test pipeline
        metrics: metrics_1000 dict from result

    Returns:
        Formatted markdown Results section
    """
    sections = []

    # Edge scores
    sections.append("### Edge Scores\n")
    testing = result.get('testing', {})
    sections.append(f"- 10 sims: Edge {testing.get('edge_10', 0):.2f}")
    sections.append(f"- 100 sims: Edge {testing.get('edge_100', 0):.2f}")
    if 'edge_1000' in testing:
        sections.append(f"- 1000 sims: Edge {testing.get('edge_1000', 0):.2f}")
    sections.append("")

    # Comparative metrics (if available)
    if metrics:
        sections.append("### Comparative Metrics (vs 30 bps Normalizer)\n")

        # Edge comparison
        sub_edge = metrics.get('submission_edge', 0)
        norm_edge = metrics.get('normalizer_edge', 0)
        advantage = metrics.get('edge_advantage', 0)

        sections.append(f"**Edge Comparison:**")
        sections.append(f"- Submission: {sub_edge:.2f}")
        sections.append(f"- Normalizer: {norm_edge:.2f}")
        sections.append(f"- Advantage: {advantage:+.2f} {'✓' if advantage > 0 else '✗'}")
        sections.append("")

        # Volume diagnostics
        sections.append(f"**Volume Diagnostics:**")

        sub_retail = metrics.get('submission_retail_volume', 0)
        norm_retail = metrics.get('normalizer_retail_volume', 0)
        retail_adv = metrics.get('retail_volume_advantage', 0)
        retail_pct = (retail_adv / norm_retail * 100) if norm_retail > 0 else 0

        sections.append(f"- Retail (submission): {sub_retail:.2f} ({retail_pct:+.1f}% vs normalizer)")

        sub_arb = metrics.get('submission_arb_volume', 0)
        norm_arb = metrics.get('normalizer_arb_volume', 0)
        arb_adv = metrics.get('arb_volume_advantage', 0)
        arb_pct = (arb_adv / norm_arb * 100) if norm_arb > 0 else 0

        sections.append(f"- Arb (submission): {sub_arb:.2f} ({arb_pct:+.1f}% vs normalizer)")
        sections.append("")

        # Fee diagnostics
        sections.append(f"**Fee Diagnostics:**")
        bid_fee = metrics.get('submission_avg_bid_fee', 0)
        ask_fee = metrics.get('submission_avg_ask_fee', 0)
        asymmetry = metrics.get('fee_asymmetry', 0)

        sections.append(f"- Avg bid fee: {bid_fee * 10000:.2f} bps")
        sections.append(f"- Avg ask fee: {ask_fee * 10000:.2f} bps")
        sections.append(f"- Asymmetry (ask - bid): {asymmetry * 10000:.2f} bps")
        sections.append("")

        # Distribution
        percentiles = metrics.get('edge_percentiles', {})
        if percentiles:
            sections.append(f"**Edge Distribution:**")
            sections.append(f"- p05: {percentiles.get('p05', 0):.2f}")
            sections.append(f"- p50: {percentiles.get('p50', 0):.2f}")
            sections.append(f"- p95: {percentiles.get('p95', 0):.2f}")
            sections.append("")

        # Win/Loss/Draw
        wins = metrics.get('wins', 0)
        losses = metrics.get('losses', 0)
        draws = metrics.get('draws', 0)
        total = wins + losses + draws
        win_rate = (wins / total * 100) if total > 0 else 0

        sections.append(f"**Win/Loss/Draw:** {wins} / {losses} / {draws} ({win_rate:.1f}% win rate)")
        sections.append("")

    # Runtime
    runtime = result.get('runtime', {})
    total_time = runtime.get('total_seconds', 0)
    sections.append(f"**Runtime:** {total_time:.1f}s total")

    return "\n".join(sections)


def generate_experiment_log(result_path: str, experiments_dir: str = "research/experiments") -> Optional[Path]:
    """
    Generate experiment log from enhanced result JSON.

    Args:
        result_path: Path to result JSON file
        experiments_dir: Directory to write experiment logs

    Returns:
        Path to generated experiment log, or None if not applicable
    """
    result = json.loads(Path(result_path).read_text())

    # Only generate logs for successful 1000-sim runs with metrics
    if not result.get('success', False):
        return None

    metrics = result.get('testing', {}).get('metrics_1000')
    if not metrics:
        return None

    exp_dir = Path(experiments_dir)
    exp_id = get_next_experiment_id(exp_dir)

    # Extract metadata
    date = result.get('timestamp', datetime.now().isoformat())[:10]
    hyp_id = result.get('hypothesis_id', 'H-baseline').replace(',', '-')
    strategy_name = result.get('strategy_name', 'Unknown')
    strategy_path = result.get('strategy_path', '')
    git_sha = result.get('git_sha', 'unknown')

    # Create filename: YYYY-MM-DD_E###_H-XXX_<slug>.md
    slug = strategy_name.lower().replace('_', '-')[:30]
    filename = f"{date}_{exp_id}_{hyp_id}_{slug}.md"

    # Generate content
    content = []
    content.append(f"# Experiment {exp_id} — {strategy_name}\n")
    content.append(f"- Date: {date}")
    content.append(f"- Hypothesis: {result.get('hypothesis_id', 'H-baseline')}")
    content.append(f"- Strategy file: `{strategy_path}`")
    content.append(f"- Git SHA: `{git_sha}`")

    if result.get('git_dirty', False):
        content.append(f"- ⚠️ Working directory had uncommitted changes")

    content.append("\n## Goal\n")

    # Infer goal from hypothesis and strategy type
    if 'H-baseline' in result.get('hypothesis_id', ''):
        content.append("Establish baseline performance curve for fixed fee strategies.")
    elif 'H-002' in result.get('hypothesis_id', '') or 'H-006' in result.get('hypothesis_id', ''):
        content.append("Test if adaptive fees based on trade signals can outperform fixed fees.")
    elif 'H-005' in result.get('hypothesis_id', ''):
        content.append("Test if fee decay mechanisms after events can improve performance.")
    else:
        content.append("Validate hypothesis and measure strategy performance.")

    content.append("\n## Change summary\n")
    content.append(f"Strategy: {strategy_name}")
    content.append(f"Parameters: (extracted from template)")

    content.append("\n## Commands run\n")
    content.append("```bash")
    content.append(f"python scripts/amm-test-pipeline.py {strategy_path} \\")
    content.append(f"  --output .ralph-amm/state/last_result.json")
    content.append("```")

    content.append("\n## Results\n")
    content.append(format_results_section(result, metrics))

    content.append("\n## Interpretation\n")

    # Auto-generate interpretation based on metrics
    edge_adv = metrics.get('edge_advantage', 0)
    if edge_adv > 5:
        content.append(f"✅ **Strong positive result**: Edge advantage of {edge_adv:.2f} suggests strategy significantly outperforms normalizer.")
    elif edge_adv > 0:
        content.append(f"✓ **Marginal improvement**: Edge advantage of {edge_adv:.2f} shows modest gains over normalizer.")
    elif edge_adv > -5:
        content.append(f"≈ **Neutral result**: Edge advantage of {edge_adv:.2f} suggests strategy performs similarly to normalizer.")
    else:
        content.append(f"✗ **Underperformance**: Edge advantage of {edge_adv:.2f} indicates strategy underperforms normalizer.")

    content.append("\n## Decision / next steps\n")
    content.append("- [To be filled based on analysis]")

    content.append("")

    # Write file
    output_path = exp_dir / filename
    output_path.write_text("\n".join(content))

    return output_path


def parse_experiment_logs(experiments_dir: str = "research/experiments") -> List[Dict]:
    """
    Parse experiment markdown files for analysis.

    Args:
        experiments_dir: Directory containing experiment logs

    Returns:
        List of experiment metadata dicts
    """
    exp_dir = Path(experiments_dir)
    if not exp_dir.exists():
        return []

    experiments = []

    for file in sorted(exp_dir.glob('*.md')):
        if file.name == 'README.md':
            continue

        # Extract from filename: YYYY-MM-DD_E###_H-XXX_<slug>.md
        match = re.match(r'(\d{4}-\d{2}-\d{2})_(E-\d{3})_(H-[^_]+)_(.+)\.md', file.name)
        if not match:
            continue

        date, exp_id, hyp_id, slug = match.groups()

        # Parse file content for key metrics
        content = file.read_text()

        # Extract edge scores
        edge_match = re.search(r'- 1000 sims: Edge ([\d.]+)', content)
        edge_1000 = float(edge_match.group(1)) if edge_match else None

        # Extract edge advantage
        adv_match = re.search(r'- Advantage: ([+-]?[\d.]+)', content)
        edge_advantage = float(adv_match.group(1)) if adv_match else None

        experiments.append({
            'date': date,
            'experiment_id': exp_id,
            'hypothesis_ids': hyp_id.split('-')[1:],  # Split "H-002-H-006" into ["002", "006"]
            'slug': slug,
            'edge_1000': edge_1000,
            'edge_advantage': edge_advantage,
            'file_path': str(file),
        })

    return experiments


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: python amm-experiment-logger.py <result_json_path>")
        sys.exit(1)

    result_path = sys.argv[1]
    output = generate_experiment_log(result_path)

    if output:
        print(f"Generated experiment log: {output}")
    else:
        print("No experiment log generated (not a 1000-sim run with metrics)")
