#!/usr/bin/env bash
set -euo pipefail

cd /Users/rbgross/amm-challenge

# name tight_band tight_fee undercut buffer enter exit def_under_delta def_buf_add def_tight
variants=(
"gate2_v1 25 28 11 1 55 32 3 1 29"
"gate2_v2 24 28 11 1 55 32 3 1 29"
"gate2_v3 26 28 11 1 55 32 3 1 29"
"gate2_v4 25 28 10 1 55 32 3 1 29"
"gate2_v5 25 28 12 1 55 32 3 1 29"
"gate2_v6 27 28 9 0 60 34 2 1 30"
"gate2_v7 24 28 13 2 50 30 4 1 30"
"gate2_v8 29 28 8 0 65 36 2 2 30"
"gate2_v9 28 28 10 2 58 33 3 0 29"
"gate2_v10 26 28 12 0 52 31 4 1 30"
)

for v in "${variants[@]}"; do
  read -r name tb tf u b en ex du db dt <<< "$v"
  out="${name}.sol"
  cp gate2_template.sol "$out"
  perl -0pi -e "s/__TIGHT_BAND_BPS__/$tb/g; s/__TIGHT_FEE_BPS__/$tf/g; s/__BASE_UNDERCUT_BPS__/$u/g; s/__BASE_BUFFER_BPS__/$b/g; s/__ENTER_DEF_BPS__/$en/g; s/__EXIT_DEF_BPS__/$ex/g; s/__DEF_UNDERCUT_DELTA_BPS__/$du/g; s/__DEF_BUFFER_ADD_BPS__/$db/g; s/__DEF_TIGHT_FEE_BPS__/$dt/g; s/__STRATEGY_NAME__/$name/g" "$out"
done

echo "Generated ${#variants[@]} gate2 variants"
