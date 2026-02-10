#!/usr/bin/env bash
# Live Knowledge Extractor
# Runs in background during Codex execution, checkpointing discoveries every N seconds

set -euo pipefail

JSONL_PATH="${1:-}"
CHECKPOINT_DIR="${2:-}"
INTERVAL="${3:-300}"  # Default: 5 minutes

if [[ -z "$JSONL_PATH" || -z "$CHECKPOINT_DIR" ]]; then
    echo "Usage: amm-phase7-live-extractor.sh <codex.jsonl> <checkpoint_dir> [interval_seconds]"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$CHECKPOINT_DIR"

echo "[live-extractor] Started monitoring $JSONL_PATH"
echo "[live-extractor] Checkpoints to: $CHECKPOINT_DIR (every ${INTERVAL}s)"

checkpoint_count=0
while true; do
    if [[ -f "$JSONL_PATH" ]]; then
        checkpoint_file="$CHECKPOINT_DIR/checkpoint_$(date +%s).json"

        # Run parser and save checkpoint
        if python "$SCRIPT_DIR/amm-phase7-codex-parser.py" "$JSONL_PATH" > "$checkpoint_file" 2>/dev/null; then
            # Extract summary info for logging
            n_experiments=$(python -c "import json; d=json.load(open('$checkpoint_file')); print(d.get('n_experiments', 0))" 2>/dev/null || echo "0")
            best_edge=$(python -c "import json; d=json.load(open('$checkpoint_file')); exps=d.get('edge_experiments',[]); print(max([e['edge'] for e in exps]) if exps else 0)" 2>/dev/null || echo "0")

            checkpoint_count=$((checkpoint_count + 1))
            echo "[live-extractor] Checkpoint #$checkpoint_count: $n_experiments experiments, best edge: $best_edge"

            # Keep only last 5 checkpoints to save disk space
            if (( checkpoint_count > 5 )); then
                oldest=$(ls -1t "$CHECKPOINT_DIR"/checkpoint_*.json 2>/dev/null | tail -1)
                if [[ -n "$oldest" ]]; then
                    rm -f "$oldest"
                fi
            fi
        fi
    fi

    sleep "$INTERVAL"
done
