#!/usr/bin/env bash
set -euo pipefail
cd /Users/rbgross/amm-challenge

# name tb tf10 base_u10 def_u10 base_b10 def_b10 enter exit
variants=(
"pgate_v1 25 280 110 110 10 10 9999 9998"
"pgate_v2 25 280 110 100 10 10 80 50"
"pgate_v3 25 280 110 95 10 10 80 50"
"pgate_v4 25 280 110 100 10 10 70 45"
"pgate_v5 25 280 110 95 10 10 70 45"
"pgate_v6 25 280 110 100 10 10 60 40"
"pgate_v7 25 280 110 95 10 10 60 40"
"pgate_v8 25 280 105 95 10 10 70 45"
"pgate_v9 25 280 115 100 10 10 70 45"
"pgate_v10 25 275 110 100 10 10 70 45"
)

for v in "${variants[@]}"; do
  read -r name tb tf bu du bb db en ex <<< "$v"
  out="${name}.sol"
  cp precision_gate_template.sol "$out"
  perl -0pi -e "s/__TIGHT_BAND_BPS__/$tb/g; s/__TIGHT_FEE_TENTHS_BPS__/$tf/g; s/__BASE_UNDERCUT_TENTHS_BPS__/$bu/g; s/__DEF_UNDERCUT_TENTHS_BPS__/$du/g; s/__BASE_BUFFER_TENTHS_BPS__/$bb/g; s/__DEF_BUFFER_TENTHS_BPS__/$db/g; s/__ENTER_DEF_BPS__/$en/g; s/__EXIT_DEF_BPS__/$ex/g; s/__STRATEGY_NAME__/$name/g" "$out"
done

echo "Generated ${#variants[@]} pgate variants"
