#!/usr/bin/env bash
#
# Phase 7 Monitoring Dashboard
# Real-time monitoring for the autonomous AI-powered strategy exploration loop
#

set -euo pipefail

PHASE7_STATE_DIR="${1:-.ralph-amm/phase7/state}"
REFRESH_INTERVAL="${2:-10}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_PY="${VENV_PY:-$REPO_ROOT/venv_fresh/bin/python3}"

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
    local progress
    progress=$(awk -v e="$elapsed" 'BEGIN{ if (e<0) e=0; printf "%.1f", (e/36000)*100 }')

    echo "═══════════════════════════════════════════════════════════════"
    echo " STATUS"
    echo "═══════════════════════════════════════════════════════════════"
    echo " Iteration:       $iteration"
    echo " Best Edge:       $best_edge (Target: 527)"
    echo " Gap to Target:   $(awk -v b="$best_edge" 'BEGIN{printf "%.2f", 527 - b}')"
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

    # Find latest Codex JSONL event stream
    local latest_jsonl
    latest_jsonl=$(ls -t "$PHASE7_STATE_DIR"/iteration_*_codex.jsonl 2>/dev/null | head -1 || true)

    if [[ -n "$latest_jsonl" && -f "$latest_jsonl" ]]; then
        local iter_num
        iter_num=$(basename "$latest_jsonl" | sed -E 's/iteration_([0-9]+)_codex\.jsonl/\1/')
        local file_size
        file_size=$(ls -lh "$latest_jsonl" | awk '{print $5}')
        local event_count
        event_count=$(wc -l < "$latest_jsonl" 2>/dev/null || echo "0")

        echo " Current Iteration: $iter_num"
        echo " Response Size:     $file_size"
        echo " Events:            $event_count"

        local last_event
        last_event="$("$VENV_PY" - "$latest_jsonl" <<'PY' 2>/dev/null || echo "unknown"
import json
import sys
from pathlib import Path

p = Path(sys.argv[1])
last_type = "unknown"
try:
    for line in reversed(p.read_text(errors="ignore").splitlines()[-200:]):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        last_type = obj.get("type") or obj.get("event") or obj.get("kind") or "unknown"
        break
except Exception:
    pass
print(last_type)
PY
)"
        echo " Last Event Type:   $last_event"

        local last_msg_path="$PHASE7_STATE_DIR/iteration_${iter_num}_last_message.md"
        if [[ -s "$last_msg_path" ]]; then
            local msg_preview
            msg_preview=$(head -c 120 "$last_msg_path" 2>/dev/null | tr '\n' ' ' | tr '\r' ' ')
            echo " Last Message:      ${msg_preview}..."
        else
            echo " Last Message:      (not captured yet)"
        fi
    else
        echo " No Codex activity yet"
    fi
    echo ""
}

print_recent_results() {
    echo "═══════════════════════════════════════════════════════════════"
    echo " RECENT RESULTS"
    echo "═══════════════════════════════════════════════════════════════"

    "$VENV_PY" <<EOF 2>/dev/null || echo " (No results yet)"
import json
from pathlib import Path

log_file = Path('$PHASE7_STATE_DIR/.strategies_log.json')
if log_file.exists():
    log = json.loads(log_file.read_text())
    if log:
        print(f' Total Strategies: {len(log)}')

        # Success rate
        ok = sum(1 for s in log if isinstance(s, dict) and s.get('status') == 'ok')
        success_rate = (ok / len(log)) * 100
        print(f' Success Rate:     {success_rate:.1f}% ({ok}/{len(log)})')
        print('')

        # Recent 5
        print(' Last 5 Tests:')
        for s in log[-5:]:
            name = s.get('strategy_name', 'Unknown')[:30]
            status = str(s.get('status') or 'unknown')
            raw_edge = s.get('final_edge')
            try:
                edge = float(raw_edge) if raw_edge is not None else None
            except (TypeError, ValueError):
                edge = None
            icon = '✓' if status == 'ok' else '✗'
            edge_str = f'{edge:.2f}' if edge is not None else 'N/A'
            print(f'   {icon} {name:30s} Edge {edge_str:>6s} ({status})')
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

    "$VENV_PY" <<EOF 2>/dev/null || echo " (No templates yet)"
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
            raw_edge = t.get('source_edge', 0)
            try:
                edge = float(raw_edge) if raw_edge is not None else 0.0
            except (TypeError, ValueError):
                edge = 0.0
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

    "$VENV_PY" <<EOF 2>/dev/null || true
import json
from pathlib import Path

log_file = Path('$PHASE7_STATE_DIR/.strategies_log.json')
if log_file.exists():
    log = json.loads(log_file.read_text())

    if len(log) >= 5:
        # Failure rate check
        failures = sum(1 for s in log if isinstance(s, dict) and s.get('status') != 'ok')
        failure_rate = (failures / len(log)) * 100 if log else 0

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
            recent = []
            for s in log[-10:]:
                if not isinstance(s, dict) or s.get('status') != 'ok':
                    continue
                raw = s.get('final_edge')
                try:
                    v = float(raw) if raw is not None else None
                except (TypeError, ValueError):
                    v = None
                if v is not None:
                    recent.append(v)
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
            edges = []
            for s in log:
                if not isinstance(s, dict) or s.get('status') != 'ok':
                    continue
                raw = s.get('final_edge')
                try:
                    v = float(raw) if raw is not None else None
                except (TypeError, ValueError):
                    v = None
                if v is not None:
                    edges.append(v)

            if not edges:
                print(' ⚠️  No successful strategies yet')
                raise SystemExit(0)

            first_edge = edges[0]
            best_edge = max(edges)
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
