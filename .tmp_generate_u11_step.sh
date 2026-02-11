#!/usr/bin/env bash
set -euo pipefail

cd /Users/rbgross/amm-challenge

# name tight_band tight_fee undercut buffer newstep_dec samestep_inc
variants=(
"u11_step_v1 25 28 11 1 0 0"
"u11_step_v2 25 28 11 1 1 1"
"u11_step_v3 25 28 11 1 2 1"
"u11_step_v4 25 28 11 1 1 2"
"u11_step_v5 25 28 11 1 2 2"
"u11_step_v6 24 28 10 1 1 1"
"u11_step_v7 26 28 12 1 1 1"
"u11_step_v8 27 28 11 0 2 1"
"u11_step_v9 28 28 12 0 1 2"
"u11_step_v10 29 28 10 2 2 2"
)

for v in "${variants[@]}"; do
  read -r name tb tf u b nd si <<< "$v"
  out="${name}.sol"
  cp u11_step_template.sol "$out"
  perl -0pi -e "s/__TIGHT_BAND_BPS__/$tb/g; s/__TIGHT_FEE_BPS__/$tf/g; s/__BASE_UNDERCUT_BPS__/$u/g; s/__PROTECT_BUFFER_BPS__/$b/g; s/__NEWSTEP_UNDERCUT_DEC_BPS__/$nd/g; s/__SAMESTEP_UNDERCUT_INC_BPS__/$si/g; s/__STRATEGY_NAME__/$name/g" "$out"
done

echo "Generated ${#variants[@]} u11_step variants"
