#!/usr/bin/env bash
#
# Phase 7 Monitoring Dashboard
# Real-time monitoring for the autonomous AI-powered strategy exploration loop
#

set -euo pipefail

PHASE7_STATE_DIR="${1:-.ralph-amm/phase7/state}"
REFRESH_INTERVAL="${2:-10}"

print_header() {
    clear
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║         Phase 7: AI-Powered Strategy Exploration              ║"
    echo "║                  Real-Time Monitor                             ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    date
    echo ""
}

print_status() {
    local iteration=$(cat "$PHASE7_STATE_DIR/.iteration_count.txt" 2>/dev/null || echo "0")
    local best_edge=$(cat "$PHASE7_STATE_DIR/.best_edge.txt" 2>/dev/null || echo "0")
    local start_time=$(cat "$PHASE7_STATE_DIR/.start_timestamp.txt" 2>/dev/null || echo "0")

    # Calculate elapsed and remaining time
    local now=$(date +%s)
    local elapsed=$((now - start_time))
    local remaining=$((36000 - elapsed))
    local elapsed_hours=$((elapsed / 3600))
    local elapsed_mins=$(((elapsed % 3600) / 60))
    local remaining_hours=$((remaining / 3600))
    local remaining_mins=$(((remaining % 3600) / 60))

    # Progress percentage
    local progress=$(echo "scale=1; ($elapsed / 36000) * 100" | bc)

    echo "═══════════════════════════════════════════════════════════════"
    echo " STATUS"
    echo "═══════════════════════════════════════════════════════════════"
    echo " Iteration:       $iteration"
    echo " Best Edge:       $best_edge (Target: 527)"
    echo " Gap to Target:   $(echo "$best_edge" | awk '{print 527 - $1}')"
    echo ""
    echo " Time Elapsed:    ${elapsed_hours}h ${elapsed_mins}m (${progress}%)"
    echo " Time Remaining:  ${remaining_hours}h ${remaining_mins}m"
    echo ""

    # Check if process is running
    if ps aux | grep -q "[r]alph-amm-phase7.sh"; then
        echo " Process Status:  ✓ RUNNING"
    else
        echo " Process Status:  ✗ NOT RUNNING"
    fi
    echo ""
}

print_codex_activity() {
    echo "═══════════════════════════════════════════════════════════════"
    echo " CODEX ACTIVITY"
    echo "═══════════════════════════════════════════════════════════════"

    # Find current iteration's Codex response
    local latest_response=$(ls -t "$PHASE7_STATE_DIR"/iteration_*_codex_response.json 2>/dev/null | head -1)

    if [[ -n "$latest_response" ]]; then
        local iter_num=$(basename "$latest_response" | sed 's/iteration_\([0-9]*\)_codex_response.json/\1/')
        local file_size=$(ls -lh "$latest_response" | awk '{print $5}')
        local event_count=$(wc -l < "$latest_response")

        echo " Current Iteration: $iter_num"
        echo " Response Size:     $file_size"
        echo " Events:            $event_count"

        # Check for completion
        local last_event=$(tail -1 "$latest_response" | jq -r '.type' 2>/dev/null || echo "unknown")
        echo " Last Event Type:   $last_event"

        # Show recent reasoning
        python3 <<EOF 2>/dev/null || echo " (Reasoning unavailable)"
import json
events = []
with open('$latest_response') as f:
    for line in f:
        try:
            events.append(json.loads(line))
        except:
            pass

# Get last reasoning item
reasoning = [e for e in events if e.get('type') == 'item.completed'
             and e.get('item', {}).get('type') == 'reasoning']
if reasoning:
    last_text = reasoning[-1]['item']['text'][:80]
    print(f' Latest Reasoning:  {last_text}...')
else:
    print(' Latest Reasoning:  (No reasoning events yet)')
EOF
    else
        echo " No Codex activity yet"
    fi
    echo ""
}

print_recent_results() {
    echo "═══════════════════════════════════════════════════════════════"
    echo " RECENT RESULTS"
    echo "═══════════════════════════════════════════════════════════════"

    python3 <<EOF 2>/dev/null || echo " (No results yet)"
import json
from pathlib import Path

log_file = Path('$PHASE7_STATE_DIR/.strategies_log.json')
if log_file.exists():
    log = json.loads(log_file.read_text())
    if log:
        print(f' Total Strategies: {len(log)}')

        # Success rate
        successful = sum(1 for s in log if s.get('final_edge', 0) > 0)
        success_rate = (successful / len(log)) * 100
        print(f' Success Rate:     {success_rate:.1f}% ({successful}/{len(log)})')
        print('')

        # Recent 5
        print(' Last 5 Tests:')
        for s in log[-5:]:
            name = s.get('strategy_name', 'Unknown')[:30]
            edge = s.get('final_edge', 0)
            status = '✓' if edge > 0 else '✗'
            print(f'   {status} {name:30s} Edge {edge:.2f}')
    else:
        print(' No strategies tested yet')
else:
    print(' No results log found')
EOF
    echo ""
}

print_templates() {
    echo "═══════════════════════════════════════════════════════════════"
    echo " TEMPLATES EXTRACTED"
    echo "═══════════════════════════════════════════════════════════════"

    python3 <<EOF 2>/dev/null || echo " (No templates yet)"
import json
from pathlib import Path

templates_file = Path('$PHASE7_STATE_DIR/.templates_created.json')
if templates_file.exists():
    templates = json.loads(templates_file.read_text())
    if templates:
        print(f' Total Templates: {len(templates)}')
        print('')
        for t in templates:
            name = t.get('template_name', 'Unknown')
            edge = t.get('source_edge', 0)
            params = t.get('parameters_count', 0)
            print(f'   • {name} (Edge {edge:.2f}, {params} params)')
    else:
        print(' No templates created yet')
else:
    print(' No templates log found')
EOF
    echo ""
}

print_quality_alerts() {
    echo "═══════════════════════════════════════════════════════════════"
    echo " QUALITY CONTROL"
    echo "═══════════════════════════════════════════════════════════════"

    python3 <<EOF 2>/dev/null || true
import json
from pathlib import Path

log_file = Path('$PHASE7_STATE_DIR/.strategies_log.json')
if log_file.exists():
    log = json.loads(log_file.read_text())

    if len(log) >= 5:
        # Failure rate check
        failures = sum(1 for s in log if not s.get('final_edge') or s.get('final_edge', 0) == 0)
        failure_rate = (failures / len(log)) * 100

        if failure_rate > 50:
            print(' ❌ CRITICAL: Failure rate {:.1f}% (>{})'.format(failure_rate, 50))
            print('    Action: Stop and review prompt/config')
        elif failure_rate > 30:
            print(' ⚠️  WARNING: Failure rate {:.1f}% (>{})'.format(failure_rate, 30))
            print('    Action: Monitor closely')
        else:
            print(' ✓ Failure rate acceptable: {:.1f}%'.format(failure_rate))

        # Plateau detection
        if len(log) >= 10:
            recent = [s.get('final_edge', 0) for s in log[-10:] if s.get('final_edge', 0) > 0]
            if len(recent) >= 5:
                mean_edge = sum(recent) / len(recent)
                variance = sum((e - mean_edge) ** 2 for e in recent) / len(recent)
                std_dev = variance ** 0.5

                if std_dev < 2.0:
                    print(' ⚠️  WARNING: Performance plateau (σ={:.2f})'.format(std_dev))
                    print('    Recent variation too low')
                else:
                    print(' ✓ Healthy variance: σ={:.2f}'.format(std_dev))

        # Improvement check
        if len(log) >= 2:
            first_edge = log[0].get('final_edge', 0)
            best_edge = max(s.get('final_edge', 0) for s in log)
            improvement = best_edge - first_edge

            if improvement > 0:
                print(' ✓ Improvement: +{:.2f} points since start'.format(improvement))
            else:
                print(' ⚠️  No improvement yet')
    else:
        print(' (Insufficient data for quality analysis)')
EOF
    echo ""
}

print_footer() {
    echo "═══════════════════════════════════════════════════════════════"
    echo " Press Ctrl+C to stop monitoring (loop will continue)"
    echo " Refresh interval: ${REFRESH_INTERVAL}s"
    echo "═══════════════════════════════════════════════════════════════"
}

# Main monitoring loop
while true; do
    print_header
    print_status
    print_codex_activity
    print_recent_results
    print_templates
    print_quality_alerts
    print_footer

    sleep "$REFRESH_INTERVAL"
done
