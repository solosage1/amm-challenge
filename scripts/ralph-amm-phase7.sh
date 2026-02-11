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
# Use gpt-5.3-codex model
CODEX_MODEL="${CODEX_MODEL:-gpt-5.3-codex}"
CODEX_MAX_OUTPUT_TOKENS="${CODEX_MAX_OUTPUT_TOKENS:-8000}"
CODEX_TIMEOUT_MINUTES="${CODEX_TIMEOUT_MINUTES:-50}"  # Max time per Codex invocation (increased for full write+test cycles)
CODEX_DISABLE_SHELL_TOOL="${CODEX_DISABLE_SHELL_TOOL:-0}"  # 0=enable shell tools (recommended; avoids "turn.started" stalls)

# Performance targets
COMPETITIVE_EDGE=527

# Pipeline screening/selection knobs
PIPE_SCREEN_SIMS="${PIPE_SCREEN_SIMS:-200}"
PIPE_SCREEN_MIN_EDGE="${PIPE_SCREEN_MIN_EDGE:-375.0}"
PIPE_PREDICTED_DROP="${PIPE_PREDICTED_DROP:--8.2}"
PIPE_PREDICTED_MIN_EDGE="${PIPE_PREDICTED_MIN_EDGE:-500.0}"
ROBUST_FREE_SPREAD="${ROBUST_FREE_SPREAD:-50.0}"
ROBUST_PENALTY_PER_POINT="${ROBUST_PENALTY_PER_POINT:-0.02}"
KNOWLEDGE_GUARDRAIL_EPSILON="${KNOWLEDGE_GUARDRAIL_EPSILON:-0.02}"

# Autonomous opportunity engine (incremental rollout; defaults are safe/OFF)
AUTO_OPP_ENGINE_ENABLED="${AUTO_OPP_ENGINE_ENABLED:-0}"   # 0=disabled (baseline behavior)
AUTO_OPP_SHADOW_ITERS="${AUTO_OPP_SHADOW_ITERS:-20}"      # read-only decision period
AUTO_OPP_CANARY_PCT="${AUTO_OPP_CANARY_PCT:-20}"          # execute on <=20% iterations in canary
AUTO_OPP_WINDOW_SIZE="${AUTO_OPP_WINDOW_SIZE:-20}"        # non-regression window
AUTO_OPP_NO_UPLIFT_EPSILON="${AUTO_OPP_NO_UPLIFT_EPSILON:-0.02}"
AUTO_OPP_NO_UPLIFT_STREAK_THRESHOLD="${AUTO_OPP_NO_UPLIFT_STREAK_THRESHOLD:-3}"
AUTO_OPP_NO_UPLIFT_COOLDOWN_ITERS="${AUTO_OPP_NO_UPLIFT_COOLDOWN_ITERS:-4}"
AUTO_OPP_NOVELTY_LOOKBACK="${AUTO_OPP_NOVELTY_LOOKBACK:-6}"
AUTO_OPP_NOVELTY_PENALTY="${AUTO_OPP_NOVELTY_PENALTY:-1.0}"
AUTO_OPP_EXPLORE_QUOTA_ENABLED="${AUTO_OPP_EXPLORE_QUOTA_ENABLED:-1}"
AUTO_OPP_EXPLORE_LOOKBACK="${AUTO_OPP_EXPLORE_LOOKBACK:-4}"
AUTO_OPP_EXPLORE_REPEAT_CLASSES="${AUTO_OPP_EXPLORE_REPEAT_CLASSES:-undercut_sweep,gating_adaptive}"
AUTO_OPP_EXPLORE_TARGET_CLASSES="${AUTO_OPP_EXPLORE_TARGET_CLASSES:-gamma_formula,asymmetric,ema_smoothing}"
AUTO_OPP_RECORD_GATES_FALLBACK="${AUTO_OPP_RECORD_GATES_FALLBACK:-1}"
AUTO_OPP_SUBFAMILY_OVERRIDE="${AUTO_OPP_SUBFAMILY_OVERRIDE:-}"
AUTO_OPP_BREAKTHROUGH_TIE_EPSILON="${AUTO_OPP_BREAKTHROUGH_TIE_EPSILON:-0.10}"
AUTO_OPP_SEVERE_SUBFAMILY_FAILURE_THRESHOLD="${AUTO_OPP_SEVERE_SUBFAMILY_FAILURE_THRESHOLD:-2}"
AUTO_OPP_GATES_FALLBACK_POLLS="${AUTO_OPP_GATES_FALLBACK_POLLS:-8}"
AUTO_OPP_GATES_FALLBACK_POLL_SECONDS="${AUTO_OPP_GATES_FALLBACK_POLL_SECONDS:-0.25}"

# Execution gates (generic threshold-driven safety/efficiency controls)
EXEC_GATES_ENABLED="${EXEC_GATES_ENABLED:-1}"                       # 1=enable real-time/batch/promotion gates
GATE_EARLY_ABORT_ENABLED="${GATE_EARLY_ABORT_ENABLED:-1}"           # 1=kill codex if first N runs all below threshold
GATE_EARLY_MIN_RESULTS="${GATE_EARLY_MIN_RESULTS:-4}"               # first N authoritative runs for early-abort decision
GATE_EARLY_DELTA="${GATE_EARLY_DELTA:-0.8}"                         # threshold: champion - delta
GATE_BATCH_FAIL_DELTA="${GATE_BATCH_FAIL_DELTA:-0.5}"               # batch fail if batch best < champion - delta
GATE_PROMOTION_CONFIRMATIONS="${GATE_PROMOTION_CONFIRMATIONS:-3}"   # confirmations required before promotion
GATE_MIN_SIMS="${GATE_MIN_SIMS:-1000}"                              # authoritative sim cutoff for gate sampling
GATE_MONITOR_POLL_SECONDS="${GATE_MONITOR_POLL_SECONDS:-1.0}"       # real-time monitor poll cadence

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
STATE_CHAMPION_SCORE="$PHASE7_STATE_DIR/.best_score.txt"
STATE_STRATEGIES="$PHASE7_STATE_DIR/.strategies_log.json"
STATE_TEMPLATES="$PHASE7_STATE_DIR/.templates_created.json"
STATE_RATE_LIMIT="$PHASE7_STATE_DIR/.rate_limit_tracker.json"
STATE_START_TIME="$PHASE7_STATE_DIR/.start_timestamp.txt"
STATE_OPP_HISTORY="$PHASE7_STATE_DIR/.opportunity_history.json"
STATE_OPP_PRIORS="$PHASE7_STATE_DIR/.opportunity_priors.json"
STATE_OPP_ROLLOUT="$PHASE7_STATE_DIR/.autoloop_rollout_state.json"
STATE_OPP_ACTIVE_PLAN="$PHASE7_STATE_DIR/.autoplan_active.json"
STATE_EXEC_GATES="$PHASE7_STATE_DIR/.execution_gates.json"
STATE_PROMO_CONFIRMATIONS="$PHASE7_STATE_DIR/.promotion_confirmations.json"

# Shared per-iteration gate abort reason set by invoke_codex_generator.
LAST_GATE_ABORT_REASON=""

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
    "$VENV_PY" - "$STATE_ITERATION" "$STATE_CHAMPION" "$STATE_CHAMPION_SCORE" "$STATE_STRATEGIES" "$STATE_TEMPLATES" \
        "$STATE_RATE_LIMIT" "$STATE_START_TIME" "$STATE_OPP_HISTORY" "$STATE_OPP_PRIORS" "$STATE_OPP_ROLLOUT" \
        "$STATE_OPP_ACTIVE_PLAN" "$STATE_EXEC_GATES" "$STATE_PROMO_CONFIRMATIONS" \
        <<'PY'
import json
import os
from pathlib import Path
import sys
import time

state_iteration = Path(sys.argv[1])
state_champion = Path(sys.argv[2])
state_champion_score = Path(sys.argv[3])
state_strategies = Path(sys.argv[4])
state_templates = Path(sys.argv[5])
state_rate_limit = Path(sys.argv[6])
state_start_time = Path(sys.argv[7])
state_opp_history = Path(sys.argv[8])
state_opp_priors = Path(sys.argv[9])
state_opp_rollout = Path(sys.argv[10])
state_opp_active_plan = Path(sys.argv[11])
state_exec_gates = Path(sys.argv[12])
state_promo_confirmations = Path(sys.argv[13])

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
ensure_float_file(state_champion_score, 374.56)
ensure_json_file(state_strategies, [])
ensure_json_file(state_templates, [])
ensure_json_file(state_rate_limit, {"last_call_timestamp": 0, "calls_count": 0})
ensure_int_file(state_start_time, int(time.time()))
ensure_json_file(state_opp_history, [])
ensure_json_file(state_opp_priors, {})
ensure_json_file(state_opp_rollout, {
    "schema_version": "1.0",
    "feature_enabled": False,
    "started_iteration": None,
    "mode": "off",
    "shadow_completed": 0,
    "canary_executed": 0,
    "baseline_metrics": None,
    "non_regression_fail_streak": 0,
    "rollback_triggered": False,
    "rollback_reason": None,
    "last_updated": None
})
ensure_json_file(state_opp_active_plan, {})
ensure_json_file(state_exec_gates, {
    "schema_version": "1.0",
    "iterations": {},
    "last_updated": None
})
ensure_json_file(state_promo_confirmations, {
    "schema_version": "1.0",
    "candidates": {},
    "last_updated": None
})
PY

    log "INFO" "State initialized."

    # Harvest any existing session data on startup
    log "INFO" "Harvesting existing session data..."
    "$VENV_PY" scripts/amm-phase7-session-harvester.py \
        --all --state-dir "$PHASE7_STATE_DIR" 2>/dev/null || true

    # Fail fast if canonical 1000-sim knowledge is inconsistent.
    if ! run_knowledge_guardrail; then
        die "Knowledge context guardrail failed after startup harvest"
    fi
}

run_knowledge_guardrail() {
    "$VENV_PY" scripts/amm-phase7-knowledge-check.py \
        --state-dir "$PHASE7_STATE_DIR" \
        --epsilon "$KNOWLEDGE_GUARDRAIL_EPSILON"
}

run_opportunity_evaluate() {
    local iteration="$1"
    local ranking_path="$2"
    local plan_path="$3"

    local enabled_arg=()
    if [[ "${AUTO_OPP_ENGINE_ENABLED}" == "1" ]]; then
        enabled_arg+=(--enabled)
    fi
    local explore_quota_arg=()
    if [[ "${AUTO_OPP_EXPLORE_QUOTA_ENABLED}" == "1" ]]; then
        explore_quota_arg+=(--explore-quota-enable)
    else
        explore_quota_arg+=(--explore-quota-disable)
    fi
    local subfamily_override_arg=()
    if [[ -n "${AUTO_OPP_SUBFAMILY_OVERRIDE}" ]]; then
        subfamily_override_arg+=(--subfamily-override "$AUTO_OPP_SUBFAMILY_OVERRIDE")
    fi

    "$VENV_PY" scripts/amm-phase7-opportunity-engine.py evaluate \
        --state-dir "$PHASE7_STATE_DIR" \
        --iteration "$iteration" \
        --target-edge "$COMPETITIVE_EDGE" \
        --shadow-iters "$AUTO_OPP_SHADOW_ITERS" \
        --canary-pct "$AUTO_OPP_CANARY_PCT" \
        --window-size "$AUTO_OPP_WINDOW_SIZE" \
        --no-uplift-epsilon "$AUTO_OPP_NO_UPLIFT_EPSILON" \
        --no-uplift-streak-threshold "$AUTO_OPP_NO_UPLIFT_STREAK_THRESHOLD" \
        --no-uplift-cooldown-iters "$AUTO_OPP_NO_UPLIFT_COOLDOWN_ITERS" \
        --novelty-lookback "$AUTO_OPP_NOVELTY_LOOKBACK" \
        --novelty-penalty "$AUTO_OPP_NOVELTY_PENALTY" \
        --explore-lookback "$AUTO_OPP_EXPLORE_LOOKBACK" \
        --explore-repeat-classes "$AUTO_OPP_EXPLORE_REPEAT_CLASSES" \
        --explore-target-classes "$AUTO_OPP_EXPLORE_TARGET_CLASSES" \
        --breakthrough-tie-epsilon "$AUTO_OPP_BREAKTHROUGH_TIE_EPSILON" \
        --severe-subfamily-failure-threshold "$AUTO_OPP_SEVERE_SUBFAMILY_FAILURE_THRESHOLD" \
        --ranking-out "$ranking_path" \
        --plan-out "$plan_path" \
        ${subfamily_override_arg[@]+"${subfamily_override_arg[@]}"} \
        ${explore_quota_arg[@]+"${explore_quota_arg[@]}"} \
        ${enabled_arg[@]+"${enabled_arg[@]}"}
}

plan_field() {
    local plan_path="$1"
    local field="$2"
    "$VENV_PY" - "$plan_path" "$field" <<'PY'
import json
import sys
from pathlib import Path

plan_path = Path(sys.argv[1])
field = sys.argv[2]
if not plan_path.exists():
    print("")
    raise SystemExit(0)
try:
    data = json.loads(plan_path.read_text())
except Exception:
    print("")
    raise SystemExit(0)
value = data.get(field, "")
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
}

record_opportunity_outcome() {
    local iteration="$1"
    local status="$2"
    local result_path="$3"
    local plan_path="$4"

    [[ -f "$plan_path" ]] || return 0
    local gates_fallback_arg=()
    if [[ "${AUTO_OPP_RECORD_GATES_FALLBACK}" == "1" ]]; then
        gates_fallback_arg+=(--use-gate-family-fallback)
    else
        gates_fallback_arg+=(--disable-gate-family-fallback)
    fi
    "$VENV_PY" scripts/amm-phase7-opportunity-engine.py record \
        --state-dir "$PHASE7_STATE_DIR" \
        --iteration "$iteration" \
        --status "$status" \
        --plan-file "$plan_path" \
        --result-file "$result_path" \
        --no-uplift-epsilon "$AUTO_OPP_NO_UPLIFT_EPSILON" \
        --no-uplift-streak-threshold "$AUTO_OPP_NO_UPLIFT_STREAK_THRESHOLD" \
        --no-uplift-cooldown-iters "$AUTO_OPP_NO_UPLIFT_COOLDOWN_ITERS" \
        --breakthrough-tie-epsilon "$AUTO_OPP_BREAKTHROUGH_TIE_EPSILON" \
        --severe-subfamily-failure-threshold "$AUTO_OPP_SEVERE_SUBFAMILY_FAILURE_THRESHOLD" \
        --gates-fallback-polls "$AUTO_OPP_GATES_FALLBACK_POLLS" \
        --gates-fallback-poll-seconds "$AUTO_OPP_GATES_FALLBACK_POLL_SECONDS" \
        --gates-state-file "$STATE_EXEC_GATES" \
        ${gates_fallback_arg[@]+"${gates_fallback_arg[@]}"} >/dev/null 2>&1 || true
}

gate_iteration_field() {
    local iteration="$1"
    local field="$2"
    "$VENV_PY" - "$STATE_EXEC_GATES" "$iteration" "$field" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
iteration = str(int(float(sys.argv[2])))
field = sys.argv[3]

if not state_path.exists():
    print("")
    raise SystemExit(0)
try:
    data = json.loads(state_path.read_text())
except Exception:
    print("")
    raise SystemExit(0)

it = (((data if isinstance(data, dict) else {}).get("iterations") or {}).get(iteration))
if not isinstance(it, dict):
    print("")
    raise SystemExit(0)

cur = it
for part in field.split("."):
    if not isinstance(cur, dict) or part not in cur:
        print("")
        raise SystemExit(0)
    cur = cur[part]

if isinstance(cur, bool):
    print("true" if cur else "false")
elif cur is None:
    print("")
else:
    print(cur)
PY
}

set_gate_iteration_promotion_status() {
    local iteration="$1"
    local blocked="$2"
    local reason="$3"
    local confirmations="$4"
    local required="$5"

    "$VENV_PY" - "$STATE_EXEC_GATES" "$iteration" "$blocked" "$reason" "$confirmations" "$required" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

state_path = Path(sys.argv[1])
iteration = str(int(float(sys.argv[2])))
blocked = sys.argv[3].strip().lower() == "true"
reason = sys.argv[4]
confirmations = int(float(sys.argv[5] or 0))
required = int(float(sys.argv[6] or 0))

def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

try:
    data = json.loads(state_path.read_text()) if state_path.exists() else {}
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
data.setdefault("schema_version", "1.0")
data.setdefault("iterations", {})
it = data["iterations"].setdefault(iteration, {"iteration": int(iteration)})
if not isinstance(it, dict):
    it = {"iteration": int(iteration)}
    data["iterations"][iteration] = it
promo = it.setdefault("promotion_gate", {})
promo["blocked"] = blocked
promo["reason"] = reason or None
promo["confirmations"] = confirmations
promo["required"] = required
promo["updated_at"] = now()
it["updated_at"] = now()
data["last_updated"] = now()
tmp = state_path.with_suffix(state_path.suffix + ".tmp")
tmp.write_text(json.dumps(data, indent=2))
os.replace(tmp, state_path)
PY
}

record_promotion_confirmation() {
    local iteration="$1"
    local strategy_name="$2"
    local strategy_path="$3"
    local final_edge="$4"
    local effective_score="$5"

    "$VENV_PY" - "$STATE_PROMO_CONFIRMATIONS" "$iteration" "$strategy_name" "$strategy_path" "$final_edge" "$effective_score" <<'PY'
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

state_path = Path(sys.argv[1])
iteration = int(float(sys.argv[2]))
strategy_name = sys.argv[3]
strategy_path = Path(sys.argv[4])
final_edge = float(sys.argv[5])
effective_score = float(sys.argv[6])

def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

if strategy_path.exists():
    digest = hashlib.sha256(strategy_path.read_bytes()).hexdigest()
else:
    digest = f"missing:{strategy_name}:{iteration}"

try:
    data = json.loads(state_path.read_text()) if state_path.exists() else {}
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
data.setdefault("schema_version", "1.0")
data.setdefault("candidates", {})
candidates = data["candidates"]
rec = candidates.setdefault(digest, {
    "strategy_name": strategy_name,
    "strategy_path": str(strategy_path),
    "first_seen_iteration": iteration,
    "confirmations": [],
    "best_effective_score": effective_score,
    "best_edge": final_edge,
})
if not isinstance(rec, dict):
    rec = {
        "strategy_name": strategy_name,
        "strategy_path": str(strategy_path),
        "first_seen_iteration": iteration,
        "confirmations": [],
        "best_effective_score": effective_score,
        "best_edge": final_edge,
    }
    candidates[digest] = rec

confs = rec.setdefault("confirmations", [])
seen_iters = {int(c.get("iteration", -1)) for c in confs if isinstance(c, dict)}
if iteration not in seen_iters:
    confs.append({
        "iteration": iteration,
        "timestamp": now(),
        "final_edge": final_edge,
        "effective_score": effective_score,
    })
rec["strategy_name"] = strategy_name
rec["strategy_path"] = str(strategy_path)
rec["best_effective_score"] = max(float(rec.get("best_effective_score", effective_score)), effective_score)
rec["best_edge"] = max(float(rec.get("best_edge", final_edge)), final_edge)
rec["last_seen_iteration"] = iteration
rec["updated_at"] = now()
data["last_updated"] = now()

tmp = state_path.with_suffix(state_path.suffix + ".tmp")
tmp.write_text(json.dumps(data, indent=2))
os.replace(tmp, state_path)
print(len(rec.get("confirmations", [])))
PY
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

    # === START LIVE EXTRACTOR (checkpoints every 5 minutes) ===
    local checkpoint_dir="$PHASE7_STATE_DIR/checkpoints_iter${iteration}"
    mkdir -p "$checkpoint_dir"
    local extractor_pid=""

    if [[ -x "scripts/amm-phase7-live-extractor.sh" ]]; then
        bash scripts/amm-phase7-live-extractor.sh \
            "$codex_jsonl_path" "$checkpoint_dir" 300 \
            >> "$PHASE7_STATE_DIR/live_extractor.log" 2>&1 &
        extractor_pid=$!
        log "INFO" "  Started live extractor (PID $extractor_pid, checkpoints to $checkpoint_dir)"
    fi

    # Invoke Codex, feeding the prompt via stdin and capturing the final assistant
    # message via --output-last-message.
    # Allow full read-write access so Codex can write strategies and run tests.
    # CRITICAL: Add timeout to prevent iteration from running indefinitely.
    local codex_ok=1
    local timeout_minutes="${CODEX_TIMEOUT_MINUTES:-40}"  # 40 minute default (down from 50 for graceful termination)
    local codex_pid=""
    local gate_monitor_pid=""
    local champion_baseline
    champion_baseline="$(cat "$STATE_CHAMPION" 2>/dev/null || echo "0")"
    LAST_GATE_ABORT_REASON=""
    local par_sim_champion="0"
    local par_sim_early_n="0"
    if [[ "${EXEC_GATES_ENABLED}" == "1" ]]; then
        par_sim_champion="$champion_baseline"
        if [[ "${GATE_EARLY_ABORT_ENABLED}" == "1" ]]; then
            par_sim_early_n="$GATE_EARLY_MIN_RESULTS"
        fi
    fi

    # Shell tool is enabled by default. Set CODEX_DISABLE_SHELL_TOOL=1 (or pass --disable-shell-tool)
    # to prevent Codex from running local commands.
    local codex_disable_args=()
    if [[ "${CODEX_DISABLE_SHELL_TOOL}" == "1" ]]; then
        codex_disable_args+=(--disable shell_tool)
    fi

    if [[ -n "$CODEX_MODEL" ]]; then
        PAR_SIM_CHAMPION="$par_sim_champion" \
        PAR_SIM_EARLY_N="$par_sim_early_n" \
        PAR_SIM_EARLY_DELTA="$GATE_EARLY_DELTA" \
        PAR_SIM_BATCH_DELTA="$GATE_BATCH_FAIL_DELTA" \
        timeout "${timeout_minutes}m" codex exec \
            --json \
            --config "max_output_tokens=$CODEX_MAX_OUTPUT_TOKENS" \
            --output-last-message "$codex_last_msg_path" \
            ${codex_disable_args[@]+"${codex_disable_args[@]}"} \
            --model "$CODEX_MODEL" \
            - < "$prompt_path" > "$codex_jsonl_path" 2> "$codex_stderr_path" &
    else
        PAR_SIM_CHAMPION="$par_sim_champion" \
        PAR_SIM_EARLY_N="$par_sim_early_n" \
        PAR_SIM_EARLY_DELTA="$GATE_EARLY_DELTA" \
        PAR_SIM_BATCH_DELTA="$GATE_BATCH_FAIL_DELTA" \
        timeout "${timeout_minutes}m" codex exec \
            --json \
            --config "max_output_tokens=$CODEX_MAX_OUTPUT_TOKENS" \
            --output-last-message "$codex_last_msg_path" \
            ${codex_disable_args[@]+"${codex_disable_args[@]}"} \
            - < "$prompt_path" > "$codex_jsonl_path" 2> "$codex_stderr_path" &
    fi
    codex_pid=$!

    if [[ "${EXEC_GATES_ENABLED}" == "1" && -f "scripts/amm-phase7-gate-monitor.py" ]]; then
        local gate_monitor_args=(
            --jsonl "$codex_jsonl_path"
            --state-file "$STATE_EXEC_GATES"
            --iteration "$iteration"
            --codex-pid "$codex_pid"
            --champion-baseline "$champion_baseline"
            --min-sims "$GATE_MIN_SIMS"
            --early-min-results "$GATE_EARLY_MIN_RESULTS"
            --early-delta "$GATE_EARLY_DELTA"
            --batch-fail-delta "$GATE_BATCH_FAIL_DELTA"
            --poll-seconds "$GATE_MONITOR_POLL_SECONDS"
        )
        if [[ "${GATE_EARLY_ABORT_ENABLED}" == "1" ]]; then
            gate_monitor_args+=(--early-enabled)
        fi
        "$VENV_PY" scripts/amm-phase7-gate-monitor.py \
            ${gate_monitor_args[@]+"${gate_monitor_args[@]}"} \
            >> "$PHASE7_STATE_DIR/gate_monitor.log" 2>&1 &
        gate_monitor_pid=$!
        log "INFO" "  Started execution gate monitor (PID $gate_monitor_pid)"
    fi

    wait "$codex_pid" && codex_ok=0 || codex_ok=$?
    if [[ -n "$gate_monitor_pid" ]]; then
        wait "$gate_monitor_pid" 2>/dev/null || true
    fi

    # === STOP LIVE EXTRACTOR ===
    if [[ -n "$extractor_pid" ]]; then
        kill "$extractor_pid" 2>/dev/null || true
        wait "$extractor_pid" 2>/dev/null || true
        log "INFO" "  Stopped live extractor"
    fi

    if [[ "${EXEC_GATES_ENABLED}" == "1" ]]; then
        local gate_early_triggered
        local gate_early_reason
        local gate_batch_best
        local gate_batch_count
        gate_early_triggered="$(gate_iteration_field "$iteration" "early_abort.triggered")"
        gate_early_reason="$(gate_iteration_field "$iteration" "early_abort.trigger_reason")"
        gate_batch_best="$(gate_iteration_field "$iteration" "batch.best_edge")"
        gate_batch_count="$(gate_iteration_field "$iteration" "batch.count")"
        if [[ "$gate_early_triggered" == "true" ]]; then
            LAST_GATE_ABORT_REASON="${gate_early_reason:-execution gate early-abort triggered}"
            log "WARN" "Execution gate early-abort triggered: ${LAST_GATE_ABORT_REASON}"
        fi
        if [[ -n "$gate_batch_count" ]]; then
            log "INFO" "  Execution gate batch snapshot: count=${gate_batch_count} best=${gate_batch_best:-N/A}"
        fi
    fi

    # === HANDLE TIMEOUT (exit code 124) - RECOVER FROM CHECKPOINT ===
    if [[ "$codex_ok" -eq 124 ]]; then
        log "WARN" "Codex timed out after ${timeout_minutes} minutes"

        # Find most recent checkpoint
        local last_checkpoint
        last_checkpoint=$(ls -1t "$checkpoint_dir"/checkpoint_*.json 2>/dev/null | head -1 || true)

        if [[ -n "$last_checkpoint" && -s "$last_checkpoint" ]]; then
            log "INFO" "  Recovering from checkpoint: $last_checkpoint"

            # Parse codex.jsonl to extract knowledge even on timeout
            local knowledge_path="$PHASE7_STATE_DIR/iteration_${iteration}_knowledge.json"
            "$VENV_PY" scripts/amm-phase7-codex-parser.py "$codex_jsonl_path" > "$knowledge_path" 2>/dev/null || true

            # Try to recover best strategy into structured output format
            if [[ -x scripts/amm-phase7-recover-from-checkpoint.py ]]; then
                "$VENV_PY" scripts/amm-phase7-recover-from-checkpoint.py \
                    --checkpoint "$last_checkpoint" \
                    --output "$codex_last_msg_path" \
                    --strategy-dir "." 2>/dev/null || true

                if [[ -s "$codex_last_msg_path" ]]; then
                    log "INFO" "  Successfully recovered strategy from checkpoint"
                    return 0
                fi
            fi
        fi

        log "ERROR" "Codex timed out and checkpoint recovery failed"
        return 1
    fi

    if [[ "$codex_ok" -eq 0 ]]; then
        # Also extract knowledge on success for future iterations
        local knowledge_path="$PHASE7_STATE_DIR/iteration_${iteration}_knowledge.json"
        "$VENV_PY" scripts/amm-phase7-codex-parser.py "$codex_jsonl_path" > "$knowledge_path" 2>/dev/null || true

        if [[ ! -s "$codex_last_msg_path" ]]; then
            log "WARN" "Codex completed but last-message file is missing/empty: $codex_last_msg_path"
            log "INFO" "  Attempting checkpoint recovery..."

            local last_checkpoint
            last_checkpoint=$(ls -1t "$checkpoint_dir"/checkpoint_*.json 2>/dev/null | head -1 || true)

            if [[ -n "$last_checkpoint" && -s "$last_checkpoint" && -x scripts/amm-phase7-recover-from-checkpoint.py ]]; then
                "$VENV_PY" scripts/amm-phase7-recover-from-checkpoint.py \
                    --checkpoint "$last_checkpoint" \
                    --output "$codex_last_msg_path" \
                    --strategy-dir "." 2>/dev/null || true
            fi

            if [[ ! -s "$codex_last_msg_path" ]]; then
                log "ERROR" "Last-message recovery failed: $codex_last_msg_path"
                return 1
            fi
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
final_score = None
effective_score = None
score_source = None
metrics = {
    "edge_10": None,
    "edge_100": None,
    "edge_1000": None,
    "edge_screen": None,
    "predicted_edge_1000": None,
}
timestamp = None
git_sha = None
git_dirty = None
selection_gate = None

if isinstance(result, dict):
    strategy_name = result.get("strategy_name") or strategy_name
    timestamp = result.get("timestamp") or timestamp
    final_edge = result.get("final_edge", None)
    final_score = result.get("final_score", None)
    git_sha = result.get("git_sha") or git_sha
    git_dirty = result.get("git_dirty") if "git_dirty" in result else git_dirty
    testing = result.get("testing", {}) if isinstance(result.get("testing", {}), dict) else {}
    metrics["edge_10"] = testing.get("edge_10", None)
    metrics["edge_100"] = testing.get("edge_100", None)
    metrics["edge_1000"] = testing.get("edge_1000", None)
    metrics["edge_screen"] = testing.get("edge_screen", None)
    metrics["predicted_edge_1000"] = testing.get("predicted_edge_1000", None)
    selection_gate = testing.get("gate", None)

if isinstance(metadata, dict):
    strategy_name = metadata.get("name") or strategy_name

if not timestamp:
    timestamp = utc_now_iso()

if strategy_name is None:
    strategy_name = "Unknown"

if final_score is not None:
    effective_score = final_score
    score_source = "final_score"
elif final_edge is not None:
    effective_score = final_edge
    score_source = "final_edge_fallback"

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
    "final_score": final_score if status == "ok" else None,
    "effective_score": effective_score if status == "ok" else None,
    "score_source": score_source if status == "ok" else None,
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
    "selection_gate": selection_gate if status == "ok" else None,
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

    # Skip if no 1000-sim result (final_edge is empty)
    if [[ -z "$final_edge" ]]; then
        return 1
    fi

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
# Handle empty final_edge (no 1000-sim result)
if not final_edge or final_edge.strip() == "":
    raise SystemExit(1)  # Don't extract template without 1000-sim result
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
    log "INFO" "Current best robust score: $(cat "$STATE_CHAMPION_SCORE")"
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
        local opp_ranking_path="$PHASE7_STATE_DIR/opportunity_rankings_iter${iteration}.json"
        local opp_plan_path="$PHASE7_STATE_DIR/autoplan_iter${iteration}.json"

        local status="ok"
        local error_stage=""
        local error_message=""
        local final_edge=""
        local final_score=""
        local effective_score=""
        local score_source="none"
        local strategy_name="Unknown"
        local opp_mode="off"
        local opp_execute="false"
        local autoplan_for_prompt=""
        local is_new_champion="0"
        local batch_gate_failed="false"
        local batch_gate_reason=""
        local promotion_gate_blocked="false"

        # === STEP 0: Harvest results from previous Codex session ===
        log "INFO" "Refreshing harvested session knowledge..."
        "$VENV_PY" scripts/amm-phase7-session-harvester.py \
            --all \
            --state-dir "$PHASE7_STATE_DIR" 2>/dev/null || true

        # Guardrail: stop this iteration before prompting if canonical knowledge is inconsistent.
        if ! run_knowledge_guardrail; then
            log "ERROR" "Knowledge guardrail failed; skipping iteration before prompt generation"
            status="prompt_failed"
            error_stage="knowledge_guardrail"
            error_message="knowledge context canonical mismatch"
            append_strategies_log_entry "$iteration" "$status" "$error_stage" "$error_message" \
                "$prompt_path" "$codex_jsonl_path" "$codex_stderr_path" "$codex_last_msg_path" \
                "$strategy_path" "$metadata_path" "$result_path"
            record_opportunity_outcome "$iteration" "$status" "$result_path" "$opp_plan_path"
            continue
        fi

        # === STEP 0.5: Opportunity discovery + autonomous plan generation ===
        if [[ "${AUTO_OPP_ENGINE_ENABLED}" == "1" ]]; then
            log "INFO" "Evaluating autonomous opportunity engine..."
            if run_opportunity_evaluate "$iteration" "$opp_ranking_path" "$opp_plan_path"; then
                opp_mode="$(plan_field "$opp_plan_path" "mode")"
                opp_execute="$(plan_field "$opp_plan_path" "execute_this_iteration")"
                if [[ "$opp_execute" == "true" ]]; then
                    autoplan_for_prompt="$opp_plan_path"
                fi
                cp "$opp_plan_path" "$STATE_OPP_ACTIVE_PLAN" 2>/dev/null || true
                log "INFO" "  Opportunity mode: ${opp_mode:-unknown} | execute=${opp_execute:-false}"
            else
                log "WARN" "  Opportunity engine evaluate failed; continuing baseline behavior"
            fi
        fi

        # === STEP 1: Generate prompt context ===
        log "INFO" "Building prompt..."
        local prompt_auto_plan_args=()
        if [[ -n "$autoplan_for_prompt" ]]; then
            prompt_auto_plan_args+=(--auto-plan "$autoplan_for_prompt")
        fi
        if ! "$VENV_PY" scripts/amm-phase7-prompt-builder.py \
            --iteration "$iteration" \
            --state-dir "$PHASE7_STATE_DIR" \
            --output "$prompt_path" \
            --target-edge "$COMPETITIVE_EDGE" \
            --max-runtime-seconds "$MAX_RUNTIME_SECONDS" \
            ${prompt_auto_plan_args[@]+"${prompt_auto_plan_args[@]}"}; then
            log "ERROR" "Failed to build prompt"
            status="prompt_failed"
            error_stage="prompt"
            error_message="prompt builder failed"
            append_strategies_log_entry "$iteration" "$status" "$error_stage" "$error_message" \
                "$prompt_path" "$codex_jsonl_path" "$codex_stderr_path" "$codex_last_msg_path" \
                "$strategy_path" "$metadata_path" "$result_path"
            record_opportunity_outcome "$iteration" "$status" "$result_path" "$opp_plan_path"
            continue
        fi

        # === STEP 2: Invoke Codex to generate strategy ===
        if ! invoke_codex_generator "$iteration" "$prompt_path" "$codex_jsonl_path" "$codex_stderr_path" "$codex_last_msg_path"; then
            log "WARN" "Codex invocation failed, continuing to next iteration"
            status="codex_failed"
            error_stage="codex"
            if [[ -n "${LAST_GATE_ABORT_REASON:-}" ]]; then
                error_message="$LAST_GATE_ABORT_REASON"
            else
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
            fi
            append_strategies_log_entry "$iteration" "$status" "$error_stage" "$error_message" \
                "$prompt_path" "$codex_jsonl_path" "$codex_stderr_path" "$codex_last_msg_path" \
                "$strategy_path" "$metadata_path" "$result_path"
            record_opportunity_outcome "$iteration" "$status" "$result_path" "$opp_plan_path"
            continue
        fi

        if [[ "${EXEC_GATES_ENABLED}" == "1" ]]; then
            batch_gate_failed="$(gate_iteration_field "$iteration" "batch.failed")"
            batch_gate_reason="$(gate_iteration_field "$iteration" "batch.fail_reason")"
            local batch_gate_best
            local batch_gate_count
            batch_gate_best="$(gate_iteration_field "$iteration" "batch.best_edge")"
            batch_gate_count="$(gate_iteration_field "$iteration" "batch.count")"
            if [[ "$batch_gate_failed" == "true" ]]; then
                log "WARN" "Batch fail gate active for iteration $iteration: ${batch_gate_reason:-batch best below threshold}"
            else
                log "INFO" "Batch gate check: count=${batch_gate_count:-0} best=${batch_gate_best:-N/A} (pass)"
            fi
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
            record_opportunity_outcome "$iteration" "$status" "$result_path" "$opp_plan_path"
            continue
        fi

        # === STEP 4: Test strategy through pipeline ===
        log "INFO" "Testing strategy..."
        if ! "$VENV_PY" scripts/amm-test-pipeline.py \
            "$strategy_path" \
            --output "$result_path" \
            --screen-sims "$PIPE_SCREEN_SIMS" \
            --screen-min-edge "$PIPE_SCREEN_MIN_EDGE" \
            --predicted-drop "$PIPE_PREDICTED_DROP" \
            --predicted-min-edge "$PIPE_PREDICTED_MIN_EDGE" \
            --robust-free-spread "$ROBUST_FREE_SPREAD" \
            --robust-penalty-per-point "$ROBUST_PENALTY_PER_POINT"; then
            log "WARN" "Strategy failed testing"
            status="test_failed"
            error_stage="test"
            error_message="amm-test-pipeline failed"
            append_strategies_log_entry "$iteration" "$status" "$error_stage" "$error_message" \
                "$prompt_path" "$codex_jsonl_path" "$codex_stderr_path" "$codex_last_msg_path" \
                "$strategy_path" "$metadata_path" "$result_path"
            record_opportunity_outcome "$iteration" "$status" "$result_path" "$opp_plan_path"
            continue
        fi

        # === STEP 5: Extract edge score ===
        # IMPORTANT: final_edge is only set when 1000 simulations were run
        final_edge="$("$VENV_PY" - "$result_path" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1])
data=json.loads(p.read_text())
v=data.get("final_edge", None)
print(v if v is not None else "")
PY
)"
        final_score="$("$VENV_PY" - "$result_path" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1])
data=json.loads(p.read_text())
v=data.get("final_score", None)
print(v if v is not None else "")
PY
)"
        strategy_name="$("$VENV_PY" - "$result_path" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1])
data=json.loads(p.read_text())
v=data.get("strategy_name", "Unknown")
print(v if v is not None else "Unknown")
PY
)"
        if [[ -n "$final_edge" ]]; then
            log "INFO" "  → Final Edge (1000 sims): $final_edge"
        else
            log "INFO" "  → Final Edge: N/A (did not qualify for 1000-sim test)"
        fi
        if [[ -n "$final_score" ]]; then
            log "INFO" "  → Final Score (robust): $final_score"
        fi
        if [[ -n "$final_score" ]]; then
            effective_score="$final_score"
            score_source="final_score"
        elif [[ -n "$final_edge" ]]; then
            effective_score="$final_edge"
            score_source="final_edge_fallback"
            log "INFO" "  → Effective champion score fallback: using final_edge=$final_edge"
        fi

        # === STEP 6: Record to learning engine ===
        "$VENV_PY" scripts/amm-learning-engine.py record \
            --result "$result_path" \
            --state-dir "$PHASE7_STATE_DIR" 2>/dev/null || true

        # === STEP 7: Check if new champion (gated promotion enforcement) ===
        local current_best
        local current_best_score
        current_best="$(cat "$STATE_CHAMPION")"
        current_best_score="$(cat "$STATE_CHAMPION_SCORE")"
        local beats_score="false"
        local beats_edge="false"
        if [[ -n "$effective_score" ]] && float_gt "$effective_score" "$current_best_score"; then
            beats_score="true"
        fi
        if [[ -n "$final_edge" ]] && float_gt "$final_edge" "$current_best"; then
            beats_edge="true"
        fi

        local confirmation_count=0
        local promotion_confirmed="false"
        local promotion_reason=""
        if [[ "$beats_score" == "true" || "$beats_edge" == "true" ]]; then
            if [[ "$batch_gate_failed" == "true" ]]; then
                promotion_gate_blocked="true"
                promotion_reason="${batch_gate_reason:-batch fail gate active; promotion blocked}"
            elif [[ "${EXEC_GATES_ENABLED}" == "1" ]] && (( GATE_PROMOTION_CONFIRMATIONS > 1 )); then
                if [[ -z "$final_edge" ]]; then
                    promotion_gate_blocked="true"
                    promotion_reason="candidate beat champion but lacks authoritative ${GATE_MIN_SIMS}-sim edge result"
                else
                    confirmation_count="$(record_promotion_confirmation "$iteration" "$strategy_name" "$strategy_path" "$final_edge" "$effective_score")"
                    if (( confirmation_count >= GATE_PROMOTION_CONFIRMATIONS )); then
                        promotion_confirmed="true"
                    else
                        promotion_gate_blocked="true"
                        promotion_reason="promotion pending confirmations: ${confirmation_count}/${GATE_PROMOTION_CONFIRMATIONS}"
                    fi
                fi
            else
                promotion_confirmed="true"
            fi
        fi

        if [[ "$promotion_confirmed" == "true" ]]; then
            if [[ "$beats_score" == "true" ]]; then
                log "INFO" "  🏆 NEW CHAMPION (score source: $score_source)! $effective_score beats $current_best_score"
                echo "$effective_score" > "$STATE_CHAMPION_SCORE"
                cp "$strategy_path" "$PHASE7_STATE_DIR/.best_strategy.sol"
                is_new_champion="1"
            fi
            if [[ "$beats_edge" == "true" ]]; then
                log "INFO" "  📈 New best raw edge: $final_edge beats $current_best"
                echo "$final_edge" > "$STATE_CHAMPION"
                is_new_champion="1"
            fi
        elif [[ "$promotion_gate_blocked" == "true" ]]; then
            log "INFO" "  ⛔ Promotion gate blocked champion update: ${promotion_reason}"
        fi

        if [[ "${EXEC_GATES_ENABLED}" == "1" ]]; then
            set_gate_iteration_promotion_status \
                "$iteration" \
                "$promotion_gate_blocked" \
                "$promotion_reason" \
                "$confirmation_count" \
                "$GATE_PROMOTION_CONFIRMATIONS"
        fi

        # Append Phase 7 source-of-truth log entry (exactly one per iteration).
        append_strategies_log_entry "$iteration" "ok" "" "" \
            "$prompt_path" "$codex_jsonl_path" "$codex_stderr_path" "$codex_last_msg_path" \
            "$strategy_path" "$metadata_path" "$result_path"
        record_opportunity_outcome "$iteration" "ok" "$result_path" "$opp_plan_path"

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

        # === STEP 9: Generate breakthrough insights ===

        # Run forensics on new champions (deep simulation analysis)
        if [[ "$is_new_champion" == "1" ]]; then
            log "INFO" "  🔬 Running forensics analysis on new champion..."
            if "$VENV_PY" scripts/amm-phase7-forensics.py \
                --strategy "$strategy_path" \
                --simulations 30 \
                --output "$PHASE7_STATE_DIR/forensics_insights.json" 2>/dev/null; then
                log "INFO" "  Forensics insights generated"
            else
                log "WARN" "  Forensics analysis failed (non-fatal)"
            fi
        fi

        # === STEP 10: Run regime tests on new champions ===
        if [[ "$is_new_champion" == "1" ]]; then
            log "INFO" "  📊 Running regime tests on new champion..."
            local regime_output="$PHASE7_STATE_DIR/regime_tests_iter${iteration}.json"
            if "$VENV_PY" scripts/amm-phase7-regime-tester.py \
                "$strategy_path" \
                --sims 100 \
                --json "$regime_output" 2>/dev/null; then
                # Extract and log key findings
                local regime_spread weakest_regime
                regime_spread="$("$VENV_PY" - "$regime_output" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1])
data=json.loads(p.read_text())
print(f"{data['summary']['corner_spread']:.1f}")
PY
)"
                weakest_regime="$("$VENV_PY" - "$regime_output" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1])
data=json.loads(p.read_text())
print(data['summary']['weakest_regime'])
PY
)"
                log "INFO" "  Regime tests complete: spread=$regime_spread, weakest=$weakest_regime"

                # Warn if spread is large
                if "$VENV_PY" - "$regime_spread" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) > 50 else 1)
PY
                then
                    log "WARN" "  ⚠ Large regime spread ($regime_spread) - consider regime-specific tuning"
                fi
            else
                log "WARN" "  Regime tests failed (non-fatal)"
            fi
        fi

        # Run synthesis engine every 10 iterations
        if (( iteration % 10 == 0 )); then
            log "INFO" "  🔬 Running cross-strategy synthesis (iteration $iteration)"
            if "$VENV_PY" scripts/amm-phase7-synthesis.py \
                --state-dir "$PHASE7_STATE_DIR" \
                --output "$PHASE7_STATE_DIR/synthesis_report.json" 2>/dev/null; then
                log "INFO" "  Synthesis report generated"
            else
                log "WARN" "  Synthesis analysis failed (non-fatal)"
            fi
        fi

        # Run assumption auditor every 50 iterations
        if (( iteration % 50 == 0 )); then
            log "INFO" "  🔍 Running assumption audit (iteration $iteration)"
            if "$VENV_PY" scripts/amm-phase7-auditor.py \
                --state-dir "$PHASE7_STATE_DIR" \
                --output "$PHASE7_STATE_DIR/assumption_audit.json" 2>/dev/null; then
                log "INFO" "  Assumption audit generated"
            else
                log "WARN" "  Assumption audit failed (non-fatal)"
            fi
        fi

        log "INFO" "Iteration $iteration complete. Current best raw edge: $(cat "$STATE_CHAMPION")"
        log "INFO" "Iteration $iteration complete. Current best robust score: $(cat "$STATE_CHAMPION_SCORE")"
        if [[ "${AUTO_OPP_ENGINE_ENABLED}" == "1" ]]; then
            log "INFO" "Iteration $iteration opportunity mode: ${opp_mode:-unknown}, execute=${opp_execute:-false}"
        fi
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
    local final_best_score=$(cat "$STATE_CHAMPION_SCORE")
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
    log "INFO" "Final Best Robust Score: $final_best_score"
    log "INFO" "Templates Created: $templates_created"
    log "INFO" "Runtime: $(format_duration $elapsed)"
    if [[ "${AUTO_OPP_ENGINE_ENABLED}" == "1" ]]; then
        local opp_rollout_summary
        opp_rollout_summary="$("$VENV_PY" - "$STATE_OPP_ROLLOUT" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1])
try:
    d=json.loads(p.read_text())
except Exception:
    d={}
mode=d.get("mode","unknown")
rollback=d.get("rollback_triggered", False)
reason=d.get("rollback_reason")
shadow=d.get("shadow_completed", 0)
canary=d.get("canary_executed", 0)
msg=f"mode={mode} shadow_completed={shadow} canary_executed={canary} rollback={rollback}"
if reason:
    msg += f" reason={reason}"
print(msg)
PY
)"
        log "INFO" "Auto opportunity rollout: $opp_rollout_summary"
    fi
    log "INFO" "======================================"

    if ! run_knowledge_guardrail; then
        log "ERROR" "Knowledge guardrail failed at final summary; skipping report generation"
        return
    fi

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
    --screen-sims N         Stage-1 screening simulations (default: 200)
    --screen-min-edge N     Minimum screening edge to consider 1000-sim run (default: 375)
    --predicted-drop N      Expected screen->1000 edge delta (default: -8.2)
    --predicted-min-edge N  Minimum predicted 1000-sim edge to run baseline (default: 500)
    --robust-free-spread N  Corner spread ignored before score penalty (default: 50)
    --robust-penalty N      Penalty per spread point above free spread (default: 0.02)
    --knowledge-epsilon N   Knowledge guardrail epsilon tolerance (default: 0.02)
    --auto-opp-enable       Enable autonomous opportunity engine (default: disabled)
    --auto-opp-shadow N     Shadow iterations before execution (default: 20)
    --auto-opp-canary N     Canary execute percentage after shadow (default: 20)
    --auto-opp-window N     Non-regression window size in iterations (default: 20)
    --auto-opp-no-uplift-eps N        No-uplift epsilon for learning/cooldown (default: 0.02)
    --auto-opp-no-uplift-streak N     Consecutive no-uplift outcomes before cooldown (default: 3)
    --auto-opp-no-uplift-cooldown N   Cooldown iterations after no-uplift streak trigger (default: 4)
    --auto-opp-novelty-lookback N     Iterations used for novelty penalty (default: 6)
    --auto-opp-novelty-penalty N      Novelty penalty multiplier (default: 1.0)
    --auto-opp-explore-enable         Enable orthogonal exploration quota (default: enabled)
    --auto-opp-explore-disable        Disable orthogonal exploration quota
    --auto-opp-explore-lookback N     Lookback window for exploration trigger (default: 4)
    --auto-opp-explore-repeat-classes CSV   Repeat-class set for trigger (default: undercut_sweep,gating_adaptive)
    --auto-opp-explore-target-classes CSV   Target classes for forced exploration (default: gamma_formula,asymmetric,ema_smoothing)
    --auto-opp-subfamily-override SPEC  Optional override (subfamily or opp:subfamily, comma-separated)
    --auto-opp-breakthrough-eps N     Tie epsilon for novel-subfamily breakthrough probes (default: 0.10)
    --auto-opp-severe-subfamily-threshold N  Family-level severe-failure trigger threshold (default: 2)
    --auto-opp-gates-fallback-polls N  Poll count when waiting for gate fallback edge (default: 8)
    --auto-opp-gates-fallback-poll-seconds N  Poll interval seconds for gate fallback (default: 0.25)
    --auto-opp-record-gates-fallback-enable   Use execution-gates fallback during record (default: enabled)
    --auto-opp-record-gates-fallback-disable  Disable execution-gates fallback during record
    --exec-gates-enable     Enable shell-level execution gates (default: enabled)
    --exec-gates-disable    Disable shell-level execution gates
    --gate-early-enable     Enable early-abort gate (default: enabled)
    --gate-early-disable    Disable early-abort gate
    --gate-early-n N        Early-abort sample size (default: 4)
    --gate-early-delta N    Early-abort delta below champion (default: 0.8)
    --gate-batch-delta N    Batch-fail delta below champion (default: 0.5)
    --gate-confirmations N  Confirmations required for promotion (default: 3)
    --gate-min-sims N       Minimum sims for authoritative gate samples (default: 1000)
    --gate-monitor-poll N   Gate monitor poll seconds (default: 1.0)
    --enable-shell-tool     Allow Codex to run local commands (default)
    --disable-shell-tool    Prevent Codex from running local commands (may cause stalls in some setups)
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
        --screen-sims)
            PIPE_SCREEN_SIMS="$2"
            shift 2
            ;;
        --screen-min-edge)
            PIPE_SCREEN_MIN_EDGE="$2"
            shift 2
            ;;
        --predicted-drop)
            PIPE_PREDICTED_DROP="$2"
            shift 2
            ;;
        --predicted-min-edge)
            PIPE_PREDICTED_MIN_EDGE="$2"
            shift 2
            ;;
        --robust-free-spread)
            ROBUST_FREE_SPREAD="$2"
            shift 2
            ;;
        --robust-penalty)
            ROBUST_PENALTY_PER_POINT="$2"
            shift 2
            ;;
        --knowledge-epsilon)
            KNOWLEDGE_GUARDRAIL_EPSILON="$2"
            shift 2
            ;;
        --auto-opp-enable)
            AUTO_OPP_ENGINE_ENABLED="1"
            shift 1
            ;;
        --auto-opp-shadow)
            AUTO_OPP_SHADOW_ITERS="$2"
            shift 2
            ;;
        --auto-opp-canary)
            AUTO_OPP_CANARY_PCT="$2"
            shift 2
            ;;
        --auto-opp-window)
            AUTO_OPP_WINDOW_SIZE="$2"
            shift 2
            ;;
        --auto-opp-no-uplift-eps)
            AUTO_OPP_NO_UPLIFT_EPSILON="$2"
            shift 2
            ;;
        --auto-opp-no-uplift-streak)
            AUTO_OPP_NO_UPLIFT_STREAK_THRESHOLD="$2"
            shift 2
            ;;
        --auto-opp-no-uplift-cooldown)
            AUTO_OPP_NO_UPLIFT_COOLDOWN_ITERS="$2"
            shift 2
            ;;
        --auto-opp-novelty-lookback)
            AUTO_OPP_NOVELTY_LOOKBACK="$2"
            shift 2
            ;;
        --auto-opp-novelty-penalty)
            AUTO_OPP_NOVELTY_PENALTY="$2"
            shift 2
            ;;
        --auto-opp-explore-enable)
            AUTO_OPP_EXPLORE_QUOTA_ENABLED="1"
            shift 1
            ;;
        --auto-opp-explore-disable)
            AUTO_OPP_EXPLORE_QUOTA_ENABLED="0"
            shift 1
            ;;
        --auto-opp-explore-lookback)
            AUTO_OPP_EXPLORE_LOOKBACK="$2"
            shift 2
            ;;
        --auto-opp-explore-repeat-classes)
            AUTO_OPP_EXPLORE_REPEAT_CLASSES="$2"
            shift 2
            ;;
        --auto-opp-explore-target-classes)
            AUTO_OPP_EXPLORE_TARGET_CLASSES="$2"
            shift 2
            ;;
        --auto-opp-subfamily-override)
            AUTO_OPP_SUBFAMILY_OVERRIDE="$2"
            shift 2
            ;;
        --auto-opp-breakthrough-eps)
            AUTO_OPP_BREAKTHROUGH_TIE_EPSILON="$2"
            shift 2
            ;;
        --auto-opp-severe-subfamily-threshold)
            AUTO_OPP_SEVERE_SUBFAMILY_FAILURE_THRESHOLD="$2"
            shift 2
            ;;
        --auto-opp-gates-fallback-polls)
            AUTO_OPP_GATES_FALLBACK_POLLS="$2"
            shift 2
            ;;
        --auto-opp-gates-fallback-poll-seconds)
            AUTO_OPP_GATES_FALLBACK_POLL_SECONDS="$2"
            shift 2
            ;;
        --auto-opp-record-gates-fallback-enable)
            AUTO_OPP_RECORD_GATES_FALLBACK="1"
            shift 1
            ;;
        --auto-opp-record-gates-fallback-disable)
            AUTO_OPP_RECORD_GATES_FALLBACK="0"
            shift 1
            ;;
        --exec-gates-enable)
            EXEC_GATES_ENABLED="1"
            shift 1
            ;;
        --exec-gates-disable)
            EXEC_GATES_ENABLED="0"
            shift 1
            ;;
        --gate-early-enable)
            GATE_EARLY_ABORT_ENABLED="1"
            shift 1
            ;;
        --gate-early-disable)
            GATE_EARLY_ABORT_ENABLED="0"
            shift 1
            ;;
        --gate-early-n)
            GATE_EARLY_MIN_RESULTS="$2"
            shift 2
            ;;
        --gate-early-delta)
            GATE_EARLY_DELTA="$2"
            shift 2
            ;;
        --gate-batch-delta)
            GATE_BATCH_FAIL_DELTA="$2"
            shift 2
            ;;
        --gate-confirmations)
            GATE_PROMOTION_CONFIRMATIONS="$2"
            shift 2
            ;;
        --gate-min-sims)
            GATE_MIN_SIMS="$2"
            shift 2
            ;;
        --gate-monitor-poll)
            GATE_MONITOR_POLL_SECONDS="$2"
            shift 2
            ;;
        --enable-shell-tool)
            CODEX_DISABLE_SHELL_TOOL="0"
            shift 1
            ;;
        --disable-shell-tool)
            CODEX_DISABLE_SHELL_TOOL="1"
            shift 1
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
require_file "scripts/run-parallel-sims.sh" "missing bounded parallel simulation helper"
if [[ "${AUTO_OPP_ENGINE_ENABLED}" == "1" ]]; then
    require_file "scripts/amm-phase7-opportunity-engine.py" "missing opportunity engine script"
fi
if [[ "${EXEC_GATES_ENABLED}" == "1" ]]; then
    require_file "scripts/amm-phase7-gate-monitor.py" "missing execution gate monitor script"
fi

log "INFO" "Codex config: model=${CODEX_MODEL:-<default>} max_output_tokens=$CODEX_MAX_OUTPUT_TOKENS timeout_minutes=$CODEX_TIMEOUT_MINUTES CODEX_DISABLE_SHELL_TOOL=$CODEX_DISABLE_SHELL_TOOL"
log "INFO" "Pipeline config: screen_sims=$PIPE_SCREEN_SIMS screen_min_edge=$PIPE_SCREEN_MIN_EDGE predicted_drop=$PIPE_PREDICTED_DROP predicted_min_edge=$PIPE_PREDICTED_MIN_EDGE robust_free_spread=$ROBUST_FREE_SPREAD robust_penalty=$ROBUST_PENALTY_PER_POINT"
log "INFO" "Knowledge guardrail config: epsilon=$KNOWLEDGE_GUARDRAIL_EPSILON"
log "INFO" "Autonomous opportunity config: enabled=$AUTO_OPP_ENGINE_ENABLED shadow_iters=$AUTO_OPP_SHADOW_ITERS canary_pct=$AUTO_OPP_CANARY_PCT window_size=$AUTO_OPP_WINDOW_SIZE"
log "INFO" "Autonomous opportunity policy: no_uplift_eps=$AUTO_OPP_NO_UPLIFT_EPSILON streak=$AUTO_OPP_NO_UPLIFT_STREAK_THRESHOLD cooldown_iters=$AUTO_OPP_NO_UPLIFT_COOLDOWN_ITERS novelty_lookback=$AUTO_OPP_NOVELTY_LOOKBACK novelty_penalty=$AUTO_OPP_NOVELTY_PENALTY"
log "INFO" "Autonomous exploration policy: enabled=$AUTO_OPP_EXPLORE_QUOTA_ENABLED lookback=$AUTO_OPP_EXPLORE_LOOKBACK repeat_classes=$AUTO_OPP_EXPLORE_REPEAT_CLASSES target_classes=$AUTO_OPP_EXPLORE_TARGET_CLASSES subfamily_override=${AUTO_OPP_SUBFAMILY_OVERRIDE:-<none>}"
log "INFO" "Autonomous innovation safeguards: breakthrough_eps=$AUTO_OPP_BREAKTHROUGH_TIE_EPSILON severe_subfamily_threshold=$AUTO_OPP_SEVERE_SUBFAMILY_FAILURE_THRESHOLD gates_fallback=$AUTO_OPP_RECORD_GATES_FALLBACK polls=$AUTO_OPP_GATES_FALLBACK_POLLS poll_seconds=$AUTO_OPP_GATES_FALLBACK_POLL_SECONDS"
log "INFO" "Execution gate config: enabled=$EXEC_GATES_ENABLED early_enabled=$GATE_EARLY_ABORT_ENABLED early_n=$GATE_EARLY_MIN_RESULTS early_delta=$GATE_EARLY_DELTA batch_delta=$GATE_BATCH_FAIL_DELTA confirmations=$GATE_PROMOTION_CONFIRMATIONS min_sims=$GATE_MIN_SIMS poll_s=$GATE_MONITOR_POLL_SECONDS"
if [[ "${CODEX_DISABLE_SHELL_TOOL}" == "1" ]]; then
    log "WARN" "Shell tool is disabled. If Codex stalls after {turn.started} with no tokens, re-run with --enable-shell-tool or set CODEX_DISABLE_SHELL_TOOL=0."
fi

init_phase7_state
main_loop

exit 0
