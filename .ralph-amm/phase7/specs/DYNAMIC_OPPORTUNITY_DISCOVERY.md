# Dynamic Opportunity Discovery v1.2 (Minimal Patch)

**Spec Version**: 1.2  
**Status**: Proposed  
**Date**: 2026-02-11  
**Scope**: Minimal, high-leverage changes only

---

## 1. Executive Summary

This version intentionally narrows scope to the smallest patch set that delivers most of the practical value without destabilizing the loop.

### 1.1 Correction Applied

The prior assumption that orthogonal forcing still required "all recent attempts" was outdated.  
Current engine already uses pressure-based logic and includes a stall floor path.

What remains is to tune behavior and improve learning quality:

1. Tighten stall trigger to `6 of last 8 no-uplift`.
2. Add EWMA delta memory to scoring.
3. Add conformance visibility to history/priors.

### 1.2 Why Minimal

We already have expanded family coverage and exploration knobs. The bottleneck is decision quality and hypothesis fidelity, not family count.

---

## 2. Objectives

1. Improve scoring responsiveness to repeated underperformance.
2. Reduce contamination from planned-vs-actual mismatch.
3. Keep all changes backward-compatible and low-risk.

### Non-Goals (for this patch)

1. No dynamic overlay engine.
2. No adaptive meta-weight optimizer.
3. No mechanism catalog / causal graph system.
4. No major schema migrations.

---

## 3. Current State (Relevant)

Already in place:

1. Expanded static family catalog.
2. Novelty and breakthrough score boosts.
3. Pressure-based orthogonal forcing.
4. Stall-floor forcing pathway.

Gap:

1. Scoring still overweights short-horizon signals.
2. No EWMA memory of persistent family/subfamily drift.
3. Mismatch is tracked implicitly (`subfamily_confidence`) but not quantified as conformance.

---

## 4. Minimal Patch Scope

### A) Exploration Trigger Tuning (No New Logic)

Tune existing stall-floor knobs to desired policy:

1. `lookback = 8`
2. `stall_min_no_uplift = 6`

This gives "ANY 6 of last 8 no-uplift" behavior via existing code path.

### B) EWMA Delta Tracking + Penalty

Track EWMA delta in priors and apply a small score penalty for persistent negative EWMA.

Formulas:

1. `ewma_delta_new = alpha * delta + (1 - alpha) * ewma_delta_old`
2. Apply penalty only if `ewma_delta < threshold`:
   - default `threshold = -0.20`
   - default max penalty `2.0` score points

### C) Conformance Visibility (Logging Only)

Add explicit conformance fields in history:

1. `conformance_score` (0.0 to 1.0)
2. `conformance_required`
3. `conformance_matched`
4. `conformance_missing`
5. `planned_vs_actual_match` (bool)

No gating in this patch. Visibility first.

---

## 5. Exact File/Function Diffs

## 5.1 `scripts/amm-phase7-opportunity-engine.py`

### `build_candidates(...)`

Add optional EWMA-based penalty at opportunity level:

1. Read `priors[c.id].ewma_delta` if present.
2. If below threshold, reduce `confidence` and/or `weighted_score` by bounded amount.
3. Include EWMA metadata in rationale and ranking output:
   - `ewma_delta`
   - `ewma_penalty`

Suggested logic:

```python
ewma_delta = safe_float(prior.get("ewma_delta"))
if ewma_delta is not None and ewma_delta < ewma_penalty_threshold:
    depth = min(1.0, abs(ewma_delta - ewma_penalty_threshold) / 0.8)
    ewma_penalty = depth * ewma_penalty_max
    c.confidence = clamp(c.confidence - 0.5 * ewma_penalty)
    c.weighted_score = max(0.0, c.weighted_score - ewma_penalty)
```

### `record(args)`

Update EWMA at both opportunity and subfamily bucket:

1. `bucket["ewma_delta"]`
2. `sub_bucket["ewma_delta"]`
3. `bucket["ewma_count"]`, `sub_bucket["ewma_count"]`

Only update when `delta` is available.

Suggested logic:

```python
alpha = float(args.ewma_alpha)
if delta is not None:
    prev = safe_float(bucket.get("ewma_delta"))
    bucket["ewma_delta"] = delta if prev is None else alpha * delta + (1 - alpha) * prev
    bucket["ewma_count"] = int(bucket.get("ewma_count", 0)) + 1
```

### `record(args)` history entry

Add conformance visibility fields:

1. `planned_vs_actual_match = (final_subfamily == selected_subfamily)` when both set.
2. `conformance_required = 1`
3. `conformance_matched = 1 if planned_vs_actual_match else 0`
4. `conformance_score = conformance_matched / conformance_required`
5. `conformance_missing = [] or ["subfamily_mismatch"]`

This keeps implementation simple and deterministic without signature extraction.

### `argparse` additions

Add evaluate flags:

```text
+ --ewma-penalty-threshold FLOAT   # default -0.20
+ --ewma-penalty-max FLOAT         # default 2.0
```

Add record flags:

```text
+ --ewma-alpha FLOAT               # default 0.30
```

---

## 5.2 `scripts/ralph-amm-phase7.sh`

### Config defaults

Set tuned defaults for existing stall-floor knobs:

1. `AUTO_OPP_EXPLORE_STALL_LOOKBACK=8`
2. `AUTO_OPP_EXPLORE_STALL_MIN_NO_UPLIFT=6`

Add EWMA knobs:

1. `AUTO_OPP_EWMA_ALPHA=0.30`
2. `AUTO_OPP_EWMA_PENALTY_THRESHOLD=-0.20`
3. `AUTO_OPP_EWMA_PENALTY_MAX=2.0`

### `run_opportunity_evaluate()`

Pass through:

1. `--ewma-penalty-threshold "$AUTO_OPP_EWMA_PENALTY_THRESHOLD"`
2. `--ewma-penalty-max "$AUTO_OPP_EWMA_PENALTY_MAX"`

### `record_opportunity_outcome()`

Pass through:

1. `--ewma-alpha "$AUTO_OPP_EWMA_ALPHA"`

### CLI usage + parser

Add options:

```text
+ --auto-opp-ewma-alpha FLOAT
+ --auto-opp-ewma-penalty-threshold FLOAT
+ --auto-opp-ewma-penalty-max FLOAT
```

---

## 6. Exact Schema Diffs (Additive Only)

## 6.1 `.opportunity_priors.json`

Add optional fields at opportunity level:

```json
{
  "ewma_delta": 0.0,
  "ewma_count": 0
}
```

Add optional fields at subfamily level:

```json
{
  "ewma_delta": 0.0,
  "ewma_count": 0
}
```

## 6.2 `.opportunity_history.json` entry

Add fields:

```json
{
  "planned_vs_actual_match": true,
  "conformance_score": 1.0,
  "conformance_required": 1,
  "conformance_matched": 1,
  "conformance_missing": []
}
```

## 6.3 `opportunity_rankings_iter*.json`

Add optional per-opportunity fields:

```json
{
  "ewma_delta": -0.28,
  "ewma_penalty": 0.6
}
```

No required shape changes elsewhere.

---

## 7. Scoring Behavior After Patch

Scoring becomes incrementally adaptive through EWMA memory:

1. Repeatedly negative outcomes reduce future ranking pressure.
2. Families that recover will naturally climb as EWMA mean-reverts.
3. Conformance visibility lets us separate true hypothesis failures from execution drift.

This improves selection without introducing a second scoring framework.

---

## 8. Rollout Plan

### Phase 1 (shadow, 3-5 iterations)

1. Enable logging and EWMA updates.
2. Keep EWMA penalty effectively off (`penalty_max=0`) for validation.

### Phase 2 (canary, 5-10 iterations)

1. Enable EWMA penalty with default max `2.0`.
2. Monitor selection shifts and no-uplift ratio.

### Phase 3 (steady state)

1. Keep tuned stall defaults (`8/6`).
2. Tune EWMA threshold/max only if regression appears.

---

## 9. Acceptance Criteria

1. Backward compatible JSON and CLI behavior when new knobs are unset.
2. History includes conformance fields for >=95% of executed iterations.
3. Priors include EWMA fields for selected opportunities/subfamilies.
4. During stalls, repeated failing families lose rank pressure within 3-5 iterations.
5. No regression in iteration success rate or runtime guardrails.

---

## 10. Monitoring Commands

```bash
# EWMA by opportunity
jq 'to_entries[] | {opp: .key, ewma: .value.ewma_delta, n: .value.ewma_count}' \
  .ralph-amm/phase7/state/.opportunity_priors.json

# Conformance trend
jq '[.[] | select(.conformance_score != null) | .conformance_score] | add/length' \
  .ralph-amm/phase7/state/.opportunity_history.json

# Ranking EWMA penalties
jq '.ranked_opportunities[] | {id, weighted_score, ewma_delta, ewma_penalty}' \
  .ralph-amm/phase7/state/opportunity_rankings_iter*.json
```

---

## 11. Deferred Items

Deferred to later versions:

1. Dynamic opportunity overlay.
2. Adaptive meta-weight tuning.
3. Mechanism catalog and lift correlation engine.
4. Signature-level conformance matching.

This keeps v1.2 tightly focused on practical, low-risk gains.

