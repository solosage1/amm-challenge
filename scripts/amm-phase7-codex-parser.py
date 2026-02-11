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


def extract_reasoning_summary(events: List[Dict], max_items: int = 10) -> List[Dict]:
    """Extract key reasoning points from the session.

    Returns list of dicts with 'summary' (truncated for display) and 'full_text'.
    """
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
                    reasoning_items.append({
                        'summary': text[:1000],  # Increased from 200 to preserve more context
                        'full_text': text,
                    })
        elif isinstance(summary, str) and len(summary) > 20:
            reasoning_items.append({
                'summary': summary[:1000],
                'full_text': summary,
            })

    # Return most recent reasoning items
    return reasoning_items[-max_items:] if reasoning_items else []


def extract_parameter_discoveries(events: List[Dict]) -> Dict[str, List[Dict]]:
    """Extract parameter search patterns from reasoning and experiments.

    Looks for:
    - Buffer/threshold values tested
    - EWMA alpha values
    - Dual-regime thresholds
    - Fee values tested
    """
    discoveries = {
        'buffer_values': [],
        'ewma_alpha_values': [],
        'fee_values': [],
        'threshold_values': [],
        'edge_by_params': [],
    }

    # Patterns for parameter extraction
    patterns = {
        'buffer': re.compile(r'buffer[=:\s]+(\d+\.?\d*)', re.IGNORECASE),
        'ewma_alpha': re.compile(r'(?:ewma|alpha)[=:\s]+(\d+\.?\d*)', re.IGNORECASE),
        'fee': re.compile(r'(?:fee|ask_?fee|bid_?fee)[=:\s]+(\d+\.?\d*)', re.IGNORECASE),
        'threshold': re.compile(r'(?:threshold|thresh)[=:\s]+(\d+\.?\d*)', re.IGNORECASE),
    }

    # Extract from reasoning items
    for event in events:
        if event.get('type') != 'item.completed':
            continue
        item = event.get('item', {})

        text = ''
        if item.get('type') == 'reasoning':
            summary = item.get('summary', [])
            if isinstance(summary, list):
                text = ' '.join(str(s.get('text', s) if isinstance(s, dict) else s) for s in summary)
            else:
                text = str(summary)
        elif item.get('type') == 'message':
            content = item.get('content', [])
            if isinstance(content, list):
                text = ' '.join(str(c.get('text', c) if isinstance(c, dict) else c) for c in content)

        if not text:
            continue

        # Look for parameter mentions
        for param_type, pattern in patterns.items():
            matches = pattern.findall(text)
            for match in matches:
                try:
                    value = float(match)
                    key = f'{param_type}_values'
                    if key in discoveries:
                        if value not in [d['value'] for d in discoveries[key]]:
                            discoveries[key].append({
                                'value': value,
                                'context': text[:200],
                            })
                except ValueError:
                    pass

    # Extract from command outputs to correlate params with edges
    experiments = extract_edge_experiments(events)
    for exp in experiments:
        cmd = exp.get('command', '')
        edge = exp.get('edge', 0)

        # Look for param values in command or strategy name
        params = {}
        for param_type, pattern in patterns.items():
            match = pattern.search(cmd)
            if match:
                try:
                    params[param_type] = float(match.group(1))
                except ValueError:
                    pass

        if params:
            discoveries['edge_by_params'].append({
                'params': params,
                'edge': edge,
                'strategy': exp.get('strategy', 'unknown'),
            })

    return discoveries


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
    parameters = extract_parameter_discoveries(events)

    return {
        'edge_experiments': experiments,
        'files_created': [f['path'] for f in files],
        'best_strategy': best,
        'reasoning_summary': reasoning,
        'parameter_discoveries': parameters,
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

    # Add parameter discoveries section
    params = result.get('parameter_discoveries', {})
    if params.get('edge_by_params'):
        lines.append("### Parameter Search Results")
        lines.append("| Strategy | Edge | Parameters |")
        lines.append("|----------|------|------------|")
        sorted_by_edge = sorted(params['edge_by_params'],
                               key=lambda x: x['edge'], reverse=True)
        for item in sorted_by_edge[:10]:
            param_str = ', '.join(f"{k}={v}" for k, v in item['params'].items())
            lines.append(f"| {item['strategy']} | {item['edge']:.2f} | {param_str} |")
        lines.append("")

    # Add reasoning summary (now with full context)
    if result.get('reasoning_summary'):
        lines.append("### Key Reasoning")
        for item in result['reasoning_summary'][:5]:
            if isinstance(item, dict):
                text = item.get('summary', '')
            else:
                text = str(item)
            # Truncate for display but preserve more context
            if len(text) > 300:
                text = text[:297] + "..."
            lines.append(f"- {text}")
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
