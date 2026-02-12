#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STATE_DIR="${STATE_DIR:-$REPO_ROOT/.ralph-amm/phase7/state}"
DEFINITIONS_PATH="${DEFINITIONS_PATH:-$REPO_ROOT/.ralph-amm/phase7/config/mechanism_definitions.json}"
LOOP_SCRIPT="${LOOP_SCRIPT:-$REPO_ROOT/scripts/simplified_loop.py}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

PID_FILE="${PID_FILE:-$STATE_DIR/simplified_loop.pid}"
LEGACY_PID_FILE="${LEGACY_PID_FILE:-$STATE_DIR/loop.pid}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/loop_output.log}"
HYPOTHESES_FILE="${HYPOTHESES_FILE:-$STATE_DIR/hypotheses_backlog.json}"
NEXT_HYPOTHESES_FILE="${NEXT_HYPOTHESES_FILE:-$STATE_DIR/hypotheses_backlog.next.json}"

ITERATIONS="${ITERATIONS:-1000}"
SLEEP_SECONDS="${SLEEP_SECONDS:-5}"
WILDCARD_FREQUENCY="${WILDCARD_FREQUENCY:-10}"
SEED_OFFSETS="${SEED_OFFSETS:-0,10000,20000}"
SCREEN_SIMS="${SCREEN_SIMS:-100}"
LLM_COMMAND="${LLM_COMMAND:-codex}"
LLM_MODEL="${LLM_MODEL:-gpt-5.3-codex}"
LLM_TIMEOUT_MINUTES="${LLM_TIMEOUT_MINUTES:-45.0}"
ROLLBACK_RESTORE_MODE="${ROLLBACK_RESTORE_MODE:-history_then_spine}"
ROLLBACK_ALLOW_SNAPSHOT_FALLBACK="${ROLLBACK_ALLOW_SNAPSHOT_FALLBACK:-0}"
TAIL_LINES="${TAIL_LINES:-100}"
STOP_WAIT_SECONDS="${STOP_WAIT_SECONDS:-15}"

usage() {
  cat <<'EOF'
Usage: scripts/simplified_loop_ctl.sh <start|stop|status|logs> [args...]

Commands:
  start [extra run-loop args]  Start the simplified loop in background via nohup.
  stop                         Stop the running simplified loop process.
  status                       Show process status and loop JSON status payload.
  logs [tail args]             Tail canonical loop log (default: tail -n 100 -f).

Environment overrides:
  STATE_DIR, DEFINITIONS_PATH, PYTHON_BIN, LOOP_SCRIPT
  PID_FILE, LOG_FILE
  HYPOTHESES_FILE, NEXT_HYPOTHESES_FILE
  ITERATIONS, SLEEP_SECONDS
  WILDCARD_FREQUENCY, SEED_OFFSETS
  SCREEN_SIMS, LLM_COMMAND, LLM_MODEL, LLM_TIMEOUT_MINUTES
  ROLLBACK_RESTORE_MODE, ROLLBACK_ALLOW_SNAPSHOT_FALLBACK
  TAIL_LINES, STOP_WAIT_SECONDS

Examples:
  scripts/simplified_loop_ctl.sh start
  scripts/simplified_loop_ctl.sh start --iterations 200 --sleep-seconds 2
  scripts/simplified_loop_ctl.sh status
  scripts/simplified_loop_ctl.sh logs
  scripts/simplified_loop_ctl.sh stop
EOF
}

pid_from_file() {
  local pid_file="$1"
  if [[ ! -f "$pid_file" ]]; then
    return 1
  fi
  local pid
  pid="$(tr -d '[:space:]' < "$pid_file")"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if kill -0 "$pid" 2>/dev/null; then
    printf '%s\n' "$pid"
    return 0
  fi
  return 1
}

running_pid() {
  local pid
  if pid="$(pid_from_file "$PID_FILE")"; then
    printf '%s\n' "$pid"
    return 0
  fi
  if pid="$(pid_from_file "$LEGACY_PID_FILE")"; then
    printf '%s\n' "$pid"
    return 0
  fi
  return 1
}

cleanup_stale_pid_files() {
  local pid_file
  for pid_file in "$PID_FILE" "$LEGACY_PID_FILE"; do
    if [[ -f "$pid_file" ]] && ! pid_from_file "$pid_file" >/dev/null; then
      rm -f "$pid_file"
    fi
  done
}

start_loop() {
  mkdir -p "$STATE_DIR"
  cleanup_stale_pid_files

  local existing_pid
  if existing_pid="$(running_pid)"; then
    echo "loop already running with pid $existing_pid"
    echo "use: scripts/simplified_loop_ctl.sh status"
    exit 1
  fi

  touch "$LOG_FILE"

  local snapshot_stamp
  snapshot_stamp="$(date -u +%Y%m%d_%H%M%S)"
  local snapshot_dir="$STATE_DIR/.archive/restart_snapshot_${snapshot_stamp}"
  mkdir -p "$snapshot_dir"
  local snapshot_file
  for snapshot_file in \
    "mechanism_stats.json" \
    "iteration_log.jsonl" \
    "hypotheses_backlog.json" \
    "policy_evolution_state.json" \
    ".best_strategy.sol" \
    ".best_edge.txt" \
    ".rollback_spine_strategy.sol" \
    ".rollback_spine_edge.txt" \
    ".rollback_spine_meta.json" \
    "shadow_selections.jsonl"; do
    if [[ -f "$STATE_DIR/$snapshot_file" ]]; then
      cp -p "$STATE_DIR/$snapshot_file" "$snapshot_dir/$snapshot_file"
    fi
  done
  if [[ -f "$HYPOTHESES_FILE" ]]; then
    cp -p "$HYPOTHESES_FILE" "$snapshot_dir/hypotheses_backlog.active.json"
  fi
  if [[ -f "$NEXT_HYPOTHESES_FILE" ]]; then
    cp -p "$NEXT_HYPOTHESES_FILE" "$snapshot_dir/hypotheses_backlog.next.json"
  fi
  echo "preflight snapshot: $snapshot_dir"

  if [[ -f "$NEXT_HYPOTHESES_FILE" ]]; then
    cp -p "$NEXT_HYPOTHESES_FILE" "$HYPOTHESES_FILE"
    echo "installed new hypotheses backlog: $NEXT_HYPOTHESES_FILE -> $HYPOTHESES_FILE"
  fi

  date +%s > "$STATE_DIR/.start_timestamp.txt"
  echo "refreshed timer start: $STATE_DIR/.start_timestamp.txt"

  if [[ -f "$STATE_DIR/.best_strategy.sol" && -f "$STATE_DIR/.best_edge.txt" ]]; then
    "$PYTHON_BIN" "$LOOP_SCRIPT" pin-spine --state-dir "$STATE_DIR" --reason "ctl_start_preflight" >/dev/null 2>&1 || true
  fi

  local cmd=(
    "$PYTHON_BIN"
    -u
    "$LOOP_SCRIPT"
    run-loop
    --state-dir "$STATE_DIR"
    --definitions "$DEFINITIONS_PATH"
    --iterations "$ITERATIONS"
    --sleep-seconds "$SLEEP_SECONDS"
    --continue-on-error
    --auto-rollback
    --wildcard-frequency "$WILDCARD_FREQUENCY"
    --seed-offsets "$SEED_OFFSETS"
    --screen-sims "$SCREEN_SIMS"
    --llm-command "$LLM_COMMAND"
    --hypotheses-file "$HYPOTHESES_FILE"
    --rollback-restore-mode "$ROLLBACK_RESTORE_MODE"
  )
  if [[ "$ROLLBACK_ALLOW_SNAPSHOT_FALLBACK" == "1" || "$ROLLBACK_ALLOW_SNAPSHOT_FALLBACK" == "true" ]]; then
    cmd+=(--rollback-allow-snapshot-fallback)
  fi
  if [[ -n "$LLM_MODEL" ]]; then
    cmd+=(--llm-model "$LLM_MODEL")
  fi
  if [[ -n "$LLM_TIMEOUT_MINUTES" ]]; then
    cmd+=(--llm-timeout-minutes "$LLM_TIMEOUT_MINUTES")
  fi
  if [[ "$#" -gt 0 ]]; then
    cmd+=("$@")
  fi

  (
    cd "$REPO_ROOT"
    nohup "${cmd[@]}" >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
  )
  rm -f "$LEGACY_PID_FILE"

  local started_pid
  started_pid="$(tr -d '[:space:]' < "$PID_FILE")"
  echo "started simplified loop pid=$started_pid"
  echo "log: $LOG_FILE"
}

stop_loop() {
  cleanup_stale_pid_files

  local pid
  if ! pid="$(running_pid)"; then
    echo "simplified loop is not running"
    return 0
  fi

  kill "$pid" 2>/dev/null || true
  local deadline=$((SECONDS + STOP_WAIT_SECONDS))
  while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do
    sleep 1
  done

  if kill -0 "$pid" 2>/dev/null; then
    echo "process $pid did not exit within ${STOP_WAIT_SECONDS}s"
    echo "retry stop or terminate manually"
    exit 1
  fi

  rm -f "$PID_FILE" "$LEGACY_PID_FILE"
  echo "stopped simplified loop pid=$pid"
}

status_loop() {
  cleanup_stale_pid_files

  local pid=""
  if pid="$(running_pid)"; then
    echo "process: running (pid=$pid)"
    ps -p "$pid" -o pid,etime,command
  else
    echo "process: stopped"
  fi

  echo "state_dir: $STATE_DIR"
  echo "definitions: $DEFINITIONS_PATH"
  echo "hypotheses_file: $HYPOTHESES_FILE"
  echo "next_hypotheses_file: $NEXT_HYPOTHESES_FILE"
  echo "pid_file: $PID_FILE"
  echo "log_file: $LOG_FILE"
  echo "--- loop status ---"
  "$PYTHON_BIN" "$LOOP_SCRIPT" status --state-dir "$STATE_DIR" || true
}

logs_loop() {
  mkdir -p "$STATE_DIR"
  touch "$LOG_FILE"
  if [[ "$#" -eq 0 ]]; then
    tail -n "$TAIL_LINES" -f "$LOG_FILE"
    return 0
  fi
  tail "$@" "$LOG_FILE"
}

main() {
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    usage
    exit 1
  fi
  shift || true

  case "$cmd" in
    start)
      start_loop "$@"
      ;;
    stop)
      stop_loop
      ;;
    status)
      status_loop
      ;;
    logs)
      logs_loop "$@"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      echo "unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
