# Phase 7 Quick Reference Card

## Launch Commands

```bash
# Test run (1 iteration, ~5-15 min)
bash scripts/ralph-amm-phase7.sh --max-iterations 1

# Short test (3 iterations, ~30-45 min)
bash scripts/ralph-amm-phase7.sh --max-iterations 3

# Production run (10 hours autonomous)
nohup bash scripts/ralph-amm-phase7.sh > phase7_run.log 2>&1 &
echo $! > .ralph-amm/phase7/phase7.pid
```

## Monitoring Commands

```bash
# Comprehensive dashboard (recommended)
bash scripts/monitor-phase7.sh

# Raw log tail
tail -f phase7_run.log

# Quick status check
cat .ralph-amm/phase7/state/.iteration_count.txt  # Iteration
cat .ralph-amm/phase7/state/.best_edge.txt        # Best edge
```

## Progress Tracking

```bash
# Check if running
ps aux | grep ralph-amm-phase7.sh | grep -v grep

# Check Codex activity
ls -lh .ralph-amm/phase7/state/iteration_*_codex_response.json | tail -1

# Event count (higher = more progress)
wc -l .ralph-amm/phase7/state/iteration_*_codex_response.json | tail -1

# Check for completion
tail -1 .ralph-amm/phase7/state/iteration_*_codex_response.json | jq -r .type
```

## Quality Checks

```bash
# Success rate
jq 'length' .ralph-amm/phase7/state/.strategies_log.json

# Latest results
jq '.[-5:]' .ralph-amm/phase7/state/.strategies_log.json

# Templates created
jq '.' .ralph-amm/phase7/state/.templates_created.json
```

## Control Commands

```bash
# Stop gracefully (after current iteration)
kill $(cat .ralph-amm/phase7/phase7.pid)

# Force stop (not recommended - may corrupt state)
kill -9 $(cat .ralph-amm/phase7/phase7.pid)

# Resume if interrupted (state persists)
bash scripts/ralph-amm-phase7.sh
```

## Understanding Codex Behavior

### With xhigh Reasoning (Current Config)

**Expected per iteration**:
- Exploration: 2-5 minutes (reads codebase)
- Reasoning: 3-7 minutes (analyzes strategy)
- Generation: 1-2 minutes (produces code)
- **Total: 6-15 minutes per iteration**

**116 events in JSONL** = normal for complex reasoning

**No output yet after 8 minutes** = still reasoning (be patient)

### Signs of Progress

✅ **Good signs**:
- File size growing (143KB+)
- New reasoning items appearing
- Event count increasing
- Latest reasoning shows strategy analysis

⚠️ **Warning signs**:
- No events for 5+ minutes
- File size stopped growing
- Stuck on same reasoning topic

## Exit Conditions

**Automatic exit when either**:
1. 10 hours elapsed
2. Edge > 527 achieved

**Manual exit**:
- Ctrl+C in foreground
- `kill $(cat .ralph-amm/phase7/phase7.pid)` in background

## After Completion

```bash
# View final report
cat .ralph-amm/phase7/PHASE7_FINAL_REPORT.md

# Check champion strategy
cat .ralph-amm/phase7/state/.best_strategy.sol

# Test robustness
python scripts/amm-learning-engine.py robustness-check \
  --strategy .ralph-amm/phase7/state/.best_strategy.sol --batches 3

# Review all templates
ls -la .ralph-amm/phase7/templates/
```

## Troubleshooting

**Codex taking > 15 minutes on one iteration**:
```bash
# Check if stuck
tail -20 .ralph-amm/phase7/state/iteration_*_codex_response.json

# If stuck, interrupt and restart
kill $(cat .ralph-amm/phase7/phase7.pid)
bash scripts/ralph-amm-phase7.sh
```

**High failure rate (>30%)**:
```bash
# Review recent failures
jq '.[] | select(.final_edge == null or .final_edge == 0)' \
  .ralph-amm/phase7/state/.strategies_log.json | tail -3

# Check validation errors in test results
ls -t .ralph-amm/phase7/state/iteration_*_result.json | head -1 | xargs jq .
```

**No improvement after 20 iterations**:
```bash
# Check hypothesis coverage
python scripts/amm-learning-engine.py hypotheses \
  --state-dir .ralph-amm/phase7/state

# Review what's being tested
jq '.[-10:] | .[] | {name, hypothesis_ids, edge}' \
  .ralph-amm/phase7/state/.strategies_log.json
```

## Performance Targets

### Per Iteration (with xhigh reasoning)
- Prompt build: 1s
- Codex generation: 6-15 min
- Code extraction: <1s
- Testing: 30-120s
- **Total: 7-17 minutes**

### 10-Hour Run
- Projected iterations: 35-85 (with xhigh reasoning)
- Target: >50 iterations
- Success rate target: >70%

### Quality Metrics
- **MVP**: Best edge > 374.56, 1+ template
- **Target**: Best edge > 400, 3+ templates
- **Stretch**: Best edge > 527 (competitive)

## Key Files

**State tracking**:
- `.ralph-amm/phase7/state/.iteration_count.txt` - Current iteration
- `.ralph-amm/phase7/state/.best_edge.txt` - Best edge
- `.ralph-amm/phase7/state/.best_strategy.sol` - Champion strategy

**Logs**:
- `phase7_run.log` - Main execution log
- `.ralph-amm/phase7/state/iteration_N_codex_response.json` - Codex JSONL events
- `.ralph-amm/phase7/state/iteration_N_result.json` - Test results

**Output**:
- `.ralph-amm/phase7/generated/phase7_strategy_N.sol` - Generated strategies
- `.ralph-amm/phase7/templates/*.sol.template` - Extracted templates
- `.ralph-amm/phase7/PHASE7_FINAL_REPORT.md` - Final report
