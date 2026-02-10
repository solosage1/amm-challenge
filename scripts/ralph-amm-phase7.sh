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

# ============================================================================
# CONFIGURATION
# ============================================================================

PHASE7_STATE_DIR=".ralph-amm/phase7/state"
PHASE7_GENERATED_DIR=".ralph-amm/phase7/generated"
PHASE7_TEMPLATES_DIR=".ralph-amm/phase7/templates"
PHASE7_PROMPTS_DIR=".ralph-amm/phase7/prompts"

# Performance targets
COMPETITIVE_EDGE=527
TEMPLATE_THRESHOLD=390

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

    # Initialize state files if they don't exist
    [[ -f "$STATE_ITERATION" ]] || echo "0" > "$STATE_ITERATION"
    [[ -f "$STATE_CHAMPION" ]] || echo "374.56" > "$STATE_CHAMPION"  # Best from Phase 1
    [[ -f "$STATE_STRATEGIES" ]] || echo "[]" > "$STATE_STRATEGIES"
    [[ -f "$STATE_TEMPLATES" ]] || echo "[]" > "$STATE_TEMPLATES"
    [[ -f "$STATE_RATE_LIMIT" ]] || echo '{"last_call_timestamp": 0, "calls_count": 0}' > "$STATE_RATE_LIMIT"
    [[ -f "$STATE_START_TIME" ]] || date +%s > "$STATE_START_TIME"

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
    if (( $(echo "$best_edge >= $COMPETITIVE_EDGE" | bc -l) )); then
        log "INFO" "🎉 Competitive edge achieved: $best_edge >= $COMPETITIVE_EDGE"
        return 0  # Exit
    fi

    return 1  # Continue
}

# ============================================================================
# RATE LIMITING
# ============================================================================

rate_limit_wait() {
    # Enforce minimum 2-second delay between API calls
    local last_call=$(jq -r '.last_call_timestamp // 0' "$STATE_RATE_LIMIT" 2>/dev/null || echo "0")
    local now=$(date +%s)
    local elapsed=$((now - last_call))

    if [[ $elapsed -lt 2 ]]; then
        local wait_time=$((2 - elapsed))
        log "DEBUG" "Rate limiting: waiting ${wait_time}s"
        sleep "$wait_time"
    fi

    # Update rate limit state
    now=$(date +%s)
    jq ".last_call_timestamp = $now | .calls_count += 1" "$STATE_RATE_LIMIT" > "$STATE_RATE_LIMIT.tmp"
    mv "$STATE_RATE_LIMIT.tmp" "$STATE_RATE_LIMIT"
}

# ============================================================================
# CODEX INVOCATION
# ============================================================================

invoke_codex_generator() {
    local iteration="$1"
    local prompt_path="$2"
    local output_path="$3"

    rate_limit_wait

    log "INFO" "Invoking Codex for strategy generation..."

    # Check if codex CLI is available
    if ! command -v codex &> /dev/null; then
        log "ERROR" "Codex CLI not found. Please ensure 'codex' is in your PATH."
        return 1
    fi

    # Invoke Codex with full-auto mode
    # Uses default Codex config (model, provider, sandbox)
    # Current config: gpt-5.2 (openai)
    if codex exec \
        --json \
        "$(cat "$prompt_path")" > "$output_path" 2>&1; then
        log "INFO" "Codex invocation successful"
        return 0
    else
        local exit_code=$?
        log "ERROR" "Codex invocation failed with code $exit_code"
        return 1
    fi
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

        # === STEP 1: Generate prompt context ===
        local prompt_path="$PHASE7_PROMPTS_DIR/iteration_${iteration}_prompt.md"
        log "INFO" "Building prompt..."
        if ! python scripts/amm-phase7-prompt-builder.py \
            --iteration "$iteration" \
            --state-dir "$PHASE7_STATE_DIR" \
            --output "$prompt_path"; then
            log "ERROR" "Failed to build prompt"
            continue
        fi

        # === STEP 2: Invoke Codex to generate strategy ===
        local codex_output="$PHASE7_STATE_DIR/iteration_${iteration}_codex_response.json"
        if ! invoke_codex_generator "$iteration" "$prompt_path" "$codex_output"; then
            log "WARN" "Codex invocation failed, continuing to next iteration"
            continue
        fi

        # === STEP 3: Extract strategy code from Codex response ===
        local strategy_path="$PHASE7_GENERATED_DIR/phase7_strategy_${iteration}.sol"
        log "INFO" "Extracting strategy code..."
        if ! python scripts/amm-phase7-code-extractor.py \
            --codex-response "$codex_output" \
            --output "$strategy_path"; then
            log "WARN" "Failed to extract valid strategy code"
            continue
        fi

        # === STEP 4: Test strategy through pipeline ===
        local result_path="$PHASE7_STATE_DIR/iteration_${iteration}_result.json"
        log "INFO" "Testing strategy..."
        if ! python scripts/amm-test-pipeline.py \
            "$strategy_path" \
            --output "$result_path"; then
            log "WARN" "Strategy failed testing"
            continue
        fi

        # === STEP 5: Extract edge score ===
        local final_edge=$(jq -r '.final_edge' "$result_path" 2>/dev/null || echo "0")
        log "INFO" "  → Final Edge: $final_edge"

        # === STEP 6: Record to learning engine ===
        python scripts/amm-learning-engine.py record \
            --result "$result_path" \
            --state-dir "$PHASE7_STATE_DIR" 2>/dev/null || true

        # === STEP 7: Check if new champion ===
        local current_best=$(cat "$STATE_CHAMPION")
        if (( $(echo "$final_edge > $current_best" | bc -l) )); then
            log "INFO" "  🏆 NEW CHAMPION! $final_edge beats $current_best"
            echo "$final_edge" > "$STATE_CHAMPION"
            cp "$strategy_path" "$PHASE7_STATE_DIR/.best_strategy.sol"

            # === STEP 8: Extract template if threshold exceeded ===
            if (( $(echo "$final_edge > $TEMPLATE_THRESHOLD" | bc -l) )); then
                log "INFO" "  📝 Extracting template (edge $final_edge > $TEMPLATE_THRESHOLD)"
                if python scripts/amm-phase7-template-extractor.py \
                    --strategy "$strategy_path" \
                    --result "$result_path" \
                    --output-dir "$PHASE7_TEMPLATES_DIR"; then
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
    local templates_created=$(jq 'length' "$STATE_TEMPLATES" 2>/dev/null || echo "0")

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
    if python scripts/amm-phase7-report-generator.py \
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

init_phase7_state
main_loop

exit 0
