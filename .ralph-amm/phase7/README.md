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

# Run in background with nohup
nohup bash scripts/ralph-amm-phase7.sh > phase7_run.log 2>&1 &

# Note the process ID
echo $! > .ralph-amm/phase7/phase7.pid

# Monitor progress
tail -f phase7_run.log

# Or check status
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

### Monitoring

**Real-time monitoring** (in separate terminal):

```bash
# Watch iteration progress
watch -n 10 'cat .ralph-amm/phase7/state/.iteration_count.txt'

# Watch best edge
watch -n 10 'cat .ralph-amm/phase7/state/.best_edge.txt'

# Check recent log entries
tail -n 20 phase7_run.log
```

**Status check**:

```bash
# Current state
cat .ralph-amm/phase7/state/.iteration_count.txt
cat .ralph-amm/phase7/state/.best_edge.txt

# Elapsed time
python -c "import time; start=$(cat .ralph-amm/phase7/state/.start_timestamp.txt); print(f'{(time.time() - start) / 3600:.2f} hours elapsed')"

# Strategies tested
jq 'length' .ralph-amm/phase7/state/.strategies_log.json

# Templates created
jq 'length' .ralph-amm/phase7/state/.templates_created.json
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
