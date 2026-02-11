# Iter 11 Remediation Spec: Authoritative Evaluation Safety and Ops Correctness

## Status
- Proposed
- Date: 2026-02-11
- Scope: `scripts/simplified_loop.py`, `tests/test_phase7_simplified_loop.py`, `.ralph-amm/phase7/docs/SIMPLIFIED_LOOP_RUNBOOK.md`

## Background
This spec remediates four review findings from the post-deep-dive implementation:

1. Bootstrap may promote non-authoritative (screen-only) candidates.
2. Non-authoritative evaluations currently influence mechanism learning and rollback triggers.
3. A new test stub does not match the updated `subprocess.run(...)` signature.
4. The runbook still contains pre-bootstrap champion/mechanism assumptions.

## Findings (Traceability)
- Bootstrap promotion risk:
  - `scripts/simplified_loop.py:1734`
  - `scripts/simplified_loop.py:1738`
  - `scripts/simplified_loop.py:1753`
  - `scripts/simplified_loop.py:1757`
  - `scripts/simplified_loop.py:1766`
- Non-authoritative stats/rollback pollution:
  - `scripts/simplified_loop.py:2075`
  - `scripts/simplified_loop.py:2117`
  - `scripts/simplified_loop.py:2142`
  - `scripts/simplified_loop.py:2144`
  - `scripts/simplified_loop.py:1598`
  - `scripts/simplified_loop.py:1617`
- Test stub signature mismatch:
  - `scripts/simplified_loop.py:1421`
  - `tests/test_phase7_simplified_loop.py:622`
- Stale runbook assumptions:
  - `.ralph-amm/phase7/docs/SIMPLIFIED_LOOP_RUNBOOK.md:110`
  - `.ralph-amm/phase7/docs/SIMPLIFIED_LOOP_RUNBOOK.md:138`
  - `.ralph-amm/phase7/docs/SIMPLIFIED_LOOP_RUNBOOK.md:157`
  - `.ralph-amm/phase7/docs/SIMPLIFIED_LOOP_RUNBOOK.md:160`

## Goals
- Ensure champion writes are authoritative-only.
- Ensure non-authoritative evaluations do not bias selection or rollback safety logic.
- Ensure screen-only evaluations are telemetry-only for mechanism-selection pressure.
- Restore test validity under the new evaluator runtime call shape.
- Align ops documentation with BandShield bootstrap reality and current mechanism taxonomy.

## Non-Goals
- No strategy logic changes inside Solidity candidates.
- No changes to `scripts/amm-test-pipeline.py` gate semantics.
- No rewrite of UCB formula beyond swapping to authoritative counters.

## Design Decisions

### Decision A: Bootstrap must require promotable winners
Bootstrap selection will only consider candidates with `promotable == true` and non-null `promotion_edge`.

Rationale:
- `final_edge`/`final_score` are authoritative only when 1000-sim stage runs.
- Allowing screen-only bootstrap can replace champion with unverified candidates.

### Decision B: UCB learning uses authoritative counters only
Mechanism-selection pressure (both exploit and explore terms) will be computed from authoritative attempts only.

Rationale:
- Screen-only values are useful telemetry, not promotion-quality evidence.
- UCB exploit and rollback should not react to preliminary screening noise.

### Decision C: Preserve observability for screen-only runs
Non-authoritative runs remain logged and counted in separate telemetry counters.

Rationale:
- We still want throughput visibility and evidence that the loop is exploring.

### Decision D: Legacy-log compatibility is fail-open for rollback safety
When `authoritative_eval` is missing in historical log rows, derive authority from legacy fields; if not derivable, treat as authoritative.

Rationale:
- A fail-closed default (`False`) can suppress severe/cumulative rollback checks after rollout.
- Fail-open preserves existing safety posture for old data while new rows become explicit.

### Decision E: Rollout requires loop quiesce and state snapshot
No remediation patch is applied while the loop is actively writing state.

Rationale:
- Concurrent writes can race schema/logic updates and corrupt interpretation of counters/logs.

## Resolved Questions
- Should screen-only runs affect exploration?
  - Decision: no. They affect telemetry only (`tries_total`, `screen_only_tries`) and do not enter UCB score inputs.
- How should old log rows without `authoritative_eval` be handled?
  - Decision: use fallback (`promotable`, `screen_only_eval`, nested `evaluation.*`) and default to authoritative when unknown.

## Remediation Plan

### 1) Bootstrap hardening (`scripts/simplified_loop.py`)

#### Required behavior changes
- During `bootstrap_champion(...)`, construct:
  - `authoritative_winners`: candidates where:
    - `summary` exists
    - `summary["promotable"] == True`
    - `summary["promotion_edge"] is not None`
  - `non_authoritative_candidates`: evaluated candidates that were not promotable.
- If `authoritative_winners` is empty:
  - Return failure payload:
    - `status: "bootstrap_failed"`
    - `reason: "no_authoritative_candidates"`
    - include full `evaluations`
    - include optional `best_screen_candidate` (highest `primary_edge`) for operator context
  - Do not mutate champion files or stats.
- Winner selection must rank only authoritative winners by:
  1. `promotion_edge` descending
  2. deterministic stable tie-breaker (`index` ascending)
- Remove `primary_edge` fallback for chosen bootstrap edge.
- Output payload must include:
  - `rejected_non_promotable_count`
  - `rejected_non_promotable_sources`

#### Acceptance criteria
- Bootstrap never writes `.best_strategy.sol`/`.best_edge.txt` unless selected winner is promotable.
- A full screen-only bootstrap run ends in `bootstrap_failed: no_authoritative_candidates`.

### 2) Authoritative-only mechanism learning (`scripts/simplified_loop.py`)

#### Required behavior changes
- Add explicit per-iteration flag:
  - `authoritative_eval = bool(promotable)`
  - include in iteration log entry as `authoritative_eval`.
- Split mechanism counters:
  - `tries_total`: increments for all valid completed iterations.
  - `tries_authoritative`: increments only when `authoritative_eval == true`.
  - `screen_only_tries`: increments only when `authoritative_eval == false`.
- UCB input switch in `select_mechanism(...)`:
  - replace all `tries` usages with `tries_authoritative` (with backward fallback to legacy `tries` when needed).
  - `total_tries` in exploration term must be authoritative aggregate only.
  - `untried` determination must be based on authoritative tries only.
- Exploit metric updates:
  - only when `authoritative_eval` is true:
    - update `total_uplift`
    - update `successes`
    - update `best_delta`
- Legacy compatibility:
  - keep `tries` persisted as an alias of `tries_authoritative` for existing tooling, or update all consumers to `tries_authoritative` in the same patch set.
  - if alias strategy is used, `tries` must never include screen-only attempts.
- Update default mechanism stats structure to include:
  - `tries_total: 0`
  - `tries_authoritative: 0`
  - `screen_only_tries: 0`
- Update stats syncing/migration path so existing state files receive missing keys with default `0`.

#### Acceptance criteria
- Completed screen-only iteration increases `tries_total` and `screen_only_tries` only.
- Completed authoritative iteration increases `tries_total` and `tries_authoritative`, and updates exploit metrics.
- Adding screen-only rows does not change relative UCB scores across mechanisms.

### 3) Authoritative-only rollback regression inputs (`scripts/simplified_loop.py`)

#### Required behavior changes
- Add helper `is_authoritative_log_entry(entry: Dict[str, Any]) -> bool` with fallback order:
  1. If `authoritative_eval` key exists, return that value.
  2. Else if `promotable` key exists, return `promotable`.
  3. Else if `screen_only_eval` key exists, return `not screen_only_eval`.
  4. Else if nested `evaluation.promotable` exists, return it.
  5. Else if nested `evaluation.screen_only` exists, return `not evaluation.screen_only`.
  6. Else return `True` (legacy fail-open default).
- In `update_rollback_status(...)`, define `authoritative_valid_entries` as:
  - `entry["valid"] == True`
  - `entry["delta"] is not None`
  - `is_authoritative_log_entry(entry) == True`
- Use `authoritative_valid_entries` for:
  - severe regression check
  - cumulative loss window check
- Keep consecutive invalid logic unchanged (invalid is still invalid).

#### Acceptance criteria
- Non-authoritative negative deltas do not trigger severe or cumulative rollback.
- Authoritative negative deltas preserve rollback behavior.
- Legacy `iteration_log.jsonl` rows missing `authoritative_eval` continue to participate in rollback checks unless explicitly marked screen-only by legacy fields.

### 4) Test fixes and added coverage (`tests/test_phase7_simplified_loop.py`)

#### Required behavior changes
- Update `fake_run(...)` stubs to accept runtime kwargs used by evaluator:
  - `cwd`, `env`, and future kwargs via `**kwargs`.

#### New tests to add
- `test_bootstrap_champion_rejects_non_promotable_candidates`
  - all candidate summaries return `promotable=False`
  - expect non-zero exit, no champion mutation.
- `test_update_rollback_status_ignores_non_authoritative_valid_entries`
  - feed log rows with severe negative deltas but `authoritative_eval=False`
  - assert rollback not triggered by those rows alone.
- `test_update_rollback_status_legacy_rows_use_fallback_authority`
  - omit `authoritative_eval` and provide legacy fields (`promotable` or `screen_only_eval`)
  - assert rollback logic follows fallback semantics.
- `test_run_iteration_screen_only_updates_only_screen_counters`
  - verify `tries_total` and `screen_only_tries` increment
  - verify authoritative try counter is unchanged
  - verify no success/uplift/best-delta mutation.
- `test_select_mechanism_ignores_screen_only_tries_for_ucb`
  - construct mechanism stats where only telemetry counters differ
  - assert selection score parity is unchanged.

#### Acceptance criteria
- Existing screen-only evaluator test passes with updated stub signature.
- New tests enforce authoritative-only safety invariants.

### 5) Runbook alignment (`.ralph-amm/phase7/docs/SIMPLIFIED_LOOP_RUNBOOK.md`)

#### Required behavior changes
- Remove hardcoded reset-to-`GammaSquaredDualRegime` and `509.23`.
- Replace reset guidance with two explicit options:
  1. Reinitialize stats around current champion (no champion replacement)
  2. Re-bootstrap champion via `simplified_loop.py bootstrap --from ...`
- Update troubleshooting example to current mechanism taxonomy:
  - replace `flow_memory` example with `fair_price_and_arb` (or current key from definitions).
  - replace sample candidate filename accordingly.
- Add command to list active mechanism keys from definitions for operator sanity.

#### Acceptance criteria
- No runbook command references obsolete mechanism names or hardcoded pre-bootstrap champion edge.

## Data Model and Compatibility
- `mechanism_stats.json` adds per-mechanism:
  - `tries_total`
  - `tries_authoritative`
  - `screen_only_tries`
- Backward compatibility:
  - missing new mechanism-stat keys default to `0` during load/sync.
  - legacy `tries` is interpreted as authoritative tries during migration.
  - if keeping `tries` for compatibility, it must mirror `tries_authoritative`.
- `iteration_log.jsonl` compatibility:
  - new rows always include `authoritative_eval`.
  - legacy rows are interpreted via `is_authoritative_log_entry(...)` fallback chain.
- Schema version handling:
  - preferred: bump schema from `2.0` to `2.1` to reflect new counters.
  - alternative: keep `2.0` and rely on lazy-key migration.

## Logging and Telemetry Changes
- Every `complete` entry includes:
  - `authoritative_eval` boolean
  - existing `promotable` and `screen_only_eval` retained
- Mechanism stats expose both policy and ops counters:
  - policy: `tries_authoritative`, `total_uplift`, `successes`, `best_delta`
  - ops: `tries_total`, `screen_only_tries`
- Bootstrap completion/failure payloads include explicit rejected non-promotable counts/sources.

## Validation Plan

### Static checks
- `python3 -m py_compile scripts/simplified_loop.py`

### Targeted unit tests
- `python3 -m pytest -q tests/test_phase7_simplified_loop.py -k "bootstrap or screen_only or rollback"`
- If local `pytest` missing, run via project interpreter once installed:
  - `venv_fresh/bin/python -m pytest ...`

### Behavioral spot checks
- Simulated bootstrap where all candidates are non-promotable:
  - expect `bootstrap_failed:no_authoritative_candidates`
- Simulated mixed promotable/non-promotable:
  - expect winner chosen from promotable set only
- Simulated screen-only iteration:
  - expect no uplift/success/best-delta side effects

## Rollout Sequence
1. Quiesce loop writers:
   - stop `run-loop` process and any active candidate-generation subprocesses.
   - verify no active writers for `mechanism_stats.json` / `iteration_log.jsonl`.
2. Take pre-change snapshot:
   - archive `.best_strategy.sol`, `.best_edge.txt`, `mechanism_stats.json`, `iteration_log.jsonl`, `policy_evolution_*`.
3. Patch bootstrap winner filtering and payloads.
4. Patch run-iteration stat accounting, UCB authoritative counters, and rollback filter logic.
5. Patch tests and add new coverage.
6. Patch runbook.
7. Run static checks and tests.
8. Execute one dry-run iteration and one controlled bootstrap smoke run.
9. Resume loop only after validation checks pass.

## Risks and Mitigations
- Risk: stricter bootstrap rejects all candidates in low-quality environments.
  - Mitigation: explicit failure payload includes best screen-only candidate and reasons.
- Risk: authoritative-only counters may reduce short-term adaptation speed.
  - Mitigation: retain telemetry counters (`tries_total`, `screen_only_tries`) for tuning screen thresholds without polluting UCB policy inputs.
- Risk: state files lacking new key.
  - Mitigation: sync/migration default injection for all new counters and legacy `tries` mapping.
- Risk: remediation applied while loop is live causes state races.
  - Mitigation: mandatory quiesce + snapshot rollout preflight.

## Review Checklist
- [ ] Bootstrap cannot write champion from non-promotable candidate.
- [ ] Rollback severe/cumulative checks use authoritative entries only.
- [ ] UCB exploit/explore terms are driven by authoritative tries only.
- [ ] Legacy log rows without `authoritative_eval` follow fallback semantics.
- [ ] Test stubs accept `cwd/env` kwargs.
- [ ] Runbook no longer references obsolete champion/mechanisms.
- [ ] Rollout includes quiesce + pre-change snapshot.
- [ ] All new/updated tests pass in environment with `pytest`.
