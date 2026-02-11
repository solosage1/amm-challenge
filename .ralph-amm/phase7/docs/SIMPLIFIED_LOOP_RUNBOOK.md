# Simplified Loop Operational Runbook

Quick reference for operating the Phase 7 simplified loop.

---

## Quick Start

```bash
# Start the loop (1000 iterations, 5s sleep between)
nohup python3 scripts/simplified_loop.py run-loop \
  --state-dir .ralph-amm/phase7/state \
  --definitions .ralph-amm/phase7/config/mechanism_definitions.json \
  --iterations 1000 \
  --sleep-seconds 5 \
  --continue-on-error \
  --auto-rollback \
  --policy-evolution-frequency 5 \
  --llm-command codex \
  --llm-model gpt-5.3-codex \
  > .ralph-amm/phase7/state/loop_output_simplified.log 2>&1 &
```

---

## Check Status

### Process Status
```bash
# Is the loop running?
ps aux | grep simplified_loop | grep -v grep

# Is codex generating?
ps aux | grep "codex exec" | grep -v grep
```

### Iteration Progress
```bash
# Count completed iterations
wc -l .ralph-amm/phase7/state/iteration_log.jsonl

# View recent iterations
tail -5 .ralph-amm/phase7/state/iteration_log.jsonl | python3 -c "
import sys, json
for line in sys.stdin:
    d = json.loads(line)
    print(f\"iter {d['iter']}: {d['mechanism']} -> {d['status']} (edge: {d.get('edge', 'N/A')}, delta: {d.get('delta', 'N/A')})\")"
```

### Champion Status
```bash
# Current champion edge
cat .ralph-amm/phase7/state/.best_edge.txt

# Champion details
python3 -c "import json; s=json.load(open('.ralph-amm/phase7/state/mechanism_stats.json')); print(f\"Champion: {s['champion']['name']} @ {s['champion']['edge']}\")"
```

### Mechanism Stats
```bash
python3 -c "
import json
s = json.load(open('.ralph-amm/phase7/state/mechanism_stats.json'))
print(f\"Total iterations: {s['global']['total_iterations']}\")
print(f\"Champion updates: {s['global']['total_champion_updates']}\")
print()
for m, d in s['mechanisms'].items():
    if d['tries'] > 0:
        rate = d['successes']/d['tries']*100
        print(f\"{m}: {d['tries']} tries, {d['successes']} successes ({rate:.0f}%), best_delta={d['best_delta']}\")
    else:
        print(f\"{m}: 0 tries\")
"
```

---

## Stop the Loop

```bash
# Graceful stop (kill loop and any codex processes)
pkill -f "simplified_loop.py"
pkill -f "codex exec"

# Verify stopped
ps aux | grep -E "(simplified_loop|codex exec)" | grep -v grep || echo "All stopped"
```

---

## Reset State (Clean Slate)

```bash
# 1. Stop the loop first
pkill -f "simplified_loop.py"
pkill -f "codex exec"

# 2. Clean iteration artifacts
rm -f .ralph-amm/phase7/state/iteration_log.jsonl
rm -f .ralph-amm/phase7/state/candidates_simplified/iter_*
rm -f .ralph-amm/phase7/state/prompts_simplified/iter_*

# 3. Reset mechanism_stats.json
python3 -c "
import json
stats_path = '.ralph-amm/phase7/state/mechanism_stats.json'
with open(stats_path) as f:
    stats = json.load(f)

# Reset champion to original
stats['champion'] = {
    'name': 'GammaSquaredDualRegime',
    'edge': 509.23,
    'baseline_edge': 509.23,
    'promoted_at': None
}

# Reset all mechanism stats
for mech in stats.get('mechanisms', {}):
    stats['mechanisms'][mech] = {
        'tries': 0, 'successes': 0, 'total_uplift': 0.0,
        'invalid_count': 0, 'compile_fail_count': 0,
        'last_tried': None, 'best_delta': None
    }

# Reset global stats
stats['global']['total_iterations'] = 0
stats['global']['total_champion_updates'] = 0
stats['global']['rollback_triggered'] = False
stats['global']['consecutive_invalid'] = 0

with open(stats_path, 'w') as f:
    json.dump(stats, f, indent=2)
print('State reset complete')
"

# 4. Reset champion edge file
echo "509.23" > .ralph-amm/phase7/state/.best_edge.txt
```

---

## Troubleshooting

### Validation Failures (retries looping)
Check if anchors are matching:
```bash
python3 -c "
import json, sys
sys.path.insert(0, 'scripts')
from simplified_loop import validate_candidate

with open('.ralph-amm/phase7/config/mechanism_definitions.json') as f:
    defs = json.load(f)
with open('.ralph-amm/phase7/state/.best_strategy.sol') as f:
    champ = f.read()
with open('.ralph-amm/phase7/state/candidates_simplified/iter_1_flow_memory.sol') as f:
    cand = f.read()

valid, reason = validate_candidate(champ, cand, 'flow_memory', defs)
print(f'Valid: {valid}, Reason: {reason}')
"
```

### Codex Not Generating
```bash
# Check codex stderr
cat .ralph-amm/phase7/state/candidates_simplified/iter_*.codex.stderr

# Check codex jsonl progress
wc -l .ralph-amm/phase7/state/candidates_simplified/iter_*.codex.jsonl
```

### Loop Stuck on Same Iteration
The iteration number comes from `mechanism_stats.json -> global.total_iterations + 1`.
If this isn't incrementing, the loop isn't completing iterations successfully.
```bash
# Check current iteration number
python3 -c "import json; print(json.load(open('.ralph-amm/phase7/state/mechanism_stats.json'))['global']['total_iterations'])"
```

---

## Key Files

| File | Purpose |
|------|---------|
| `.ralph-amm/phase7/state/mechanism_stats.json` | UCB1 stats, champion info, global counters |
| `.ralph-amm/phase7/state/iteration_log.jsonl` | Detailed log of each iteration |
| `.ralph-amm/phase7/state/.best_strategy.sol` | Current champion code |
| `.ralph-amm/phase7/state/.best_edge.txt` | Current champion edge |
| `.ralph-amm/phase7/config/mechanism_definitions.json` | Mechanism anchors, overlap policies |
| `.ralph-amm/phase7/state/candidates_simplified/` | Generated candidates and results |
| `.ralph-amm/phase7/state/prompts_simplified/` | LLM prompts |

---

## Configuration Reference

| Flag | Default | Description |
|------|---------|-------------|
| `--iterations` | 10 | Number of iterations to run |
| `--sleep-seconds` | 0 | Delay between iterations |
| `--exploration-c` | 0.5 | UCB1 exploration constant |
| `--improvement-threshold` | 0.02 | Min delta to count as success |
| `--max-retries-on-invalid` | 2 | Validation retry attempts |
| `--wildcard-frequency` | 10 | Every Nth iteration is wildcard |
| `--policy-evolution-frequency` | 5 | Policy review every N iterations |
| `--auto-rollback` | false | Auto-rollback on consecutive failures |
| `--llm-timeout-minutes` | 40 | Codex timeout |

---

## UCB1 Selection Formula

```
score(mechanism) = mean_uplift + exploration_c * sqrt(ln(total_tries) / mechanism_tries)
```

Untried mechanisms get infinite score (always selected first).
