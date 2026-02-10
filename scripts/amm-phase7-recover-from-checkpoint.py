#!/usr/bin/env python3
"""
Recover best strategy from a checkpoint file when Codex times out.

This script reads the checkpoint JSON (produced by amm-phase7-codex-parser.py)
and extracts the best strategy, formatting it as a structured output that
the orchestrator can process.
"""

import argparse
import json
import sys
from pathlib import Path


def recover_best_strategy(checkpoint_path: Path, output_path: Path, strategy_dir: Path = None):
    """
    Extract best strategy from checkpoint and create structured output.

    Args:
        checkpoint_path: Path to checkpoint JSON file
        output_path: Path to write structured strategy output
        strategy_dir: Optional directory containing .sol files to recover content from
    """
    with open(checkpoint_path) as f:
        data = json.load(f)

    best = data.get('best_strategy')
    experiments = data.get('edge_experiments', [])

    if not best and not experiments:
        print("No experiments found in checkpoint")
        sys.exit(1)

    # If no best_strategy computed, find it from experiments
    if not best and experiments:
        best_exp = max(experiments, key=lambda x: x.get('edge', 0))
        best = {
            'name': best_exp['strategy'],
            'edge': best_exp['edge'],
            'content': None,
            'path': None
        }

    # Try to find strategy content from filesystem if not in checkpoint
    strategy_content = best.get('content')
    if not strategy_content and strategy_dir:
        # Try exact path first
        if best.get('path'):
            path = strategy_dir / best['path']
            if path.exists():
                strategy_content = path.read_text()

        # Try by name
        if not strategy_content:
            for sol_file in strategy_dir.glob('*.sol'):
                if best['name'] in sol_file.name or sol_file.stem in best['name']:
                    strategy_content = sol_file.read_text()
                    break

    # Build structured output
    output_lines = []
    output_lines.append(f"# Recovered from timeout checkpoint")
    output_lines.append(f"# Best edge: {best.get('edge', 'unknown')}")
    output_lines.append(f"# Strategy: {best.get('name', 'unknown')}")
    output_lines.append("")

    if strategy_content:
        # Create full structured output that orchestrator expects
        output_lines.append("---DRAFT_STRATEGY_IDEA---")
        output_lines.append(f"Recovered from timeout. Best performing strategy: {best['name']}")
        output_lines.append("---END_DRAFT_STRATEGY_IDEA---")
        output_lines.append("")
        output_lines.append("---DESIGN_REVIEW---")
        output_lines.append("Recovered from timeout checkpoint.")
        output_lines.append("---END_DESIGN_REVIEW---")
        output_lines.append("")
        output_lines.append("---REVISED_IMPLEMENTATION---")
        output_lines.append("```solidity")
        output_lines.append(strategy_content)
        output_lines.append("```")
        output_lines.append("---END_REVISED_IMPLEMENTATION---")
        output_lines.append("")
        output_lines.append("---STRATEGY_METADATA---")

        # Extract name from content if possible
        import re
        name_match = re.search(r'return\s+"([^"]+)"', strategy_content)
        strategy_name = name_match.group(1) if name_match else best['name']

        metadata = {
            "name": strategy_name,
            "hypothesis_ids": ["H-timeout-recovery"],
            "slots_used": 0,
            "key_innovation": f"Recovered from timeout with edge {best.get('edge', 0):.2f}",
            "expected_edge_range": [best.get('edge', 0) - 20, best.get('edge', 0) + 20]
        }
        output_lines.append(json.dumps(metadata, indent=2))
        output_lines.append("---END_STRATEGY_METADATA---")
    else:
        # No content found, just report what we know
        output_lines.append(f"# Could not recover strategy content for {best.get('name')}")
        output_lines.append(f"# Check {strategy_dir} for .sol files")

        # List experiments found
        output_lines.append("")
        output_lines.append("# Experiments from this iteration:")
        for exp in sorted(experiments, key=lambda x: x.get('edge', 0), reverse=True)[:10]:
            output_lines.append(f"#   {exp['strategy']}: {exp.get('edge', 0):.2f} edge")

    output = "\n".join(output_lines)
    output_path.write_text(output)

    print(f"Recovered strategy: {best.get('name')}")
    print(f"Edge: {best.get('edge', 'unknown')}")
    print(f"Output written to: {output_path}")

    return best


def main():
    parser = argparse.ArgumentParser(description="Recover strategy from timeout checkpoint")
    parser.add_argument("--checkpoint", required=True, help="Path to checkpoint JSON")
    parser.add_argument("--output", required=True, help="Path for structured output")
    parser.add_argument("--strategy-dir", default=".", help="Directory containing .sol files")
    args = parser.parse_args()

    recover_best_strategy(
        Path(args.checkpoint),
        Path(args.output),
        Path(args.strategy_dir)
    )


if __name__ == '__main__':
    main()
