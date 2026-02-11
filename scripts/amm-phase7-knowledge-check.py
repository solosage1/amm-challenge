#!/usr/bin/env python3
"""
Validate Phase 7 knowledge context canonical 1000-sim consistency.

Checks:
1. `true_best_edge_1000` matches max edge in `all_tested_strategies_1000` (within epsilon).
2. `true_best_strategy_1000` is one of the strategies tied for that max edge.
3. Backward alias `true_best_edge` matches `true_best_edge_1000` (within epsilon).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def fail(message: str) -> int:
    print(f"[knowledge-check] FAIL: {message}", file=sys.stderr)
    return 1


def parse_float(value, field: str) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        raise ValueError(f"{field} is not a float-compatible value: {value!r}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate canonical 1000-sim knowledge consistency")
    parser.add_argument("--state-dir", required=True, help="Path to phase7 state directory")
    parser.add_argument(
        "--epsilon",
        type=float,
        default=0.02,
        help="Float tolerance for comparisons (default: 0.02)",
    )
    args = parser.parse_args()

    state_dir = Path(args.state_dir)
    knowledge_path = state_dir / ".knowledge_context.json"
    if not knowledge_path.exists():
        return fail(f"Missing knowledge context: {knowledge_path}")

    try:
        knowledge = json.loads(knowledge_path.read_text())
    except Exception as exc:
        return fail(f"Unable to parse {knowledge_path}: {exc}")

    entries = knowledge.get("all_tested_strategies_1000")
    if not isinstance(entries, list):
        return fail("all_tested_strategies_1000 is missing or not a list")

    try:
        true_best_1000 = parse_float(knowledge.get("true_best_edge_1000"), "true_best_edge_1000")
    except ValueError as exc:
        return fail(str(exc))

    # Backward alias should remain synchronized for compatibility.
    alias_value = knowledge.get("true_best_edge")
    if alias_value is not None:
        try:
            alias_edge = parse_float(alias_value, "true_best_edge")
        except ValueError as exc:
            return fail(str(exc))
        if abs(alias_edge - true_best_1000) > args.epsilon:
            return fail(
                f"Alias mismatch: true_best_edge={alias_edge:.6f} "
                f"!= true_best_edge_1000={true_best_1000:.6f} (eps={args.epsilon})"
            )

    if not entries:
        if abs(true_best_1000) <= args.epsilon:
            print(
                "[knowledge-check] PASS: no 1000-sim entries present and "
                f"true_best_edge_1000={true_best_1000:.6f} within epsilon"
            )
            return 0
        return fail(
            "No all_tested_strategies_1000 entries, but "
            f"true_best_edge_1000={true_best_1000:.6f} is non-zero"
        )

    parsed_entries = []
    for i, row in enumerate(entries):
        if not isinstance(row, dict):
            return fail(f"Entry {i} in all_tested_strategies_1000 is not an object")
        if int(row.get("sims", 0) or 0) < 1000:
            return fail(f"Entry {i} has sims < 1000: {row.get('sims')!r}")
        try:
            edge = parse_float(row.get("edge"), f"all_tested_strategies_1000[{i}].edge")
        except ValueError as exc:
            return fail(str(exc))
        parsed_entries.append((edge, str(row.get("name", "Unknown"))))

    max_edge = max(edge for edge, _ in parsed_entries)
    if abs(max_edge - true_best_1000) > args.epsilon:
        return fail(
            f"Edge mismatch: max(all_tested_strategies_1000)={max_edge:.6f} "
            f"!= true_best_edge_1000={true_best_1000:.6f} (eps={args.epsilon})"
        )

    true_best_strategy = str(knowledge.get("true_best_strategy_1000", "Unknown"))
    top_names = sorted({name for edge, name in parsed_entries if abs(edge - max_edge) <= args.epsilon})
    if true_best_strategy not in top_names:
        return fail(
            "Strategy mismatch: true_best_strategy_1000="
            f"{true_best_strategy!r} not in top strategies at max edge {max_edge:.6f}: {top_names}"
        )

    print(
        "[knowledge-check] PASS: canonical 1000-sim fields consistent "
        f"(edge={true_best_1000:.6f}, strategy={true_best_strategy}, eps={args.epsilon})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
