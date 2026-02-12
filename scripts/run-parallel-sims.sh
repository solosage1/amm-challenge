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
  --champion EDGE     Champion baseline for family gates (default: 0; <=0 disables family gates)
  --early-n N         Early-abort sample size for family gate (default: 4)
  --early-delta D     Early-abort threshold delta (default: 0.8)
  --batch-delta D     Family batch-fail threshold delta (default: 0.5)
  --help              Show this help

Output:
  - Per-run logs in OUTPUT_DIR/<timestamp_pid>/*.log
  - Tabular results in OUTPUT_DIR/<timestamp_pid>/results.tsv
  - Machine-readable stdout lines:
      PAR_SIM_FAMILY_START<TAB>run_id<TAB>n_strategies<TAB>champion<TAB>early_n<TAB>early_delta<TAB>batch_delta
      PAR_SIM_RESULT<TAB>strategy<TAB>edge_or_NA<TAB>sims<TAB>status
      PAR_SIM_FAMILY_ABORT<TAB>run_id<TAB>reason<TAB>completed_count<TAB>killed_count
      PAR_SIM_FAMILY_END<TAB>run_id<TAB>best_edge_or_NA<TAB>completed_count<TAB>failed<TAB>reason
EOF
}

workers=4
sims=1000
amm_match=""
output_root=".ralph-amm/phase7/state/parallel_sims"
champion="${PAR_SIM_CHAMPION:-0}"
early_n="${PAR_SIM_EARLY_N:-4}"
early_delta="${PAR_SIM_EARLY_DELTA:-0.8}"
batch_delta="${PAR_SIM_BATCH_DELTA:-0.5}"
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
        --champion)
            champion="$2"
            shift 2
            ;;
        --early-n)
            early_n="$2"
            shift 2
            ;;
        --early-delta)
            early_delta="$2"
            shift 2
            ;;
        --batch-delta)
            batch_delta="$2"
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

is_number() {
    [[ "${1:-}" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]
}

float_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'
}

float_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

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

if ! [[ "$early_n" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --early-n must be a non-negative integer." >&2
    exit 2
fi

if ! is_number "$champion"; then
    echo "ERROR: --champion must be numeric." >&2
    exit 2
fi
if ! is_number "$early_delta"; then
    echo "ERROR: --early-delta must be numeric." >&2
    exit 2
fi
if ! is_number "$batch_delta"; then
    echo "ERROR: --batch-delta must be numeric." >&2
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
completed_edges_file="$run_dir/.completed_edges"
touch "$completed_edges_file"

echo "[run-parallel-sims] run_id=$run_id workers=$workers sims=$sims n=${#strategies[@]}"
echo "[run-parallel-sims] output_dir=$run_dir"
printf 'PAR_SIM_FAMILY_START\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_id" "${#strategies[@]}" "$champion" "$early_n" "$early_delta" "$batch_delta"

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
    local tmp_result
    local start_ts
    local end_ts
    local duration
    local status
    local edge

    stem="$(basename "${strategy_path%.*}")"
    log_file="$run_dir/${idx}_${stem}.log"
    result_file="$run_dir/result_${idx}.tsv"
    tmp_result="$run_dir/result_${idx}.tsv.tmp"
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
        "$strategy_path" "$status" "$edge" "$duration" "$log_file" > "$tmp_result"
    mv "$tmp_result" "$result_file"

    # Shared completion stream in completion order.
    printf '%s\t%s\t%s\t%s\n' "$idx" "$strategy_path" "$status" "$edge" >> "$completed_edges_file"
}

sanitize_reason() {
    local reason="$1"
    reason="${reason//$'\t'/ }"
    reason="${reason//$'\n'/ }"
    reason="$(echo "$reason" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    echo "${reason:-none}"
}

gates_enabled="0"
if is_number "$champion" && float_gt "$champion" "0"; then
    gates_enabled="1"
fi

early_abort_triggered="0"
early_abort_reason=""
early_abort_threshold=""
if [[ "$gates_enabled" == "1" ]]; then
    early_abort_threshold="$(awk -v c="$champion" -v d="$early_delta" 'BEGIN { printf "%.10f", (c - d) }')"
fi

check_early_abort() {
    if [[ "$gates_enabled" != "1" ]]; then
        return 1
    fi
    if [[ "$early_abort_triggered" == "1" ]]; then
        return 0
    fi
    if [[ "$early_n" -le 0 ]]; then
        return 1
    fi

    local reason
    if reason="$(
        python3 - "$completed_edges_file" "$early_n" "$early_abort_threshold" "$champion" "$early_delta" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
early_n = int(sys.argv[2])
threshold = float(sys.argv[3])
champion = float(sys.argv[4])
delta = float(sys.argv[5])

edges = []
if path.exists():
    for line in path.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        status = parts[2]
        edge_raw = parts[3]
        if status != "0":
            continue
        try:
            edge = float(edge_raw)
        except Exception:
            continue
        edges.append(edge)

if len(edges) < early_n:
    raise SystemExit(1)

first = edges[:early_n]
if all(edge < threshold for edge in first):
    edges_txt = ", ".join(f"{e:.2f}" for e in first)
    print(
        f"first {early_n} successful edges [{edges_txt}] are all < "
        f"champion {champion:.2f} - {delta:.2f} ({threshold:.2f})"
    )
    raise SystemExit(0)

raise SystemExit(1)
PY
    )"; then
        early_abort_triggered="1"
        early_abort_reason="$reason"
        return 0
    fi
    return 1
}

total="${#strategies[@]}"
launched_count=0
declare -a launched=()
declare -a pids=()

for ((i = 1; i <= total; i++)); do
    launched[$i]=0
    pids[$i]=""
done

kill_running_jobs() {
    local killed=0
    local pid
    for pid in $(jobs -pr 2>/dev/null || true); do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            killed=$((killed + 1))
        fi
    done
    sleep 0.3
    for pid in $(jobs -pr 2>/dev/null || true); do
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    echo "$killed"
}

running_jobs() {
    jobs -pr 2>/dev/null | wc -l | tr -d ' '
}

for ((i = 1; i <= total; i++)); do
    if [[ "$gates_enabled" == "1" && "$early_n" -gt 0 && "$i" -eq $((early_n + 1)) ]]; then
        # Barrier: decide early-abort after the first early_n strategies complete
        # before launching additional strategies.
        wait 2>/dev/null || true
        if check_early_abort; then
            break
        fi
    fi

    read -r -n1 _ <&9

    if check_early_abort; then
        # Return consumed token before breaking.
        printf '.' >&9
        break
    fi

    strategy="${strategies[$((i - 1))]}"
    launched[$i]=1
    launched_count=$((launched_count + 1))
    echo "[run-parallel-sims] queued #$i: $strategy"

    (
        run_one "$i" "$strategy"
        printf '.' >&9
    ) &
    pids[$i]=$!
done

killed_count=0
if [[ "$early_abort_triggered" != "1" ]]; then
    while true; do
        if [[ "$(running_jobs)" -le 0 ]]; then
            break
        fi
        if check_early_abort; then
            killed_count="$(kill_running_jobs)"
            break
        fi
        sleep 0.05
    done
fi

if [[ "$early_abort_triggered" == "1" ]]; then
    if [[ "$(running_jobs)" -gt 0 ]]; then
        extra_killed="$(kill_running_jobs)"
        if [[ "$extra_killed" =~ ^[0-9]+$ ]]; then
            killed_count=$((killed_count + extra_killed))
        fi
    fi
fi

# Collect all child exits (ignore failures; encoded in per-run status files).
wait 2>/dev/null || true

{
    printf 'strategy\tstatus\tedge\tduration_s\tlog_file\n'
    for ((i = 1; i <= total; i++)); do
        result_path="$run_dir/result_${i}.tsv"
        if [[ -f "$result_path" ]]; then
            cat "$result_path"
            continue
        fi

        strategy="${strategies[$((i - 1))]}"
        stem="$(basename "${strategy%.*}")"
        log_file="$run_dir/${i}_${stem}.log"
        if [[ "$early_abort_triggered" == "1" ]]; then
            printf '%s\t42\tNA\t0\t%s\n' "$strategy" "$log_file"
        elif [[ "${launched[$i]}" == "1" ]]; then
            printf '%s\t99\tNA\t0\t%s\n' "$strategy" "$log_file"
        else
            printf '%s\t99\tNA\t0\t%s\n' "$strategy" "$log_file"
        fi
    done
} > "$run_dir/results.tsv"

# Emit PAR_SIM_RESULT lines in completion-table order for deterministic parsing.
while IFS=$'\t' read -r strategy status edge _duration _log_file; do
    if [[ "$strategy" == "strategy" ]]; then
        continue
    fi
    printf 'PAR_SIM_RESULT\t%s\t%s\t%s\t%s\n' "$strategy" "$edge" "$sims" "$status"
done < "$run_dir/results.tsv"

echo ""
echo "[run-parallel-sims] completed. results=$run_dir/results.tsv"

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

rows.sort(
    key=lambda r: (
        r["edge_val"] is not None,
        r["edge_val"] if r["edge_val"] is not None else -10**9,
    ),
    reverse=True,
)

for row in rows:
    strategy = row["strategy"][:30]
    edge = row["edge"]
    status = row["status"]
    duration = row["duration_s"]
    print(f"{strategy:<30} {edge:>8}  {status:>6}  {duration:>10}")
PY

best_edge="NA"
completed_count=0
fail_count=0
batch_failed="false"
family_reason="ok"

while IFS=$'\t' read -r strategy status edge _duration _log; do
    if [[ "$strategy" == "strategy" ]]; then
        continue
    fi
    if [[ "$status" == "0" ]]; then
        completed_count=$((completed_count + 1))
        if is_number "$edge"; then
            if [[ "$best_edge" == "NA" ]] || float_gt "$edge" "$best_edge"; then
                best_edge="$edge"
            fi
        fi
    elif [[ "$status" != "42" ]]; then
        fail_count=$((fail_count + 1))
    fi
done < "$run_dir/results.tsv"

if [[ "$gates_enabled" == "1" && "$early_abort_triggered" != "1" ]]; then
    batch_threshold="$(awk -v c="$champion" -v d="$batch_delta" 'BEGIN { printf "%.10f", (c - d) }')"
    if [[ "$best_edge" == "NA" ]]; then
        batch_failed="true"
        family_reason="no successful numeric edge results"
    elif float_lt "$best_edge" "$batch_threshold"; then
        batch_failed="true"
        family_reason="best ${best_edge} < champion ${champion} - ${batch_delta} (${batch_threshold})"
    fi
fi

if [[ "$early_abort_triggered" == "1" ]]; then
    aborted_total=$((total - completed_count))
    if [[ "$aborted_total" -gt "$killed_count" ]]; then
        killed_count="$aborted_total"
    fi
    abort_reason="$(sanitize_reason "$early_abort_reason")"
    printf 'PAR_SIM_FAMILY_ABORT\t%s\t%s\t%s\t%s\n' \
        "$run_id" "$abort_reason" "$completed_count" "$killed_count"
    family_reason="$abort_reason"
    batch_failed="true"
fi

family_reason="$(sanitize_reason "$family_reason")"
printf 'PAR_SIM_FAMILY_END\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_id" "$best_edge" "$completed_count" "$batch_failed" "$family_reason"

if [[ "$early_abort_triggered" == "1" ]]; then
    exit 42
fi

if [[ "$fail_count" -gt 0 ]]; then
    echo "[run-parallel-sims] WARNING: $fail_count run(s) failed." >&2
    exit 1
fi

exit 0
