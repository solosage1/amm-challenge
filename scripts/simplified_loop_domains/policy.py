from __future__ import annotations

import hashlib
import json
import re
from typing import Any, Dict, List, Optional, Sequence


def _safe_probability(value: Any) -> Optional[float]:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    if parsed < 0.0:
        return 0.0
    if parsed > 1.0:
        return 1.0
    return parsed


def extract_iteration_policy_metadata(source: str) -> Optional[Dict[str, Any]]:
    match = re.search(r"//\s*ITERATION_POLICY\s*(\{.*\})", source)
    if not match:
        return None
    try:
        payload = json.loads(match.group(1))
    except json.JSONDecodeError:
        return None
    if not isinstance(payload, dict):
        return None
    return payload


def apply_iteration_policy_decision(
    mechanism_stats: Dict[str, Any],
    policy_metadata: Optional[Dict[str, Any]],
    iteration: int,
    cooldown_span: int,
    min_confidence: float,
) -> None:
    if not isinstance(policy_metadata, dict):
        return

    decision = str(policy_metadata.get("decision", "")).strip() or None
    confidence = _safe_probability(policy_metadata.get("confidence"))
    ceiling_probability = _safe_probability(policy_metadata.get("ceiling_probability"))
    reason = policy_metadata.get("reason")
    next_mechanism = policy_metadata.get("next_mechanism")

    mechanism_stats["last_policy_decision"] = decision
    mechanism_stats["last_policy_confidence"] = confidence
    mechanism_stats["last_policy_ceiling_probability"] = ceiling_probability
    mechanism_stats["last_policy_reason"] = reason if isinstance(reason, str) else None
    mechanism_stats["last_policy_next_mechanism"] = (
        next_mechanism if isinstance(next_mechanism, str) and next_mechanism else None
    )

    if decision in {"pivot", "ceiling_reached"} and confidence is not None and confidence >= float(min_confidence):
        current = int(mechanism_stats.get("cooldown_until_iter", 0) or 0)
        mechanism_stats["cooldown_until_iter"] = max(current, int(iteration) + max(0, int(cooldown_span)))


def format_iteration_policy_hints(*mechanism_infos: Dict[str, Any]) -> str:
    hints: List[str] = []
    for info in mechanism_infos:
        if not isinstance(info, dict):
            continue
        policy_cfg = info.get("iteration_policy")
        if not isinstance(policy_cfg, dict):
            continue
        ceiling = policy_cfg.get("ceiling_threshold")
        if ceiling is not None:
            hints.append(f"- Ceiling threshold hint: {ceiling}")
        cooldown = policy_cfg.get("cooldown_span")
        if cooldown is not None:
            hints.append(f"- Cooldown span hint: {cooldown}")
        note = policy_cfg.get("note")
        if isinstance(note, str) and note.strip():
            hints.append(f"- {note.strip()}")
    return "\n".join(hints) if hints else "- (none)"


