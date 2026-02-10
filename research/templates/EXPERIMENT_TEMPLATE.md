# Experiment E-XXX — <short title>

- Date: YYYY-MM-DD
- Hypothesis: H-XXX
- Strategy file(s): `contracts/src/<Strategy>.sol`
- Git SHA: `<output of git rev-parse HEAD>`

## Goal

What are we trying to learn or validate?

## Change summary

What changed vs the control strategy?

## Commands run

Include exact commands and simulation counts:

```bash
source venv_fresh/bin/activate
amm-match validate <path>
amm-match run <path> --simulations 10
amm-match run <path> --simulations 100
amm-match run <path> --simulations 1000
```

## Results

- 10 sims: AvgEdge = <...>
- 100 sims: AvgEdge = <...> (repeat N times if needed)
- 1000 sims: AvgEdge = <...> (repeat N times if needed)

If available, include diagnostics:

- retailVolumeY (submission vs normalizer)
- arbVolumeY (submission vs normalizer)
- average fees (bid/ask), and whether they are step-averaged or volume-weighted

## Interpretation

- Did the result support the hypothesis?
- Was the improvement significant given expected variance?

## Decision / next steps

- Continue / iterate (what parameter sweep next?)
- Stop (why?)
- Update hypothesis status (what to change in `research/HYPOTHESES_BACKLOG.md`?)

