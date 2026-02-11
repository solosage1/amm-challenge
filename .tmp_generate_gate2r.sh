#!/usr/bin/env bash
set -euo pipefail

cd /Users/rbgross/amm-challenge

# name tight_band tight_fee undercut buffer enter exit def_under_delta def_buf_add def_tight
variants=(
"gate2r_v1 25 28 11 1 9999 9998 0 0 28"
"gate2r_v2 25 28 11 1 90 55 1 1 29"
"gate2r_v3 25 28 11 1 80 50 2 1 29"
"gate2r_v4 25 28 11 1 70 45 2 1 29"
"gate2r_v5 25 28 10 1 80 50 2 1 29"
"gate2r_v6 25 28 12 1 80 50 2 1 29"
"gate2r_v7 24 28 8 1 85 52 1 1 29"
"gate2r_v8 26 28 13 1 85 52 3 1 29"
"gate2r_v9 25 28 11 0 80 50 2 2 29"
"gate2r_v10 25 28 11 2 80 50 2 0 29"
)

for v in "${variants[@]}"; do
  read -r name tb tf u b en ex du db dt <<< "$v"
  out="${name}.sol"
  cp gate2_template.sol "$out"
  perl -0pi -e "s/__TIGHT_BAND_BPS__/$tb/g; s/__TIGHT_FEE_BPS__/$tf/g; s/__BASE_UNDERCUT_BPS__/$u/g; s/__BASE_BUFFER_BPS__/$b/g; s/__ENTER_DEF_BPS__/$en/g; s/__EXIT_DEF_BPS__/$ex/g; s/__DEF_UNDERCUT_DELTA_BPS__/$du/g; s/__DEF_BUFFER_ADD_BPS__/$db/g; s/__DEF_TIGHT_FEE_BPS__/$dt/g; s/__STRATEGY_NAME__/$name/g" "$out"
done

echo "Generated ${#variants[@]} gate2r variants"
