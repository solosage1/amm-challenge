# Phase 7: AI-Powered Strategy Exploration

## Overview

Phase 7 is an autonomous AI-powered loop that uses Claude API (via Codex CLI) to generate novel AMM strategy patterns, test them deterministically, and extract reusable templates from successful patterns.

**Status**: ✅ All components implemented and ready for production

## What Was Built

### Core Components

1. **ralph-amm-phase7.sh** - Main orchestrator (~13KB)
   - Manages 10-hour runtime with dual exit conditions
   - Coordinates all components
   - Tracks state and champions
   - Generates final report

2. **amm-phase7-prompt-builder.py** - Prompt engineering engine
   - Constructs context-aware prompts
   - Enforces Draft→Review→Revise pattern
   - Prioritizes hypothesis gaps
   - Adapts based on results

3. **amm-phase7-code-extractor.py** - Response parser
   - Extracts Solidity from Codex responses
   - Validates against security constraints
   - Handles malformed outputs gracefully

4. **amm-phase7-template-extractor.py** - Pattern extraction
   - Converts successful strategies (edge > 390) into templates
   - Identifies parameterizable constants
   - Generates schema documentation

5. **amm-phase7-report-generator.py** - Final reporting
   - Performance analysis
   - Hypothesis coverage tracking
   - Top strategies summary
   - Recommendations

### Directory Structure

```
.ralph-amm/phase7/
├── state/
│   ├── .iteration_count.txt         # Current iteration
│   ├── .best_edge.txt                # Best edge achieved
│   ├── .start_timestamp.txt          # Start time (Unix)
│   ├── .strategies_log.json          # All strategies tested
│   ├── .templates_created.json       # Templates extracted
│   ├── .rate_limit_tracker.json      # API call tracking
│   └── .best_strategy.sol            # Current champion
├── generated/                        # Generated strategies
├── templates/                        # Extracted templates
├── prompts/                          # Generated prompts (archived)
└── PHASE7_FINAL_REPORT.md           # Final report (generated at end)
```

## How It Works

### The Autonomous Loop

```
1. Build Prompt
   ↓ (context-aware, hypothesis-driven)
2. Invoke Codex
   ↓ (Draft → Review → Revise → Implementation)
3. Extract Code
   ↓ (parse, validate, save)
4. Test Strategy
   ↓ (validation → compilation → 10/100/1000 sims)
5. Record Results
   ↓ (update champion, log results)
6. Extract Template
   ↓ (if edge > 390, create reusable template)
7. Check Exit Conditions
   ↓ (time: 10 hours OR edge > 527)
8. Loop or Exit
```

### Exit Conditions

The loop automatically exits when **either** condition is met:

1. **Time**: 36,000 seconds (10 hours) elapsed
2. **Performance**: Edge > 527 (competitive threshold)

### Prompt Engineering

The system enforces a structured workflow for each strategy generation:

1. **DRAFT_STRATEGY_IDEA** - Initial concept
2. **DESIGN_REVIEW** - Critical analysis
3. **REVISED_IMPLEMENTATION** - Final Solidity code
4. **STRATEGY_METADATA** - JSON metadata

This ensures AI considers constraints, edge cases, and optimizations before implementation.

## Prerequisites

### Required

1. **Python Environment**: Python 3.8+ with dependencies
   ```bash
   source venv_fresh/bin/activate  # Or your venv
   ```

2. **Codex CLI**: Installed and configured
   ```bash
   # Check if available
   codex --version

   # If not installed, follow Codex CLI setup instructions
   # https://github.com/anthropics/claude-code
   ```

3. **Claude API Key**: Configured for Codex
   ```bash
   # Usually configured in ~/.config/claude/config.json
   # or via ANTHROPIC_API_KEY environment variable
   ```

4. **Existing Infrastructure**: Phase 1-6 components operational
   - amm-test-pipeline.py
   - amm-learning-engine.py
   - amm-strategy-generator.py

## Usage

### Quick Start (3-Iteration Test)

Test the system with a short run:

```bash
cd /Users/rbgross/amm-challenge

# Run for 3 iterations (testing)
bash scripts/ralph-amm-phase7.sh --max-iterations 3

# Monitor output
# Expect: ~5-10 minutes per iteration
```

### Production Run (10 Hours)

Launch the full autonomous loop:

```bash
cd /Users/rbgross/amm-challenge

# Launch in background
nohup bash scripts/ralph-amm-phase7.sh > phase7_run.log 2>&1 &

# Save PID for later
echo $! > .ralph-amm/phase7/phase7.pid

# Monitor with dashboard (recommended)
bash scripts/monitor-phase7.sh

# Or monitor with raw logs
tail -f phase7_run.log

# Or check status programmatically
python scripts/amm-learning-engine.py status --state-dir .ralph-amm/phase7/state
```

### Custom Parameters

```bash
# Run for 1 hour (testing)
bash scripts/ralph-amm-phase7.sh --max-runtime 3600

# Run with different target edge
bash scripts/ralph-amm-phase7.sh --target-edge 450

# Run for specific iterations
bash scripts/ralph-amm-phase7.sh --max-iterations 50
```

### Monitoring & Quality Control

#### Quick Start: Monitoring Dashboard

**Recommended: Use the automated monitoring dashboard**:
```bash
# Launch comprehensive real-time dashboard
bash scripts/monitor-phase7.sh

# With custom refresh interval (default: 10s)
bash scripts/monitor-phase7.sh .ralph-amm/phase7/state 5
```

**Dashboard displays**:
- Current iteration, best edge, time remaining
- Codex activity (file size, event count, latest reasoning)
- Recent test results (last 5 strategies)
- Templates extracted
- Quality alerts (failure rate, plateau detection)
- Performance projections

Press Ctrl+C to stop monitoring (Phase 7 loop continues running).

#### Manual Monitoring Commands (Advanced)

**Watch iteration progress**:
```bash
# Update every 10 seconds
watch -n 10 'cat .ralph-amm/phase7/state/.iteration_count.txt'

# Watch best edge
watch -n 10 'cat .ralph-amm/phase7/state/.best_edge.txt'

# Monitor Codex response file growth (indicates activity)
watch -n 5 'ls -lh .ralph-amm/phase7/state/iteration_*_codex_response.json | tail -1'

# Check JSONL event count (shows Codex progress)
watch -n 5 'wc -l .ralph-amm/phase7/state/iteration_*_codex_response.json | tail -1'

# Check for completion events
watch -n 5 'tail -1 .ralph-amm/phase7/state/iteration_*_codex_response.json | jq -r .type 2>/dev/null'
```

**Check recent log entries**:
```bash
# Last 20 lines of main log
tail -n 20 phase7_run.log

# Follow log in real-time
tail -f phase7_run.log

# Filter for key events only
tail -f phase7_run.log | grep -E "Iteration|Edge|Champion|Template"
```

#### Detailed Status Checks

**Current state snapshot**:
```bash
# Current iteration and best edge
echo "Iteration: $(cat .ralph-amm/phase7/state/.iteration_count.txt)"
echo "Best Edge: $(cat .ralph-amm/phase7/state/.best_edge.txt)"

# Elapsed time calculation
python3 -c "
import time
start = int(open('.ralph-amm/phase7/state/.start_timestamp.txt').read())
elapsed = time.time() - start
hours = elapsed / 3600
remaining = (36000 - elapsed) / 3600
print(f'Elapsed: {hours:.2f} hours')
print(f'Remaining: {remaining:.2f} hours')
print(f'Progress: {(elapsed/36000)*100:.1f}%')
"

# Strategies tested
jq 'length' .ralph-amm/phase7/state/.strategies_log.json

# Templates created
jq 'length' .ralph-amm/phase7/state/.templates_created.json
```

#### Codex Activity Monitoring

**Check if Codex is actively running**:
```bash
# Process check
ps aux | grep ralph-amm-phase7.sh | grep -v grep

# Check current Codex iteration
ls -t .ralph-amm/phase7/state/iteration_*_codex_response.json | head -1
```

**Analyze Codex progress on current iteration**:
```bash
# Count events in current iteration
python3 -c "
import json
events = []
with open('.ralph-amm/phase7/state/iteration_1_codex_response.json') as f:
    for line in f:
        try:
            events.append(json.loads(line))
        except:
            pass

print(f'Total events: {len(events)}')
print(f'Last event: {events[-1].get(\"type\", \"unknown\")}')

# Show recent reasoning
reasoning_items = [e for e in events if e.get('type') == 'item.completed'
                   and e.get('item', {}).get('type') == 'reasoning']
if reasoning_items:
    last = reasoning_items[-1]['item']['text'][:150]
    print(f'Latest reasoning: {last}...')
"
```

**Check for completion**:
```bash
# Look for turn.ended or thread.ended events
grep -E '"type":"(turn\.ended|thread\.ended)"' \
  .ralph-amm/phase7/state/iteration_*_codex_response.json | tail -5
```

#### Performance Metrics

**Iteration rate calculation**:
```bash
python3 -c "
import time
import json

# Load state
iteration = int(open('.ralph-amm/phase7/state/.iteration_count.txt').read())
start = int(open('.ralph-amm/phase7/state/.start_timestamp.txt').read())
elapsed = time.time() - start

if iteration > 0 and elapsed > 0:
    rate_per_min = iteration / (elapsed / 60)
    rate_per_hour = iteration / (elapsed / 3600)
    avg_time_per_iter = elapsed / iteration

    print(f'Iterations: {iteration}')
    print(f'Rate: {rate_per_min:.2f} iter/min ({rate_per_hour:.1f} iter/hour)')
    print(f'Avg time per iteration: {avg_time_per_iter:.1f} seconds')

    # Project total
    remaining_time = 36000 - elapsed
    projected_total = iteration + (remaining_time / avg_time_per_iter)
    print(f'Projected total iterations: {int(projected_total)}')
else:
    print('No iterations completed yet')
"
```

**Success rate tracking**:
```bash
python3 -c "
import json

log = json.loads(open('.ralph-amm/phase7/state/.strategies_log.json').read())
total = len(log)
successful = sum(1 for s in log if s.get('final_edge', 0) > 0)

if total > 0:
    success_rate = (successful / total) * 100
    print(f'Success rate: {success_rate:.1f}% ({successful}/{total})')

    # Best performers
    sorted_log = sorted(log, key=lambda x: x.get('final_edge', 0), reverse=True)
    print('\nTop 3 strategies:')
    for i, s in enumerate(sorted_log[:3], 1):
        name = s.get('strategy_name', 'Unknown')
        edge = s.get('final_edge', 0)
        print(f'  {i}. {name}: {edge:.2f}')
else:
    print('No strategies tested yet')
"
```

#### Quality Control Alerts

**Check for issues**:
```bash
# High failure rate alert
python3 -c "
import json
log = json.loads(open('.ralph-amm/phase7/state/.strategies_log.json').read())
if log:
    failures = sum(1 for s in log if not s.get('final_edge') or s.get('final_edge', 0) == 0)
    total = len(log)
    failure_rate = (failures / total) * 100

    print(f'Failure rate: {failure_rate:.1f}%')
    if failure_rate > 30:
        print('⚠️  WARNING: High failure rate (>30%)')
        print('Consider adjusting prompt or Codex config')
    elif failure_rate > 50:
        print('❌ CRITICAL: Very high failure rate (>50%)')
        print('STOP and review Codex outputs')
    else:
        print('✓ Failure rate acceptable')
"

# Performance plateau detection
python3 -c "
import json
log = json.loads(open('.ralph-amm/phase7/state/.strategies_log.json').read())
if len(log) >= 10:
    recent = [s.get('final_edge', 0) for s in log[-10:] if s.get('final_edge', 0) > 0]
    if recent:
        mean_edge = sum(recent) / len(recent)
        variance = sum((e - mean_edge) ** 2 for e in recent) / len(recent)
        std_dev = variance ** 0.5

        print(f'Recent 10 iterations:')
        print(f'  Mean edge: {mean_edge:.2f}')
        print(f'  Std dev: {std_dev:.2f}')

        if std_dev < 2.0:
            print('⚠️  WARNING: Performance plateau detected (σ < 2.0)')
            print('Consider adjusting exploration strategy')
        else:
            print('✓ Healthy variance in results')
"

# Disk space monitoring
du -sh .ralph-amm/phase7/ && echo "Target: < 1GB for full 10-hour run"
```

### Stopping the Run

**Graceful stop**:

```bash
# Stop after current iteration completes
kill $(cat .ralph-amm/phase7/phase7.pid)
```

**Force stop** (not recommended):

```bash
# Kill immediately (may corrupt state)
kill -9 $(cat .ralph-amm/phase7/phase7.pid)
```

## Expected Performance

### Resource Usage

- **CPU**: 1-4 cores (simulation-heavy)
- **Memory**: ~2-4 GB RAM
- **Disk**: ~100 MB per 100 iterations
- **Network**: Minimal (API calls only)

### Timeline

- **Per Iteration**: 3-5 minutes average
  - Prompt building: ~1s
  - Codex generation: 10-30s
  - Code extraction: ~1s
  - Testing (10/100/1000 sims): 30-120s
  - Recording: ~1s

- **10-Hour Run**: ~100-200 iterations estimated

### Success Criteria

**Minimum Viable (MVP)**:
- 50+ iterations completed
- Best edge > 374.56 (improves on Phase 1)
- 1+ template extracted
- <30% validation failures

**Target**:
- 100+ iterations completed
- Best edge > 400
- 3+ templates extracted
- All 6 core hypotheses explored
- <20% validation failures

**Stretch**:
- **Edge > 527** (competitive threshold) ← Primary goal
- Early exit before 10 hours
- 5+ templates extracted
- Novel mechanisms discovered

## Output Files

### During Run

- `.ralph-amm/phase7/state/.iteration_count.txt` - Current iteration
- `.ralph-amm/phase7/state/.best_edge.txt` - Current best edge
- `.ralph-amm/phase7/state/.best_strategy.sol` - Champion strategy
- `.ralph-amm/phase7/generated/phase7_strategy_N.sol` - Generated strategies
- `.ralph-amm/phase7/prompts/iteration_N_prompt.md` - Prompts used

### After Completion

- `.ralph-amm/phase7/PHASE7_FINAL_REPORT.md` - Comprehensive report
- `.ralph-amm/phase7/templates/*.sol.template` - Extracted templates
- `.ralph-amm/phase7/state/.strategies_log.json` - Full test history

## Troubleshooting

### Common Issues

**1. "Codex CLI not found"**
```bash
# Install Codex CLI
# Follow https://github.com/anthropics/claude-code

# Or check PATH
which codex
```

**2. "Rate limit exceeded"**
```
# System has built-in 2-second delays
# If still hitting limits, wait and resume
bash scripts/ralph-amm-phase7.sh --max-iterations 100
```

**3. "Validation failures > 50%"**
```bash
# Prompt may need refinement
# Check recent failed strategies:
jq '.[-10:]' .ralph-amm/phase7/state/.strategies_log.json
```

**4. "No improvement after 50 iterations"**
```
# May have reached local maximum
# Check hypothesis coverage:
python scripts/amm-learning-engine.py hypotheses \
  --state-dir .ralph-amm/phase7/state

# Consider adjusting prompt focus
```

### Debug Mode

Enable verbose logging:

```bash
# Edit ralph-amm-phase7.sh, change log level:
# log "DEBUG" ...  (instead of INFO)

# Or tail full output:
tail -f phase7_run.log | grep -v "DEBUG"
```

## Next Steps After Completion

1. **Review Results**:
   ```bash
   cat .ralph-amm/phase7/PHASE7_FINAL_REPORT.md
   ```

2. **Test Champion**:
   ```bash
   python scripts/amm-learning-engine.py robustness-check \
     --strategy .ralph-amm/phase7/state/.best_strategy.sol --batches 3
   ```

3. **Extract Insights**:
   ```bash
   python scripts/amm-learning-engine.py hypotheses \
     --state-dir .ralph-amm/phase7/state
   ```

4. **Use Templates**:
   - Copy templates to `.ralph-amm/templates/`
   - Use with amm-strategy-generator.py for Phase 1-6 exploration

5. **Submit Best Strategy**:
   - If edge > 527, consider submitting to competition
   - Run additional robustness checks first

## Architecture Notes

### Design Decisions

1. **Template-Based (Phases 1-6)** vs **AI-Powered (Phase 7)**:
   - Phase 7 complements template-based exploration
   - Templates handle known patterns efficiently
   - AI explores novel, unexpected patterns

2. **Draft→Review→Revise Workflow**:
   - Inspired by Ralph coding loop from aegis-app
   - Forces AI to self-critique before implementation
   - Reduces validation failures significantly

3. **Dual Exit Conditions**:
   - Time limit prevents runaway costs
   - Performance target enables early success exit
   - User maintains control

4. **Rate Limiting**:
   - 2-second minimum between API calls (~40 RPM max)
   - Protects against 429 errors
   - Configurable if needed

### Integration with Existing Systems

- **Reuses**: amm-test-pipeline.py (validation, compilation, testing)
- **Reuses**: amm-learning-engine.py (result recording, analysis)
- **Extends**: Research workflow (hypothesis tracking, experiment logs)
- **Generates**: New templates for future Phase 1-6 exploration

## Support

For issues or questions:

1. Check this README
2. Review plan file: `/Users/rbgross/.claude/plans/concurrent-skipping-diffie.md`
3. Examine component source code in `scripts/amm-phase7-*.py`
4. Review detailed plan: `/Users/rbgross/.claude/plans/concurrent-skipping-diffie-agent-ab5c354.md`

---

**Phase 7 Implementation Complete**: ✅ Ready for Production Run

**Next Action**: Launch 10-hour production run when ready

```bash
cd /Users/rbgross/amm-challenge
nohup bash scripts/ralph-amm-phase7.sh > phase7_run.log 2>&1 &
```
