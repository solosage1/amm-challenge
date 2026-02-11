#!/usr/bin/env bash
#
# Watcher script: Wait for iteration 3 to finish, then restart loop with new flags
#

set -euo pipefail

LOOP_PID=69395
CODEX_PID=16560
LOG_FILE=".ralph-amm/phase7/state/restart_watcher.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

cd /Users/rbgross/amm-challenge

log "Watcher started - monitoring iteration 3 (Codex PID $CODEX_PID)"
log "Will kill loop PID $LOOP_PID and restart with autonomous opportunity engine"

# Poll every 30 seconds for codex process to exit
while kill -0 "$CODEX_PID" 2>/dev/null; do
    # Also check if iteration 3 output contains final markers
    if grep -q '---STRATEGY_IDEA---' .ralph-amm/phase7/state/iteration_3_codex.jsonl 2>/dev/null; then
        log "Detected ---STRATEGY_IDEA--- marker in iteration 3 output"
        # Give it a moment to finish writing
        sleep 10
        break
    fi
    sleep 30
done

log "Iteration 3 Codex process finished or produced final output"

# Kill the old loop
if kill -0 "$LOOP_PID" 2>/dev/null; then
    log "Killing old loop (PID $LOOP_PID)..."
    kill "$LOOP_PID" 2>/dev/null || true
    sleep 2
    # Force kill if still running
    kill -9 "$LOOP_PID" 2>/dev/null || true
    log "Old loop killed"
else
    log "Old loop already exited"
fi

# Kill any remaining iteration 3 child processes
pkill -f "iteration_3" 2>/dev/null || true
log "Cleaned up iteration 3 child processes"

# Wait a moment for cleanup
sleep 3

# Start new loop with autonomous opportunity engine
log "Starting new loop with autonomous opportunity engine..."
log "Command: bash scripts/ralph-amm-phase7.sh --auto-opp-enable --auto-opp-shadow 0 --auto-opp-canary 100"

nohup bash scripts/ralph-amm-phase7.sh --auto-opp-enable --auto-opp-shadow 0 --auto-opp-canary 100 \
    >> .ralph-amm/phase7/state/loop_output.log 2>&1 &

NEW_PID=$!
log "New loop started with PID $NEW_PID"
log "Watcher complete - new autonomous opportunity loop is running"
