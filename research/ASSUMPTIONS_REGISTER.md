# Assumptions register

This file tracks non-code assumptions used when interpreting leaderboard data and making strategy decisions.

## How to use this register

- Add a new assumption as `A-###` with a short statement and a concrete validation approach.
- If a hypothesis depends on an assumption, link it explicitly.
- Prefer validations that can be executed locally; if validation requires website submissions or network access, say so.

## Status values

- `open`: assumed but not validated
- `validated`: confirmed (record how)
- `rejected`: shown false (record impact)
- `monitor`: likely true but could change (requires periodic re-check)

## Register (current)

| ID | Statement | Why it matters | Validation approach | Status |
| --- | --- | --- | --- | --- |
| A-001 | Website scoring and step ordering match this repo’s implementation. | All leaderboard interpretation depends on it. | Compare local `amm-match` results vs a known website run of the same strategy. | open |
| A-002 | Reported “average fees” are a time-average of fee quotes (step-average), not volume-weighted. | Changes how we interpret the fee regime (35–38 bps). | Compute both step-average and volume-weighted fees locally; compare to website diagnostics for a submitted strategy. | open |
| A-003 | Evaluation seeds/conditions differ across website submissions (baseline edge varies across Top-20). | Leaderboard deltas may be noisy; need robustness testing. | Submit the same strategy multiple times; measure baseline edge variance and score variance. | open |
| A-004 | Submission API aggregates correspond to the same match used for the leaderboard row and are stable over time. | Snapshot reproducibility. | Re-fetch the same `submission.id` later and diff aggregates. | monitor |
| A-005 | Website normalizer remains a fixed 30 bps strategy. | Normalizer defines the competition for retail flow. | Validate via website documentation or by submitting a strategy and inspecting reported baseline fees. | monitor |
| A-006 | `arbVolumeY` and `retailVolumeY` match the local engine’s definitions (sum of Y per trade). | We use these as diagnostics for hypotheses. | Compare local volume metrics to website metrics for the same strategy. | open |
| A-007 | Snapshot extraction was correct and captured the real Top-20 at the capture time. | Prevents “bad data” driving hypotheses. | Manual spot-check against the website UI; cross-check multiple capture methods. | open |
| A-008 | No public source code/writeups exist for the Top-20 entries in the snapshot. | Prevents over-confident attribution of mechanisms. | Periodic search of linked profiles and public repos; update snapshot notes if found. | monitor |
| A-009 | Local submission validation constraints match website constraints (blocked patterns + forbidden opcodes). | Ensures local experiments are submission-feasible. | Attempt a submission that passes locally but uses borderline constructs; verify acceptance/rejection aligns. | open |
| A-010 | Local toolchain matches the website (Solidity version, viaIR, EVM version). | Differences could cause performance mismatches or validation drift. | Compare compiler settings (0.8.24, viaIR) and EVM settings against website; confirm via submission logs. | open |

## Notes

- Any assumption that requires live submissions should be treated as potentially high cost and scheduled intentionally.
