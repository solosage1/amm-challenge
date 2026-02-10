#!/usr/bin/env bash
set -euo pipefail

# Ralph-AMM: Autonomous Strategy Development Loop
# Inspired by Ralph coding loop from aegis-app

# ============================================================
# Configuration
# ============================================================

PLAN_FILE=".ralph-amm/state/@strategy_plan.md"
BEST_EDGE_FILE=".ralph-amm/state/.best_edge_score.txt"
STRATEGIES_TESTED_FILE=".ralph-amm/state/.strategies_tested.json"
GENERATED_DIR=".ralph-amm/generated"
TARGET_EDGE=400
MAX_LOOPS=${MAX_LOOPS:-0}  # 0 = unlimited

# ============================================================
# Helper Functions
# ============================================================

log() {
  local level="$1"
  local message="$2"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [%s] %s\n' "$ts" "$level" "$message"
}

die() {
  log "ERROR" "$1"
  exit 1
}

find_first_unchecked_task() {
  # Find first line starting with "- [ ]"
  grep -m 1 "^- \[ \]" "$PLAN_FILE" 2>/dev/null || echo ""
}

extract_task_number() {
  local task="$1"
  # Extract task number (e.g., "1.1", "2.3")
  echo "$task" | grep -oE '[0-9]+\.[0-9]+' | head -1
}

extract_template() {
  local task="$1"
  # Extract template name from "Template: xyz" line
  echo "$task" | grep -A 10 "Template:" | grep "Template:" | sed 's/.*Template: //' | tr -d ' '
}

extract_params() {
  local task="$1"
  # Extract params JSON from "Params: {...}" line
  echo "$task" | grep -A 10 "Params:" | grep "Params:" | sed 's/.*Params: //'
}

generate_strategy_id() {
  local task_num="$1"
  # Count existing strategies to generate sequential ID
  local count
  count=$(ls -1 "$GENERATED_DIR"/*.sol 2>/dev/null | wc -l | tr -d ' ')
  printf "strategy_%03d_task_%s" "$((count + 1))" "${task_num//./_}"
}

mark_task_complete() {
  local task_num="$1"
  local edge="$2"
  # Replace "- [ ] X.Y:" with "- [x] X.Y: → Edge Y.YY"
  sed -i.bak "s/^- \[ \] $task_num:/- [x] $task_num: → Edge $edge/" "$PLAN_FILE"
}

get_best_edge() {
  if [[ -f "$BEST_EDGE_FILE" ]]; then
    cat "$BEST_EDGE_FILE"
  else
    echo "0"
  fi
}

check_target_achieved() {
  local best_edge="$1"
  local target="$2"
  # Use bc for floating point comparison
  if command -v bc >/dev/null 2>&1; then
    [[ $(echo "$best_edge >= $target" | bc -l) -eq 1 ]]
  else
    # Fallback: integer comparison (multiply by 100)
    local best_int
    local target_int
    best_int=$(printf "%.0f" "$(echo "$best_edge * 100" | bc -l)")
    target_int=$(printf "%.0f" "$(echo "$target * 100" | bc -l)")
    [[ $best_int -ge $target_int ]]
  fi
}

# ============================================================
# Main Loop
# ============================================================

main() {
  log "INFO" "======================================"
  log "INFO" "Ralph-AMM Autonomous Loop Starting"
  log "INFO" "======================================"
  log "INFO" "Plan: $PLAN_FILE"
  log "INFO" "Target Edge: $TARGET_EDGE"
  log "INFO" ""

  local loop_count=0

  while true; do
    loop_count=$((loop_count + 1))

    # Check max loops limit
    if [[ $MAX_LOOPS -gt 0 && $loop_count -gt $MAX_LOOPS ]]; then
      log "INFO" "Max loops ($MAX_LOOPS) reached. Exiting."
      break
    fi

    log "INFO" "=== Loop Iteration $loop_count ==="

    # 1. Find next task
    log "INFO" "Step 1: Reading strategy plan..."
    local task
    task=$(find_first_unchecked_task)

    if [[ -z "$task" ]]; then
      log "INFO" "All tasks complete! Exiting."
      break
    fi

    local task_num
    task_num=$(extract_task_number "$task")
    log "INFO" "  → Task $task_num found"

    # 2. Parse task
    log "INFO" "Step 2: Parsing task parameters..."
    local template
    local params
    local strategy_id

    # Read multiple lines after the task to get template and params
    local task_block
    task_block=$(awk "/^- \[ \] $task_num:/{flag=1; next} /^- \[/{flag=0} flag" "$PLAN_FILE")

    template=$(echo "$task_block" | grep "Template:" | sed 's/.*Template: //' | tr -d ' ')
    params=$(echo "$task_block" | grep "Params:" | sed 's/.*Params: //')
    strategy_id=$(generate_strategy_id "$task_num")

    log "INFO" "  → Template: $template"
    log "INFO" "  → Strategy ID: $strategy_id"

    # 3. Generate strategy code
    log "INFO" "Step 3: Generating strategy code..."
    local strategy_path="$GENERATED_DIR/${strategy_id}.sol"

    python scripts/amm-strategy-generator.py \
      --template "$template" \
      --params "$params" \
      --output "$strategy_path" || die "Strategy generation failed"

    # 4. Test strategy
    log "INFO" "Step 4: Running test pipeline..."
    local result_path=".ralph-amm/state/last_result.json"

    python scripts/amm-test-pipeline.py \
      "$strategy_path" \
      --output "$result_path" || {
        log "WARN" "Test pipeline failed. Marking task deferred."
        sed -i.bak "s/^- \[ \] $task_num:/- [d] $task_num: → FAILED/" "$PLAN_FILE"
        continue
      }

    # 5. Extract results and record to history
    local final_edge
    final_edge=$(python -c "import json; print(json.load(open('$result_path'))['final_edge'])")

    log "INFO" "  → Final Edge: $final_edge"

    # Record result to learning engine
    python scripts/amm-learning-engine.py record --result "$result_path" 2>/dev/null || true

    # 6. Update best if champion
    local current_best
    current_best=$(get_best_edge)

    if (( $(echo "$final_edge > $current_best" | bc -l) )); then
      log "INFO" "  🏆 NEW CHAMPION! Edge $final_edge beats $current_best"
      echo "$final_edge" > "$BEST_EDGE_FILE"
      cp "$strategy_path" ".ralph-amm/state/.best_strategy.sol"
    fi

    # 7. Mark task complete
    log "INFO" "Step 5: Updating strategy plan..."
    mark_task_complete "$task_num" "$final_edge"

    # 8. Check exit conditions
    current_best=$(get_best_edge)

    if check_target_achieved "$current_best" "$TARGET_EDGE"; then
      log "INFO" ""
      log "INFO" "=========================================="
      log "INFO" "🎉 TARGET ACHIEVED! 🎉"
      log "INFO" "=========================================="
      log "INFO" "Best Edge: $current_best (target: $TARGET_EDGE)"
      log "INFO" "Best Strategy: .ralph-amm/state/.best_strategy.sol"
      log "INFO" "Strategies Tested: $loop_count"
      log "INFO" "=========================================="
      exit 0
    fi

    log "INFO" "Current best: $current_best (target: $TARGET_EDGE)"
    log "INFO" ""

    # Small delay between iterations
    sleep 1
  done

  # Final summary
  log "INFO" ""
  log "INFO" "======================================"
  log "INFO" "Loop Complete"
  log "INFO" "======================================"
  log "INFO" "Iterations: $loop_count"
  log "INFO" "Best Edge: $(get_best_edge)"
  log "INFO" "======================================"
}

# ============================================================
# Entry Point
# ============================================================

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --max-loops)
      MAX_LOOPS="$2"
      shift 2
      ;;
    --target)
      TARGET_EDGE="$2"
      shift 2
      ;;
    --help|-h)
      cat <<EOF
Ralph-AMM: Autonomous Strategy Development Loop

Usage:
  bash scripts/ralph-amm.sh [OPTIONS]

Options:
  --max-loops N    Stop after N iterations (default: unlimited)
  --target EDGE    Target edge to achieve (default: 400)
  --help, -h       Show this help message

Examples:
  # Run until target achieved or all tasks complete
  bash scripts/ralph-amm.sh

  # Run only 3 iterations for testing
  bash scripts/ralph-amm.sh --max-loops 3

  # Set different target
  bash scripts/ralph-amm.sh --target 380
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Run main loop
main
