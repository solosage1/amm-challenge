#!/bin/bash
exec bash scripts/ralph-amm-phase7.sh \
  --auto-opp-enable \
  --auto-opp-shadow 0 \
  --auto-opp-canary 100 \
  --auto-opp-explore-enable \
  --auto-opp-breakthrough-eps 0.10 \
  --auto-opp-severe-subfamily-threshold 2 \
  --auto-opp-gates-fallback-polls 8 \
  --auto-opp-gates-fallback-poll-seconds 0.25 \
  --auto-opp-record-gates-fallback-enable \
  --auto-opp-ewma-penalty-max 1.0 \
  --auto-opp-conformance-weight-match 1.0 \
  --auto-opp-conformance-weight-partial 0.25 \
  --auto-opp-conformance-weight-mismatch 0.10
