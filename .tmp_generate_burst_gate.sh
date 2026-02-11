#!/usr/bin/env bash
set -euo pipefail

cd /Users/rbgross/amm-challenge

# name tb tf u b en ex du db dt fi fd fm um
variants=(
"bgate_v1 25 28 11 1 9999 9998 0 0 28 0 0 0 13"
"bgate_v2 25 28 10 1 9999 9998 0 0 28 1 1 2 13"
"bgate_v3 25 28 9 1 9999 9998 0 0 28 1 1 3 13"
"bgate_v4 25 28 10 2 9999 9998 0 0 28 1 1 2 13"
"bgate_v5 25 28 11 1 85 55 2 1 29 1 1 2 13"
"bgate_v6 24 28 10 1 80 50 1 1 29 1 1 3 13"
"bgate_v7 26 28 12 1 80 50 3 1 29 1 1 2 13"
"bgate_v8 25 28 11 2 90 55 2 0 29 1 1 3 13"
"bgate_v9 27 28 9 1 90 60 2 1 29 2 1 4 13"
"bgate_v10 24 28 13 0 85 55 3 1 29 1 1 2 13"
)

for v in "${variants[@]}"; do
  read -r name tb tf u b en ex du db dt fi fd fm um <<< "$v"
  out="${name}.sol"
  cp burst_gate_template.sol "$out"
  perl -0pi -e "s/__TIGHT_BAND_BPS__/$tb/g; s/__TIGHT_FEE_BPS__/$tf/g; s/__BASE_UNDERCUT_BPS__/$u/g; s/__BASE_BUFFER_BPS__/$b/g; s/__ENTER_DEF_BPS__/$en/g; s/__EXIT_DEF_BPS__/$ex/g; s/__DEF_UNDERCUT_DELTA_BPS__/$du/g; s/__DEF_BUFFER_ADD_BPS__/$db/g; s/__DEF_TIGHT_FEE_BPS__/$dt/g; s/__FLOW_INC_BPS__/$fi/g; s/__FLOW_DECAY_BPS__/$fd/g; s/__FLOW_MAX_BPS__/$fm/g; s/__UNDERCUT_MAX_BPS__/$um/g; s/__STRATEGY_NAME__/$name/g" "$out"
done

echo "Generated ${#variants[@]} burst_gate variants"
