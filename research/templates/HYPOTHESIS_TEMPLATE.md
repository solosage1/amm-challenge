# Hypothesis H-XXX — <short title>

- Status: `proposed` | `testing` | `supported` | `rejected` | `blocked`
- Priority: `P0` | `P1` | `P2`
- Depends on assumptions: A-XXX, A-YYY
- Related snapshot / findings: `research/LEADERBOARD_FINDINGS.md` (optional)

## Statement

One sentence describing what should improve and why.

## Mechanism (link to code)

- Which simulator mechanics does this exploit?
- Relevant files: `<paths>`

## Measurable predictions

- Primary metric: AvgEdge at 1000 sims
- Secondary diagnostics: retail volume, arb volume, average fees, tail risk (p05 edge)

## Implementation sketch (under constraints)

- Storage plan (`slots[]` usage)
- Gas budget considerations (~250k/callback)
- Validator constraints (no external calls, no assembly, etc.)

## Experiment plan

- Controls: what baseline strategy/version is this compared to?
- Tests:
  - 10 sims: smoke test, correctness
  - 100 sims: iterate + coarse parameter sweep
  - 1000 sims: confirm significance and robustness
- Success criteria (quantitative):
  - Example: +X edge at 1000 sims over control, repeated across N runs

## Failure modes

- What could go wrong and how will we detect it?

## Links

- Experiment logs: `research/experiments/YYYY-MM-DD_Exxx_H-XXX_<slug>.md`

