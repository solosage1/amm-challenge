#!/usr/bin/env bash
#
# Ralph-AMM Phase 7: Autonomous AI-Powered Strategy Exploration
#
# This script orchestrates a 10-hour autonomous loop that uses Claude API (via Codex CLI)
# to generate novel AMM strategy patterns, test them, and extract reusable templates.
#
# Exit conditions:
#   1. Time: 36,000 seconds (10 hours) elapsed
#   2. Performance: Edge > 527 (competitive threshold)
#

set -euo pipefail

# Ensure we run from repo root for consistent relative paths.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ============================================================================
# CONFIGURATION
# ============================================================================

PHASE7_STATE_DIR=".ralph-amm/phase7/state"
PHASE7_GENERATED_DIR=".ralph-amm/phase7/generated"
PHASE7_TEMPLATES_DIR=".ralph-amm/phase7/templates"
PHASE7_PROMPTS_DIR=".ralph-amm/phase7/prompts"

# Pin all execution to venv_fresh for autonomy.
VENV_PY="${VENV_PY:-venv_fresh/bin/python3}"
AMM_MATCH="${AMM_MATCH:-venv_fresh/bin/amm-match}"

# Codex configuration
# If CODEX_MODEL is empty, Codex uses its configured default model/provider.
CODEX_MODEL="${CODEX_MODEL:-}"
CODEX_MAX_OUTPUT_TOKENS="${CODEX_MAX_OUTPUT_TOKENS:-8000}"
CODEX_TIMEOUT_MINUTES="${CODEX_TIMEOUT_MINUTES:-50}"  # Max time per Codex invocation (increased for full write+test cycles)

# Performance targets
COMPETITIVE_EDGE=527

# Template extraction (reachable) rules
TEMPLATE_MIN_EDGE="${TEMPLATE_MIN_EDGE:-350.0}"
TEMPLATE_WITHIN_BEST="${TEMPLATE_WITHIN_BEST:-5.0}"
TEMPLATE_TOP_K="${TEMPLATE_TOP_K:-5}"

# Runtime limits
MAX_RUNTIME_SECONDS=36000  # 10 hours
MAX_ITERATIONS=${MAX_ITERATIONS:-999999}  # Override with --max-iterations

# State files
STATE_ITERATION="$PHASE7_STATE_DIR/.iteration_count.txt"
STATE_CHAMPION="$PHASE7_STATE_DIR/.best_edge.txt"
STATE_STRATEGIES="$PHASE7_STATE_DIR/.strategies_log.json"
STATE_TEMPLATES="$PHASE7_STATE_DIR/.templates_created.json"
STATE_RATE_LIMIT="$PHASE7_STATE_DIR/.rate_limit_tracker.json"
STATE_START_TIME="$PHASE7_STATE_DIR/.start_timestamp.txt"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message"
}

die() {
    log "ERROR" "$*"
    exit 1
}

require_file() {
    local path="$1"
    local hint="${2:-}"
    [[ -f "$path" ]] || die "Missing required file: $path${hint:+ ($hint)}"
}

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

float_ge() {
    "$VENV_PY" - "$1" "$2" <<'PY'
import sys
a = float(sys.argv[1])
b = float(sys.argv[2])
raise SystemExit(0 if a >= b else 1)
PY
}

float_gt() {
    "$VENV_PY" - "$1" "$2" <<'PY'
import sys
a = float(sys.argv[1])
b = float(sys.argv[2])
raise SystemExit(0 if a > b else 1)
PY
}

get_elapsed_seconds() {
    local start=$(cat "$STATE_START_TIME" 2>/dev/null || echo "0")
    local now=$(date +%s)
    echo $((now - start))
}

get_remaining_seconds() {
    local elapsed=$(get_elapsed_seconds)
    local remaining=$((MAX_RUNTIME_SECONDS - elapsed))
    echo "$remaining"
}

format_duration() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    printf "%dh %dm %ds" "$hours" "$minutes" "$secs"
}

# ============================================================================
# STATE MANAGEMENT
# ============================================================================

init_phase7_state() {
    log "INFO" "Initializing Phase 7 state..."

    # Create directories if they don't exist
    mkdir -p "$PHASE7_STATE_DIR" "$PHASE7_GENERATED_DIR" "$PHASE7_TEMPLATES_DIR" "$PHASE7_PROMPTS_DIR"

    # Initialize / repair state files (must be valid JSON / scalars).
    "$VENV_PY" - "$STATE_ITERATION" "$STATE_CHAMPION" "$STATE_STRATEGIES" "$STATE_TEMPLATES" \
        "$STATE_RATE_LIMIT" "$STATE_START_TIME" <<'PY'
import json
import os
from pathlib import Path
import sys
import time

state_iteration = Path(sys.argv[1])
state_champion = Path(sys.argv[2])
state_strategies = Path(sys.argv[3])
state_templates = Path(sys.argv[4])
state_rate_limit = Path(sys.argv[5])
state_start_time = Path(sys.argv[6])

def atomic_write_text(path: Path, text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)

def ensure_int_file(path: Path, default: int) -> None:
    try:
        v = int(path.read_text().strip())
        if v < 0:
            raise ValueError("negative")
    except Exception:
        atomic_write_text(path, str(default))

def ensure_float_file(path: Path, default: float) -> None:
    try:
        float(path.read_text().strip())
    except Exception:
        atomic_write_text(path, str(default))

def ensure_json_file(path: Path, default_obj) -> None:
    try:
        obj = json.loads(path.read_text())
        # Ensure type matches default.
        if not isinstance(obj, type(default_obj)):
            raise TypeError("wrong type")
    except Exception:
        atomic_write_text(path, json.dumps(default_obj))

ensure_int_file(state_iteration, 0)
ensure_float_file(state_champion, 374.56)
ensure_json_file(state_strategies, [])
ensure_json_file(state_templates, [])
ensure_json_file(state_rate_limit, {"last_call_timestamp": 0, "calls_count": 0})
ensure_int_file(state_start_time, int(time.time()))
PY

    log "INFO" "State initialized."
}

# ============================================================================
# EXIT CONDITION CHECKING
# ============================================================================

check_exit_conditions() {
    local elapsed=$(get_elapsed_seconds)
    local best_edge=$(cat "$STATE_CHAMPION")
    local iteration=$(cat "$STATE_ITERATION")

    # Check iteration limit (for testing)
    if [[ $iteration -ge $MAX_ITERATIONS ]]; then
        log "INFO" "Iteration limit reached: $iteration >= $MAX_ITERATIONS"
        return 0  # Exit
    fi

    # Check time limit
    if [[ $elapsed -ge $MAX_RUNTIME_SECONDS ]]; then
        log "INFO" "Time limit reached: $(format_duration $elapsed) >= $(format_duration $MAX_RUNTIME_SECONDS)"
        return 0  # Exit
    fi

    # Check performance target
    if float_ge "$best_edge" "$COMPETITIVE_EDGE"; then
        log "INFO" "🎉 Competitive edge achieved: $best_edge >= $COMPETITIVE_EDGE"
        return 0  # Exit
    fi

    return 1  # Continue
}

# ============================================================================
# RATE LIMITING
# ============================================================================

rate_limit_wait() {
    # Enforce minimum 2-second delay between API calls and update tracker atomically.
    "$VENV_PY" - "$STATE_RATE_LIMIT" <<'PY'
import json
import os
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
min_delay = 2
now = int(time.time())

try:
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise TypeError("rate limit state must be object")
except Exception:
    data = {"last_call_timestamp": 0, "calls_count": 0}

last_call = int(data.get("last_call_timestamp") or 0)
elapsed = now - last_call
if elapsed < min_delay:
    time.sleep(min_delay - elapsed)

now = int(time.time())
data["last_call_timestamp"] = now
data["calls_count"] = int(data.get("calls_count") or 0) + 1

tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(json.dumps(data))
os.replace(tmp, path)
PY
}

# ============================================================================
# CODEX INVOCATION
# ============================================================================

invoke_codex_generator() {
    local iteration="$1"
    local prompt_path="$2"
    local codex_jsonl_path="$3"
    local codex_stderr_path="$4"
    local codex_last_msg_path="$5"

    rate_limit_wait

    log "INFO" "Invoking Codex for strategy generation..."

    # Check if codex CLI is available
    if ! command -v codex &> /dev/null; then
        log "ERROR" "Codex CLI not found. Please ensure 'codex' is in your PATH."
        return 1
    fi

    # Ensure debug artifacts exist even on failure.
    : > "$codex_jsonl_path"
    : > "$codex_stderr_path"
    rm -f "$codex_last_msg_path" 2>/dev/null || true

    # Invoke Codex, feeding the prompt via stdin and capturing the final assistant
    # message via --output-last-message.
    # Allow full read-write access so Codex can write strategies and run tests.
    # CRITICAL: Add timeout to prevent iteration from running indefinitely.
    local codex_ok=1
    local timeout_minutes="${CODEX_TIMEOUT_MINUTES:-50}"  # 50 minute default per iteration

    if [[ -n "$CODEX_MODEL" ]]; then
        timeout "${timeout_minutes}m" codex exec \
            --json \
            --config "max_output_tokens=$CODEX_MAX_OUTPUT_TOKENS" \
            --output-last-message "$codex_last_msg_path" \
            --model "$CODEX_MODEL" \
            - < "$prompt_path" > "$codex_jsonl_path" 2> "$codex_stderr_path" && codex_ok=0 || codex_ok=$?
    else
        timeout "${timeout_minutes}m" codex exec \
            --json \
            --config "max_output_tokens=$CODEX_MAX_OUTPUT_TOKENS" \
            --output-last-message "$codex_last_msg_path" \
            - < "$prompt_path" > "$codex_jsonl_path" 2> "$codex_stderr_path" && codex_ok=0 || codex_ok=$?
    fi

    if [[ "$codex_ok" -eq 0 ]]; then
        if [[ ! -s "$codex_last_msg_path" ]]; then
            log "ERROR" "Codex completed but last-message file is missing/empty: $codex_last_msg_path"
            return 1
        fi
        log "INFO" "Codex invocation successful (last message captured)"
        return 0
    fi

    log "ERROR" "Codex invocation failed with code $codex_ok"
    return 1
}

# ============================================================================
# STRATEGY LOGGING (source of truth for Phase 7)
# ============================================================================

append_strategies_log_entry() {
    local iteration="$1"
    local status="$2"              # ok | prompt_failed | codex_failed | extract_failed | test_failed
    local error_stage="$3"         # prompt | codex | extract | test | (empty)
    local error_message="$4"       # short string or empty
    local prompt_path="$5"
    local codex_jsonl_path="$6"
    local codex_stderr_path="$7"
    local codex_last_msg_path="$8"
    local strategy_path="$9"
    local metadata_path="${10}"
    local result_path="${11}"

    "$VENV_PY" - "$STATE_STRATEGIES" "$iteration" "$status" "$error_stage" "$error_message" \
        "$prompt_path" "$codex_jsonl_path" "$codex_stderr_path" "$codex_last_msg_path" \
        "$strategy_path" "$metadata_path" "$result_path" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    strategies_log_path,
    iteration,
    status,
    error_stage,
    error_message,
    prompt_path,
    codex_jsonl_path,
    codex_stderr_path,
    codex_last_message_path,
    strategy_path,
    metadata_path,
    result_path,
) = sys.argv[1:13]

iteration_i = int(iteration)
log_path = Path(strategies_log_path)

def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

def load_json(path: Path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return None

result = load_json(Path(result_path)) if Path(result_path).exists() else None
metadata = load_json(Path(metadata_path)) if Path(metadata_path).exists() else None

# Derive fields (prefer result, then metadata, then defaults)
strategy_name = None
final_edge = None
metrics = {"edge_10": None, "edge_100": None, "edge_1000": None}
timestamp = None
git_sha = None
git_dirty = None

if isinstance(result, dict):
    strategy_name = result.get("strategy_name") or strategy_name
    timestamp = result.get("timestamp") or timestamp
    final_edge = result.get("final_edge", None)
    git_sha = result.get("git_sha") or git_sha
    git_dirty = result.get("git_dirty") if "git_dirty" in result else git_dirty
    testing = result.get("testing", {}) if isinstance(result.get("testing", {}), dict) else {}
    metrics["edge_10"] = testing.get("edge_10", None)
    metrics["edge_100"] = testing.get("edge_100", None)
    metrics["edge_1000"] = testing.get("edge_1000", None)

if isinstance(metadata, dict):
    strategy_name = metadata.get("name") or strategy_name

if not timestamp:
    timestamp = utc_now_iso()

if strategy_name is None:
    strategy_name = "Unknown"

# Normalize hypothesis_ids as array
hypothesis_ids = []
slots_used = None
key_innovation = None
expected_edge_range = None
if isinstance(metadata, dict):
    raw = metadata.get("hypothesis_ids", [])
    if isinstance(raw, list):
        hypothesis_ids = [str(x) for x in raw]
    if "slots_used" in metadata:
        slots_used = metadata.get("slots_used")
    if "key_innovation" in metadata:
        key_innovation = metadata.get("key_innovation")
    if "expected_edge_range" in metadata:
        expected_edge_range = metadata.get("expected_edge_range")

entry = {
    "iteration": iteration_i,
    "status": status,
    "timestamp": timestamp,
    "final_edge": final_edge if status == "ok" else None,
    "strategy_name": strategy_name,
    "hypothesis_ids": hypothesis_ids,
    "git_sha": git_sha,
    "git_dirty": git_dirty,
    "slots_used": slots_used,
    "key_innovation": key_innovation,
    "expected_edge_range": expected_edge_range,
    "artifact_paths": {
        "prompt_path": prompt_path,
        "codex_jsonl_path": codex_jsonl_path,
        "codex_stderr_path": codex_stderr_path,
        "codex_last_message_path": codex_last_message_path,
        "strategy_path": strategy_path,
        "metadata_path": metadata_path,
        "result_path": result_path,
    },
    "metrics": metrics,
    "error": {
        "stage": (error_stage or None) if status != "ok" else None,
        "message": (error_message or None) if status != "ok" else None,
    },
}

try:
    existing = json.loads(log_path.read_text())
    if not isinstance(existing, list):
        existing = []
except Exception:
    existing = []

existing.append(entry)

tmp = log_path.with_suffix(log_path.suffix + ".tmp")
tmp.write_text(json.dumps(existing, indent=2))
os.replace(tmp, log_path)
PY
}

should_extract_template() {
    local iteration="$1"
    local final_edge="$2"
    local best_edge="$3"
    local is_new_champion="$4" # 1 or 0

    "$VENV_PY" - "$STATE_STRATEGIES" "$iteration" "$final_edge" "$best_edge" "$is_new_champion" \
        "$TEMPLATE_MIN_EDGE" "$TEMPLATE_WITHIN_BEST" "$TEMPLATE_TOP_K" <<'PY'
import json
import sys
from pathlib import Path

(
    strategies_log_path,
    iteration,
    final_edge,
    best_edge,
    is_new_champion,
    min_edge,
    within_best,
    top_k,
) = sys.argv[1:9]

iteration_i = int(iteration)
final_edge_f = float(final_edge)
best_edge_f = float(best_edge)
is_new = str(is_new_champion) == "1"
min_edge_f = float(min_edge)
within_f = float(within_best)
top_k_i = int(float(top_k))

try:
    data = json.loads(Path(strategies_log_path).read_text())
    if not isinstance(data, list):
        data = []
except Exception:
    data = []

def ok_edge(entry):
    if not isinstance(entry, dict):
        return None
    if entry.get("status") != "ok":
        return None
    v = entry.get("final_edge", None)
    if v is None:
        return None
    try:
        return float(v)
    except Exception:
        return None

# (A) Always extract on new champion
if is_new:
    raise SystemExit(0)

# (B) Within best band + above min
if final_edge_f >= min_edge_f and (best_edge_f - final_edge_f) <= within_f:
    raise SystemExit(0)

# (C) In current top-K among ok entries
edges = []
for e in data:
    v = ok_edge(e)
    if v is None:
        continue
    edges.append((v, e.get("iteration")))
edges.sort(key=lambda t: t[0], reverse=True)
top_iters = {it for _, it in edges[:top_k_i]}
raise SystemExit(0 if iteration_i in top_iters else 1)
PY
}

# ============================================================================
# MAIN LOOP
# ============================================================================

main_loop() {
    log "INFO" "======================================"
    log "INFO" "Phase 7: AI-Powered Strategy Exploration"
    log "INFO" "======================================"
    log "INFO" "Target: Edge > $COMPETITIVE_EDGE OR $(format_duration $MAX_RUNTIME_SECONDS)"
    log "INFO" "Current best: $(cat "$STATE_CHAMPION")"
    log "INFO" ""

    while true; do
        # Check exit conditions first
        if check_exit_conditions; then
            break
        fi

        # Increment iteration
        local iteration=$(cat "$STATE_ITERATION")
        iteration=$((iteration + 1))
        echo "$iteration" > "$STATE_ITERATION"

        local elapsed=$(get_elapsed_seconds)
        local remaining=$(get_remaining_seconds)

        log "INFO" "=== Iteration $iteration ==="
        log "INFO" "Elapsed: $(format_duration $elapsed) / Remaining: $(format_duration $remaining)"

        # === Iteration artifact paths ===
        local prompt_path="$PHASE7_PROMPTS_DIR/iteration_${iteration}_prompt.md"
        local codex_jsonl_path="$PHASE7_STATE_DIR/iteration_${iteration}_codex.jsonl"
        local codex_stderr_path="$PHASE7_STATE_DIR/iteration_${iteration}_codex.stderr"
        local codex_last_msg_path="$PHASE7_STATE_DIR/iteration_${iteration}_last_message.md"
        local strategy_path="$PHASE7_GENERATED_DIR/phase7_strategy_${iteration}.sol"
        local metadata_path="$PHASE7_GENERATED_DIR/phase7_strategy_${iteration}.json"
        local result_path="$PHASE7_STATE_DIR/iteration_${iteration}_result.json"

        local status="ok"
        local error_stage=""
        local error_message=""
        local final_edge=""
        local is_new_champion="0"

        # === STEP 1: Generate prompt context ===
        log "INFO" "Building prompt..."
        if ! "$VENV_PY" scripts/amm-phase7-prompt-builder.py \
            --iteration "$iteration" \
            --state-dir "$PHASE7_STATE_DIR" \
            --output "$prompt_path" \
            --target-edge "$COMPETITIVE_EDGE" \
            --max-runtime-seconds "$MAX_RUNTIME_SECONDS"; then
            log "ERROR" "Failed to build prompt"
            status="prompt_failed"
            error_stage="prompt"
            error_message="prompt builder failed"
            append_strategies_log_entry "$iteration" "$status" "$error_stage" "$error_message" \
                "$prompt_path" "$codex_jsonl_path" "$codex_stderr_path" "$codex_last_msg_path" \
                "$strategy_path" "$metadata_path" "$result_path"
            continue
        fi

        # === STEP 2: Invoke Codex to generate strategy ===
        if ! invoke_codex_generator "$iteration" "$prompt_path" "$codex_jsonl_path" "$codex_stderr_path" "$codex_last_msg_path"; then
            log "WARN" "Codex invocation failed, continuing to next iteration"
            status="codex_failed"
            error_stage="codex"
            error_message="$("$VENV_PY" - "$codex_stderr_path" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
if not p.exists():
    print("codex failed (no stderr)")
    raise SystemExit(0)
lines=p.read_text(errors="ignore").strip().splitlines()
print((lines[-1] if lines else "codex failed").strip()[:300])
PY
)"
            append_strategies_log_entry "$iteration" "$status" "$error_stage" "$error_message" \
                "$prompt_path" "$codex_jsonl_path" "$codex_stderr_path" "$codex_last_msg_path" \
                "$strategy_path" "$metadata_path" "$result_path"
            continue
        fi

        # === STEP 3: Extract strategy code from Codex response ===
        log "INFO" "Extracting strategy code..."
        if ! "$VENV_PY" scripts/amm-phase7-code-extractor.py \
            --codex-response "$codex_last_msg_path" \
            --output "$strategy_path"; then
            log "WARN" "Failed to extract valid strategy code"
            status="extract_failed"
            error_stage="extract"
            error_message="code extraction/validation failed"
            append_strategies_log_entry "$iteration" "$status" "$error_stage" "$error_message" \
                "$prompt_path" "$codex_jsonl_path" "$codex_stderr_path" "$codex_last_msg_path" \
                "$strategy_path" "$metadata_path" "$result_path"
            continue
        fi

        # === STEP 4: Test strategy through pipeline ===
        log "INFO" "Testing strategy..."
        if ! "$VENV_PY" scripts/amm-test-pipeline.py \
            "$strategy_path" \
            --output "$result_path"; then
            log "WARN" "Strategy failed testing"
            status="test_failed"
            error_stage="test"
            error_message="amm-test-pipeline failed"
            append_strategies_log_entry "$iteration" "$status" "$error_stage" "$error_message" \
                "$prompt_path" "$codex_jsonl_path" "$codex_stderr_path" "$codex_last_msg_path" \
                "$strategy_path" "$metadata_path" "$result_path"
            continue
        fi

        # === STEP 5: Extract edge score ===
        final_edge="$("$VENV_PY" - "$result_path" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1])
data=json.loads(p.read_text())
v=data.get("final_edge", None)
print(v if v is not None else "")
PY
)"
        log "INFO" "  → Final Edge: $final_edge"

        # === STEP 6: Record to learning engine ===
        "$VENV_PY" scripts/amm-learning-engine.py record \
            --result "$result_path" \
            --state-dir "$PHASE7_STATE_DIR" 2>/dev/null || true

        # === STEP 7: Check if new champion ===
        local current_best=$(cat "$STATE_CHAMPION")
        if float_gt "$final_edge" "$current_best"; then
            log "INFO" "  🏆 NEW CHAMPION! $final_edge beats $current_best"
            echo "$final_edge" > "$STATE_CHAMPION"
            cp "$strategy_path" "$PHASE7_STATE_DIR/.best_strategy.sol"
            is_new_champion="1"
        fi

        # Append Phase 7 source-of-truth log entry (exactly one per iteration).
        append_strategies_log_entry "$iteration" "ok" "" "" \
            "$prompt_path" "$codex_jsonl_path" "$codex_stderr_path" "$codex_last_msg_path" \
            "$strategy_path" "$metadata_path" "$result_path"

        # === STEP 8: Extract template (reachable rules; idempotent per iteration) ===
        local template_sentinel="$PHASE7_STATE_DIR/iteration_${iteration}_template_extracted.ok"
        if [[ -f "$template_sentinel" ]]; then
            log "INFO" "  📝 Template already extracted for iteration $iteration (skipping)"
        else
            local best_edge_now
            best_edge_now="$(cat "$STATE_CHAMPION")"
            if should_extract_template "$iteration" "$final_edge" "$best_edge_now" "$is_new_champion"; then
                log "INFO" "  📝 Extracting template (edge=$final_edge; best=$best_edge_now; new_champion=$is_new_champion)"
                if "$VENV_PY" scripts/amm-phase7-template-extractor.py \
                    --strategy "$strategy_path" \
                    --result "$result_path" \
                    --output-dir "$PHASE7_TEMPLATES_DIR"; then
                    : > "$template_sentinel"
                    log "INFO" "  Template extracted successfully"
                else
                    log "WARN" "  Template extraction failed"
                fi
            fi
        fi

        log "INFO" "Iteration $iteration complete. Current best: $(cat "$STATE_CHAMPION")"
        log "INFO" ""

        # Brief pause between iterations
        sleep 2
    done

    # Final summary
    final_summary
}

# ============================================================================
# FINAL SUMMARY
# ============================================================================

final_summary() {
    local total_iterations=$(cat "$STATE_ITERATION")
    local final_best=$(cat "$STATE_CHAMPION")
    local elapsed=$(get_elapsed_seconds)
    local templates_created
    templates_created="$("$VENV_PY" - "$STATE_TEMPLATES" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1])
try:
    data=json.loads(p.read_text())
    print(len(data) if isinstance(data, list) else 0)
except Exception:
    print(0)
PY
)"

    log "INFO" ""
    log "INFO" "======================================"
    log "INFO" "Phase 7 Complete"
    log "INFO" "======================================"
    log "INFO" "Iterations: $total_iterations"
    log "INFO" "Final Best Edge: $final_best"
    log "INFO" "Templates Created: $templates_created"
    log "INFO" "Runtime: $(format_duration $elapsed)"
    log "INFO" "======================================"

    # Generate detailed report
    log "INFO" "Generating final report..."
    if "$VENV_PY" scripts/amm-phase7-report-generator.py \
        --state-dir "$PHASE7_STATE_DIR" \
        --output ".ralph-amm/phase7/PHASE7_FINAL_REPORT.md"; then
        log "INFO" "Report generated: .ralph-amm/phase7/PHASE7_FINAL_REPORT.md"
    else
        log "WARN" "Failed to generate final report"
    fi
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

print_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
    --max-iterations N      Maximum iterations (default: unlimited)
    --max-runtime N         Maximum runtime in seconds (default: 36000 = 10 hours)
    --target-edge N         Target edge to achieve (default: 527)
    --help                  Show this help message

Examples:
    # Run full 10-hour loop
    bash scripts/ralph-amm-phase7.sh

    # Run for 3 iterations (testing)
    bash scripts/ralph-amm-phase7.sh --max-iterations 3

    # Run for 1 hour
    bash scripts/ralph-amm-phase7.sh --max-runtime 3600
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --max-iterations)
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        --max-runtime)
            MAX_RUNTIME_SECONDS="$2"
            shift 2
            ;;
        --target-edge)
            COMPETITIVE_EDGE="$2"
            shift 2
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            log "ERROR" "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# ============================================================================
# ENTRY POINT
# ============================================================================

require_file "$VENV_PY" "create/activate venv_fresh first"
require_file "$AMM_MATCH" "ensure venv_fresh has project installed"
require_cmd codex

init_phase7_state
main_loop

exit 0
