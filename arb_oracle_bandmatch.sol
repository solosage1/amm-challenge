// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Arb-anchored fair-price inference + "band protect" with competitive-side fee
///         chosen to approximately match/beat the 30bps normalizer given inferred fair.
/// @dev Uses only AMMStrategyBase.slots[0..31] for state.
contract Strategy is AMMStrategyBase {
    // Slot layout:
    // 0: lastTimestamp (last seen trade timestamp)
    // 1: currentBidFee (WAD)
    // 2: currentAskFee (WAD)
    // 3: fairPriceEwma (WAD, Y per X)
    // 4: volEwma (WAD, abs return proxy)

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);

        slots[0] = 0;
        slots[3] = p0;
        slots[4] = bpsToWad(8); // ~8 bps prior

        bidFee = bpsToWad(60);
        askFee = bpsToWad(60);
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

        uint256 fair = slots[3];
        uint256 vol = slots[4];

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx); // Y per X (WAD)

        // Update fair/vol once per step using the first observed trade as an arb anchor.
        if (trade.timestamp != lastTs) {
            uint256 gammaUsed = WAD - (trade.isBuy ? prevBid : prevAsk);

            uint256 fairCandidate = fair;
            if (gammaUsed != 0 && spot != 0) {
                // Arb boundary condition:
                // - AMM bought X: post spot = fair/gamma  => fair = spot*gamma
                // - AMM sold X : post spot = gamma*fair => fair = spot/gamma
                fairCandidate = trade.isBuy ? wmul(spot, gammaUsed) : wdiv(spot, gammaUsed);
            }

            // Simple arb-likelihood check: did the trade move spot toward prior fair?
            bool arbLikely = false;
            if (fair != 0 && spot != 0) {
                uint256 x0;
                uint256 y0;
                if (trade.isBuy) {
                    // AMM bought X: x increased, y decreased.
                    x0 = rx >= trade.amountX ? (rx - trade.amountX) : 0;
                    y0 = ry + trade.amountY;
                } else {
                    // AMM sold X: x decreased, y increased.
                    x0 = rx + trade.amountX;
                    y0 = ry >= trade.amountY ? (ry - trade.amountY) : 0;
                }
                uint256 spotBefore = x0 == 0 ? 0 : wdiv(y0, x0);
                uint256 distBefore = absDiff(spotBefore, fair);
                uint256 distAfter = absDiff(spot, fair);
                bool movedToward = distAfter < distBefore;
                bool dirMatches = (spotBefore > fair && trade.isBuy) || (spotBefore < fair && !trade.isBuy);
                arbLikely = movedToward && dirMatches;
            }

            // Clamp candidate jumps (retail can be first-trade when no arb).
            uint256 maxJump = bpsToWad(300); // 3%
            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                if (rel > maxJump) {
                    uint256 delta = wmul(fair, maxJump);
                    fairCandidate = fairCandidate > fair ? fair + delta : fair - delta;
                }
            }

            // EWMA update: faster when anchor looks like arb, slower otherwise.
            uint256 alpha = arbLikely ? 35 : 15; // percent weight on candidate
            fair = (fair * (100 - alpha) + fairCandidate * alpha) / 100;

            // Vol proxy = |ΔfairCandidate| / fair (EWMA beta=0.20), floor at 1 bp.
            if (fair != 0) {
                uint256 ret = wdiv(absDiff(fairCandidate, fair), fair);
                vol = (vol * 80 + ret * 20) / 100;
                uint256 volFloor = bpsToWad(1);
                if (vol < volFloor) vol = volFloor;
            }

            slots[0] = trade.timestamp;
            slots[3] = fair;
            slots[4] = vol;
        }

        // Fallback if we can't form a price.
        if (spot == 0 || fair == 0) {
            bidFee = bpsToWad(45);
            askFee = bpsToWad(45);
            slots[1] = bidFee;
            slots[2] = askFee;
            return (bidFee, askFee);
        }

        // Baseline (normalizer) gamma for 30 bps.
        uint256 gammaBase = WAD - bpsToWad(30);
        // Small undercut to win routing on the competitive side.
        uint256 undercut = bpsToWad(2);

        // Buffer on the protected side to tolerate fair-estimation error + next-step drift.
        // Keep it modest; volatility is small but nonzero.
        uint256 buffer = bpsToWad(6) + vol; // ~ (6 bps + vol)

        if (spot >= fair) {
            // Spot > fair: protect bid side (discourage sells / prevent arb selling X to us).
            uint256 gammaReq = wdiv(fair, spot); // <= 1
            uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
            bidFee = clampFee(req + buffer);

            // Competitive ask side: choose fee so our marginal buy price matches baseline.
            uint256 gammaMatch = wdiv(wmul(spot, gammaBase), fair);
            askFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
            askFee = askFee > undercut ? (askFee - undercut) : 0;
        } else {
            // Spot < fair: protect ask side (discourage buys / prevent arb buying X from us).
            uint256 gammaReq = wdiv(spot, fair); // <= 1
            uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
            askFee = clampFee(req + buffer);

            // Competitive bid side: choose fee so our marginal sell price matches baseline.
            uint256 gammaMatch = wdiv(wmul(fair, gammaBase), spot);
            bidFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
            bidFee = bidFee > undercut ? (bidFee - undercut) : 0;
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function getName() external pure override returns (string memory) {
        return "ArbOracleBandMatch";
    }
}

