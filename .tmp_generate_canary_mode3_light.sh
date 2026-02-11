#!/usr/bin/env bash
set -euo pipefail

cd /Users/rbgross/amm-challenge

# name enter exit_def exit_rec def_cd rec_cd def_buf def_under rec_under def_tight rec_tight
variants=(
"canary_mode3_light_l1 70 45 24 2 1 3 2 13 30 27"
"canary_mode3_light_l2 80 50 24 2 1 4 0 13 30 27"
"canary_mode3_light_l3 60 40 23 3 2 3 1 14 30 27"
"canary_mode3_light_l4 90 55 26 1 1 3 3 12 30 27"
"canary_mode3_light_l5 70 35 22 3 2 5 0 14 30 27"
"canary_mode3_light_l6 65 42 23 2 2 4 1 13 30 27"
)

for v in "${variants[@]}"; do
  read -r name en ex er dcd rcd db du ru dt rt <<< "$v"
  out="${name}.sol"
  cp canary_mode3_light_template.sol "$out"
  perl -0pi -e "s/__ENTER_DEF_BPS__/$en/g; s/__EXIT_DEF_BPS__/$ex/g; s/__EXIT_REC_BPS__/$er/g; s/__DEF_CD__/$dcd/g; s/__REC_CD__/$rcd/g; s/__DEF_BUF_BPS__/$db/g; s/__DEF_UNDER_BPS__/$du/g; s/__REC_UNDER_BPS__/$ru/g; s/__DEF_TIGHT_BPS__/$dt/g; s/__REC_TIGHT_BPS__/$rt/g; s/__STRATEGY_NAME__/$name/g" "$out"
done

echo "Generated ${#variants[@]} light variants"
