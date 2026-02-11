#!/usr/bin/env bash
set -euo pipefail

# Run amm-match simulations for multiple strategy files with a bounded worker pool.
# Designed to avoid xargs/job-control portability issues across shells.
#
# Usage:
#   bash scripts/run-parallel-sims.sh a.sol b.sol c.sol --workers 4 --sims 1000
#   bash scripts/run-parallel-sims.sh a.sol b.sol --workers 2 --sims 1000 -- --seed-offset 2000

usage() {
    cat <<'EOF'
Usage: run-parallel-sims.sh STRATEGY.sol [STRATEGY2.sol ...] [OPTIONS] [-- EXTRA_AMM_MATCH_ARGS...]

Options:
  --workers N         Parallel workers (default: 4)
  --sims N            Simulations per strategy (default: 1000)
  --amm-match PATH    amm-match executable path (default: ./venv_fresh/bin/amm-match or PATH lookup)
  --output-dir DIR    Output directory root (default: .ralph-amm/phase7/state/parallel_sims)
  --help              Show this help

Output:
  - Per-run logs in OUTPUT_DIR/<timestamp_pid>/*.log
  - Tabular results in OUTPUT_DIR/<timestamp_pid>/results.tsv
  - Machine-readable stdout lines for automation:
      PAR_SIM_RESULT<TAB>strategy<TAB>edge_or_NA<TAB>sims<TAB>status
EOF
}

workers=4
sims=1000
amm_match=""
output_root=".ralph-amm/phase7/state/parallel_sims"
extra_args=()
strategies=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workers)
            workers="$2"
            shift 2
            ;;
        --sims)
            sims="$2"
            shift 2
            ;;
        --amm-match)
            amm_match="$2"
            shift 2
            ;;
        --output-dir)
            output_root="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                extra_args+=("$1")
                shift
            done
            break
            ;;
        --*)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            strategies+=("$1")
            shift
            ;;
    esac
done

if [[ "${#strategies[@]}" -eq 0 ]]; then
    echo "ERROR: Provide at least one strategy file." >&2
    usage >&2
    exit 2
fi

if ! [[ "$workers" =~ ^[0-9]+$ ]] || [[ "$workers" -lt 1 ]]; then
    echo "ERROR: --workers must be a positive integer." >&2
    exit 2
fi

if ! [[ "$sims" =~ ^[0-9]+$ ]] || [[ "$sims" -lt 1 ]]; then
    echo "ERROR: --sims must be a positive integer." >&2
    exit 2
fi

if [[ -z "$amm_match" ]]; then
    if [[ -x "./venv_fresh/bin/amm-match" ]]; then
        amm_match="./venv_fresh/bin/amm-match"
    elif command -v amm-match >/dev/null 2>&1; then
        amm_match="$(command -v amm-match)"
    else
        echo "ERROR: amm-match not found. Use --amm-match PATH or install in PATH." >&2
        exit 2
    fi
fi

run_id="$(date '+%Y%m%d_%H%M%S')_$$"
run_dir="$output_root/$run_id"
mkdir -p "$run_dir"

echo "[run-parallel-sims] run_id=$run_id workers=$workers sims=$sims n=${#strategies[@]}"
echo "[run-parallel-sims] output_dir=$run_dir"

cleanup_children() {
    local pid
    for pid in $(jobs -pr 2>/dev/null || true); do
        kill "$pid" 2>/dev/null || true
    done
}

cleanup_sem() {
    exec 9>&- 2>/dev/null || true
    exec 9<&- 2>/dev/null || true
}

trap 'cleanup_children; cleanup_sem; exit 130' INT TERM
trap 'cleanup_sem' EXIT

sem_fifo="$(mktemp -u "${TMPDIR:-/tmp}/run_parallel_sims.XXXXXX")"
mkfifo "$sem_fifo"
exec 9<>"$sem_fifo"
rm -f "$sem_fifo"

for ((i = 0; i < workers; i++)); do
    printf '.' >&9
done

run_one() {
    local idx="$1"
    local strategy_path="$2"
    local stem
    local log_file
    local result_file
    local start_ts
    local end_ts
    local duration
    local status
    local edge

    stem="$(basename "${strategy_path%.*}")"
    log_file="$run_dir/${idx}_${stem}.log"
    result_file="$run_dir/result_${idx}.tsv"
    start_ts="$(date +%s)"

    if [[ ! -f "$strategy_path" ]]; then
        status=2
        edge="NA"
        {
            echo "ERROR: strategy file not found: $strategy_path"
        } > "$log_file"
    else
        if "$amm_match" run "$strategy_path" --simulations "$sims" ${extra_args[@]+"${extra_args[@]}"} > "$log_file" 2>&1; then
            status=0
        else
            status=$?
        fi

        edge="$(sed -n -E 's/.*Edge:[[:space:]]*([+-]?[0-9]+([.][0-9]+)?).*/\1/p' "$log_file" | tail -n 1)"
        if [[ -z "$edge" ]]; then
            edge="NA"
        fi
    fi

    end_ts="$(date +%s)"
    duration=$((end_ts - start_ts))

    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$strategy_path" "$status" "$edge" "$duration" "$log_file" > "$result_file"
}

idx=0
for strategy in "${strategies[@]}"; do
    idx=$((idx + 1))
    echo "[run-parallel-sims] queued #$idx: $strategy"

    read -r -n1 _ <&9
    (
        run_one "$idx" "$strategy"
        printf '.' >&9
    ) &
done

wait

{
    printf 'strategy\tstatus\tedge\tduration_s\tlog_file\n'
    for ((i = 1; i <= idx; i++)); do
        if [[ -f "$run_dir/result_${i}.tsv" ]]; then
            cat "$run_dir/result_${i}.tsv"
        else
            printf 'unknown\t99\tNA\t0\t%s\n' "$run_dir/result_${i}.missing.log"
        fi
    done
} > "$run_dir/results.tsv"

echo ""
echo "[run-parallel-sims] completed. results=$run_dir/results.tsv"

# Machine-readable lines for downstream parsers.
for ((i = 1; i <= idx; i++)); do
    if [[ -f "$run_dir/result_${i}.tsv" ]]; then
        IFS=$'\t' read -r strategy status edge duration _log_file < "$run_dir/result_${i}.tsv"
    else
        strategy="unknown"
        status="99"
        edge="NA"
    fi
    printf 'PAR_SIM_RESULT\t%s\t%s\t%s\t%s\n' "$strategy" "$edge" "$sims" "$status"
done

echo ""
echo "Strategy                        Edge       Status  Duration(s)"
echo "-------------------------------------------------------------"
python3 - "$run_dir/results.tsv" <<'PY'
import csv
import sys

path = sys.argv[1]
rows = []
with open(path, newline="", encoding="utf-8") as fh:
    reader = csv.DictReader(fh, delimiter="\t")
    for row in reader:
        edge_raw = row.get("edge", "NA")
        try:
            edge_val = float(edge_raw)
        except Exception:
            edge_val = None
        rows.append(
            {
                "strategy": row.get("strategy", ""),
                "status": row.get("status", ""),
                "edge": edge_raw,
                "edge_val": edge_val,
                "duration_s": row.get("duration_s", ""),
            }
        )

rows.sort(key=lambda r: (r["edge_val"] is not None, r["edge_val"] if r["edge_val"] is not None else -10**9), reverse=True)

for row in rows:
    strategy = row["strategy"][:30]
    edge = row["edge"]
    status = row["status"]
    duration = row["duration_s"]
    print(f"{strategy:<30} {edge:>8}  {status:>6}  {duration:>10}")
PY

fail_count="$(awk -F $'\t' 'NR>1 && $2 != "0" {c++} END{print c+0}' "$run_dir/results.tsv")"
if [[ "$fail_count" -gt 0 ]]; then
    echo "[run-parallel-sims] WARNING: $fail_count run(s) failed." >&2
    exit 1
fi

exit 0
