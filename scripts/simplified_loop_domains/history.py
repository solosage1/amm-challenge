from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from .shared import atomic_write_json, atomic_write_text, load_json, parse_get_name, utc_now_iso


DEFAULT_CHAMPION_HISTORY_MAX = 10
CHAMPION_HISTORY_DIR = ".champion_history"
CHAMPION_HISTORY_MANIFEST = "manifest.json"


def load_champion(state_dir: Path) -> Tuple[str, float, str]:
    code = (state_dir / ".best_strategy.sol").read_text()
    edge = float((state_dir / ".best_edge.txt").read_text().strip())
    name = parse_get_name(code) or "unknown_champion"
    return code, edge, name


def load_champion_history_manifest(state_dir: Path) -> Dict[str, Any]:
    history_dir = state_dir / CHAMPION_HISTORY_DIR
    manifest_path = history_dir / CHAMPION_HISTORY_MANIFEST
    if manifest_path.exists():
        return load_json(manifest_path, {})
    return {
        "schema_version": "1.0",
        "max_history": DEFAULT_CHAMPION_HISTORY_MAX,
        "total_promotions": 0,
        "champions": [],
        "best_ever": None,
    }


def save_champion_history_manifest(state_dir: Path, manifest: Dict[str, Any]) -> None:
    history_dir = state_dir / CHAMPION_HISTORY_DIR
    history_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = history_dir / CHAMPION_HISTORY_MANIFEST
    atomic_write_json(manifest_path, manifest)


def next_champion_sequence(manifest: Dict[str, Any]) -> int:
    champions = manifest.get("champions", [])
    if not champions:
        return 1
    return max(c.get("sequence_number", 0) for c in champions) + 1


def rotate_champion_history(state_dir: Path, manifest: Dict[str, Any], max_history: int) -> None:
    history_dir = state_dir / CHAMPION_HISTORY_DIR
    champions = manifest.get("champions", [])
    best_ever_seq = manifest.get("best_ever", {}).get("sequence_number") if manifest.get("best_ever") else None

    while len(champions) > max_history:
        removed = False
        for idx, champion in enumerate(champions):
            if champion["sequence_number"] != best_ever_seq:
                dir_to_remove = history_dir / champion["directory"]
                if dir_to_remove.exists():
                    shutil.rmtree(dir_to_remove)
                champions.pop(idx)
                removed = True
                break
        if not removed:
            break

    manifest["champions"] = champions


def archive_champion(
    state_dir: Path,
    champion_code: str,
    champion_edge: float,
    champion_name: str,
    iteration: int,
    mechanism_name: str,
    delta: float,
    evaluation_summary: Optional[Dict[str, Any]] = None,
    candidate_path: Optional[str] = None,
    max_history: int = DEFAULT_CHAMPION_HISTORY_MAX,
) -> Dict[str, Any]:
    history_dir = state_dir / CHAMPION_HISTORY_DIR
    manifest = load_champion_history_manifest(state_dir)

    sequence = next_champion_sequence(manifest)
    champion_dir = history_dir / f"champion_{sequence:03d}"
    champion_dir.mkdir(parents=True, exist_ok=True)

    champions = manifest.get("champions", [])
    previous_name = champions[-1]["name"] if champions else None
    previous_edge = champions[-1]["edge"] if champions else None

    metadata: Dict[str, Any] = {
        "sequence_number": sequence,
        "name": champion_name,
        "edge": champion_edge,
        "promoted_at": utc_now_iso(),
        "iteration": iteration,
        "mechanism_that_promoted": mechanism_name,
        "delta_over_previous": delta,
        "previous_champion_name": previous_name,
        "previous_champion_edge": previous_edge,
    }
    if evaluation_summary:
        metadata["evaluation_summary"] = evaluation_summary
    if candidate_path:
        metadata["candidate_path"] = candidate_path

    atomic_write_text(champion_dir / "strategy.sol", champion_code)
    atomic_write_json(champion_dir / "metadata.json", metadata)

    manifest_entry = {
        "sequence_number": sequence,
        "name": champion_name,
        "edge": champion_edge,
        "promoted_at": metadata["promoted_at"],
        "directory": f"champion_{sequence:03d}",
    }
    manifest["champions"].append(manifest_entry)
    manifest["total_promotions"] = manifest.get("total_promotions", 0) + 1

    best_ever = manifest.get("best_ever")
    if best_ever is None or champion_edge > best_ever.get("edge", float("-inf")):
        manifest["best_ever"] = manifest_entry.copy()

    if max_history > 0:
        rotate_champion_history(state_dir, manifest, max_history)

    manifest["max_history"] = max_history
    save_champion_history_manifest(state_dir, manifest)
    return metadata


def get_champion_by_sequence(state_dir: Path, sequence: int) -> Optional[Tuple[str, Dict[str, Any]]]:
    history_dir = state_dir / CHAMPION_HISTORY_DIR
    manifest = load_champion_history_manifest(state_dir)

    for champion in manifest.get("champions", []):
        if champion["sequence_number"] == sequence:
            champion_dir = history_dir / champion["directory"]
            code_path = champion_dir / "strategy.sol"
            meta_path = champion_dir / "metadata.json"
            if code_path.exists() and meta_path.exists():
                code = code_path.read_text()
                metadata = load_json(meta_path, {})
                return code, metadata
    return None


def get_nth_previous_champion(state_dir: Path, n: int) -> Optional[Tuple[str, Dict[str, Any]]]:
    manifest = load_champion_history_manifest(state_dir)
    champions = manifest.get("champions", [])
    if n < 1 or n > len(champions):
        return None
    target = champions[-n]
    return get_champion_by_sequence(state_dir, target["sequence_number"])


def list_champion_history(state_dir: Path) -> List[Dict[str, Any]]:
    manifest = load_champion_history_manifest(state_dir)
    champions = manifest.get("champions", [])
    return list(reversed(champions))


def champion_history_list(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    manifest = load_champion_history_manifest(state_dir)
    champions = manifest.get("champions", [])
    best_ever = manifest.get("best_ever")

    if getattr(args, "json", False):
        print(json.dumps({"champions": champions, "best_ever": best_ever}, indent=2))
        return 0

    print(f"Champion History ({len(champions)} entries, max={manifest.get('max_history', 'unlimited')}):")
    for champion in reversed(champions):
        marker = " [BEST-EVER]" if best_ever and best_ever.get("sequence_number") == champion["sequence_number"] else ""
        print(f"  #{champion['sequence_number']:03d}: {champion['name']} @ {champion['edge']:.2f} bps ({champion['promoted_at']}){marker}")
    return 0


def champion_history_show(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    result = get_champion_by_sequence(state_dir, args.sequence)
    if result is None:
        print(json.dumps({"error": f"Champion sequence {args.sequence} not found"}, indent=2))
        return 1
    _, metadata = result
    print(json.dumps(metadata, indent=2))
    return 0


def champion_history_revert(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    result = get_champion_by_sequence(state_dir, args.sequence)
    if result is None:
        print(json.dumps({"error": f"Champion sequence {args.sequence} not found"}, indent=2))
        return 1

    code, metadata = result
    current_code, current_edge, current_name = load_champion(state_dir)
    max_history = int(getattr(args, "champion_history_max", DEFAULT_CHAMPION_HISTORY_MAX))
    archive_champion(
        state_dir=state_dir,
        champion_code=current_code,
        champion_edge=current_edge,
        champion_name=current_name,
        iteration=-1,
        mechanism_name="manual_revert",
        delta=metadata["edge"] - current_edge,
        max_history=max_history,
    )

    atomic_write_text(state_dir / ".best_strategy.sol", code)
    atomic_write_text(state_dir / ".best_edge.txt", f"{metadata['edge']:.2f}\n")

    archive_dir = state_dir / ".archive"
    archive_dir.mkdir(parents=True, exist_ok=True)
    with (archive_dir / "rollback_log.txt").open("a") as handle:
        handle.write(f"{utc_now_iso()} history_revert sequence={args.sequence} reason={args.reason}\n")

    print(json.dumps({
        "status": "reverted",
        "to_sequence": args.sequence,
        "to_name": metadata["name"],
        "to_edge": metadata["edge"],
        "from_name": current_name,
        "from_edge": current_edge,
        "reason": args.reason,
    }, indent=2))
    return 0

