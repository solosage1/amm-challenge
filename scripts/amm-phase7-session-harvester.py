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

    # Canonical best metric is 1000-sim edge.
    results_1000 = [r for r in results if r.n_simulations >= 1000]
    has_1000_results = bool(results_1000)
    if has_1000_results:
        best_result_1000 = max(results_1000, key=lambda r: r.edge)
        true_best_edge_1000 = float(best_result_1000.edge)
        true_best_strategy_1000 = best_result_1000.strategy_name
    else:
        # Explicit no-data state for canonical 1000-sim ranking.
        true_best_edge_1000 = 0.0
        true_best_strategy_1000 = "Unknown"

    # Track best-any as a secondary signal for exploration prioritization.
    if results:
        best_result_any = max(results, key=lambda r: r.edge)
        true_best_edge_any = float(best_result_any.edge)
        true_best_strategy_any = best_result_any.strategy_name
    else:
        true_best_edge_any = 0.0
        true_best_strategy_any = "Unknown"

    # Build strategies table
    all_tested = []
    seen_strategies = set()
    # Prioritize higher simulation counts before edge so authoritative results appear first.
    for r in sorted(results, key=lambda x: (x.n_simulations, x.edge), reverse=True):
        key = (r.strategy_name, r.iteration, r.n_simulations)
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

    all_tested_1000 = [
        s for s in all_tested if int(s.get("sims", 0) or 0) >= 1000
    ]

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
        # Backward-compatible canonical aliases:
        'true_best_edge': true_best_edge_1000,
        'true_best_strategy': true_best_strategy_1000,
        # Explicit metrics:
        'has_1000_results': has_1000_results,
        'state_best_edge_benchmark': float(current_best_edge),
        'true_best_edge_1000': true_best_edge_1000,
        'true_best_strategy_1000': true_best_strategy_1000,
        'true_best_edge_any': true_best_edge_any,
        'true_best_strategy_any': true_best_strategy_any,
        'all_tested_strategies': all_tested[:20],  # Limit size
        'all_tested_strategies_1000': all_tested_1000[:20],
        'lessons_learned': lessons,
        'regressions': regression_list,
        'harvested_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
        'total_results_harvested': len(results)
    }


def infer_mechanisms(strategy_name: str) -> list[str]:
    """Infer coarse mechanism tags from strategy naming conventions."""
    name = strategy_name.lower()
    mechanisms: list[str] = []
    if re.match(r"canary_mode3_v\d+$", name):
        mechanisms.append("regime_state_machine_heavy")
    if re.match(r"canary_mode3_light_l\d+$", name):
        mechanisms.append("regime_state_machine_light")
    if "compunder" in name or re.search(r"_u\d+", name):
        mechanisms.append("competitive_undercut")
    if "gamma" in name:
        mechanisms.append("gamma_squared_anchor")
    if "band" in name:
        mechanisms.append("tight_band_regime")
    if "buf" in name:
        mechanisms.append("protective_buffer")
    if "inventory" in name:
        mechanisms.append("inventory_trigger")
    if "cooldown" in name:
        mechanisms.append("cooldown_logic")
    return mechanisms if mechanisms else ["unspecified"]


def infer_parameters(strategy_name: str) -> dict[str, int]:
    """Infer parameter values from strategy naming conventions."""
    name = strategy_name.lower()
    params: dict[str, int] = {}

    m = re.search(r"compunder(\d+)", name)
    if m:
        params["competitive_undercut_bps"] = int(m.group(1))
    m = re.search(r"_u(\d+)", name)
    if m:
        params.setdefault("competitive_undercut_bps", int(m.group(1)))
    m = re.search(r"band(\d+)", name)
    if m:
        params["tight_band_bps"] = int(m.group(1))
    m = re.search(r"buf(\d+)", name)
    if m:
        params["protective_buffer_bps"] = int(m.group(1))
    m = re.search(r"(?:_t|tight)(\d+)", name)
    if m:
        params["tight_fee_bps"] = int(m.group(1))
    m = re.search(r"(?:_i|init)(\d+)", name)
    if m:
        params["init_fee_bps"] = int(m.group(1))
    return params


def build_failed_approaches(results: list[HarvestedResult], champion_edge: float) -> list[dict]:
    """Build failed-approach records from known family patterns."""
    failed: list[dict] = []

    def summarize_family(approach: str, regex: str) -> None:
        family = [r for r in results if re.match(regex, r.strategy_name.lower())]
        if len(family) < 4:
            return
        best = max(r.edge for r in family)
        delta = best - champion_edge
        # Hard non-promotion / family-kill signal from loop recommendations.
        if delta <= -0.8:
            failed.append({
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "approach": approach,
                "reason": (
                    f"best {best:.2f} is {abs(delta):.2f} below champion {champion_edge:.2f}; "
                    "failed family gate (< champion - 0.8 after initial batch)"
                ),
                "edge_achieved": round(best, 2),
                "delta_vs_champion": round(delta, 2),
                "sample_size": len(family),
            })

    summarize_family("heavy_3_state_regime_machine", r"canary_mode3_v\d+$")
    summarize_family("light_3_state_regime_machine", r"canary_mode3_light_l\d+$")
    return failed


def sync_knowledge_store(
    state_dir: Path,
    results: list[HarvestedResult],
    knowledge_context: dict,
    lessons: list[str],
    dry_run: bool = False,
) -> None:
    """
    Rebuild knowledge_store.json from harvested authoritative data.
    Keeps schema backward compatible while replacing stale placeholder content.
    """
    store_path = state_dir / "knowledge_store.json"
    existing = {}
    if store_path.exists():
        try:
            existing = json.loads(store_path.read_text())
        except Exception:
            existing = {}

    now = datetime.now(timezone.utc).isoformat()
    champion_edge = float(knowledge_context.get("true_best_edge_1000", 0.0) or 0.0)
    champion_name = str(knowledge_context.get("true_best_strategy_1000", "Unknown") or "Unknown")

    dedup: dict[tuple[int, str, int, float], HarvestedResult] = {}
    for r in results:
        key = (int(r.iteration), str(r.strategy_name), int(r.n_simulations), round(float(r.edge), 8))
        dedup[key] = r
    sorted_results = sorted(
        dedup.values(),
        key=lambda x: (int(x.n_simulations), float(x.edge), -int(x.iteration)),
        reverse=True,
    )[:400]

    edge_results = []
    mechanism_ceilings: dict[str, dict] = {}
    param_optima: dict[str, dict] = {}

    for r in sorted_results:
        mechanisms = infer_mechanisms(r.strategy_name)
        params = infer_parameters(r.strategy_name)
        edge_results.append({
            "timestamp": r.timestamp,
            "strategy": r.strategy_name,
            "edge": float(r.edge),
            "mechanisms": mechanisms,
            "parameters": params,
            "iteration": int(r.iteration),
            "n_simulations": int(r.n_simulations),
            "strategy_file": r.strategy_file,
        })

        for mech in mechanisms:
            ceiling = mechanism_ceilings.setdefault(mech, {
                "ceiling": float(r.edge),
                "ceiling_strategy": r.strategy_name,
                "appearances": 0,
            })
            ceiling["appearances"] += 1
            if float(r.edge) > float(ceiling["ceiling"]):
                ceiling["ceiling"] = float(r.edge)
                ceiling["ceiling_strategy"] = r.strategy_name

        for param, value in params.items():
            bucket = param_optima.setdefault(param, {
                "best_value": value,
                "best_edge": float(r.edge),
                "all_tested": [],
            })
            bucket["all_tested"].append({str(value): float(r.edge)})
            if float(r.edge) > float(bucket["best_edge"]):
                bucket["best_edge"] = float(r.edge)
                bucket["best_value"] = value

    failed_approaches = build_failed_approaches(sorted_results, champion_edge)
    insights = [{
        "timestamp": now,
        "category": "canonical_best_1000",
        "insight": f"Champion remains {champion_name} at {champion_edge:.2f} edge (1000 sims).",
        "evidence": ".knowledge_context.json canonical ranking",
        "confidence": 1.0,
    }]
    for lesson in lessons[:8]:
        insights.append({
            "timestamp": now,
            "category": "session_lesson",
            "insight": lesson,
            "evidence": "codex reasoning trace harvest",
            "confidence": 0.6,
        })

    data = {
        "version": int(existing.get("version", 1) or 1),
        "created": existing.get("created", now),
        "edge_results": edge_results,
        "parameter_optima": param_optima,
        "mechanism_ceilings": mechanism_ceilings,
        "failed_approaches": failed_approaches,
        "insights": insights,
        "regime_weaknesses": existing.get("regime_weaknesses", []),
        "canonical_best_1000": {
            "strategy": champion_name,
            "edge": champion_edge,
            "harvested_at": knowledge_context.get("harvested_at"),
        },
        "updated": now,
    }

    if dry_run:
        print(
            f"[DRY RUN] Would rewrite knowledge_store.json: "
            f"{len(edge_results)} edge_results, {len(failed_approaches)} failed_approaches"
        )
        return

    tmp_path = store_path.with_suffix(".json.tmp")
    tmp_path.write_text(json.dumps(data, indent=2))
    tmp_path.rename(store_path)
    print(
        f"Synced knowledge_store.json ({len(edge_results)} edge_results, "
        f"{len(failed_approaches)} failed approaches)"
    )


def sync_opportunity_priors(
    state_dir: Path,
    failed_approaches: list[dict],
    max_iteration: int,
    dry_run: bool = False,
) -> None:
    """Project harvested family failures into opportunity priors/cooldowns."""
    priors_path = state_dir / ".opportunity_priors.json"
    priors = {}
    if priors_path.exists():
        try:
            priors = json.loads(priors_path.read_text())
        except Exception:
            priors = {}
    if not isinstance(priors, dict):
        priors = {}

    # Map family failures to the exploration family we should cool down.
    severe_mode3_failure = any(
        str(x.get("approach")) in {"heavy_3_state_regime_machine", "light_3_state_regime_machine"}
        for x in failed_approaches
    )
    if not severe_mode3_failure:
        return

    key = "regime_state_transition_search"
    bucket = priors.setdefault(
        key,
        {
            "successes": 0,
            "failures": 0,
            "neutral": 0,
            "severe_failures": 0,
            "cooldown_until_iteration": 0,
            "cooldown_reason": None,
        },
    )
    bucket["severe_failures"] = max(int(bucket.get("severe_failures", 0) or 0), 1)
    bucket["failures"] = max(int(bucket.get("failures", 0) or 0), 1)
    cooldown_until = int(max_iteration) + 4
    bucket["cooldown_until_iteration"] = max(
        int(bucket.get("cooldown_until_iteration", 0) or 0),
        cooldown_until,
    )
    bucket["cooldown_reason"] = (
        "harvested family failure: heavy/light 3-state regime machine underperformed champion by >0.8"
    )
    bucket["status"] = "FAILED"
    bucket["failed_at_iteration"] = int(max_iteration)

    if dry_run:
        print(
            f"[DRY RUN] Would update .opportunity_priors.json: "
            f"{key}.cooldown_until_iteration={bucket['cooldown_until_iteration']}"
        )
        return

    tmp_path = priors_path.with_suffix(".json.tmp")
    tmp_path.write_text(json.dumps(priors, indent=2))
    tmp_path.rename(priors_path)
    print(
        f"Updated .opportunity_priors.json cooldown: {key} until iteration "
        f"{bucket['cooldown_until_iteration']}"
    )


def update_state_files(
    state_dir: Path,
    results: list[HarvestedResult],
    knowledge_context: dict,
    lessons: Optional[list[str]] = None,
    dry_run: bool = False
) -> None:
    """Update state files with harvested data."""

    # Update .best_edge.txt from canonical 1000-sim best only (sync exact value).
    best_edge_path = state_dir / '.best_edge.txt'
    current_best = 0.0
    if best_edge_path.exists():
        try:
            current_best = float(best_edge_path.read_text().strip())
        except ValueError:
            pass

    canonical_best = float(knowledge_context.get('true_best_edge_1000', knowledge_context.get('true_best_edge', 0.0)))
    has_1000_results = bool(knowledge_context.get('has_1000_results', False))
    if has_1000_results:
        if abs(canonical_best - current_best) > 1e-9:
            if dry_run:
                print(f"[DRY RUN] Would sync .best_edge.txt to canonical 1000-sim value: {current_best} -> {canonical_best}")
            else:
                best_edge_path.write_text(f"{canonical_best:.2f}\n")
                print(f"Synced .best_edge.txt to canonical 1000-sim value: {current_best} -> {canonical_best}")
    else:
        print("No >=1000-sim results harvested; leaving .best_edge.txt unchanged")

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
            key = (
                entry.get('iteration'),
                entry.get('strategy_name'),
                entry.get('final_edge'),
                entry.get('n_simulations'),
            )
            existing_keys.add(key)

    # Add new results
    new_entries = []
    for r in results:
        key = (r.iteration, r.strategy_name, r.edge, r.n_simulations)
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

    # Keep prompt-level persistent knowledge store synchronized to canonical data.
    sync_knowledge_store(
        state_dir,
        results,
        knowledge_context,
        lessons or [],
        dry_run=dry_run,
    )
    failed_approaches = build_failed_approaches(
        results,
        float(knowledge_context.get("true_best_edge_1000", 0.0) or 0.0),
    )
    max_iteration = max((int(r.iteration) for r in results), default=0)
    sync_opportunity_priors(
        state_dir,
        failed_approaches,
        max_iteration=max_iteration,
        dry_run=dry_run,
    )


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

    print(
        f"\nTrue best edge (1000 sims): {knowledge_context['true_best_edge_1000']:.2f} "
        f"({knowledge_context['true_best_strategy_1000']})"
    )
    print(
        f"Best edge (any sims): {knowledge_context['true_best_edge_any']:.2f} "
        f"({knowledge_context['true_best_strategy_any']})"
    )

    if knowledge_context['regressions']:
        print("\nRegressions detected:")
        for reg in knowledge_context['regressions']:
            print(f"  {reg['from']} ({reg['from_edge']:.2f}) -> {reg['to']} ({reg['to_edge']:.2f})")

    if lessons:
        print("\nLessons learned:")
        for lesson in lessons[:5]:
            print(f"  - {lesson[:80]}...")

    # Update state files
    update_state_files(
        state_dir,
        results,
        knowledge_context,
        lessons=lessons,
        dry_run=args.dry_run,
    )


if __name__ == '__main__':
    main()
