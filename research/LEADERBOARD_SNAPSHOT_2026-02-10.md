# Leaderboard snapshot (Top 20) — 2026-02-10

This document records a point-in-time Top-20 leaderboard snapshot and derived diagnostics that were available publicly on the AMM Fee Strategy Challenge website at capture time.

- Raw data: `research/data/leaderboard/2026-02-10/top20.json`
- Derived metrics: `research/data/leaderboard/2026-02-10/top20_metrics.json`

## Summary (`FACT`)

- Capture time: 2026-02-10 (UTC)
- All Top-20 entries: 1000 wins / 0 losses / 0 draws in the reported match results (`top20.json`)
- AvgEdge range: 523.835 to 526.388 (mean 524.380)
- Mean “average fee” diagnostic: 36.997 bps (min 34.995, max 38.195)
- Fee asymmetry: 19/20 entries show `askFee < bidFee` on average (mean askMinusBid = -1.279 bps)
- Mean reported volumes to the submission AMM: retail ~76,478 Y; arbitrage ~23,263 Y (averaged over the match’s simulations)
- Baseline edge varies across these matches: 347.491 to 365.344 (mean 358.636)

Statistics above are computed from `top20_metrics.json`. Interpretation of “average fee” is tracked as an assumption; see `research/ASSUMPTIONS_REGISTER.md`.

## Top 20 table (`FACT`)

| Rank | Author | Strategy | Created | AvgEdge | EdgeΔvs30 | BidFee(bps) | AskFee(bps) | RetailVolY | ArbVolY | Attempts |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | @basedfk | New CLIZA.ai Soon! | 2026-02-10 12:08Z | 526.388 | 171.286 | 36.01 | 36.20 | 77325 | 23799 | 24 |
| 2 | @josusanmartin | v1555 | 2026-02-10 04:54Z | 526.049 | 173.003 | 35.73 | 35.64 | 77694 | 24289 | 86 |
| 3 | @UngusTrade | overfit | 2026-02-10 08:47Z | 524.739 | 162.879 | 38.25 | 36.95 | 75793 | 22376 | 9 |
| 4 | @rishabhjava | AD61 | 2026-02-10 06:05Z | 524.592 | 167.018 | 37.21 | 35.78 | 76703 | 23132 | 1 |
| 5 | @stokasz | PARADIGMFARMINGINFERENCE | 2026-02-10 06:54Z | 524.482 | 161.703 | 38.34 | 37.16 | 75526 | 22269 | 36 |
| 6 | @kbrizzle_ | 👻 | 2026-02-10 10:15Z | 524.451 | 161.662 | 39.11 | 37.28 | 75684 | 22333 | 22 |
| 7 | @DollarBill1488 | AD12 | 2026-02-10 05:22Z | 524.410 | 163.257 | 38.08 | 36.71 | 75913 | 22549 | 15 |
| 8 | @fluketendencies | testing | 2026-02-10 09:27Z | 524.386 | 172.435 | 36.65 | 34.42 | 77861 | 24809 | 25 |
| 9 | @MidTermDev | cma_v16 | 2026-02-10 12:31Z | 524.261 | 167.558 | 37.35 | 35.71 | 76929 | 23749 | 2 |
| 10 | @ChrisTorresLugo | #BenitoBowl | 2026-02-10 11:23Z | 524.161 | 162.551 | 38.03 | 37.04 | 75781 | 22759 | 5 |
| 11 | @0xhelios | decay | 2026-02-10 11:33Z | 524.089 | 163.370 | 37.92 | 36.54 | 75962 | 23018 | 12 |
| 12 | @eliahilse | Kyora Medallion | 2026-02-10 02:59Z | 524.072 | 163.365 | 37.75 | 36.56 | 75986 | 22949 | 17 |
| 13 | @christopherwxyz | hey mom! | 2026-02-10 11:19Z | 524.071 | 161.106 | 38.30 | 37.14 | 75493 | 22192 | 7 |
| 14 | @be11pepper | H31_R2 | 2026-02-10 04:52Z | 524.036 | 158.693 | 38.90 | 37.49 | 74906 | 21812 | 22 |
| 15 | @unhedged21 | EQX_Labs_v23 | 2026-02-10 01:14Z | 523.967 | 176.475 | 36.34 | 33.65 | 78924 | 25437 | 25 |
| 16 | @adrianleb | hmmmm | 2026-02-10 12:23Z | 523.932 | 163.818 | 38.29 | 36.78 | 76165 | 22979 | 3 |
| 17 | @lostbutlucky | HazardDistilledTable | 2026-02-10 05:06Z | 523.928 | 168.603 | 37.51 | 35.99 | 77239 | 23856 | 20 |
| 18 | @frok_ai | frokked | 2026-02-09 23:02Z | 523.878 | 168.182 | 37.04 | 36.87 | 77290 | 24996 | 8 |
| 19 | @llm_kv | v54_shock_026 | 2026-02-10 04:19Z | 523.876 | 163.298 | 37.89 | 36.49 | 75989 | 22853 | 7 |
| 20 | @js_horne | idea guy | 2026-02-09 20:34Z | 523.835 | 164.622 | 38.06 | 36.75 | 76405 | 23102 | 36 |

## How to use this snapshot

- Treat the numbers as an external observation, not as the simulator’s ground truth. Canonical mechanics live in `research/JUDGING_ALGORITHM.md`.
- Use `research/LEADERBOARD_FINDINGS.md` to translate observations into testable hypotheses.
