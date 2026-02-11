#!/usr/bin/env bash
set -euo pipefail

cd /Users/rbgross/amm-challenge

# name ENTER_MIS EXIT_MIS NORMAL_MIS ENTER_INV EXIT_INV NORMAL_INV DEF_CD REC_CD TIGHT_BAND NORM_TIGHT REC_TIGHT DEF_TIGHT NORM_BUF REC_BUF DEF_BUF NORM_UNDER REC_UNDER DEF_UNDER TILT_TRIG TILT_NORM TILT_DEF
variants=(
"canary_mode3_v1 46 30 22 190 150 130 3 2 25 28 27 30 1 1 4 11 14 1 170 2 3"
"canary_mode3_v2 42 28 20 170 130 115 3 2 25 28 27 30 1 1 5 11 15 1 150 2 4"
"canary_mode3_v3 50 32 24 210 170 150 4 2 26 28 27 30 1 1 5 10 14 2 190 1 3"
"canary_mode3_v4 40 26 19 160 120 105 2 2 24 28 27 30 1 1 4 12 16 1 145 2 3"
"canary_mode3_v5 44 30 21 180 140 120 2 3 25 28 27 30 1 1 4 11 15 0 165 2 3"
"canary_mode3_v6 48 31 23 200 160 140 3 3 26 28 27 30 1 1 5 11 15 1 180 1 3"
"canary_mode3_v7 43 29 21 175 135 120 3 2 25 28 27 30 1 1 4 11 13 1 155 2 3"
"canary_mode3_v8 47 30 22 195 150 130 4 2 25 28 27 30 1 1 5 10 13 2 175 1 4"
"canary_mode3_v9 41 27 19 165 125 110 2 2 24 28 27 30 1 1 4 12 15 1 145 3 4"
"canary_mode3_v10 45 29 21 185 145 125 3 1 25 28 27 30 1 1 4 11 14 0 165 2 3"
)

for v in "${variants[@]}"; do
  read -r name em xm nm ei xi ni dcd rcd tb nt rt dt nb rb db nu ru du tt tn td <<< "$v"
  out="${name}.sol"
  cp canary_mode3_template.sol "$out"
  perl -0pi -e "s/__ENTER_MIS_BPS__/$em/g; s/__EXIT_MIS_BPS__/$xm/g; s/__NORMAL_MIS_BPS__/$nm/g; s/__ENTER_INV_BPS__/$ei/g; s/__EXIT_INV_BPS__/$xi/g; s/__NORMAL_INV_BPS__/$ni/g; s/__DEF_COOLDOWN__/$dcd/g; s/__REC_COOLDOWN__/$rcd/g; s/__TIGHT_BAND_BPS__/$tb/g; s/__NORM_TIGHT_BPS__/$nt/g; s/__REC_TIGHT_BPS__/$rt/g; s/__DEF_TIGHT_BPS__/$dt/g; s/__NORM_BUF_BPS__/$nb/g; s/__REC_BUF_BPS__/$rb/g; s/__DEF_BUF_BPS__/$db/g; s/__NORM_UNDER_BPS__/$nu/g; s/__REC_UNDER_BPS__/$ru/g; s/__DEF_UNDER_BPS__/$du/g; s/__TILT_TRIGGER_BPS__/$tt/g; s/__TILT_NORM_BPS__/$tn/g; s/__TILT_DEF_BPS__/$td/g; s/__STRATEGY_NAME__/$name/g" "$out"
done

echo "Generated ${#variants[@]} variants"
