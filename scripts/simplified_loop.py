#!/usr/bin/env python3
"""
Simplified Phase 7 loop: champion-centric mechanism modification.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import re
import shlex
import shutil
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


SCHEMA_VERSION = "2.0"
DEFAULT_EXPLORATION_C = 0.5
DEFAULT_IMPROVEMENT_THRESHOLD = 0.02
DEFAULT_MAX_RETRIES_ON_INVALID = 2
DEFAULT_WILDCARD_FREQUENCY = 10
DEFAULT_ROLLBACK_CONSECUTIVE_INVALID = 3
DEFAULT_ROLLBACK_SEVERE_REGRESSION = -0.5
DEFAULT_ROLLBACK_CUMULATIVE_LOSS = -1.0
DEFAULT_ROLLBACK_WINDOW = 10
DEFAULT_LLM_COMMAND = os.environ.get("CODEX_CLI", "codex")
DEFAULT_LLM_MODEL = os.environ.get("CODEX_MODEL", "")
DEFAULT_LLM_TIMEOUT_MINUTES = env_float("CODEX_TIMEOUT_MINUTES", 40.0)
DEFAULT_LLM_MAX_OUTPUT_TOKENS = env_int("CODEX_MAX_OUTPUT_TOKENS", 8000)
DEFAULT_POLICY_EVOLUTION_FREQUENCY = 5
POLICY_EVOLUTION_LOOKBACK = 25
POLICY_EVOLUTION_MAX_NEW_MECHANISMS = 3
POLICY_EVOLUTION_MAX_SPAN_RATIO = 0.85
POLICY_EVOLUTION_MAX_SPAN_LINES = 260


PROMPT_TEMPLATE = """
You are improving an AMM fee strategy by modifying ONE specific mechanism.

## CURRENT CHAMPION CODE
```solidity
{champion_code}
```

## YOUR TASK
Modify the **{mechanism_name}** mechanism to improve expected edge.

### Current Implementation
{current_implementation}

### Code Location
{code_location}

### Current Parameters
{parameters_formatted}

### Suggested Directions to Explore
{modification_directions}

## CONSTRAINTS
1. ONLY modify code related to {mechanism_name}
2. Keep all other mechanisms unchanged:
{other_mechanisms}
3. Output a complete, compilable Solidity contract
4. Keep contract declaration as `contract Strategy`
5. Set getName() return value to "{variant_name}"
6. Keep interface compatibility (afterInitialize, afterSwap, getName)

## OUTPUT FORMAT
Return ONLY the complete Solidity code. No explanations before or after.
""".strip()


WILDCARD_PROMPT_TEMPLATE = """
You are improving an AMM fee strategy with a broad structural change.

## CURRENT CHAMPION CODE
```solidity
{champion_code}
```

## YOUR TASK
Propose a complete contract revision that can modify any mechanism if it improves expected edge.

## CONSTRAINTS
1. Output a complete, compilable Solidity contract
2. Keep contract declaration as `contract Strategy`
3. Set getName() return value to "{variant_name}"
4. Keep interface compatibility (afterInitialize, afterSwap, getName)

## OUTPUT FORMAT
Return ONLY the complete Solidity code. No explanations before or after.
""".strip()


POLICY_EVOLUTION_PROMPT_TEMPLATE = """
You are updating mechanism boundary policy for a single-mechanism AMM evolution loop.

## CURRENT CHAMPION CODE
```solidity
{champion_code}
```

## CURRENT DEFINITIONS JSON
```json
{definitions_json}
```

## RECENT LOOP SIGNALS
{signals_json}

## RECENT INVALID EXAMPLES
{invalid_examples}

## YOUR TASK
Return an improved full definitions JSON that keeps the system safe but less brittle to realistic agent edits.

## REQUIREMENTS
1. Keep all existing mechanism keys (you may add up to {max_new_mechanisms} new mechanisms).
2. Each mechanism must keep anchor-based `anchors` with resolvable start/end strings.
3. `allowed_overlap_with` may only contain valid mechanism names.
4. Preserve one-mechanism-at-a-time intent while allowing natural helper extraction and conceptual overlaps.
5. Return strict JSON only (no markdown, no prose).
""".strip()


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return default


def atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    os.close(fd)
    tmp = Path(tmp_path)
    tmp.write_text(content)
    tmp.replace(path)


def atomic_write_json(path: Path, payload: Any) -> None:
    atomic_write_text(path, json.dumps(payload, indent=2))


def append_jsonl(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        handle.write(json.dumps(payload) + "\n")


def parse_get_name(source: str) -> Optional[str]:
    match = re.search(r'return\s+"([^"]+)";', source)
    return match.group(1) if match else None


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


def format_parameters(params: Dict[str, Any]) -> str:
    rows = []
    for key, value in params.items():
        rows.append(f"- {key}: {value}")
    return "\n".join(rows) if rows else "- (none)"


def format_directions(directions: Sequence[str]) -> str:
    rows = []
    for item in directions:
        rows.append(f"- {item}")
    return "\n".join(rows) if rows else "- (none)"


def select_mechanism(
    mechanisms: Dict[str, Dict[str, Any]],
    exploration_c: float,
    rng: random.Random,
) -> str:
    total_tries = sum(int(m.get("tries", 0) or 0) for m in mechanisms.values())
    if total_tries == 0:
        return rng.choice(list(mechanisms.keys()))

    untried = [name for name, rec in mechanisms.items() if int(rec.get("tries", 0) or 0) == 0]
    if untried:
        return rng.choice(untried)

    best_name = ""
    best_score = float("-inf")
    for name, rec in mechanisms.items():
        tries = int(rec.get("tries", 0) or 0)
        if tries <= 0:
            continue
        total_uplift = float(rec.get("total_uplift", 0.0) or 0.0)
        exploit = total_uplift / tries
        explore = exploration_c * math.sqrt(math.log(max(2, total_tries)) / tries)
        score = exploit + explore
        if score > best_score:
            best_score = score
            best_name = name
    if not best_name:
        return rng.choice(list(mechanisms.keys()))
    return best_name


def should_run_wildcard(iteration: int, stats: Dict[str, Any], wildcard_frequency: int) -> bool:
    if wildcard_frequency > 0 and iteration % wildcard_frequency == 0:
        return True
    mechanisms = stats.get("mechanisms", {})
    if not mechanisms:
        return False
    all_tried = all(int(v.get("tries", 0) or 0) >= 3 for v in mechanisms.values())
    none_successful = all(int(v.get("successes", 0) or 0) == 0 for v in mechanisms.values())
    return bool(all_tried and none_successful)


def build_prompt(
    champion_code: str,
    mechanism_name: str,
    mechanism_info: Dict[str, Any],
    other_mechanisms: Sequence[str],
    variant_name: str,
) -> str:
    return PROMPT_TEMPLATE.format(
        champion_code=champion_code,
        mechanism_name=mechanism_name,
        current_implementation=str(mechanism_info.get("current_implementation", "")),
        code_location=str(mechanism_info.get("code_location", "")),
        parameters_formatted=format_parameters(dict(mechanism_info.get("parameters", {}))),
        modification_directions=format_directions(list(mechanism_info.get("modification_directions", []))),
        other_mechanisms=", ".join(other_mechanisms),
        variant_name=variant_name,
    )


def build_wildcard_prompt(champion_code: str, variant_name: str) -> str:
    return WILDCARD_PROMPT_TEMPLATE.format(
        champion_code=champion_code,
        variant_name=variant_name,
    )


def definitions_fingerprint(definitions: Dict[str, Any]) -> str:
    payload = json.dumps(definitions, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()


def build_policy_evolution_prompt(
    champion_code: str,
    definitions: Dict[str, Any],
    signals: Dict[str, Any],
    invalid_examples: Sequence[Dict[str, Any]],
) -> str:
    examples = json.dumps(list(invalid_examples), indent=2)
    if not invalid_examples:
        examples = "[]"
    return POLICY_EVOLUTION_PROMPT_TEMPLATE.format(
        champion_code=champion_code,
        definitions_json=json.dumps(definitions, indent=2),
        signals_json=json.dumps(signals, indent=2),
        invalid_examples=examples,
        max_new_mechanisms=POLICY_EVOLUTION_MAX_NEW_MECHANISMS,
    )


def collect_iteration_failure_signals(
    log_entries: Sequence[Dict[str, Any]],
    lookback: int = POLICY_EVOLUTION_LOOKBACK,
) -> Dict[str, Any]:
    window = list(log_entries[-max(1, int(lookback)) :])
    status_counts: Dict[str, int] = {}
    invalid_reason_counts: Dict[str, int] = {}
    invalid_by_mechanism: Dict[str, int] = {}
    for entry in window:
        status = str(entry.get("status", "unknown"))
        status_counts[status] = status_counts.get(status, 0) + 1
        if status in {"invalid", "compile_failed", "llm_failed"}:
            mechanism = str(entry.get("mechanism", "unknown"))
            invalid_by_mechanism[mechanism] = invalid_by_mechanism.get(mechanism, 0) + 1
            reason = str(entry.get("reason", status))
            invalid_reason_counts[reason] = invalid_reason_counts.get(reason, 0) + 1
    return {
        "lookback_entries": len(window),
        "status_counts": status_counts,
        "invalid_by_mechanism": invalid_by_mechanism,
        "invalid_reason_counts": invalid_reason_counts,
    }


def pick_recent_invalid_examples(
    log_entries: Sequence[Dict[str, Any]],
    limit: int = 6,
) -> List[Dict[str, Any]]:
    picks: List[Dict[str, Any]] = []
    for entry in reversed(log_entries):
        if str(entry.get("status")) not in {"invalid", "compile_failed", "llm_failed"}:
            continue
        sample = {
            "iter": entry.get("iter"),
            "mechanism": entry.get("mechanism"),
            "status": entry.get("status"),
            "reason": entry.get("reason"),
            "candidate_path": entry.get("candidate_path"),
        }
        picks.append(sample)
        if len(picks) >= limit:
            break
    picks.reverse()
    return picks


def generate_mock_candidate(
    champion_code: str,
    mechanism_name: str,
    mechanism_info: Dict[str, Any],
    iteration: int,
) -> str:
    spans = resolve_mechanism_spans(champion_code, mechanism_info)
    if not spans:
        return champion_code + f"\n// mock mutation iter={iteration} mechanism={mechanism_name}\n"

    first_line = spans[0][0]
    lines = champion_code.splitlines()
    idx = max(0, min(len(lines), first_line - 1))
    marker = f"// mock mutation iter={iteration} mechanism={mechanism_name}"
    if lines:
        lines[idx] = f"{lines[idx]} {marker}".rstrip()
    else:
        lines = [marker]
    mutated = "\n".join(lines) + "\n"
    mutated = re.sub(
        r'return\s+"([^"]+)";',
        f'return "{mechanism_name}_mod_v{iteration}";',
        mutated,
        count=1,
    )
    return mutated


def extract_solidity_from_response(response_text: str) -> Optional[str]:
    text = response_text.strip()
    if not text:
        return None

    revised = re.search(
        r"---REVISED_IMPLEMENTATION---\s*```(?:solidity|sol)?\s*(.*?)\s*```",
        text,
        re.DOTALL | re.IGNORECASE,
    )
    if revised:
        payload = revised.group(1).strip()
        if payload:
            return payload + "\n"

    fenced_blocks = re.findall(
        r"```(?:solidity|sol)?\s*(.*?)\s*```",
        text,
        re.DOTALL | re.IGNORECASE,
    )
    if fenced_blocks:
        def score(block: str) -> Tuple[int, int]:
            points = 0
            if "contract Strategy" in block:
                points += 4
            if "pragma solidity" in block:
                points += 2
            if "afterSwap" in block:
                points += 1
            return points, len(block)

        candidate = max(fenced_blocks, key=score).strip()
        if candidate:
            return candidate + "\n"

    pragma_idx = text.find("pragma solidity")
    contract_idx = text.find("contract Strategy")
    if pragma_idx >= 0:
        candidate = text[pragma_idx:].strip()
        return candidate + "\n" if candidate else None
    if contract_idx >= 0:
        candidate = text[contract_idx:].strip()
        return candidate + "\n" if candidate else None
    return None


def generate_candidate_with_llm(
    prompt_path: Path,
    artifact_prefix: Path,
    llm_command: str,
    llm_model: str,
    llm_timeout_minutes: float,
    llm_max_output_tokens: int,
    llm_disable_shell_tool: bool,
    attempt: int = 0,
) -> Tuple[Optional[str], Optional[str], Dict[str, str]]:
    response_text, error, artifacts = run_llm_exec(
        prompt_path=prompt_path,
        artifact_prefix=artifact_prefix,
        llm_command=llm_command,
        llm_model=llm_model,
        llm_timeout_minutes=llm_timeout_minutes,
        llm_max_output_tokens=llm_max_output_tokens,
        llm_disable_shell_tool=llm_disable_shell_tool,
        attempt=attempt,
    )
    if response_text is None:
        return None, error or "llm_failed", artifacts
    candidate = extract_solidity_from_response(response_text)
    if not candidate:
        return None, "llm_extract_failed", artifacts
    return candidate, None, artifacts


def extract_json_payload_from_response(response_text: str) -> Optional[Dict[str, Any]]:
    text = response_text.strip()
    if not text:
        return None

    fenced_blocks = re.findall(r"```(?:json)?\s*(.*?)\s*```", text, re.DOTALL | re.IGNORECASE)
    candidates = fenced_blocks + [text]
    for block in candidates:
        snippet = block.strip()
        if not snippet:
            continue
        try:
            payload = json.loads(snippet)
            if isinstance(payload, dict):
                return payload
        except json.JSONDecodeError:
            start = snippet.find("{")
            end = snippet.rfind("}")
            if start >= 0 and end > start:
                fragment = snippet[start : end + 1]
                try:
                    payload = json.loads(fragment)
                    if isinstance(payload, dict):
                        return payload
                except json.JSONDecodeError:
                    continue
    return None


def run_llm_exec(
    prompt_path: Path,
    artifact_prefix: Path,
    llm_command: str,
    llm_model: str,
    llm_timeout_minutes: float,
    llm_max_output_tokens: int,
    llm_disable_shell_tool: bool,
    attempt: int = 0,
) -> Tuple[Optional[str], Optional[str], Dict[str, str]]:
    suffix = "" if attempt <= 0 else f"_retry{attempt}"
    stem = artifact_prefix.name
    codex_jsonl_path = artifact_prefix.with_name(f"{stem}{suffix}.codex.jsonl")
    codex_stderr_path = artifact_prefix.with_name(f"{stem}{suffix}.codex.stderr")
    codex_last_msg_path = artifact_prefix.with_name(f"{stem}{suffix}.codex.last_message.md")
    artifacts = {
        "codex_jsonl_path": str(codex_jsonl_path),
        "codex_stderr_path": str(codex_stderr_path),
        "codex_last_message_path": str(codex_last_msg_path),
    }

    parts = shlex.split(llm_command)
    if not parts:
        return None, "llm_command_empty", artifacts
    executable = parts[0]
    if shutil.which(executable) is None and not Path(executable).exists():
        return None, f"llm_command_not_found:{executable}", artifacts

    cmd = [
        *parts,
        "exec",
        "--json",
        "--config",
        f"max_output_tokens={int(llm_max_output_tokens)}",
        "--output-last-message",
        str(codex_last_msg_path),
    ]
    if llm_disable_shell_tool:
        cmd += ["--disable", "shell_tool"]
    if llm_model:
        cmd += ["--model", llm_model]
    cmd.append("-")

    timeout_seconds = max(60, int(float(llm_timeout_minutes) * 60))
    prompt_text = prompt_path.read_text()
    codex_jsonl_path.parent.mkdir(parents=True, exist_ok=True)
    if codex_last_msg_path.exists():
        codex_last_msg_path.unlink()

    try:
        with codex_jsonl_path.open("w") as stdout_handle, codex_stderr_path.open("w") as stderr_handle:
            proc = subprocess.run(
                cmd,
                input=prompt_text,
                stdout=stdout_handle,
                stderr=stderr_handle,
                text=True,
                timeout=timeout_seconds,
                check=False,
            )
    except subprocess.TimeoutExpired:
        return None, f"llm_timeout_after_minutes={llm_timeout_minutes}", artifacts
    except OSError as exc:
        return None, f"llm_exec_oserror:{exc}", artifacts

    if proc.returncode != 0:
        stderr_tail = ""
        if codex_stderr_path.exists():
            lines = codex_stderr_path.read_text(errors="ignore").strip().splitlines()
            if lines:
                stderr_tail = lines[-1][:400]
        reason = f"llm_exit_code={proc.returncode}"
        if stderr_tail:
            reason = f"{reason}:{stderr_tail}"
        return None, reason, artifacts

    if not codex_last_msg_path.exists():
        return None, "llm_missing_last_message", artifacts
    response_text = codex_last_msg_path.read_text()
    return response_text, None, artifacts


def generate_policy_candidate_with_llm(
    prompt_path: Path,
    artifact_prefix: Path,
    llm_command: str,
    llm_model: str,
    llm_timeout_minutes: float,
    llm_max_output_tokens: int,
    llm_disable_shell_tool: bool,
) -> Tuple[Optional[Dict[str, Any]], Optional[str], Dict[str, str]]:
    response_text, error, artifacts = run_llm_exec(
        prompt_path=prompt_path,
        artifact_prefix=artifact_prefix,
        llm_command=llm_command,
        llm_model=llm_model,
        llm_timeout_minutes=llm_timeout_minutes,
        llm_max_output_tokens=llm_max_output_tokens,
        llm_disable_shell_tool=llm_disable_shell_tool,
        attempt=0,
    )
    if response_text is None:
        return None, error or "llm_failed", artifacts
    payload = extract_json_payload_from_response(response_text)
    if payload is None:
        return None, "policy_extract_failed", artifacts
    return payload, None, artifacts


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
) -> Tuple[bool, str]:
    mechanisms = definitions.get("mechanisms", {})
    if not isinstance(mechanisms, dict):
        return False, "definitions has no mechanisms"

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
        return False, f"target mechanism not found: {target_mechanism}"

    target_before = normalize_region(regions_original[target_mechanism])
    target_after = normalize_region(regions_candidate.get(target_mechanism, ""))
    if target_before and target_after:
        if target_before == target_after:
            return False, f"target mechanism '{target_mechanism}' was not modified"
    else:
        # If candidate-side anchors drifted, use whole-contract identity as minimal guard.
        if normalize_region(original_code) == normalize_region(candidate_code):
            return False, f"target mechanism '{target_mechanism}' was not modified"

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
            return False, f"non-target mechanism '{mech}' was modified"

    return True, "valid"


def default_mechanism_stats() -> Dict[str, Any]:
    return {
        "tries": 0,
        "successes": 0,
        "total_uplift": 0.0,
        "invalid_count": 0,
        "compile_fail_count": 0,
        "last_tried": None,
        "best_delta": None,
    }


def sync_stats_mechanisms(stats: Dict[str, Any], definitions: Dict[str, Any]) -> bool:
    changed = False
    stats_mechanisms = stats.setdefault("mechanisms", {})
    if not isinstance(stats_mechanisms, dict):
        stats["mechanisms"] = {}
        stats_mechanisms = stats["mechanisms"]
        changed = True

    definition_mechanisms = definitions.get("mechanisms", {})
    if not isinstance(definition_mechanisms, dict):
        return changed

    for mechanism_name in definition_mechanisms.keys():
        if mechanism_name not in stats_mechanisms or not isinstance(stats_mechanisms[mechanism_name], dict):
            stats_mechanisms[mechanism_name] = default_mechanism_stats()
            changed = True

    for stale_name in list(stats_mechanisms.keys()):
        if stale_name not in definition_mechanisms:
            stats_mechanisms.pop(stale_name, None)
            changed = True

    return changed


def normalize_policy_mechanism_definition(
    name: str,
    candidate_info: Any,
    current_info: Any,
) -> Dict[str, Any]:
    merged: Dict[str, Any] = {}
    if isinstance(current_info, dict):
        merged.update(current_info)
    if isinstance(candidate_info, dict):
        merged.update(candidate_info)

    merged["current_implementation"] = str(merged.get("current_implementation", "") or "")
    merged["code_location"] = str(merged.get("code_location", "") or "")

    parameters = merged.get("parameters", {})
    merged["parameters"] = parameters if isinstance(parameters, dict) else {}

    directions = merged.get("modification_directions", [])
    if not isinstance(directions, list):
        directions = []
    merged["modification_directions"] = [str(item) for item in directions if isinstance(item, str) and item.strip()]

    raw_allowed = merged.get("allowed_overlap_with", [])
    if not isinstance(raw_allowed, list):
        raw_allowed = []
    allowed: List[str] = []
    seen_allowed: set[str] = set()
    for item in raw_allowed:
        if not isinstance(item, str):
            continue
        value = item.strip()
        if not value or value == name or value in seen_allowed:
            continue
        seen_allowed.add(value)
        allowed.append(value)
    merged["allowed_overlap_with"] = allowed

    raw_anchors = merged.get("anchors", [])
    if not isinstance(raw_anchors, list):
        raw_anchors = []
    anchors: List[Dict[str, Any]] = []
    for anchor in raw_anchors:
        if not isinstance(anchor, dict):
            continue
        start = str(anchor.get("start", "") or "")
        end = str(anchor.get("end", "") or start)
        if not start:
            continue
        normalized_anchor: Dict[str, Any] = {"start": start, "end": end}
        for numeric_key in ("occurrence", "end_occurrence", "before", "after"):
            if numeric_key not in anchor:
                continue
            try:
                normalized_anchor[numeric_key] = int(anchor[numeric_key])
            except (TypeError, ValueError):
                continue
        anchors.append(normalized_anchor)
    merged["anchors"] = anchors
    return merged


def normalize_policy_definitions_payload(
    payload: Dict[str, Any],
    current_definitions: Dict[str, Any],
    champion_edge: float,
) -> Optional[Dict[str, Any]]:
    raw_mechanisms = payload.get("mechanisms")
    if not isinstance(raw_mechanisms, dict):
        return None

    current_mechanisms = current_definitions.get("mechanisms", {})
    if not isinstance(current_mechanisms, dict):
        current_mechanisms = {}

    normalized_mechanisms: Dict[str, Dict[str, Any]] = {}
    for mechanism_name, candidate_info in raw_mechanisms.items():
        if not isinstance(mechanism_name, str):
            continue
        name = mechanism_name.strip()
        if not name:
            continue
        normalized_mechanisms[name] = normalize_policy_mechanism_definition(
            name=name,
            candidate_info=candidate_info,
            current_info=current_mechanisms.get(name, {}),
        )

    if not normalized_mechanisms:
        return None

    schema_version = payload.get("schema_version", current_definitions.get("schema_version", "1.0"))
    champion_file = payload.get("champion_file", current_definitions.get("champion_file", ".best_strategy.sol"))
    raw_edge = payload.get("champion_edge", champion_edge)
    try:
        normalized_edge = float(raw_edge)
    except (TypeError, ValueError):
        normalized_edge = float(champion_edge)

    return {
        "schema_version": str(schema_version),
        "champion_file": str(champion_file),
        "champion_edge": normalized_edge,
        "mechanisms": normalized_mechanisms,
    }


def span_line_count(spans: Sequence[Tuple[int, int]]) -> int:
    merged = merge_spans(spans)
    return sum(max(0, end - start + 1) for start, end in merged)


def validate_policy_definitions(
    candidate_definitions: Dict[str, Any],
    current_definitions: Dict[str, Any],
    champion_code: str,
) -> Tuple[bool, str, Dict[str, Any]]:
    report: Dict[str, Any] = {
        "errors": [],
        "warnings": [],
        "added_mechanisms": [],
        "missing_mechanisms": [],
        "span_lines_by_mechanism": {},
    }

    candidate_mechanisms = candidate_definitions.get("mechanisms", {})
    current_mechanisms = current_definitions.get("mechanisms", {})
    if not isinstance(candidate_mechanisms, dict):
        return False, "candidate_definitions_missing_mechanisms", report
    if not isinstance(current_mechanisms, dict):
        current_mechanisms = {}

    missing = sorted(set(current_mechanisms.keys()) - set(candidate_mechanisms.keys()))
    added = sorted(set(candidate_mechanisms.keys()) - set(current_mechanisms.keys()))
    report["missing_mechanisms"] = missing
    report["added_mechanisms"] = added

    if missing:
        report["errors"].append(f"missing_existing_mechanisms:{','.join(missing)}")
    if len(added) > POLICY_EVOLUTION_MAX_NEW_MECHANISMS:
        report["errors"].append(f"too_many_new_mechanisms:{len(added)}")

    champion_line_count = max(1, len(champion_code.splitlines()))
    max_span_allowed = max(
        10,
        min(
            POLICY_EVOLUTION_MAX_SPAN_LINES,
            int(champion_line_count * POLICY_EVOLUTION_MAX_SPAN_RATIO),
        ),
    )
    report["max_span_allowed"] = max_span_allowed

    mechanism_names = set(candidate_mechanisms.keys())
    for mechanism_name, mechanism_info in candidate_mechanisms.items():
        if not isinstance(mechanism_info, dict):
            report["errors"].append(f"mechanism_not_object:{mechanism_name}")
            continue

        spans = resolve_mechanism_spans(champion_code, mechanism_info)
        if not spans:
            report["errors"].append(f"unresolved_spans:{mechanism_name}")
            continue
        total_lines = span_line_count(spans)
        report["span_lines_by_mechanism"][mechanism_name] = total_lines
        if total_lines > max_span_allowed:
            report["errors"].append(f"span_too_large:{mechanism_name}:{total_lines}")

        allowed = mechanism_info.get("allowed_overlap_with", [])
        if not isinstance(allowed, list):
            report["errors"].append(f"invalid_allowed_overlap_with:{mechanism_name}")
            continue
        for overlap_target in allowed:
            if not isinstance(overlap_target, str):
                report["errors"].append(f"invalid_overlap_target:{mechanism_name}")
                continue
            if overlap_target not in mechanism_names:
                report["errors"].append(f"unknown_overlap_target:{mechanism_name}->{overlap_target}")
            if overlap_target == mechanism_name:
                report["errors"].append(f"self_overlap_not_allowed:{mechanism_name}")

    if report["errors"]:
        return False, report["errors"][0], report
    return True, "valid", report


def shadow_score_policy_candidate(
    champion_code: str,
    current_definitions: Dict[str, Any],
    candidate_definitions: Dict[str, Any],
    log_entries: Sequence[Dict[str, Any]],
    lookback: int = POLICY_EVOLUTION_LOOKBACK,
) -> Dict[str, Any]:
    replayed = 0
    rescued_validations = 0
    regressed_validations = 0
    unchanged = 0
    missing_candidate_file = 0
    for entry in list(log_entries[-max(1, int(lookback)) :]):
        mechanism_name = str(entry.get("mechanism", ""))
        if not mechanism_name or mechanism_name == "wildcard":
            continue
        candidate_path_raw = entry.get("candidate_path")
        if not candidate_path_raw:
            continue
        candidate_path = Path(str(candidate_path_raw))
        if not candidate_path.exists():
            missing_candidate_file += 1
            continue
        try:
            candidate_code = candidate_path.read_text()
        except OSError:
            missing_candidate_file += 1
            continue

        old_valid, _ = validate_candidate(
            champion_code,
            candidate_code,
            mechanism_name,
            current_definitions,
        )
        new_valid, _ = validate_candidate(
            champion_code,
            candidate_code,
            mechanism_name,
            candidate_definitions,
        )
        replayed += 1
        if (not old_valid) and new_valid:
            rescued_validations += 1
        elif old_valid and (not new_valid):
            regressed_validations += 1
        else:
            unchanged += 1

    return {
        "replayed_candidates": replayed,
        "rescued_validations": rescued_validations,
        "regressed_validations": regressed_validations,
        "unchanged": unchanged,
        "missing_candidate_file": missing_candidate_file,
        "shadow_score": rescued_validations - regressed_validations,
    }


def write_definitions_with_optional_mirror(path: Path, payload: Dict[str, Any]) -> None:
    atomic_write_json(path, payload)
    if path.suffix.lower() == ".json":
        mirror = path.with_suffix(".yaml")
        if mirror.exists():
            atomic_write_json(mirror, payload)
    elif path.suffix.lower() in {".yaml", ".yml"}:
        mirror = path.with_suffix(".json")
        if mirror.exists():
            atomic_write_json(mirror, payload)


def maybe_run_policy_evolution(args: argparse.Namespace, completed_iteration: int) -> Optional[Dict[str, Any]]:
    frequency = int(getattr(args, "policy_evolution_frequency", DEFAULT_POLICY_EVOLUTION_FREQUENCY))
    if frequency <= 0:
        return None
    if completed_iteration <= 0 or completed_iteration % frequency != 0:
        return None

    state_dir = Path(args.state_dir)
    definitions_path = Path(args.definitions)
    policy_log_path = state_dir / "policy_evolution_log.jsonl"
    policy_state_path = state_dir / "policy_evolution_state.json"
    policy_prompt_dir = state_dir / "prompts_policy"
    policy_candidate_dir = state_dir / "candidates_policy"
    policy_history_dir = state_dir / "policy_history"
    policy_prompt_dir.mkdir(parents=True, exist_ok=True)
    policy_candidate_dir.mkdir(parents=True, exist_ok=True)
    policy_history_dir.mkdir(parents=True, exist_ok=True)

    policy_state = load_json(policy_state_path, {})
    if int(policy_state.get("last_trigger_iteration", 0) or 0) == completed_iteration:
        return {
            "status": "skipped_already_triggered",
            "iter": completed_iteration,
            "ts": utc_now_iso(),
        }

    try:
        current_definitions = load_definitions(definitions_path)
    except Exception as exc:
        entry = {
            "status": "policy_failed_load_definitions",
            "iter": completed_iteration,
            "ts": utc_now_iso(),
            "reason": f"load_definitions_error:{exc}",
        }
        append_jsonl(policy_log_path, entry)
        atomic_write_json(
            policy_state_path,
            {
                "last_trigger_iteration": completed_iteration,
                "last_status": entry["status"],
                "updated_at": utc_now_iso(),
            },
        )
        return entry

    champion_code, champion_edge, _ = load_champion(state_dir)
    iteration_log = read_iteration_log(state_dir / "iteration_log.jsonl")
    signals = collect_iteration_failure_signals(iteration_log, lookback=POLICY_EVOLUTION_LOOKBACK)
    invalid_examples = pick_recent_invalid_examples(iteration_log, limit=6)
    prompt_text = build_policy_evolution_prompt(
        champion_code=champion_code,
        definitions=current_definitions,
        signals=signals,
        invalid_examples=invalid_examples,
    )
    prompt_path = policy_prompt_dir / f"iter_{completed_iteration}_policy.md"
    atomic_write_text(prompt_path, prompt_text + "\n")

    base_entry: Dict[str, Any] = {
        "status": "policy_started",
        "iter": completed_iteration,
        "ts": utc_now_iso(),
        "definitions_path": str(definitions_path),
        "prompt_path": str(prompt_path),
        "signals": signals,
    }

    if bool(getattr(args, "dry_run", False)):
        entry = dict(base_entry)
        entry["status"] = "policy_skipped_dry_run"
        append_jsonl(policy_log_path, entry)
        atomic_write_json(
            policy_state_path,
            {
                "last_trigger_iteration": completed_iteration,
                "last_status": entry["status"],
                "updated_at": utc_now_iso(),
            },
        )
        return entry

    artifact_prefix = policy_candidate_dir / f"iter_{completed_iteration}_policy"
    payload, llm_error, llm_artifacts = generate_policy_candidate_with_llm(
        prompt_path=prompt_path,
        artifact_prefix=artifact_prefix,
        llm_command=str(args.llm_command),
        llm_model=str(args.llm_model),
        llm_timeout_minutes=float(args.llm_timeout_minutes),
        llm_max_output_tokens=int(args.llm_max_output_tokens),
        llm_disable_shell_tool=bool(args.llm_disable_shell_tool),
    )
    entry = dict(base_entry)
    if llm_artifacts:
        entry.update(llm_artifacts)
    if payload is None:
        entry["status"] = "policy_llm_failed"
        entry["reason"] = llm_error or "policy_llm_failed"
        append_jsonl(policy_log_path, entry)
        atomic_write_json(
            policy_state_path,
            {
                "last_trigger_iteration": completed_iteration,
                "last_status": entry["status"],
                "updated_at": utc_now_iso(),
            },
        )
        return entry

    normalized = normalize_policy_definitions_payload(
        payload=payload,
        current_definitions=current_definitions,
        champion_edge=champion_edge,
    )
    if normalized is None:
        entry["status"] = "policy_rejected_invalid_schema"
        entry["reason"] = "candidate_payload_missing_mechanisms"
        append_jsonl(policy_log_path, entry)
        atomic_write_json(
            policy_state_path,
            {
                "last_trigger_iteration": completed_iteration,
                "last_status": entry["status"],
                "updated_at": utc_now_iso(),
            },
        )
        return entry

    valid, reason, validation_report = validate_policy_definitions(
        candidate_definitions=normalized,
        current_definitions=current_definitions,
        champion_code=champion_code,
    )
    shadow_report = shadow_score_policy_candidate(
        champion_code=champion_code,
        current_definitions=current_definitions,
        candidate_definitions=normalized,
        log_entries=iteration_log,
        lookback=POLICY_EVOLUTION_LOOKBACK,
    )
    entry["validation"] = validation_report
    entry["shadow"] = shadow_report

    current_hash = definitions_fingerprint(current_definitions)
    candidate_hash = definitions_fingerprint(normalized)
    entry["definitions_hash_before"] = current_hash
    entry["definitions_hash_after"] = candidate_hash

    if candidate_hash == current_hash:
        entry["status"] = "policy_no_change"
        append_jsonl(policy_log_path, entry)
        atomic_write_json(
            policy_state_path,
            {
                "last_trigger_iteration": completed_iteration,
                "last_status": entry["status"],
                "updated_at": utc_now_iso(),
            },
        )
        return entry

    if not valid:
        entry["status"] = "policy_rejected_validation"
        entry["reason"] = reason
        append_jsonl(policy_log_path, entry)
        atomic_write_json(
            policy_state_path,
            {
                "last_trigger_iteration": completed_iteration,
                "last_status": entry["status"],
                "updated_at": utc_now_iso(),
            },
        )
        return entry

    if int(shadow_report.get("regressed_validations", 0) or 0) > 0:
        entry["status"] = "policy_rejected_shadow_regression"
        entry["reason"] = "shadow_regression_detected"
        append_jsonl(policy_log_path, entry)
        atomic_write_json(
            policy_state_path,
            {
                "last_trigger_iteration": completed_iteration,
                "last_status": entry["status"],
                "updated_at": utc_now_iso(),
            },
        )
        return entry

    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    backup_path = policy_history_dir / f"{definitions_path.stem}.iter_{completed_iteration}.{stamp}{definitions_path.suffix or '.json'}"
    if definitions_path.exists():
        shutil.copy2(definitions_path, backup_path)
    write_definitions_with_optional_mirror(definitions_path, normalized)

    entry["status"] = "policy_applied"
    entry["backup_path"] = str(backup_path)
    append_jsonl(policy_log_path, entry)
    atomic_write_json(
        policy_state_path,
        {
            "last_trigger_iteration": completed_iteration,
            "last_status": entry["status"],
            "last_applied_hash": candidate_hash,
            "updated_at": utc_now_iso(),
        },
    )
    return entry


def evaluate_with_pipeline(
    candidate_path: Path,
    result_path: Path,
    python_exe: str,
    screen_sims: int,
) -> Tuple[Optional[float], Optional[str]]:
    cmd = [
        python_exe,
        "scripts/amm-test-pipeline.py",
        str(candidate_path),
        "--output",
        str(result_path),
        "--screen-sims",
        str(screen_sims),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return None, f"pipeline_failed:{proc.returncode}"

    result = load_json(result_path, {})
    edge = result.get("final_edge")
    if edge is None:
        return None, "pipeline_no_final_edge"
    return float(edge), None


def mock_delta(mechanism: str, iteration: int, seed: int) -> float:
    digest = hashlib.sha256(f"{mechanism}:{iteration}:{seed}".encode()).hexdigest()
    raw = int(digest[:8], 16)
    value = (raw % 51) - 25
    return float(value) / 100.0


def load_definitions(path: Path) -> Dict[str, Any]:
    raw = path.read_text()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        if path.suffix.lower() not in {".yaml", ".yml"}:
            raise
        try:
            import yaml  # type: ignore
        except ImportError as exc:
            raise ValueError(
                f"YAML definitions require PyYAML, or provide JSON definitions: {path}"
            ) from exc
        data = yaml.safe_load(raw)
    if not isinstance(data, dict):
        raise ValueError(f"invalid mechanism definitions format: {path}")
    return data


def initialize_stats(
    state_dir: Path,
    definitions: Dict[str, Any],
    exploration_c: float,
    improvement_threshold: float,
    max_retries_on_invalid: int,
    wildcard_frequency: int,
) -> Dict[str, Any]:
    champion_code = (state_dir / ".best_strategy.sol").read_text()
    champion_name = parse_get_name(champion_code) or "unknown_champion"
    champion_edge = float((state_dir / ".best_edge.txt").read_text().strip())
    mechanisms = {}
    for mechanism_name in definitions.get("mechanisms", {}).keys():
        mechanisms[mechanism_name] = default_mechanism_stats()
    return {
        "schema_version": SCHEMA_VERSION,
        "champion": {
            "name": champion_name,
            "edge": champion_edge,
            "baseline_edge": champion_edge,
            "promoted_at": utc_now_iso(),
        },
        "mechanisms": mechanisms,
        "global": {
            "total_iterations": 0,
            "total_champion_updates": 0,
            "exploration_constant": exploration_c,
            "improvement_threshold": improvement_threshold,
            "max_retries_on_invalid": max_retries_on_invalid,
            "wildcard_frequency": wildcard_frequency,
            "rollback_triggered": False,
            "rollback_reason": None,
            "consecutive_invalid": 0,
        },
    }


def load_or_init_stats(
    stats_path: Path,
    state_dir: Path,
    definitions: Dict[str, Any],
    exploration_c: float,
    improvement_threshold: float,
    max_retries_on_invalid: int,
    wildcard_frequency: int,
) -> Dict[str, Any]:
    existing = load_json(stats_path, {})
    if isinstance(existing, dict) and existing.get("mechanisms"):
        return existing
    stats = initialize_stats(
        state_dir=state_dir,
        definitions=definitions,
        exploration_c=exploration_c,
        improvement_threshold=improvement_threshold,
        max_retries_on_invalid=max_retries_on_invalid,
        wildcard_frequency=wildcard_frequency,
    )
    atomic_write_json(stats_path, stats)
    return stats


def load_champion(state_dir: Path) -> Tuple[str, float, str]:
    code = (state_dir / ".best_strategy.sol").read_text()
    edge = float((state_dir / ".best_edge.txt").read_text().strip())
    name = parse_get_name(code) or "unknown_champion"
    return code, edge, name


def update_rollback_status(
    stats: Dict[str, Any],
    log_entries: List[Dict[str, Any]],
    consecutive_invalid_threshold: int,
    severe_regression_threshold: float,
    cumulative_loss_threshold: float,
    cumulative_window: int,
) -> Optional[str]:
    consecutive_invalid = 0
    for entry in reversed(log_entries):
        if bool(entry.get("valid", False)):
            break
        consecutive_invalid += 1
    stats["global"]["consecutive_invalid"] = consecutive_invalid

    reason: Optional[str] = None
    if consecutive_invalid >= consecutive_invalid_threshold:
        reason = f"consecutive_invalid>={consecutive_invalid_threshold}"

    valid_entries = [e for e in log_entries if bool(e.get("valid", False)) and e.get("delta") is not None]
    if valid_entries:
        latest_delta = float(valid_entries[-1]["delta"])
        if latest_delta <= severe_regression_threshold:
            reason = f"severe_regression<={severe_regression_threshold}"

    recent = valid_entries[-cumulative_window:]
    cumulative = sum(float(e.get("delta", 0.0) or 0.0) for e in recent)
    if len(recent) == cumulative_window and cumulative <= cumulative_loss_threshold:
        reason = f"cumulative_loss_{cumulative_window}<={cumulative_loss_threshold}"

    champion_edge = float(stats.get("champion", {}).get("edge", 0.0) or 0.0)
    baseline_edge = float(stats.get("champion", {}).get("baseline_edge", champion_edge) or champion_edge)
    if champion_edge < baseline_edge:
        reason = "champion_destroyed"

    if reason:
        stats["global"]["rollback_triggered"] = True
        stats["global"]["rollback_reason"] = reason
        return reason
    return None


def perform_rollback(
    state_dir: Path,
    reason: str,
    archive_only: bool,
) -> Dict[str, Any]:
    snapshot_dir = state_dir / "migration_snapshot"
    archive_dir = state_dir / ".archive"
    archive_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")

    moved: List[str] = []
    for name in ("mechanism_stats.json", "iteration_log.jsonl", "shadow_selections.jsonl"):
        src = state_dir / name
        if src.exists():
            dst = archive_dir / f"{name}.failed_{stamp}"
            shutil.move(str(src), str(dst))
            moved.append(str(dst))

    restored: List[str] = []
    if not archive_only:
        restore_files = [
            ".opportunity_priors.json",
            ".opportunity_history.json",
            ".best_strategy.sol",
            ".best_edge.txt",
        ]
        for name in restore_files:
            src = snapshot_dir / name
            if src.exists():
                dst = state_dir / name
                shutil.copy2(src, dst)
                restored.append(str(dst))

    with (archive_dir / "rollback_log.txt").open("a") as handle:
        handle.write(f"{utc_now_iso()} reason={reason} moved={moved} restored={restored}\n")

    return {"reason": reason, "moved": moved, "restored": restored}


def read_iteration_log(path: Path) -> List[Dict[str, Any]]:
    if not path.exists():
        return []
    rows: List[Dict[str, Any]] = []
    with path.open() as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                payload = json.loads(stripped)
                if isinstance(payload, dict):
                    rows.append(payload)
            except json.JSONDecodeError:
                continue
    return rows


def run_iteration(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    stats_path = state_dir / "mechanism_stats.json"
    log_path = state_dir / "iteration_log.jsonl"
    prompt_dir = state_dir / "prompts_simplified"
    prompt_dir.mkdir(parents=True, exist_ok=True)
    candidate_dir = state_dir / "candidates_simplified"
    candidate_dir.mkdir(parents=True, exist_ok=True)

    definitions = load_definitions(Path(args.definitions))
    stats = load_or_init_stats(
        stats_path=stats_path,
        state_dir=state_dir,
        definitions=definitions,
        exploration_c=float(args.exploration_c),
        improvement_threshold=float(args.improvement_threshold),
        max_retries_on_invalid=int(args.max_retries_on_invalid),
        wildcard_frequency=int(args.wildcard_frequency),
    )
    if sync_stats_mechanisms(stats, definitions):
        atomic_write_json(stats_path, stats)

    iteration = int(stats.get("global", {}).get("total_iterations", 0) or 0) + 1
    rng = random.Random(int(args.seed) + iteration)

    champion_code, champion_edge, champion_name = load_champion(state_dir)
    mechanisms = dict(definitions.get("mechanisms", {}))
    if not mechanisms:
        raise ValueError("definitions has no mechanisms")

    wildcard = should_run_wildcard(iteration, stats, int(args.wildcard_frequency))
    candidate_pool = {name: rec for name, rec in stats["mechanisms"].items() if name in mechanisms}
    if not candidate_pool:
        candidate_pool = {name: default_mechanism_stats() for name in mechanisms.keys()}
        stats["mechanisms"] = candidate_pool
    mechanism_name = "wildcard" if wildcard else select_mechanism(
        candidate_pool, float(args.exploration_c), rng
    )

    candidate_code = ""
    prompt_text = ""
    prompt_path = prompt_dir / f"iter_{iteration}_{mechanism_name}.md"
    candidate_path = candidate_dir / f"iter_{iteration}_{mechanism_name}.sol"
    llm_artifacts: Dict[str, str] = {}

    if wildcard:
        variant_name = f"wildcard_mod_v{iteration}"
        prompt_text = build_wildcard_prompt(
            champion_code=champion_code,
            variant_name=variant_name,
        )
    else:
        mechanism_info = mechanisms[mechanism_name]
        variant_name = f"{mechanism_name}_mod_v{iteration}"
        prompt_text = build_prompt(
            champion_code=champion_code,
            mechanism_name=mechanism_name,
            mechanism_info=mechanism_info,
            other_mechanisms=[m for m in mechanisms.keys() if m != mechanism_name],
            variant_name=variant_name,
        )

    atomic_write_text(prompt_path, prompt_text + "\n")

    if args.candidate_file:
        candidate_code = Path(args.candidate_file).read_text()
    elif args.dry_run:
        if wildcard:
            candidate_code = champion_code + f"\n// wildcard mutation iter={iteration}\n"
        else:
            candidate_code = generate_mock_candidate(
                champion_code=champion_code,
                mechanism_name=mechanism_name,
                mechanism_info=mechanism_info,
                iteration=iteration,
            )
    else:
        artifact_prefix = candidate_dir / f"iter_{iteration}_{mechanism_name}"
        candidate_code, llm_error, llm_artifacts = generate_candidate_with_llm(
            prompt_path=prompt_path,
            artifact_prefix=artifact_prefix,
            llm_command=str(args.llm_command),
            llm_model=str(args.llm_model),
            llm_timeout_minutes=float(args.llm_timeout_minutes),
            llm_max_output_tokens=int(args.llm_max_output_tokens),
            llm_disable_shell_tool=bool(args.llm_disable_shell_tool),
            attempt=0,
        )
        if candidate_code is None:
            if mechanism_name in stats["mechanisms"]:
                stats["mechanisms"][mechanism_name]["invalid_count"] = int(
                    stats["mechanisms"][mechanism_name].get("invalid_count", 0) or 0
                ) + 1
            stats["global"]["total_iterations"] = iteration
            entry = {
                "iter": iteration,
                "ts": utc_now_iso(),
                "status": "llm_failed",
                "mechanism": mechanism_name,
                "valid": False,
                "reason": llm_error or "llm_failed",
                "champion_edge_before": champion_edge,
                "prompt_path": str(prompt_path),
                "candidate_path": str(candidate_path),
            }
            if llm_artifacts:
                entry.update(llm_artifacts)
            append_jsonl(log_path, entry)
            logs = read_iteration_log(log_path)
            update_rollback_status(
                stats,
                logs,
                int(args.rollback_consecutive_invalid),
                float(args.rollback_severe_regression),
                float(args.rollback_cumulative_loss),
                int(args.rollback_window),
            )
            atomic_write_json(stats_path, stats)
            if bool(args.auto_rollback) and stats["global"].get("rollback_triggered"):
                rollback_meta = perform_rollback(state_dir, str(stats["global"]["rollback_reason"]), archive_only=False)
                print(json.dumps({"status": "rolled_back", **rollback_meta}, indent=2))
                return 2
            print(json.dumps(entry, indent=2))
            return 1

    atomic_write_text(candidate_path, candidate_code)

    valid = True
    reason = "valid"
    retries = int(args.max_retries_on_invalid)
    if not wildcard:
        for attempt in range(retries + 1):
            valid, reason = validate_candidate(champion_code, candidate_code, mechanism_name, definitions)
            if valid:
                break
            if attempt >= retries:
                break
            if args.candidate_file:
                break
            if args.dry_run:
                candidate_code = generate_mock_candidate(
                    champion_code=champion_code,
                    mechanism_name=mechanism_name,
                    mechanism_info=mechanisms[mechanism_name],
                    iteration=iteration + attempt + 1,
                )
            else:
                artifact_prefix = candidate_dir / f"iter_{iteration}_{mechanism_name}"
                candidate_code, llm_error, llm_artifacts = generate_candidate_with_llm(
                    prompt_path=prompt_path,
                    artifact_prefix=artifact_prefix,
                    llm_command=str(args.llm_command),
                    llm_model=str(args.llm_model),
                    llm_timeout_minutes=float(args.llm_timeout_minutes),
                    llm_max_output_tokens=int(args.llm_max_output_tokens),
                    llm_disable_shell_tool=bool(args.llm_disable_shell_tool),
                    attempt=attempt + 1,
                )
                if candidate_code is None:
                    reason = llm_error or "llm_retry_failed"
                    break
            atomic_write_text(candidate_path, candidate_code)

    if not valid:
        if mechanism_name in stats["mechanisms"]:
            stats["mechanisms"][mechanism_name]["invalid_count"] = int(
                stats["mechanisms"][mechanism_name].get("invalid_count", 0) or 0
            ) + 1
        stats["global"]["total_iterations"] = iteration
        entry = {
            "iter": iteration,
            "ts": utc_now_iso(),
            "status": "invalid",
            "mechanism": mechanism_name,
            "valid": False,
            "reason": reason,
            "champion_edge_before": champion_edge,
            "prompt_path": str(prompt_path),
            "candidate_path": str(candidate_path),
        }
        if llm_artifacts:
            entry.update(llm_artifacts)
        append_jsonl(log_path, entry)
        logs = read_iteration_log(log_path)
        update_rollback_status(
            stats,
            logs,
            int(args.rollback_consecutive_invalid),
            float(args.rollback_severe_regression),
            float(args.rollback_cumulative_loss),
            int(args.rollback_window),
        )
        atomic_write_json(stats_path, stats)
        if bool(args.auto_rollback) and stats["global"].get("rollback_triggered"):
            rollback_meta = perform_rollback(state_dir, str(stats["global"]["rollback_reason"]), archive_only=False)
            print(json.dumps({"status": "rolled_back", **rollback_meta}, indent=2))
            return 2
        print(json.dumps(entry, indent=2))
        return 1

    result_path = candidate_dir / f"iter_{iteration}_{mechanism_name}.result.json"
    candidate_edge: Optional[float]
    eval_error: Optional[str]
    if args.dry_run:
        delta = mock_delta(mechanism_name, iteration, int(args.seed))
        candidate_edge = champion_edge + delta
        eval_error = None
    else:
        candidate_edge, eval_error = evaluate_with_pipeline(
            candidate_path=candidate_path,
            result_path=result_path,
            python_exe=str(args.python_exe),
            screen_sims=int(args.screen_sims),
        )

    if candidate_edge is None:
        if mechanism_name in stats["mechanisms"]:
            stats["mechanisms"][mechanism_name]["compile_fail_count"] = int(
                stats["mechanisms"][mechanism_name].get("compile_fail_count", 0) or 0
            ) + 1
            stats["mechanisms"][mechanism_name]["invalid_count"] = int(
                stats["mechanisms"][mechanism_name].get("invalid_count", 0) or 0
            ) + 1
        stats["global"]["total_iterations"] = iteration
        entry = {
            "iter": iteration,
            "ts": utc_now_iso(),
            "status": "compile_failed",
            "mechanism": mechanism_name,
            "valid": False,
            "reason": eval_error or "evaluation_failed",
            "champion_edge_before": champion_edge,
            "prompt_path": str(prompt_path),
            "candidate_path": str(candidate_path),
            "result_path": str(result_path),
        }
        if llm_artifacts:
            entry.update(llm_artifacts)
        append_jsonl(log_path, entry)
        logs = read_iteration_log(log_path)
        update_rollback_status(
            stats,
            logs,
            int(args.rollback_consecutive_invalid),
            float(args.rollback_severe_regression),
            float(args.rollback_cumulative_loss),
            int(args.rollback_window),
        )
        atomic_write_json(stats_path, stats)
        if bool(args.auto_rollback) and stats["global"].get("rollback_triggered"):
            rollback_meta = perform_rollback(state_dir, str(stats["global"]["rollback_reason"]), archive_only=False)
            print(json.dumps({"status": "rolled_back", **rollback_meta}, indent=2))
            return 2
        print(json.dumps(entry, indent=2))
        return 1

    delta = candidate_edge - champion_edge

    promoted = False
    if candidate_edge > champion_edge:
        atomic_write_text(state_dir / ".best_strategy.sol", candidate_code)
        atomic_write_text(state_dir / ".best_edge.txt", f"{candidate_edge:.2f}\n")
        promoted = True
        stats["champion"]["edge"] = candidate_edge
        stats["champion"]["name"] = parse_get_name(candidate_code) or f"iter_{iteration}_champion"
        stats["champion"]["promoted_at"] = utc_now_iso()
        stats["global"]["total_champion_updates"] = int(
            stats["global"].get("total_champion_updates", 0) or 0
        ) + 1
    else:
        stats["champion"]["name"] = champion_name
        stats["champion"]["edge"] = champion_edge

    if mechanism_name in stats["mechanisms"]:
        m = stats["mechanisms"][mechanism_name]
        m["tries"] = int(m.get("tries", 0) or 0) + 1
        m["total_uplift"] = float(m.get("total_uplift", 0.0) or 0.0) + float(delta)
        m["last_tried"] = utc_now_iso()
        if delta > float(args.improvement_threshold):
            m["successes"] = int(m.get("successes", 0) or 0) + 1
        prev_best = m.get("best_delta")
        if prev_best is None or float(delta) > float(prev_best):
            m["best_delta"] = float(delta)

    stats["global"]["total_iterations"] = iteration

    entry = {
        "iter": iteration,
        "ts": utc_now_iso(),
        "status": "complete",
        "mechanism": mechanism_name,
        "valid": True,
        "delta": delta,
        "edge": candidate_edge,
        "promoted": promoted,
        "wildcard": wildcard,
        "champion_edge_before": champion_edge,
        "prompt_path": str(prompt_path),
        "candidate_path": str(candidate_path),
        "result_path": str(result_path),
    }
    if llm_artifacts:
        entry.update(llm_artifacts)
    append_jsonl(log_path, entry)

    logs = read_iteration_log(log_path)
    update_rollback_status(
        stats,
        logs,
        int(args.rollback_consecutive_invalid),
        float(args.rollback_severe_regression),
        float(args.rollback_cumulative_loss),
        int(args.rollback_window),
    )
    atomic_write_json(stats_path, stats)

    if bool(args.auto_rollback) and stats["global"].get("rollback_triggered"):
        rollback_meta = perform_rollback(state_dir, str(stats["global"]["rollback_reason"]), archive_only=False)
        print(json.dumps({"status": "rolled_back", **rollback_meta}, indent=2))
        return 2

    print(json.dumps(entry, indent=2))
    return 0


def show_status(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    stats_path = state_dir / "mechanism_stats.json"
    log_path = state_dir / "iteration_log.jsonl"
    policy_state_path = state_dir / "policy_evolution_state.json"
    stats = load_json(stats_path, {})
    logs = read_iteration_log(log_path)
    policy_state = load_json(policy_state_path, {})

    if not stats:
        print(json.dumps({"status": "uninitialized", "state_dir": str(state_dir)}, indent=2))
        return 0

    payload = {
        "state_dir": str(state_dir),
        "schema_version": stats.get("schema_version"),
        "champion": stats.get("champion", {}),
        "global": stats.get("global", {}),
        "mechanism_stats": stats.get("mechanisms", {}),
        "log_entries": len(logs),
        "last_entry": logs[-1] if logs else None,
        "policy_evolution": policy_state if isinstance(policy_state, dict) else {},
    }
    print(json.dumps(payload, indent=2))
    return 0


def run_loop(args: argparse.Namespace) -> int:
    count = int(args.iterations)
    sleep_seconds = float(args.sleep_seconds)
    state_dir = Path(args.state_dir)
    for i in range(count):
        run_code = run_iteration(args)
        stats = load_json(state_dir / "mechanism_stats.json", {})
        completed_iteration = int(stats.get("global", {}).get("total_iterations", 0) or 0)
        policy_entry = maybe_run_policy_evolution(args, completed_iteration)
        if policy_entry is not None:
            print(json.dumps({"policy_evolution": policy_entry}, indent=2))
        if run_code != 0 and not bool(args.continue_on_error):
            return run_code
        if bool(args.shadow_script):
            shadow_cmd = [str(args.python_exe), str(args.shadow_script), "--state-dir", str(args.state_dir)]
            if args.shadow_snapshot_dir:
                shadow_cmd += ["--snapshot-dir", str(args.shadow_snapshot_dir)]
            shadow_cmd += ["--iteration", str(i + 1)]
            subprocess.run(shadow_cmd, check=False)
        if i + 1 < count and sleep_seconds > 0:
            time.sleep(sleep_seconds)
    return 0


def rollback_check(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    stats_path = state_dir / "mechanism_stats.json"
    log_path = state_dir / "iteration_log.jsonl"
    stats = load_json(stats_path, {})
    if not stats:
        print(json.dumps({"status": "uninitialized"}, indent=2))
        return 0
    logs = read_iteration_log(log_path)
    reason = update_rollback_status(
        stats,
        logs,
        int(args.rollback_consecutive_invalid),
        float(args.rollback_severe_regression),
        float(args.rollback_cumulative_loss),
        int(args.rollback_window),
    )
    atomic_write_json(stats_path, stats)
    payload = {
        "rollback_triggered": bool(stats.get("global", {}).get("rollback_triggered")),
        "rollback_reason": stats.get("global", {}).get("rollback_reason"),
        "evaluated_reason": reason,
    }
    print(json.dumps(payload, indent=2))
    if bool(args.apply) and payload["rollback_triggered"]:
        meta = perform_rollback(state_dir, str(payload["rollback_reason"]), archive_only=False)
        print(json.dumps({"status": "rolled_back", **meta}, indent=2))
    return 0


def force_rollback(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    meta = perform_rollback(
        state_dir=state_dir,
        reason=str(args.reason),
        archive_only=bool(args.archive_only),
    )
    print(json.dumps({"status": "rolled_back", **meta}, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Simplified champion-centric Phase 7 loop")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_common(run_parser: argparse.ArgumentParser) -> None:
        run_parser.add_argument("--state-dir", default=".ralph-amm/phase7/state")
        run_parser.add_argument(
            "--definitions",
            default=".ralph-amm/phase7/config/mechanism_definitions.json",
        )
        run_parser.add_argument("--exploration-c", type=float, default=DEFAULT_EXPLORATION_C)
        run_parser.add_argument("--improvement-threshold", type=float, default=DEFAULT_IMPROVEMENT_THRESHOLD)
        run_parser.add_argument("--max-retries-on-invalid", type=int, default=DEFAULT_MAX_RETRIES_ON_INVALID)
        run_parser.add_argument("--wildcard-frequency", type=int, default=DEFAULT_WILDCARD_FREQUENCY)
        run_parser.add_argument("--seed", type=int, default=7)
        run_parser.add_argument("--rollback-consecutive-invalid", type=int, default=DEFAULT_ROLLBACK_CONSECUTIVE_INVALID)
        run_parser.add_argument("--rollback-severe-regression", type=float, default=DEFAULT_ROLLBACK_SEVERE_REGRESSION)
        run_parser.add_argument("--rollback-cumulative-loss", type=float, default=DEFAULT_ROLLBACK_CUMULATIVE_LOSS)
        run_parser.add_argument("--rollback-window", type=int, default=DEFAULT_ROLLBACK_WINDOW)
        run_parser.add_argument("--auto-rollback", action="store_true")
        run_parser.add_argument("--python-exe", default="python3")
        run_parser.add_argument("--screen-sims", type=int, default=100)
        run_parser.add_argument("--dry-run", action="store_true")
        run_parser.add_argument("--candidate-file")
        run_parser.add_argument("--llm-command", default=DEFAULT_LLM_COMMAND)
        run_parser.add_argument("--llm-model", default=DEFAULT_LLM_MODEL)
        run_parser.add_argument("--llm-timeout-minutes", type=float, default=DEFAULT_LLM_TIMEOUT_MINUTES)
        run_parser.add_argument("--llm-max-output-tokens", type=int, default=DEFAULT_LLM_MAX_OUTPUT_TOKENS)
        run_parser.add_argument("--llm-disable-shell-tool", action="store_true")
        run_parser.add_argument("--policy-evolution-frequency", type=int, default=DEFAULT_POLICY_EVOLUTION_FREQUENCY)

    run_once = sub.add_parser("run-once", help="Run one simplified loop iteration")
    add_common(run_once)
    run_once.set_defaults(func=run_iteration)

    run_many = sub.add_parser("run-loop", help="Run multiple simplified loop iterations")
    add_common(run_many)
    run_many.add_argument("--iterations", type=int, default=10)
    run_many.add_argument("--sleep-seconds", type=float, default=0.0)
    run_many.add_argument("--continue-on-error", action="store_true")
    run_many.add_argument("--shadow-script", default="scripts/shadow_selector.py")
    run_many.add_argument("--shadow-snapshot-dir")
    run_many.set_defaults(func=run_loop)

    status = sub.add_parser("status", help="Show simplified loop status")
    status.add_argument("--state-dir", default=".ralph-amm/phase7/state")
    status.set_defaults(func=show_status)

    rollback_check_parser = sub.add_parser("rollback-check", help="Evaluate rollback triggers")
    rollback_check_parser.add_argument("--state-dir", default=".ralph-amm/phase7/state")
    rollback_check_parser.add_argument("--rollback-consecutive-invalid", type=int, default=DEFAULT_ROLLBACK_CONSECUTIVE_INVALID)
    rollback_check_parser.add_argument("--rollback-severe-regression", type=float, default=DEFAULT_ROLLBACK_SEVERE_REGRESSION)
    rollback_check_parser.add_argument("--rollback-cumulative-loss", type=float, default=DEFAULT_ROLLBACK_CUMULATIVE_LOSS)
    rollback_check_parser.add_argument("--rollback-window", type=int, default=DEFAULT_ROLLBACK_WINDOW)
    rollback_check_parser.add_argument("--apply", action="store_true")
    rollback_check_parser.set_defaults(func=rollback_check)

    rollback_parser = sub.add_parser("rollback", help="Force rollback from migration snapshot")
    rollback_parser.add_argument("--state-dir", default=".ralph-amm/phase7/state")
    rollback_parser.add_argument("--reason", required=True)
    rollback_parser.add_argument("--archive-only", action="store_true")
    rollback_parser.set_defaults(func=force_rollback)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
