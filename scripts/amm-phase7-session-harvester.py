#!/usr/bin/env python3
"""
AMM Phase 7 Session Harvester

Parses Codex JSONL session logs to extract:
- Test results from `amm-match run` commands
- Lessons learned from reasoning traces
- Regression detection

Outputs:
- Updates .strategies_log.json with harvested results
- Updates .best_edge.txt if higher edge found
- Creates .knowledge_context.json for prompt builder
"""

import argparse
import json
import re
import sys
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


@dataclass
class HarvestedResult:
    """A test result extracted from a Codex session."""
    iteration: int
    strategy_file: str
    strategy_name: str
    edge: float
    n_simulations: int
    timestamp: str
    source: str = "codex_session"
    command: str = ""


@dataclass
class Regression:
    """A detected performance regression."""
    from_strategy: str
    from_edge: float
    to_strategy: str
    to_edge: float
    iteration: int


def parse_codex_jsonl(jsonl_path: Path) -> list[dict]:
    """Parse JSONL file, return list of event dicts."""
    events = []
    if not jsonl_path.exists():
        return events

    with open(jsonl_path, 'r', errors='replace') as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
                events.append(event)
            except json.JSONDecodeError:
                # Skip malformed lines (partial writes, etc.)
                continue
    return events


def extract_amm_match_results(events: list[dict], iteration: int) -> list[HarvestedResult]:
    """
    Find command_execution items with 'amm-match run' commands.
    Parse the aggregated_output for edge scores.

    Pattern to match in output:
        "StrategyName Edge: 499.32"
    """
    results = []
    edge_pattern = re.compile(r'(\w+)\s+Edge:\s*([\d.]+)')

    for event in events:
        if event.get('type') != 'item.completed':
            continue

        item = event.get('item', {})
        if item.get('type') != 'command_execution':
            continue
        if item.get('status') != 'completed':
            continue

        command = item.get('command', '')
        if 'amm-match run' not in command:
            continue

        output = item.get('aggregated_output', '')
        if not output:
            continue

        # Extract strategy file from command
        # Pattern: amm-match run some_strategy.sol --simulations N
        file_match = re.search(r'amm-match run\s+(\S+\.sol)', command)
        strategy_file = file_match.group(1) if file_match else 'unknown.sol'

        # Extract simulation count
        sim_match = re.search(r'--simulations?\s+(\d+)', command)
        n_sims = int(sim_match.group(1)) if sim_match else 10

        # Extract edge score from output
        edge_match = edge_pattern.search(output)
        if not edge_match:
            continue

        strategy_name = edge_match.group(1)
        edge = float(edge_match.group(2))

        results.append(HarvestedResult(
            iteration=iteration,
            strategy_file=strategy_file,
            strategy_name=strategy_name,
            edge=edge,
            n_simulations=n_sims,
            timestamp=datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
            source='codex_session',
            command=command[:200]  # Truncate for storage
        ))

    return results


def extract_lessons_from_reasoning(events: list[dict]) -> list[str]:
    """
    Find reasoning items that contain insights.
    Use heuristics to identify learning moments.
    """
    lessons = []
    insight_patterns = [
        r"I\s+realiz(?:e|ed)\s+(?:that\s+)?(.{20,150})",
        r"(?:The|This)\s+(?:key|important|critical)\s+(?:insight|lesson|point)\s+is\s+(.{20,150})",
        r"(?:works|worked)\s+because\s+(.{20,150})",
        r"(?:backfired|failed|regressed)\s+because\s+(.{20,150})",
        r"(?:The\s+)?problem\s+(?:is|was)\s+(.{20,100})",
        r"Simple\s+(.{20,100})\s+outperform",
    ]

    seen = set()

    for event in events:
        if event.get('type') != 'item.completed':
            continue

        item = event.get('item', {})
        if item.get('type') != 'reasoning':
            continue

        text = item.get('text', '')
        if not text:
            continue

        for pattern in insight_patterns:
            matches = re.findall(pattern, text, re.IGNORECASE)
            for match in matches:
                # Clean up the match
                lesson = match.strip()
                lesson = re.sub(r'\s+', ' ', lesson)
                lesson = lesson.rstrip('.')

                # Skip duplicates and very short matches
                if len(lesson) < 20:
                    continue
                lesson_key = lesson.lower()[:50]
                if lesson_key in seen:
                    continue
                seen.add(lesson_key)

                lessons.append(lesson)

    return lessons[:10]  # Limit to top 10 lessons


def detect_regressions(results: list[HarvestedResult]) -> list[Regression]:
    """
    Find cases where strategy modifications made performance worse.
    """
    regressions = []

    # Group by iteration and sort by edge
    by_iteration: dict[int, list[HarvestedResult]] = {}
    for r in results:
        by_iteration.setdefault(r.iteration, []).append(r)

    for iteration, iter_results in by_iteration.items():
        if len(iter_results) < 2:
            continue

        # Sort by edge descending
        sorted_results = sorted(iter_results, key=lambda x: x.edge, reverse=True)
        best = sorted_results[0]

        # Find results that came after the best and are significantly worse
        for r in sorted_results[1:]:
            # If edge dropped by more than 30%, it's a regression
            if r.edge < best.edge * 0.7:
                regressions.append(Regression(
                    from_strategy=best.strategy_name,
                    from_edge=best.edge,
                    to_strategy=r.strategy_name,
                    to_edge=r.edge,
                    iteration=iteration
                ))

    return regressions


def harvest_iteration(iteration: int, state_dir: Path) -> tuple[list[HarvestedResult], list[str]]:
    """Process one iteration's JSONL file."""
    jsonl_path = state_dir / f'iteration_{iteration}_codex.jsonl'

    if not jsonl_path.exists():
        return [], []

    events = parse_codex_jsonl(jsonl_path)
    results = extract_amm_match_results(events, iteration)
    lessons = extract_lessons_from_reasoning(events)

    return results, lessons


def harvest_all_iterations(state_dir: Path) -> tuple[list[HarvestedResult], list[str]]:
    """Process all iteration JSONL files."""
    all_results = []
    all_lessons = []

    # Find all iteration files
    for jsonl_file in sorted(state_dir.glob('iteration_*_codex.jsonl')):
        match = re.search(r'iteration_(\d+)_codex\.jsonl', jsonl_file.name)
        if not match:
            continue
        iteration = int(match.group(1))

        results, lessons = harvest_iteration(iteration, state_dir)
        all_results.extend(results)
        all_lessons.extend(lessons)

    # Deduplicate lessons
    seen = set()
    unique_lessons = []
    for lesson in all_lessons:
        key = lesson.lower()[:50]
        if key not in seen:
            seen.add(key)
            unique_lessons.append(lesson)

    return all_results, unique_lessons[:15]  # Limit total lessons


def build_knowledge_context(
    results: list[HarvestedResult],
    lessons: list[str],
    current_best_edge: float
) -> dict:
    """Build the knowledge context for prompt builder."""

    # Find true best - ONLY from 1000+ simulation results (leaderboard threshold)
    MIN_SIMS_FOR_BEST = 1000
    high_confidence_results = [r for r in results if r.n_simulations >= MIN_SIMS_FOR_BEST]

    if high_confidence_results:
        best_result = max(high_confidence_results, key=lambda r: r.edge)
        true_best_edge = max(best_result.edge, current_best_edge)
        true_best_strategy = best_result.strategy_name if best_result.edge >= current_best_edge else "Unknown"
    else:
        true_best_edge = current_best_edge
        true_best_strategy = "Unknown"

    # Build strategies table
    all_tested = []
    seen_strategies = set()
    for r in sorted(results, key=lambda x: x.edge, reverse=True):
        key = (r.strategy_name, r.iteration)
        if key in seen_strategies:
            continue
        seen_strategies.add(key)
        all_tested.append({
            'name': r.strategy_name,
            'edge': r.edge,
            'sims': r.n_simulations,
            'iteration': r.iteration,
            'file': r.strategy_file
        })

    # Detect regressions
    regressions = detect_regressions(results)
    regression_list = [
        {
            'from': reg.from_strategy,
            'from_edge': reg.from_edge,
            'to': reg.to_strategy,
            'to_edge': reg.to_edge,
            'iteration': reg.iteration
        }
        for reg in regressions
    ]

    return {
        'true_best_edge': true_best_edge,
        'true_best_strategy': true_best_strategy,
        'all_tested_strategies': all_tested[:20],  # Limit size
        'lessons_learned': lessons,
        'regressions': regression_list,
        'harvested_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
        'total_results_harvested': len(results)
    }


def update_state_files(
    state_dir: Path,
    results: list[HarvestedResult],
    knowledge_context: dict,
    dry_run: bool = False
) -> None:
    """Update state files with harvested data."""

    # Update .best_edge.txt if we found a better edge
    best_edge_path = state_dir / '.best_edge.txt'
    current_best = 0.0
    if best_edge_path.exists():
        try:
            current_best = float(best_edge_path.read_text().strip())
        except ValueError:
            pass

    if knowledge_context['true_best_edge'] > current_best:
        if dry_run:
            print(f"[DRY RUN] Would update .best_edge.txt: {current_best} -> {knowledge_context['true_best_edge']}")
        else:
            best_edge_path.write_text(f"{knowledge_context['true_best_edge']:.2f}\n")
            print(f"Updated .best_edge.txt: {current_best} -> {knowledge_context['true_best_edge']}")

    # Write knowledge context
    knowledge_path = state_dir / '.knowledge_context.json'
    if dry_run:
        print(f"[DRY RUN] Would write .knowledge_context.json with {len(results)} results")
    else:
        tmp_path = knowledge_path.with_suffix('.json.tmp')
        tmp_path.write_text(json.dumps(knowledge_context, indent=2))
        tmp_path.rename(knowledge_path)
        print(f"Wrote .knowledge_context.json with {len(results)} results")

    # Append to strategies log (only new results not already there)
    log_path = state_dir / '.strategies_log.json'
    existing_log = []
    if log_path.exists():
        try:
            existing_log = json.loads(log_path.read_text())
        except json.JSONDecodeError:
            existing_log = []

    # Find existing codex_session entries to avoid duplicates
    existing_keys = set()
    for entry in existing_log:
        if entry.get('source') == 'codex_session':
            key = (entry.get('iteration'), entry.get('strategy_name'), entry.get('final_edge'))
            existing_keys.add(key)

    # Add new results
    new_entries = []
    for r in results:
        key = (r.iteration, r.strategy_name, r.edge)
        if key in existing_keys:
            continue

        entry = {
            'iteration': r.iteration,
            'status': 'harvested',
            'timestamp': r.timestamp,
            'final_edge': r.edge,
            'strategy_name': r.strategy_name,
            'source': 'codex_session',
            'n_simulations': r.n_simulations,
            'strategy_file': r.strategy_file,
            'hypothesis_ids': [],
            'artifact_paths': {
                'strategy_file': r.strategy_file
            }
        }
        new_entries.append(entry)

    if new_entries:
        if dry_run:
            print(f"[DRY RUN] Would append {len(new_entries)} entries to .strategies_log.json")
        else:
            existing_log.extend(new_entries)
            tmp_path = log_path.with_suffix('.json.tmp')
            tmp_path.write_text(json.dumps(existing_log, indent=2))
            tmp_path.rename(log_path)
            print(f"Appended {len(new_entries)} entries to .strategies_log.json")


def main():
    parser = argparse.ArgumentParser(description='Harvest results from Codex sessions')
    parser.add_argument('--iteration', type=int, help='Specific iteration to harvest')
    parser.add_argument('--all', action='store_true', help='Harvest all iterations')
    parser.add_argument('--state-dir', type=str, required=True, help='Path to state directory')
    parser.add_argument('--dry-run', action='store_true', help='Show what would be done without writing')
    args = parser.parse_args()

    state_dir = Path(args.state_dir)
    if not state_dir.exists():
        print(f"Error: State directory does not exist: {state_dir}", file=sys.stderr)
        sys.exit(1)

    # Harvest results
    if args.all:
        print(f"Harvesting all iterations from {state_dir}...")
        results, lessons = harvest_all_iterations(state_dir)
    elif args.iteration:
        print(f"Harvesting iteration {args.iteration} from {state_dir}...")
        results, lessons = harvest_iteration(args.iteration, state_dir)
    else:
        print("Error: Specify --iteration N or --all", file=sys.stderr)
        sys.exit(1)

    if not results:
        print("No amm-match results found in session logs")
        return

    print(f"Found {len(results)} test results")
    print(f"Found {len(lessons)} lessons learned")

    # Show top results
    sorted_results = sorted(results, key=lambda x: x.edge, reverse=True)
    print("\nTop 5 results:")
    for r in sorted_results[:5]:
        print(f"  {r.strategy_name}: {r.edge:.2f} (iter {r.iteration}, {r.n_simulations} sims)")

    # Get current best edge
    best_edge_path = state_dir / '.best_edge.txt'
    current_best = 0.0
    if best_edge_path.exists():
        try:
            current_best = float(best_edge_path.read_text().strip())
        except ValueError:
            pass

    # Build knowledge context
    knowledge_context = build_knowledge_context(results, lessons, current_best)

    print(f"\nTrue best edge: {knowledge_context['true_best_edge']:.2f} ({knowledge_context['true_best_strategy']})")

    if knowledge_context['regressions']:
        print("\nRegressions detected:")
        for reg in knowledge_context['regressions']:
            print(f"  {reg['from']} ({reg['from_edge']:.2f}) -> {reg['to']} ({reg['to_edge']:.2f})")

    if lessons:
        print("\nLessons learned:")
        for lesson in lessons[:5]:
            print(f"  - {lesson[:80]}...")

    # Update state files
    update_state_files(state_dir, results, knowledge_context, dry_run=args.dry_run)


if __name__ == '__main__':
    main()
