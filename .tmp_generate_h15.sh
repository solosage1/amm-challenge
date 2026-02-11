#!/usr/bin/env bash
set -euo pipefail
cd /Users/rbgross/amm-challenge

# name tight_band tight_fee undercut buffer enter exit def_under_delta def_buf_add def_tight
variants=(
"h15_v1 25 28 11 1 9999 9998 0 0 28"
"h15_v2 25 28 11 1 220 150 2 1 29"
"h15_v3 25 28 11 1 180 120 2 1 29"
"h15_v4 25 28 11 1 140 90 1 1 29"
"h15_v5 25 28 11 1 120 80 1 0 28"
"h15_v6 25 28 11 1 100 65 1 0 28"
"h15_v7 25 28 11 0 120 80 1 1 28"
"h15_v8 25 28 11 2 120 80 1 0 28"
"h15_v9 24 28 10 1 120 80 1 0 28"
"h15_v10 26 28 12 1 120 80 2 0 28"
)

for v in "${variants[@]}"; do
  read -r name tb tf u b en ex du db dt <<< "$v"
  out="${name}.sol"
  cp gate2_template.sol "$out"
  perl -0pi -e "s/__TIGHT_BAND_BPS__/$tb/g; s/__TIGHT_FEE_BPS__/$tf/g; s/__BASE_UNDERCUT_BPS__/$u/g; s/__BASE_BUFFER_BPS__/$b/g; s/__ENTER_DEF_BPS__/$en/g; s/__EXIT_DEF_BPS__/$ex/g; s/__DEF_UNDERCUT_DELTA_BPS__/$du/g; s/__DEF_BUFFER_ADD_BPS__/$db/g; s/__DEF_TIGHT_FEE_BPS__/$dt/g; s/__STRATEGY_NAME__/$name/g" "$out"
done

echo "Generated ${#variants[@]} h15 variants"
