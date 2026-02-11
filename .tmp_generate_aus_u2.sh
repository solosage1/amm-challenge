#!/usr/bin/env bash
set -euo pipefail
cd /Users/rbgross/amm-challenge

# name tight_band tight_fee undercut buffer enter exit def_under_delta def_buf_add def_tight
variants=(
"aus_u2_v1 25 28 11 1 9999 9998 0 0 28"
"aus_u2_v2 25 28 10 1 9999 9998 0 0 28"
"aus_u2_v3 25 28 12 1 9999 9998 0 0 28"
"aus_u2_v4 24 28 11 1 78 50 1 0 29"
"aus_u2_v5 26 28 11 1 78 50 1 0 29"
"aus_u2_v6 25 28 11 0 80 50 2 1 29"
"aus_u2_v7 25 28 11 2 80 50 2 0 29"
"aus_u2_v8 24 28 10 0 82 52 2 1 29"
"aus_u2_v9 26 28 12 0 82 52 2 1 29"
"aus_u2_v10 27 28 13 1 85 54 2 1 29"
)

for v in "${variants[@]}"; do
  read -r name tb tf u b en ex du db dt <<< "$v"
  out="${name}.sol"
  cp gate2_template.sol "$out"
  perl -0pi -e "s/__TIGHT_BAND_BPS__/$tb/g; s/__TIGHT_FEE_BPS__/$tf/g; s/__BASE_UNDERCUT_BPS__/$u/g; s/__BASE_BUFFER_BPS__/$b/g; s/__ENTER_DEF_BPS__/$en/g; s/__EXIT_DEF_BPS__/$ex/g; s/__DEF_UNDERCUT_DELTA_BPS__/$du/g; s/__DEF_BUFFER_ADD_BPS__/$db/g; s/__DEF_TIGHT_FEE_BPS__/$dt/g; s/__STRATEGY_NAME__/$name/g" "$out"
done

echo "Generated ${#variants[@]} aus_u2 variants"
