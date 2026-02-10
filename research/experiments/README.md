# Experiments

This folder contains experiment logs that connect strategy changes to measurable outcomes in the local simulator.

## Naming convention

Use a file name that makes it easy to search:

`YYYY-MM-DD_E###_H-###_<short-slug>.md`

Example:

`2026-02-10_E001_H-003_inventory-skew-v1.md`

## What to record

Use `research/templates/EXPERIMENT_TEMPLATE.md` and include:

- The hypothesis ID(s)
- The exact `amm-match` commands run (10/100/1000 sims)
- The strategy file path(s) and any parameters/constants changed
- Enough output to reproduce the comparison later
- A decision (continue/stop) and what you updated in the backlog

## Cross-linking

- Update `research/HYPOTHESES_BACKLOG.md` with links to experiment logs.
- If you discover a new assumption, add it to `research/ASSUMPTIONS_REGISTER.md` and reference it from the experiment.

