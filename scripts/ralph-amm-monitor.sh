#!/usr/bin/env bash
set -euo pipefail

# Ralph-AMM Monitor: Real-time progress dashboard
# Displays live status while autonomous loop runs

# ============================================================
# Configuration
# ============================================================

STATE_DIR=".ralph-amm/state"
PLAN_FILE="$STATE_DIR/@strategy_plan.md"
BEST_EDGE_FILE="$STATE_DIR/.best_edge_score.txt"
HISTORY_FILE="$STATE_DIR/.strategies_tested.json"
LAST_RESULT_FILE="$STATE_DIR/last_result.json"
REFRESH_INTERVAL=2  # seconds

# ============================================================
# Helper Functions
# ============================================================

get_best_edge() {
  if [[ -f "$BEST_EDGE_FILE" ]]; then
    cat "$BEST_EDGE_FILE"
  else
    echo "0"
  fi
}

get_task_counts() {
  if [[ ! -f "$PLAN_FILE" ]]; then
    echo "0 0"
    return
  fi

  local completed
  local total
  completed=$(grep -c "^- \[x\]" "$PLAN_FILE" 2>/dev/null || echo "0")
  total=$(grep -c "^- \[" "$PLAN_FILE" 2>/dev/null || echo "0")
  echo "$completed $total"
}

get_strategies_tested() {
  if [[ ! -f "$HISTORY_FILE" ]]; then
    echo "0"
    return
  fi

  # Count entries in JSON array
  python3 -c "import json; print(len(json.load(open('$HISTORY_FILE'))))" 2>/dev/null || echo "0"
}

get_current_task() {
  if [[ ! -f "$PLAN_FILE" ]]; then
    echo "No plan file"
    return
  fi

  # Find first unchecked task
  local task
  task=$(grep -m 1 "^- \[ \]" "$PLAN_FILE" 2>/dev/null || echo "")

  if [[ -z "$task" ]]; then
    echo "All tasks complete"
  else
    # Extract task description (everything after "- [ ] X.Y: ")
    echo "$task" | sed 's/^- \[ \] [0-9]\+\.[0-9]\+: //' | head -c 50
  fi
}

get_last_result() {
  if [[ ! -f "$LAST_RESULT_FILE" ]]; then
    echo "none none none"
    return
  fi

  python3 -c "
import json
import sys
try:
    data = json.load(open('$LAST_RESULT_FILE'))
    name = data.get('strategy_name', 'unknown')
    edge = data.get('final_edge', 0)
    success = 'OK' if data.get('success') else 'FAIL'
    print(f'{name} {edge:.2f} {success}')
except:
    print('error 0 none')
" 2>/dev/null || echo "error 0 none"
}

get_recent_history() {
  if [[ ! -f "$HISTORY_FILE" ]]; then
    return
  fi

  python3 -c "
import json
try:
    history = json.load(open('$HISTORY_FILE'))
    recent = history[-5:]  # Last 5
    for entry in reversed(recent):
        name = entry.get('id', 'unknown')
        edge = entry.get('final_edge', 0)
        print(f'{name}: {edge:.2f}')
except:
    pass
" 2>/dev/null || true
}

get_best_strategy() {
  if [[ ! -f "$HISTORY_FILE" ]]; then
    echo "none 0"
    return
  fi

  python3 -c "
import json
try:
    history = json.load(open('$HISTORY_FILE'))
    if not history:
        print('none 0')
    else:
        best = max(history, key=lambda h: h.get('final_edge', 0))
        name = best.get('id', 'unknown')
        edge = best.get('final_edge', 0)
        print(f'{name} {edge:.2f}')
except:
    print('error 0')
" 2>/dev/null || echo "error 0"
}

check_loop_running() {
  # Check if ralph-amm.sh process is running
  if pgrep -f "ralph-amm.sh" >/dev/null 2>&1; then
    echo "RUNNING"
  else
    echo "STOPPED"
  fi
}

draw_dashboard() {
  clear

  # Header
  echo "┌─────────────────────────────────────────────────────────────┐"
  echo "│          RALPH-AMM Autonomous Loop Monitor                  │"
  echo "└─────────────────────────────────────────────────────────────┘"
  echo ""

  # Status
  local status
  status=$(check_loop_running)

  if [[ "$status" == "RUNNING" ]]; then
    echo "Status: 🟢 RUNNING"
  else
    echo "Status: 🔴 STOPPED"
  fi
  echo ""

  # Current task
  local current_task
  current_task=$(get_current_task)
  echo "Current: $current_task"
  echo ""

  # Progress
  local counts
  local completed
  local total
  counts=$(get_task_counts)
  completed=$(echo "$counts" | awk '{print $1}')
  total=$(echo "$counts" | awk '{print $2}')

  local percent=0
  if [[ $total -gt 0 ]]; then
    percent=$(awk "BEGIN {printf \"%.1f\", ($completed / $total) * 100}")
  fi

  echo "Progress: $completed / $total ($percent%)"

  # Draw progress bar
  local bar_width=50
  local filled
  filled=$(awk "BEGIN {printf \"%.0f\", ($completed / $total) * $bar_width}")
  printf "["
  for ((i=0; i<bar_width; i++)); do
    if [[ $i -lt $filled ]]; then
      printf "="
    else
      printf " "
    fi
  done
  printf "]\n"
  echo ""

  # Best strategy
  echo "┌─────────────────────────────────────────────────────────────┐"
  echo "│ BEST STRATEGY                                               │"
  echo "└─────────────────────────────────────────────────────────────┘"

  local best_info
  local best_name
  local best_edge_val
  best_info=$(get_best_strategy)
  best_name=$(echo "$best_info" | awk '{print $1}')
  best_edge_val=$(echo "$best_info" | awk '{print $2}')

  local current_best
  current_best=$(get_best_edge)

  local gap
  gap=$(awk "BEGIN {printf \"%.2f\", 400 - $current_best}")

  echo "  ID: $best_name"
  echo "  Edge: $best_edge_val"
  echo "  Gap to Target (400): $gap points"
  echo ""

  # Recent tests
  echo "┌─────────────────────────────────────────────────────────────┐"
  echo "│ RECENT TESTS                                                │"
  echo "└─────────────────────────────────────────────────────────────┘"

  local recent
  recent=$(get_recent_history)

  if [[ -z "$recent" ]]; then
    echo "  No tests recorded yet"
  else
    echo "$recent" | while IFS= read -r line; do
      echo "  $line"
    done
  fi
  echo ""

  # Strategies tested
  local tested
  tested=$(get_strategies_tested)
  echo "Total Strategies Tested: $tested"
  echo ""

  # Footer
  echo "──────────────────────────────────────────────────────────────"
  echo "Press Ctrl+C to exit monitor"
  echo "Last updated: $(date '+%Y-%m-%d %H:%M:%S')"
}

# ============================================================
# Main Loop
# ============================================================

main() {
  # Check if state directory exists
  if [[ ! -d "$STATE_DIR" ]]; then
    echo "Error: State directory not found: $STATE_DIR"
    echo "Have you initialized the ralph-amm system?"
    exit 1
  fi

  # Trap Ctrl+C for clean exit
  trap 'echo ""; echo "Monitor stopped."; exit 0' INT

  # Main monitoring loop
  while true; do
    draw_dashboard
    sleep "$REFRESH_INTERVAL"
  done
}

# ============================================================
# Entry Point
# ============================================================

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --refresh)
      REFRESH_INTERVAL="$2"
      shift 2
      ;;
    --help|-h)
      cat <<EOF
Ralph-AMM Monitor: Real-time progress dashboard

Usage:
  bash scripts/ralph-amm-monitor.sh [OPTIONS]

Options:
  --refresh N      Refresh interval in seconds (default: 2)
  --help, -h       Show this help message

Examples:
  # Start monitor with default settings
  bash scripts/ralph-amm-monitor.sh

  # Monitor with 5 second refresh
  bash scripts/ralph-amm-monitor.sh --refresh 5

  # Run in background while loop runs
  bash scripts/ralph-amm.sh &
  bash scripts/ralph-amm-monitor.sh
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
