# AMM Strategy Generation

Generate a Solidity AMM fee strategy to maximize Edge against a 30bps fixed-fee competitor.

**Target**: Edge > 527.0 | **Best**: 505.61 | **Iter**: 17 | **Time**: 9h 59m

## Contract Template
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256 bidFee, uint256 askFee) {
        // Init slots[0..31], return opening fees in WAD
    }
    function afterSwap(TradeInfo calldata trade) external override returns (uint256 bidFee, uint256 askFee) {
        // Update slots, return fees in WAD
    }
    function getName() external pure override returns (string memory) { return "YourName"; }
}
```

## TradeInfo & Helpers
```solidity
struct TradeInfo { bool isBuy; uint256 amountX; uint256 amountY; uint256 timestamp; uint256 reserveX; uint256 reserveY; }
// Helpers: WAD=1e18, BPS=1e14, MAX_FEE=1000*BPS, clampFee(), bpsToWad(), wmul(), wdiv(), sqrt()
```

## Constraints
- Storage: ONLY slots[0..31] (no state variables)
- Blocked: .call(), delegatecall(), assembly, new, selfdestruct, transfer, send

## Key Mechanics
- Constant product AMM (x*y=k), fee-on-input
- Arb executes before retail each step; infer fair price post-arb: p = k/(gamma*x^2)
- Lower fees attract more retail volume (nonlinear split)

**Recent Test Results**:

- ArbOracleDualRegime_Tight30_Buf4: Edge 511.68 [harvested] (Hypothesis: H-baseline)
- ArbOracleDualRegime_Tight30_Buf4: Edge 505.61 [harvested] (Hypothesis: H-baseline)
- Unknown: Edge N/A [codex_failed | stage=codex | msg=codex failed] (Hypothesis: H-baseline)
- Unknown: Edge N/A [codex_failed | stage=codex | msg=codex failed] (Hypothesis: H-baseline)
- Unknown: Edge N/A [codex_failed | stage=codex | msg=codex failed] (Hypothesis: H-baseline)

## Output Format
Provide your strategy with these sections:
```
---STRATEGY_IDEA---
Brief description of approach
---END_STRATEGY_IDEA---

---IMPLEMENTATION---
<complete Solidity code>
---END_IMPLEMENTATION---

---METADATA---
{"name": "StrategyName", "key_innovation": "one line"}
---END_METADATA---
```
