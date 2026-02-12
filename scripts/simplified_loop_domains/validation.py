from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple


POLICY_EVOLUTION_LOOKBACK = 25
POLICY_EVOLUTION_MAX_NEW_MECHANISMS = 3
POLICY_EVOLUTION_MAX_SPAN_RATIO = 0.85
POLICY_EVOLUTION_MAX_SPAN_LINES = 260


def parse_line_ranges(code_location: str) -> List[Tuple[int, int]]:
    spans: List[Tuple[int, int]] = []
    for start, end in re.findall(r"(\d+)\s*-\s*(\d+)", code_location):
        s = int(start)
        e = int(end)
        if s > e:
            s, e = e, s
        spans.append((s, e))
    return spans


def merge_spans(spans: Sequence[Tuple[int, int]]) -> List[Tuple[int, int]]:
    if not spans:
        return []
    ordered = sorted((min(a, b), max(a, b)) for a, b in spans)
    merged: List[Tuple[int, int]] = [ordered[0]]
    for start, end in ordered[1:]:
        prev_start, prev_end = merged[-1]
        if start <= prev_end + 1:
            merged[-1] = (prev_start, max(prev_end, end))
        else:
            merged.append((start, end))
    return merged


def anchor_match(line: str, pattern: str) -> bool:
    if pattern.startswith("re:"):
        try:
            return re.search(pattern[3:], line) is not None
        except re.error:
            return False
    return pattern in line


def find_anchor_line(
    lines: Sequence[str],
    pattern: str,
    start_index: int = 0,
    occurrence: int = 1,
) -> Optional[int]:
    if not pattern:
        return None
    target_occurrence = max(1, int(occurrence))
    seen = 0
    for idx in range(max(0, start_index), len(lines)):
        if anchor_match(lines[idx], pattern):
            seen += 1
            if seen >= target_occurrence:
                return idx
    return None


def parse_anchor_spans(source: str, anchors: Any) -> List[Tuple[int, int]]:
    if not isinstance(anchors, list):
        return []
    lines = source.splitlines()
    resolved: List[Tuple[int, int]] = []

    def _to_int(value: Any, default: int) -> int:
        try:
            return int(value)
        except (TypeError, ValueError):
            return default

    for anchor in anchors:
        if not isinstance(anchor, dict):
            continue
        start_pattern = str(anchor.get("start", "") or "")
        end_pattern = str(anchor.get("end", "") or start_pattern)
        if not start_pattern:
            continue
        start_occurrence = _to_int(anchor.get("occurrence", 1), 1)
        end_occurrence = _to_int(anchor.get("end_occurrence", 1), 1)
        before = _to_int(anchor.get("before", 0), 0)
        after = _to_int(anchor.get("after", 0), 0)

        start_idx = find_anchor_line(lines, start_pattern, 0, start_occurrence)
        if start_idx is None:
            continue
        end_idx = find_anchor_line(lines, end_pattern, start_idx, end_occurrence)
        if end_idx is None:
            continue

        lo = max(1, min(start_idx, end_idx) + 1 - before)
        hi = min(len(lines), max(start_idx, end_idx) + 1 + after)
        if lo <= hi:
            resolved.append((lo, hi))
    return merge_spans(resolved)


def resolve_mechanism_spans_with_status(
    source: str,
    mechanism_info: Dict[str, Any],
    allow_line_fallback: bool = True,
) -> Tuple[List[Tuple[int, int]], str]:
    raw_anchors = mechanism_info.get("anchors")
    has_anchors = isinstance(raw_anchors, list) and len(raw_anchors) > 0
    anchor_spans = parse_anchor_spans(source, raw_anchors)
    if anchor_spans:
        return anchor_spans, "anchors"
    if has_anchors and not allow_line_fallback:
        return [], "anchor_unresolved"
    line_spans = merge_spans(parse_line_ranges(str(mechanism_info.get("code_location", ""))))
    if line_spans:
        return line_spans, "line_ranges"
    if has_anchors:
        return [], "anchor_unresolved"
    return [], "unresolved"


def resolve_mechanism_spans(
    source: str,
    mechanism_info: Dict[str, Any],
    allow_line_fallback: bool = True,
) -> List[Tuple[int, int]]:
    spans, _ = resolve_mechanism_spans_with_status(
        source=source,
        mechanism_info=mechanism_info,
        allow_line_fallback=allow_line_fallback,
    )
    return spans


def code_region(source: str, spans: Sequence[Tuple[int, int]]) -> str:
    lines = source.splitlines()
    chunks: List[str] = []
    for start, end in spans:
        lo = max(1, start)
        hi = min(len(lines), end)
        if lo <= hi:
            chunks.append("\n".join(lines[lo - 1 : hi]))
    return "\n".join(chunks)


def normalize_region(text: str) -> str:
    return "".join(text.split())


def extract_regions_by_mechanism(
    source: str,
    definitions: Dict[str, Any],
) -> Dict[str, str]:
    output: Dict[str, str] = {}
    for mech, info in definitions.get("mechanisms", {}).items():
        spans = resolve_mechanism_spans(source, dict(info))
        output[mech] = code_region(source, spans)
    return output


def allowed_overlap_for_target(definitions: Dict[str, Any], target_mechanism: str) -> set[str]:
    mechanisms = definitions.get("mechanisms", {})
    if not isinstance(mechanisms, dict):
        return set()
    target_info = mechanisms.get(target_mechanism, {})
    if not isinstance(target_info, dict):
        return set()
    raw = target_info.get("allowed_overlap_with", [])
    if not isinstance(raw, list):
        return set()
    allowed: set[str] = set()
    for item in raw:
        if isinstance(item, str) and item:
            allowed.add(item)
    return allowed


def validate_candidate(
    original_code: str,
    candidate_code: str,
    target_mechanism: str,
    definitions: Dict[str, Any],
) -> Tuple[bool, str, List[str]]:
    warnings: List[str] = []
    mechanisms = definitions.get("mechanisms", {})
    if not isinstance(mechanisms, dict):
        return False, "definitions has no mechanisms", warnings

    regions_original: Dict[str, str] = {}
    regions_candidate: Dict[str, str] = {}
    candidate_span_status: Dict[str, str] = {}

    for mech, info in mechanisms.items():
        if not isinstance(info, dict):
            continue
        original_spans, _ = resolve_mechanism_spans_with_status(
            source=original_code,
            mechanism_info=info,
            allow_line_fallback=True,
        )
        candidate_spans, candidate_status = resolve_mechanism_spans_with_status(
            source=candidate_code,
            mechanism_info=info,
            allow_line_fallback=False,
        )
        regions_original[mech] = code_region(original_code, original_spans)
        regions_candidate[mech] = code_region(candidate_code, candidate_spans)
        candidate_span_status[mech] = candidate_status

    allowed_overlap = allowed_overlap_for_target(definitions, target_mechanism)

    if target_mechanism not in regions_original:
        return False, f"target mechanism not found: {target_mechanism}", warnings

    target_before = normalize_region(regions_original[target_mechanism])
    target_after = normalize_region(regions_candidate.get(target_mechanism, ""))
    target_modified = True
    if target_before and target_after:
        if target_before == target_after:
            target_modified = False
    else:
        if normalize_region(original_code) == normalize_region(candidate_code):
            target_modified = False
    if not target_modified:
        warnings.append(f"soft_check:target mechanism '{target_mechanism}' was not modified")

    drifted_mechanisms: List[str] = []
    for mech, status in candidate_span_status.items():
        if status == "anchor_unresolved" and mech != target_mechanism:
            drifted_mechanisms.append(mech)
    if drifted_mechanisms:
        warnings.append(f"anchor_drift:{','.join(drifted_mechanisms)}")

    for mech in regions_original:
        if mech == target_mechanism:
            continue
        if candidate_span_status.get(mech) == "anchor_unresolved":
            continue
        before = normalize_region(regions_original.get(mech, ""))
        after = normalize_region(regions_candidate.get(mech, ""))
        if not before or not after:
            continue
        if before != after:
            if mech in allowed_overlap:
                continue
            warnings.append(f"soft_check:non-target mechanism '{mech}' was modified")

    return True, "valid_with_warnings" if warnings else "valid", warnings


def span_line_count(spans: Sequence[Tuple[int, int]]) -> int:
    merged = merge_spans(spans)
    return sum(max(0, end - start + 1) for start, end in merged)

