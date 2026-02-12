#!/usr/bin/env python3
"""Manually promote a new champion strategy with proper archiving and atomic writes."""

import re
import sys
from datetime import datetime, timezone
from pathlib import Path

# Add scripts directory to path
REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from simplified_loop_domains.history import archive_champion
from simplified_loop_domains.runner import write_rollback_spine
from simplified_loop_domains.shared import atomic_write_text


def promote_new_champion(
    state_dir: Path,
    new_strategy_path: Path,
    new_edge: float,
    reason: str = "manual_promotion_iter6_reconstructed",
):
    """Promote a new champion strategy with full archiving and safety."""

    print(f"Promoting new champion from: {new_strategy_path}")
    print(f"Target edge: {new_edge:.2f} bps")

    # 1. Read new strategy code
    new_code = new_strategy_path.read_text()

    # Extract name from new strategy
    match = re.search(r'return\s+"([^"]+)";', new_code)
    new_name = match.group(1) if match else "unknown"
    print(f"New champion name: {new_name}")

    # 2. Load current champion for archiving
    best_strategy_path = state_dir / ".best_strategy.sol"
    best_edge_path = state_dir / ".best_edge.txt"

    if best_strategy_path.exists():
        old_code = best_strategy_path.read_text()
        old_edge_str = best_edge_path.read_text().strip()
        old_edge = float(old_edge_str)

        # Extract old name
        match = re.search(r'return\s+"([^"]+)";', old_code)
        old_name = match.group(1) if match else "unknown"

        print(f"\nArchiving current champion:")
        print(f"  Name: {old_name}")
        print(f"  Edge: {old_edge:.2f} bps")

        # 3. Archive current champion to history
        try:
            archive_champion(
                state_dir=state_dir,
                champion_code=old_code,
                champion_name=old_name,
                champion_edge=old_edge,
                promoted_at=datetime.now(timezone.utc).isoformat(),
                iteration=None,  # Manual promotion
                mechanism_name="manual_promotion",
                delta=new_edge - old_edge,
                previous_champion_name=old_name,
                previous_champion_edge=old_edge,
                evaluation_summary={
                    "source": "manual",
                    "reason": reason,
                    "reconstructed_from": "iteration_6_timeout",
                },
                candidate_path=str(new_strategy_path),
            )
            print("✓ Current champion archived to history")
        except Exception as e:
            print(f"⚠ Warning: Could not archive to history: {e}")
            print("  (This is non-fatal; continuing with promotion)")
    else:
        old_edge = 0.0

    # 4. Write new champion files (atomic)
    print(f"\nInstalling new champion:")
    atomic_write_text(best_strategy_path, new_code)
    print(f"✓ Wrote {best_strategy_path}")

    atomic_write_text(best_edge_path, f"{new_edge:.2f}\n")
    print(f"✓ Wrote {best_edge_path}")

    # 5. Update rollback spine
    print(f"\nUpdating rollback spine:")
    write_rollback_spine(
        state_dir=state_dir,
        code=new_code,
        edge=new_edge,
        source="manual_promotion",
        reason=reason,
        name=new_name,
    )
    print(f"✓ Updated rollback spine")

    # 6. Summary
    print(f"\n{'='*60}")
    print(f"✓ Champion promotion complete!")
    print(f"  New champion: {new_name}")
    print(f"  New edge: {new_edge:.2f} bps")
    if best_strategy_path.exists() and old_edge > 0:
        print(f"  Improvement: +{new_edge - old_edge:.2f} bps")
    print(f"{'='*60}")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Manually promote a new champion strategy")
    parser.add_argument("--state-dir", type=Path, required=True, help="State directory")
    parser.add_argument("--strategy", type=Path, required=True, help="New strategy .sol file")
    parser.add_argument("--edge", type=float, required=True, help="New edge value")
    parser.add_argument("--reason", default="manual_promotion", help="Reason for promotion")

    args = parser.parse_args()

    promote_new_champion(
        state_dir=args.state_dir,
        new_strategy_path=args.strategy,
        new_edge=args.edge,
        reason=args.reason,
    )
