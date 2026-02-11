### Previous Iteration Discoveries (Manual sims from iteration 8–9 logs)

- `ArbBandProtect`: **490.96 Edge @ 1000 sims** (`iteration_8_codex.jsonl:202`)
- `ArbOracleBandMatch2`: **497.57 Edge @ 1000 sims** (`iteration_8_codex.jsonl:223`)
- `ArbOracleDualRegime`: **502.27 Edge @ 1000 sims** (`iteration_9_codex.jsonl:197`)
- `ArbOracleDualRegimeExact`: **502.58 Edge @ 1000 sims** (`iteration_9_codex.jsonl:200`)
- `ArbOracleDualRegime_Tight30_Buf4`: **505.61 Edge @ 1000 sims** (local run, 2026-02-10)
- `ArbOracleDualRegimeRecenter`: **504.93 Edge @ 1000 sims** (local run, 2026-02-10)

Notes:
- Dual-regime + (tight=30bps) is currently best-known locally, but still ~21.4 edge short of **527**.
- Next likely gains come from: (1) better arb-vs-retail classification on the first trade of a step, (2) per-step two-phase quoting (after arb, go aggressively competitive for same-step retail), and (3) handling the arb “cap at 99% reserves” case to avoid biased fair anchors.
