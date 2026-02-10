#!/usr/bin/env python3
"""
Parse codex.jsonl to extract:
1. Edge scores from amm-match run commands
2. Strategies created via file_change events
3. Key reasoning patterns

This parser bridges the gap between Codex's agentic output (file_change events)
and the orchestrator's expected text-based markers.
"""

import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Any, Optional


def extract_edge_experiments(events: List[Dict]) -> List[Dict]:
    """Extract edge scores from command_execution events."""
    experiments = []

    for event in events:
        if event.get('type') != 'item.completed':
            continue
        item = event.get('item', {})
        if item.get('type') != 'command_execution':
            continue

        cmd = item.get('command', '')
        output = item.get('aggregated_output', '') or item.get('output', '')

        # Look for amm-match run commands
        if 'amm-match' in cmd and 'run' in cmd:
            # Extract strategy name
            strategy_match = re.search(r'run\s+(\S+\.sol)', cmd)
            strategy = strategy_match.group(1) if strategy_match else 'unknown'

            # Extract edge score - try multiple patterns
            edge_match = re.search(r'Edge:\s*(-?\d+\.?\d*)', output)
            if not edge_match:
                edge_match = re.search(r'edge[:\s]+(-?\d+\.?\d*)', output, re.IGNORECASE)

            if edge_match:
                try:
                    edge = float(edge_match.group(1))
                    experiments.append({
                        'strategy': strategy,
                        'edge': edge,
                        'command': cmd[:150]
                    })
                except ValueError:
                    pass

    return experiments


def extract_file_changes(events: List[Dict]) -> List[Dict]:
    """Extract created strategy files with their content."""
    files = []

    for event in events:
        if event.get('type') != 'item.completed':
            continue
        item = event.get('item', {})
        if item.get('type') != 'file_change':
            continue

        changes = item.get('changes', [])
        for change in changes:
            path = change.get('path', '')
            content = change.get('content', '')

            if path and path.endswith('.sol'):
                files.append({
                    'path': path,
                    'content': content,
                    'size': len(content) if content else 0
                })

    return files


def extract_best_strategy(events: List[Dict]) -> Optional[Dict]:
    """Find the best performing strategy from the session."""
    experiments = extract_edge_experiments(events)
    file_changes = extract_file_changes(events)

    if not experiments:
        return None

    # Find best edge
    best_exp = max(experiments, key=lambda x: x['edge'])

    # Try to find matching file content
    strategy_name = best_exp['strategy']
    for fc in file_changes:
        if strategy_name in fc['path'] or Path(fc['path']).stem in strategy_name:
            return {
                'name': strategy_name,
                'edge': best_exp['edge'],
                'content': fc['content'],
                'path': fc['path']
            }

    return {
        'name': strategy_name,
        'edge': best_exp['edge'],
        'content': None,
        'path': None
    }


def extract_reasoning_summary(events: List[Dict], max_items: int = 5) -> List[str]:
    """Extract key reasoning points from the session."""
    reasoning_items = []

    for event in events:
        if event.get('type') != 'item.completed':
            continue
        item = event.get('item', {})
        if item.get('type') != 'reasoning':
            continue

        summary = item.get('summary', [])
        if isinstance(summary, list):
            for s in summary:
                if isinstance(s, dict):
                    text = s.get('text', '')
                else:
                    text = str(s)
                if text and len(text) > 20:
                    reasoning_items.append(text[:200])
        elif isinstance(summary, str) and len(summary) > 20:
            reasoning_items.append(summary[:200])

    # Return most recent reasoning items
    return reasoning_items[-max_items:] if reasoning_items else []


def parse_codex_jsonl(jsonl_path: str) -> Dict[str, Any]:
    """Main parsing function."""
    events = []
    path = Path(jsonl_path)

    if not path.exists():
        return {
            'error': f'File not found: {jsonl_path}',
            'edge_experiments': [],
            'files_created': [],
            'best_strategy': None,
            'reasoning_summary': [],
            'n_events': 0
        }

    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue

    experiments = extract_edge_experiments(events)
    files = extract_file_changes(events)
    best = extract_best_strategy(events)
    reasoning = extract_reasoning_summary(events)

    return {
        'edge_experiments': experiments,
        'files_created': [f['path'] for f in files],
        'best_strategy': best,
        'reasoning_summary': reasoning,
        'n_events': len(events),
        'n_experiments': len(experiments),
        'n_files': len(files)
    }


def format_discoveries(result: Dict) -> str:
    """Format parsed results as markdown discoveries."""
    lines = []

    if result.get('edge_experiments'):
        lines.append("### Edge Experiments")
        lines.append("| Strategy | Edge |")
        lines.append("|----------|------|")

        # Sort by edge descending
        sorted_exps = sorted(result['edge_experiments'],
                           key=lambda x: x['edge'], reverse=True)
        for exp in sorted_exps[:10]:
            lines.append(f"| {exp['strategy']} | {exp['edge']:.2f} |")
        lines.append("")

    if result.get('best_strategy'):
        best = result['best_strategy']
        lines.append(f"### Best Strategy: {best['name']}")
        lines.append(f"- Edge: {best['edge']:.2f}")
        if best.get('path'):
            lines.append(f"- Path: {best['path']}")
        lines.append("")

    if result.get('files_created'):
        lines.append("### Files Created")
        for f in result['files_created']:
            lines.append(f"- {f}")
        lines.append("")

    return "\n".join(lines)


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: amm-phase7-codex-parser.py <codex.jsonl> [--format markdown]")
        sys.exit(1)

    jsonl_path = sys.argv[1]
    format_md = '--format' in sys.argv and 'markdown' in sys.argv

    result = parse_codex_jsonl(jsonl_path)

    if format_md:
        print(format_discoveries(result))
    else:
        print(json.dumps(result, indent=2))
