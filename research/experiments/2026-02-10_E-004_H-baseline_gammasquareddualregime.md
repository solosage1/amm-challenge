# Experiment E-004 — GammaSquaredDualRegime

- Date: 2026-02-10
- Hypothesis: H-baseline
- Strategy file: `.ralph-amm/phase7/generated/phase7_strategy_19.sol`
- Git SHA: `aa8750d`
- ⚠️ Working directory had uncommitted changes

## Goal

Validate hypothesis and measure strategy performance.

## Change summary

Strategy: GammaSquaredDualRegime
Parameters: (extracted from template)

## Commands run

```bash
python scripts/amm-test-pipeline.py .ralph-amm/phase7/generated/phase7_strategy_19.sol \
  --output .ralph-amm/state/last_result.json
```

## Results

### Edge Scores

- 10 sims: Edge 534.25
- 100 sims: Edge 519.67
- 1000 sims: Edge 506.17

### Comparative Metrics (vs 30 bps Normalizer)

**Edge Comparison:**
- Submission: 506.17
- Normalizer: 389.83
- Advantage: +116.33 ✓

**Volume Diagnostics:**
- Retail (submission): 70381.16 (-21.4% vs normalizer)
- Arb (submission): 22282.01 (-53.2% vs normalizer)

**Fee Diagnostics:**
- Avg bid fee: 48.55 bps
- Avg ask fee: 49.36 bps
- Asymmetry (ask - bid): 0.81 bps

**Edge Distribution:**
- p05: 368.88
- p50: 505.07
- p95: 653.83

**Win/Loss/Draw:** 1000 / 0 / 0 (100.0% win rate)

**Runtime:** 73.8s total

## Interpretation

✅ **Strong positive result**: Edge advantage of 116.33 suggests strategy significantly outperforms normalizer.

## Decision / next steps

- [To be filled based on analysis]
