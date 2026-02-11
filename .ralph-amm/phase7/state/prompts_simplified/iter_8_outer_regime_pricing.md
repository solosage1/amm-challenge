You are improving an AMM fee strategy by modifying ONE specific mechanism.

## CURRENT CHAMPION CODE
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Dual-regime arb-oracle with **gamma^2 competitor anchoring** on the competitive side.
///         Intuition: the 30bps normalizer's post-arb spot sits at ~p/γ or γ·p, so its *worse* side
///         quote is ~p/γ^2 or γ^2·p. Matching that (instead of assuming spot≈p) lets us charge
///         materially higher fees while still winning flow on the side where normalizer is weak.
contract Strategy is AMMStrategyBase {
    // slots:
    // 0 lastTimestamp
    // 1 currentBidFee
    // 2 currentAskFee
    // 3 fairPrice (WAD, Y per X)

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);
        slots[0] = type(uint256).max;
        slots[3] = p0;

        // Slightly competitive start to get early retail flow / anchors.
        bidFee = bpsToWad(25);
        askFee = bpsToWad(25);
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function afterSwap(TradeInfo calldata trade)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 lastTs = slots[0];
        uint256 prevBid = slots[1];
        uint256 prevAsk = slots[2];

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        uint256 fair = slots[3];

        // Update fair once per step from first observed trade (arb anchor when present). // mock mutation iter=5 mechanism=fair_price_estimation
        if (trade.timestamp != lastTs) {
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate = fair;
            if (gamma != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            // Robust jump clamp (retail can be first-trade when no arb hits us).
            uint256 maxJump = 400 * BPS; // 4%
            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                if (rel > maxJump) {
                    uint256 delta = wmul(fair, maxJump);
                    fairCandidate = fairCandidate > fair ? fair + delta : fair - delta;
                }
            }

            // EWMA (old 80% / new 20%).
            fair = (fair * 80 + fairCandidate * 20) / 100;
            slots[0] = trade.timestamp;
            slots[3] = fair;
        }

        if (spot == 0 || fair == 0) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
            slots[1] = bidFee;
            slots[2] = askFee;
            return (bidFee, askFee);
        }

        uint256 mis = wdiv(absDiff(spot, fair), fair); // mock mutation iter=1 mechanism=flow_memory
        uint256 tightBand = bpsToWad(25);

        if (mis <= tightBand) { // mock mutation iter=3 mechanism=tight_band_pricing // mock mutation iter=7 mechanism=tight_band_pricing
            // Near fair: match the normalizer so we don't pay unnecessary fee undercuts.
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
        } else {
            uint256 gammaBase = WAD - bpsToWad(30); // mock mutation iter=2 mechanism=outer_regime_pricing
            uint256 gammaBaseSq = wmul(gammaBase, gammaBase);
            uint256 buffer = bpsToWad(4);

            if (spot > fair) {
                // Spot > fair: protect bid side (arb would sell X to us).
                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer);

                // Competitive ask side: match normalizer's *weak* ask quote (~p/γ^2).
                uint256 gammaMatch = wdiv(wmul(spot, gammaBaseSq), fair);
                askFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
            } else {
                // Spot < fair: protect ask side (arb would buy X from us).
                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer);

                // Competitive bid side: match normalizer's *weak* bid quote (~γ^2·p).
                uint256 gammaMatch = wdiv(wmul(fair, gammaBaseSq), spot);
                bidFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
            }
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function getName() external pure override returns (string memory) {
        return "tight_band_pricing_mod_v7";
    }
}

```

## YOUR TASK
Modify the **outer_regime_pricing** mechanism to improve expected edge.

### Current Implementation
Competitive side uses gamma-squared matching against normalizer weakness in the out-of-band regime.

### Code Location
afterSwap lines 89-90, 99-101, 108-110

### Current Parameters
- BASE_MATCH_FEE_BPS: 30
- COMPETITOR_MODEL: gamma_squared

### Suggested Directions to Explore
- Try gamma-power variants beyond square
- Use mispricing-proportional matching aggressiveness
- Blend competitor models by regime confidence
- Add side-specific competitive offsets

## CONSTRAINTS
1. ONLY modify code related to outer_regime_pricing
2. Keep all other mechanisms unchanged:
fair_price_estimation, flow_memory, arbitrage_response, tight_band_pricing
3. Output a complete, compilable Solidity contract
4. Keep contract declaration as `contract Strategy`
5. Set getName() return value to "outer_regime_pricing_mod_v8"
6. Keep interface compatibility (afterInitialize, afterSwap, getName)

## OUTPUT FORMAT
Return ONLY the complete Solidity code. No explanations before or after.
