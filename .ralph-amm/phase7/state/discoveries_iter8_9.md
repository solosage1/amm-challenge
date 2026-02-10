## Discoveries from Iterations 8-9

### Best Strategies Tested (Edge Scores)
| Strategy | Edge (200 sim) | Edge (1000 sim) |
|----------|----------------|-----------------|
| ArbOracleDualRegimeExact | 516.16 | 502.58 |
| ArbOracleDualRegime | 515.90 | 502.27 |
| ArbOracleBandMatch2 | 511.28 | 497.57 |
| ArbBandProtect | 504.23 | 490.96 |
| ArbPulseTwoPhase | 445.01 | ~440 |

### Constant Fee Baseline (for reference)
- const70.sol: 392 edge (best constant)
- const30.sol: 347 edge (normalizer baseline)

### Key Findings
1. **Oracle-based fair price inference** beats EWMA-based (~515 vs ~490)
2. **Dual regime** (different fees pre/post arb) is essential
3. **Exact fair calculation** from post-arb reserves works best
4. **Gap to 527**: Only ~11 points from current best

### Parameters That Work
- tightFee: 25-30 bps (competitive side)
- protectFee: 60-100 bps (protection side)
- buffer: 8-15 bps
- EWMA alpha: 0.15-0.35 (if used)

### What Didn't Work
- ArbPulseTwoPhase (~445) - timing-based switching hurt volume
- Very high initial fees (80+ bps) - loses early retail
- Symmetric fees when mispriced - need asymmetry

### Best Strategy Code Pattern (ArbOracleDualRegimeExact)
```solidity
// Core mechanism:
// 1. After arb trade: Calculate exact fair price from post-trade reserves
//    fairPrice = sqrt(reserveY * reserveX) normalized
// 2. Compare pool price to fair price to determine mispricing direction
// 3. Set asymmetric fees:
//    - Tight fee (25-30 bps) on side that corrects mispricing (attracts retail)
//    - Protection fee (60-100 bps) on side that worsens mispricing (deters adverse selection)
// 4. Track if last trade was arb to distinguish regimes
```

### Directions to Explore for >527 Edge
1. **Tighter post-arb fees**: Current 25-30 bps might go to 20-25 bps
2. **Wider protection spread**: Current 60-100 bps might go to 100-150 bps
3. **Inventory-adjusted asymmetry**: Skew based on reserve ratio, not just direction
4. **Volatility adaptation**: Higher fees during high volatility periods
5. **Multi-step memory**: Track patterns across 2-3 trades, not just last trade
