#!/usr/bin/env bash
set -euo pipefail

cd /Users/rbgross/amm-challenge

# name tight_band tight_fee undercut buffer def_enter def_exit def_under_reduce def_buf_add retail_inc arb_dec retail_tighten
variants=(
"adaptive_u2_v1 24 28 8 0 70 45 2 1 1 1 1"
"adaptive_u2_v2 24 28 9 1 70 45 2 1 1 1 1"
"adaptive_u2_v3 25 28 10 1 70 45 2 1 1 1 1"
"adaptive_u2_v4 25 28 11 1 70 45 2 1 1 1 1"
"adaptive_u2_v5 25 28 12 1 70 45 2 1 1 1 1"
"adaptive_u2_v6 26 28 13 1 75 50 2 1 1 1 1"
"adaptive_u2_v7 27 28 10 0 80 55 2 1 1 1 1"
"adaptive_u2_v8 27 28 11 2 80 55 2 1 1 1 1"
"adaptive_u2_v9 28 28 12 0 85 60 2 1 1 1 1"
"adaptive_u2_v10 29 28 9 2 90 65 2 1 1 1 1"
)

for v in "${variants[@]}"; do
  read -r name tb tf u b de dx dur dba ri ad rt <<< "$v"
  out="${name}.sol"
  cp adaptive_u2_template.sol "$out"
  perl -0pi -e "s/__TIGHT_BAND_BPS__/$tb/g; s/__TIGHT_FEE_BPS__/$tf/g; s/__BASE_UNDERCUT_BPS__/$u/g; s/__BASE_BUFFER_BPS__/$b/g; s/__DEF_ENTER_BPS__/$de/g; s/__DEF_EXIT_BPS__/$dx/g; s/__DEF_UNDERCUT_REDUCE_BPS__/$dur/g; s/__DEF_BUFFER_ADD_BPS__/$dba/g; s/__RETAIL_UNDERCUT_INC_BPS__/$ri/g; s/__ARB_UNDERCUT_DEC_BPS__/$ad/g; s/__RETAIL_TIGHTEN_BPS__/$rt/g; s/__STRATEGY_NAME__/$name/g" "$out"
done

echo "Generated ${#variants[@]} adaptive_u2 variants"
