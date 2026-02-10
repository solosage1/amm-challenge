### Previous Iteration Discoveries (Manual sims from iteration 8–9 logs)

- `ArbBandProtect`: **490.96 Edge @ 1000 sims** (`iteration_8_codex.jsonl:202`)
- `ArbOracleBandMatch2`: **497.57 Edge @ 1000 sims** (`iteration_8_codex.jsonl:223`)
- `ArbOracleDualRegime`: **502.27 Edge @ 1000 sims** (`iteration_9_codex.jsonl:197`)
- `ArbOracleDualRegimeExact`: **502.58 Edge @ 1000 sims** (`iteration_9_codex.jsonl:200`)

Notes:
- Dual-regime + **exact arb inversion** is the current best-known family, but still ~24.4 edge short of **527**.
- Next likely gains come from: (1) better arb-vs-retail classification on the first trade of a step, (2) per-step two-phase quoting (after arb, go aggressively competitive for same-step retail), and (3) handling the arb “cap at 99% reserves” case to avoid biased fair anchors.

