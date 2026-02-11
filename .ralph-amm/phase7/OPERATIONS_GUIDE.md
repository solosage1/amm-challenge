# Phase 7 Operations Guide

**Last Updated**: 2026-02-10
**Purpose**: Comprehensive operational guide for running the Phase 7 autonomous AI-powered strategy exploration loop

---

## Prerequisites Checklist

Before running Phase 7, ensure:

- [x] **Python environment**: `venv_fresh` exists with all dependencies
- [x] **Codex CLI installed**: `codex --version` shows version
- [x] **Codex permissions fixed**: `sudo chown -R $(whoami) ~/.codex && chmod -R u+rwX ~/.codex`
- [x] **Codex working**: Test with `echo "test" | codex exec --json --output-last-message /tmp/test.md -`
- [x] **Existing infrastructure**: amm-test-pipeline.py, amm-learning-engine.py operational
- [x] **Disk space**: >10GB available for 10-hour run

---

## Quick Start

### 1. Test Codex Permissions

**Always verify before launching**:
```bash
echo "Generate a simple AMM strategy" | codex exec --json --output-last-message /tmp/test.md -
cat /tmp/test.md  # Should show AI response
```

**If permission errors occur**:
```bash
sudo chown -R $(whoami) ~/.codex
chmod -R u+rwX ~/.codex
```

### 2. Launch Phase 7

**Short test (3 iterations)**:
```bash
cd /Users/rbgross/amm-challenge
bash scripts/ralph-amm-phase7.sh --max-iterations 3
```

**Production run (10 hours)**:
```bash
cd /Users/rbgross/amm-challenge

# Launch in background
nohup bash scripts/ralph-amm-phase7.sh > phase7_run.log 2>&1 &

# Save PID
echo $! > .ralph-amm/phase7/phase7.pid

# Monitor immediately
bash scripts/monitor-phase7.sh
```

### 3. Monitor Progress

**Option A: Dashboard (recommended)**:
```bash
bash scripts/monitor-phase7.sh
# Press Ctrl+C to exit monitoring (loop continues)
```

**Option B: Raw logs**:
```bash
tail -f phase7_run.log
```

**Option C: Quick checks**:
```bash
# Iteration count
cat .ralph-amm/phase7/state/.iteration_count.txt

# Best edge
cat .ralph-amm/phase7/state/.best_edge.txt

# Process status
ps aux | grep ralph-amm-phase7.sh | grep -v grep
```

---

## Understanding Codex Behavior

### Expected Performance

**With `reasoning effort: xhigh` (default config)**:
- **Exploration phase**: 2-5 minutes (reads codebase)
- **Reasoning phase**: 3-10 minutes (analyzes strategy)
- **Generation phase**: 1-3 minutes (produces code)
- **Total per iteration**: 6-18 minutes

**10-hour run projections**:
- **Optimistic**: 100+ iterations (if avg 6 min/iter)
- **Realistic**: 50-85 iterations (if avg 8-12 min/iter)
- **Conservative**: 35-50 iterations (if avg 12-18 min/iter)

### Signs of Healthy Progress

✅ **Good signs**:
- Codex JSONL file growing (check with `ls -lh`)
- Event count increasing (check with `wc -l`)
- Reasoning topics evolving (not stuck on same topic)
- Commands executed (exploration happening)
- New iterations completing

⚠️ **Warning signs**:
- Same reasoning topic repeated 10+ times
- No file growth for 5+ minutes
- All iterations failing (>80% failure rate)
- Permission errors in stderr files

### Codex Activity Patterns

**Normal exploration pattern**:
```
Reasoning → Command → Reasoning → Command → ... → Final Output
```

**Stuck pattern** (bad):
```
Reasoning → Reasoning → Reasoning → (no commands, same topic)
```

**Active pattern** (good):
```
Recent 20 events: 12 reasoning, 4 commands
Topics: Evolving from basic to specific
```

---

## Monitoring Commands

### Real-Time Monitoring

**Watch iteration progress**:
```bash
watch -n 10 'cat .ralph-amm/phase7/state/.iteration_count.txt'
```

**Watch Codex file growth**:
```bash
watch -n 5 'ls -lh .ralph-amm/phase7/state/iteration_*_codex.jsonl | tail -1'
```

**Check event count**:
```bash
watch -n 5 'wc -l .ralph-amm/phase7/state/iteration_*_codex.jsonl | tail -1'
```

### Health Checks

**Check recent activity** (last 30 events):
```bash
tail -30 .ralph-amm/phase7/state/iteration_*_codex.jsonl | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        if e.get('type') == 'item.completed':
            itype = e.get('item', {}).get('type', '')
            if itype == 'reasoning':
                text = e['item']['text'][:120]
                print(f'Reasoning: {text}...')
            elif itype == 'command_execution':
                cmd = e['item'].get('command', '')[:80]
                status = e['item'].get('status', '')
                print(f'Command: {cmd} [{status}]')
    except:
        pass
"
```

**Check success rate**:
```bash
python3 -c "
import json
log = json.load(open('.ralph-amm/phase7/state/.strategies_log.json'))
total = len(log)
ok = sum(1 for s in log if s.get('status') == 'ok')
print(f'Success rate: {ok}/{total} ({ok/total*100:.1f}%)')
"
```

**Check for completion events**:
```bash
grep -E '"type":"(turn\.ended|thread\.ended)"' \
  .ralph-amm/phase7/state/iteration_*_codex.jsonl | tail -5
```

### Performance Metrics

**Iteration rate calculation**:
```bash
python3 -c "
import time
iteration = int(open('.ralph-amm/phase7/state/.iteration_count.txt').read())
start = int(open('.ralph-amm/phase7/state/.start_timestamp.txt').read())
elapsed = time.time() - start

if iteration > 0:
    rate_per_hour = iteration / (elapsed / 3600)
    avg_time = elapsed / iteration
    remaining = 36000 - elapsed
    projected_total = iteration + (remaining / avg_time)

    print(f'Iterations: {iteration}')
    print(f'Rate: {rate_per_hour:.1f} iter/hour')
    print(f'Avg time: {avg_time:.1f} sec/iter')
    print(f'Projected total: {int(projected_total)}')
else:
    print('No iterations completed yet')
"
```

---

## Quality Control

### Failure Rate Monitoring

**Check failure rate**:
```bash
python3 -c "
import json
log = json.load(open('.ralph-amm/phase7/state/.strategies_log.json'))
if log:
    failures = sum(1 for s in log if s.get('status') != 'ok')
    total = len(log)
    rate = failures / total * 100

    print(f'Failure rate: {rate:.1f}%')
    if rate > 50:
        print('❌ CRITICAL: Stop and review')
    elif rate > 30:
        print('⚠️  WARNING: Monitor closely')
    else:
        print('✓ Acceptable')
"
```

**Review recent failures**:
```bash
python3 -c "
import json
log = json.load(open('.ralph-amm/phase7/state/.strategies_log.json'))
failures = [s for s in log if s.get('status') != 'ok'][-5:]

print('Recent 5 failures:')
for f in failures:
    iter_num = f['iteration']
    status = f['status']
    stage = f.get('error', {}).get('stage', 'unknown')
    msg = f.get('error', {}).get('message', '')[:60]
    print(f'  Iter {iter_num}: {status} [{stage}] {msg}')
"
```

### Plateau Detection

**Check if stuck**:
```bash
python3 -c "
import json
log = json.load(open('.ralph-amm/phase7/state/.strategies_log.json'))
ok_entries = [s for s in log if s.get('status') == 'ok']

if len(ok_entries) >= 10:
    recent = [s['final_edge'] for s in ok_entries[-10:]]
    mean = sum(recent) / len(recent)
    variance = sum((e - mean) ** 2 for e in recent) / len(recent)
    std_dev = variance ** 0.5

    print(f'Recent 10: mean={mean:.2f}, σ={std_dev:.2f}')
    if std_dev < 2.0:
        print('⚠️  Plateau detected (σ < 2.0)')
    else:
        print('✓ Healthy variance')
"
```

---

## Control & Management

### Stopping the Loop

**Graceful stop** (recommended):
```bash
# After current iteration completes
kill $(cat .ralph-amm/phase7/phase7.pid)
```

**Force stop** (use only if necessary):
```bash
# Immediate termination (may corrupt current iteration)
kill -9 $(cat .ralph-amm/phase7/phase7.pid)
```

### Resuming

**After graceful stop**:
```bash
# State persists automatically
bash scripts/ralph-amm-phase7.sh

# Or in background
nohup bash scripts/ralph-amm-phase7.sh > phase7_run.log 2>&1 &
```

**After force stop**:
```bash
# Check state integrity first
cat .ralph-amm/phase7/state/.iteration_count.txt
cat .ralph-amm/phase7/state/.best_edge.txt
jq '.' .ralph-amm/phase7/state/.strategies_log.json | head

# If valid, resume normally
bash scripts/ralph-amm-phase7.sh
```

---

## Troubleshooting

### Issue: Codex Permission Errors

**Symptoms**:
```
ERROR: Operation not permitted (os error 1)
Codex cannot access /Users/rbgross/.codex/sessions
```

**Fix**:
```bash
sudo chown -R $(whoami) ~/.codex
chmod -R u+rwX ~/.codex
```

**Verify**:
```bash
echo "test" | codex exec --json --output-last-message /tmp/test.md -
```

### Issue: High Failure Rate (>50%)

**Check what's failing**:
```bash
# Look at recent stderr files
ls -t .ralph-amm/phase7/state/iteration_*_codex.stderr | head -3 | xargs tail -20

# Check extraction failures
ls -t .ralph-amm/phase7/state/iteration_*_last_message.md | head -1 | xargs cat
```

**Common causes**:
1. Codex not following structured format → Review prompt template
2. Validation failures → Check SolidityValidator constraints
3. API errors → Check stderr for rate limits or auth issues

### Issue: Slow Iteration Rate (<2 iter/hour)

**Diagnosis**:
```bash
# Check if Codex is stuck in exploration
tail -50 .ralph-amm/phase7/state/iteration_*_codex.jsonl | \
  python3 -c "
import sys, json
reasoning_count = 0
command_count = 0
for line in sys.stdin:
    try:
        e = json.loads(line)
        if e.get('type') == 'item.completed':
            itype = e.get('item', {}).get('type', '')
            if itype == 'reasoning': reasoning_count += 1
            elif itype == 'command_execution': command_count += 1
    except: pass

print(f'Recent 50 events: {reasoning_count} reasoning, {command_count} commands')
if reasoning_count > 40 and command_count < 5:
    print('⚠️  Stuck in reasoning loop')
else:
    print('✓ Normal exploration pattern')
"
```

**Actions**:
- If stuck: Kill and restart (Ctrl+C)
- If normal: Be patient - xhigh reasoning takes time

### Issue: No Improvement After 20+ Iterations

**Check hypothesis coverage**:
```bash
python3 scripts/amm-learning-engine.py hypotheses \
  --state-dir .ralph-amm/phase7/state
```

**Review strategy patterns**:
```bash
jq '.[-10:] | .[] | {iteration, name: .strategy_name, edge: .final_edge, hypothesis: .hypothesis_ids}' \
  .ralph-amm/phase7/state/.strategies_log.json
```

**Possible causes**:
- All hypotheses explored → May need new approach
- Plateau reached → Consider parameter optimization instead
- Prompt needs refinement → Adjust for more exploration

---

## Post-Run Analysis

### Review Final Report

```bash
cat .ralph-amm/phase7/PHASE7_FINAL_REPORT.md
```

**Key metrics**:
- Total iterations
- Success rate
- Final best edge
- Templates created
- Hypothesis coverage

### Test Champion Strategy

**Robustness check** (3 seed batches):
```bash
python3 scripts/amm-learning-engine.py robustness-check \
  --strategy .ralph-amm/phase7/state/.best_strategy.sol --batches 3
```

**Expected output**:
- Mean edge: ~best_edge ± σ
- Assessment: Excellent (σ<5), Good (σ<10), Moderate (σ<15)

### Analyze Hypothesis Coverage

```bash
python3 scripts/amm-learning-engine.py hypotheses \
  --state-dir .ralph-amm/phase7/state
```

**Interpret**:
- **Supported** (improvement >5 points): Hypothesis validated
- **Marginal** (improvement 0-5 points): Weak signal
- **Neutral** (improvement -2 to 0): No effect
- **Rejected** (improvement <-2): Counterproductive

### Extract Insights

**Top performers**:
```bash
jq '[.[] | select(.status == "ok")] | sort_by(.final_edge) | reverse | .[0:5] | .[] | {iter: .iteration, name: .strategy_name, edge: .final_edge, hypothesis: .hypothesis_ids}' \
  .ralph-amm/phase7/state/.strategies_log.json
```

**Template summary**:
```bash
jq '.' .ralph-amm/phase7/state/.templates_created.json
```

---

## State Management

### State Directory Structure

```
.ralph-amm/phase7/state/
├── .iteration_count.txt         # Current iteration (scalar)
├── .best_edge.txt                # Best edge (scalar)
├── .start_timestamp.txt          # Unix timestamp (scalar)
├── .strategies_log.json          # Source of truth (array)
├── .templates_created.json       # Template registry (array)
├── .rate_limit_tracker.json      # API call tracking (object)
├── .best_strategy.sol            # Current champion (Solidity)
├── iteration_N_codex.jsonl       # JSONL event stream (per iteration)
├── iteration_N_codex.stderr      # Codex errors (per iteration)
├── iteration_N_last_message.md   # Final response (per iteration)
└── iteration_N_result.json       # Test results (per iteration)
```

### Backup Strategy

**Before long run**:
```bash
# Backup current state
tar -czf phase7_state_backup_$(date +%Y%m%d_%H%M%S).tar.gz \
  .ralph-amm/phase7/state/
```

**Periodic snapshots** (every 10 iterations):
```bash
# Add to cron or run manually
mkdir -p .ralph-amm/phase7/state/backups
cp -r .ralph-amm/phase7/state/.*.txt .ralph-amm/phase7/state/.*.json \
  .ralph-amm/phase7/state/backups/snapshot_$(date +%Y%m%d_%H%M%S)/
```

### State Recovery

**If state corrupted**:
```bash
# Restore from backup
tar -xzf phase7_state_backup_TIMESTAMP.tar.gz

# Or reset to Phase 1 baseline
echo "0" > .ralph-amm/phase7/state/.iteration_count.txt
echo "374.56" > .ralph-amm/phase7/state/.best_edge.txt
echo "[]" > .ralph-amm/phase7/state/.strategies_log.json
```

---

## Configuration Tuning

### Environment Variables

**Codex configuration**:
```bash
export CODEX_MODEL="claude-sonnet-4-5"  # or "" for default
export CODEX_MAX_OUTPUT_TOKENS=8000
export CODEX_TIMEOUT_MINUTES=20  # Timeout per iteration (default: 20min)
export CODEX_DISABLE_SHELL_TOOL=0  # Recommended: avoid stalls where stream stops after {turn.started}
```

**CRITICAL SANDBOX SETTING**:
The script now uses `--sandbox read-only` to prevent Codex from:
- Editing files (`arb_infer_protect.sol`, etc.)
- Running interactive grid searches (`amm-match run ...`)
- Getting stuck in internal optimization loops

This forces Codex to **output-only mode** - it can only return the structured response (DRAFT_STRATEGY_IDEA → DESIGN_REVIEW → REVISED_IMPLEMENTATION → STRATEGY_METADATA).

**Template extraction tuning**:
```bash
export TEMPLATE_MIN_EDGE=350.0        # Minimum edge to consider
export TEMPLATE_WITHIN_BEST=5.0       # Points from best to extract
export TEMPLATE_TOP_K=5               # Extract top-K strategies
```

**Runtime limits**:
```bash
# Override in command
bash scripts/ralph-amm-phase7.sh \
  --max-runtime 7200 \              # 2 hours
  --max-iterations 50 \             # Stop after 50
  --target-edge 450                 # Lower target
```

### Codex Reasoning Effort

**Your current config** (in ~/.codex/config.toml or similar):
```
model = "gpt-5.2"
provider = "openai"
reasoning effort = "xhigh"
```

**To speed up iterations** (less thorough):
```
reasoning effort = "medium"
```

**To improve quality** (slower):
```
reasoning effort = "xhigh"  # Already set
```

---

## Expected Outcomes

### Success Criteria

**Minimum Viable (MVP)**:
- [x] 50+ iterations completed
- [x] Best edge > 374.56
- [x] 1+ template extracted
- [x] <30% failure rate
- [x] System runs without crashes

**Target**:
- [ ] 100+ iterations completed
- [ ] Best edge > 400
- [ ] 3+ templates extracted
- [ ] All 6 core hypotheses explored
- [ ] <20% failure rate

**Stretch**:
- [ ] Best edge > 527 (competitive)
- [ ] Early exit before 10 hours
- [ ] 5+ templates extracted
- [ ] Novel mechanisms discovered

### Interpreting Results

**Edge improvements**:
- **+0 to +5**: Marginal (noise level)
- **+5 to +15**: Solid improvement
- **+15 to +30**: Strong signal
- **+30+**: Breakthrough (unlikely but possible)

**Template value**:
- **1-2 templates**: Incremental gains
- **3-5 templates**: Good coverage
- **5+ templates**: Comprehensive exploration

---

## Common Operational Patterns

### Pattern 1: 10-Hour Full Run

```bash
# 1. Launch
cd /Users/rbgross/amm-challenge
nohup bash scripts/ralph-amm-phase7.sh > phase7_run.log 2>&1 &
echo $! > .ralph-amm/phase7/phase7.pid

# 2. Monitor for first 30 minutes
bash scripts/monitor-phase7.sh
# Press Ctrl+C after verifying healthy operation

# 3. Check periodically (every 2 hours)
tail -20 phase7_run.log | grep -E "Iteration|Edge|Champion"

# 4. After completion
cat .ralph-amm/phase7/PHASE7_FINAL_REPORT.md
```

### Pattern 2: Iterative Development

```bash
# Run short batches, review, adjust
bash scripts/ralph-amm-phase7.sh --max-iterations 5
# Review results
cat .ralph-amm/phase7/PHASE7_FINAL_REPORT.md
# Adjust prompts/config as needed
# Repeat
```

### Pattern 3: Hypothesis-Focused Run

```bash
# Edit prompt template to focus on specific hypothesis
# (e.g., only H-001 fair price inference)
# Then run
bash scripts/ralph-amm-phase7.sh --max-iterations 20
```

---

## File Locations Reference

### Source Code
- `scripts/ralph-amm-phase7.sh` - Main orchestrator
- `scripts/amm-phase7-prompt-builder.py` - Prompt generation
- `scripts/amm-phase7-code-extractor.py` - Response parsing
- `scripts/amm-phase7-template-extractor.py` - Template creation
- `scripts/amm-phase7-report-generator.py` - Report generation
- `scripts/monitor-phase7.sh` - Real-time dashboard

### Documentation
- `.ralph-amm/phase7/README.md` - Comprehensive usage guide
- `.ralph-amm/phase7/QUICK_REFERENCE.md` - Command quick reference
- `.ralph-amm/phase7/OPERATIONS_GUIDE.md` - This file

### State & Logs
- `.ralph-amm/phase7/state/` - All state files
- `.ralph-amm/phase7/generated/` - Generated strategies
- `.ralph-amm/phase7/templates/` - Extracted templates
- `.ralph-amm/phase7/prompts/` - Generated prompts
- `phase7_run.log` - Main execution log

---

## Quick Reference Card

### Launch
```bash
nohup bash scripts/ralph-amm-phase7.sh > phase7_run.log 2>&1 &
echo $! > .ralph-amm/phase7/phase7.pid
```

### Monitor
```bash
bash scripts/monitor-phase7.sh
# or
tail -f phase7_run.log
```

### Stop
```bash
kill $(cat .ralph-amm/phase7/phase7.pid)
```

### Check Status
```bash
cat .ralph-amm/phase7/state/.iteration_count.txt  # Iteration
cat .ralph-amm/phase7/state/.best_edge.txt        # Best edge
ps aux | grep ralph-amm-phase7.sh | grep -v grep # Running?
```

### After Completion
```bash
cat .ralph-amm/phase7/PHASE7_FINAL_REPORT.md
```

---

**For detailed technical documentation, see**: [README.md](.ralph-amm/phase7/README.md)
**For command quick reference, see**: [QUICK_REFERENCE.md](.ralph-amm/phase7/QUICK_REFERENCE.md)
