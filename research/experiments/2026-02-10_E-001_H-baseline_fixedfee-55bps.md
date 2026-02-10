# Experiment E-001 — FixedFee_55bps

- Date: 2026-02-10
- Hypothesis: H-baseline
- Strategy file: `.ralph-amm/generated/strategy_009_task_1_8.sol`
- Git SHA: `6b6921f`
- ⚠️ Working directory had uncommitted changes

## Goal

Establish baseline performance curve for fixed fee strategies.

## Change summary

Strategy: FixedFee_55bps
Parameters: (extracted from template)

## Commands run

```bash
python scripts/amm-test-pipeline.py .ralph-amm/generated/strategy_009_task_1_8.sol \
  --output .ralph-amm/state/last_result.json
```

## Results

### Edge Scores

- 10 sims: Edge 396.71
- 100 sims: Edge 383.97
- 1000 sims: Edge 373.31

### Comparative Metrics (vs 30 bps Normalizer)

**Edge Comparison:**
- Submission: 373.31
- Normalizer: 469.38
- Advantage: -96.07 ✗

**Volume Diagnostics:**
- Retail (submission): 52102.11 (-51.7% vs normalizer)
- Arb (submission): 19616.86 (-64.9% vs normalizer)

**Fee Diagnostics:**
- Avg bid fee: 55.00 bps
- Avg ask fee: 55.00 bps
- Asymmetry (ask - bid): 0.00 bps

**Edge Distribution:**
- p05: 279.39
- p50: 372.88
- p95: 471.95

**Win/Loss/Draw:** 0 / 1000 / 0 (0.0% win rate)

**Runtime:** 49.6s total

## Interpretation

✗ **Underperformance**: Edge advantage of -96.07 indicates strategy underperforms normalizer.

## Decision / next steps

- [To be filled based on analysis]
