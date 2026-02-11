#!/usr/bin/env bash
set -euo pipefail
cd /Users/rbgross/amm-challenge

# name tb tf u b de dx dr db ri ai rt
variants=(
"aus_u3_v1 25 28 11 1 9999 9998 0 0 0 0 0"
"aus_u3_v2 25 28 11 1 9999 9998 0 0 1 1 0"
"aus_u3_v3 24 28 10 1 9999 9998 0 0 1 1 0"
"aus_u3_v4 26 28 12 1 9999 9998 0 0 1 1 0"
"aus_u3_v5 25 28 11 0 9999 9998 0 0 1 1 0"
"aus_u3_v6 25 28 11 2 9999 9998 0 0 1 1 0"
"aus_u3_v7 25 28 11 1 80 50 2 0 1 1 1"
"aus_u3_v8 24 28 10 1 75 48 2 1 1 1 1"
"aus_u3_v9 26 28 12 0 90 60 1 0 1 1 1"
"aus_u3_v10 27 28 9 1 85 55 2 1 2 1 1"
)

for v in "${variants[@]}"; do
  read -r name tb tf u b de dx dr db ri ai rt <<< "$v"
  out="${name}.sol"
  cp adaptive_u2_template.sol "$out"
  perl -0pi -e "s/__TIGHT_BAND_BPS__/$tb/g; s/__TIGHT_FEE_BPS__/$tf/g; s/__BASE_UNDERCUT_BPS__/$u/g; s/__BASE_BUFFER_BPS__/$b/g; s/__DEF_ENTER_BPS__/$de/g; s/__DEF_EXIT_BPS__/$dx/g; s/__DEF_UNDERCUT_REDUCE_BPS__/$dr/g; s/__DEF_BUFFER_ADD_BPS__/$db/g; s/__RETAIL_UNDERCUT_INC_BPS__/$ri/g; s/__ARB_UNDERCUT_DEC_BPS__/$ai/g; s/__RETAIL_TIGHTEN_BPS__/$rt/g; s/__STRATEGY_NAME__/$name/g" "$out"
done

echo "Generated ${#variants[@]} aus_u3 variants"
