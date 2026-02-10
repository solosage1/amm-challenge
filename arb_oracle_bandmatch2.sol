// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Arb-anchored fair inference + protect-side fee to sit inside inferred no-arb band.
///         Competitive-side fee is computed to roughly match the 30bps normalizer's marginal quote.
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
        slots[0] = 0;
        slots[3] = p0;

        // Start moderately wide until we get a clean arb anchor.
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

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        uint256 fair = slots[3];

        // Update fair once per step from first observed trade (arb gives exact anchor).
        if (trade.timestamp != lastTs) {
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate = fair;
            if (gamma != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            // Clamp candidate jumps; first-trade can be retail when no arb.
            uint256 maxJump = 400 * BPS; // 4.0%
            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                if (rel > maxJump) {
                    uint256 delta = wmul(fair, maxJump);
                    fairCandidate = fairCandidate > fair ? fair + delta : fair - delta;
                }
            }

            // EWMA (old 85% / new 15%): conservative to avoid retail-anchor noise.
            fair = (fair * 85 + fairCandidate * 15) / 100;
            slots[0] = trade.timestamp;
            slots[3] = fair;
        }

        if (spot == 0 || fair == 0) {
            bidFee = bpsToWad(45);
            askFee = bpsToWad(45);
            slots[1] = bidFee;
            slots[2] = askFee;
            return (bidFee, askFee);
        }

        // Baseline gamma (30 bps).
        uint256 gammaBase = WAD - bpsToWad(30);
        uint256 undercut = bpsToWad(2);
        uint256 buffer = bpsToWad(10);

        if (spot > fair) {
            // Protect bid side: ensure spot <= fair/gammaBid (no profitable sell-X arb).
            uint256 gammaReq = wdiv(fair, spot);
            uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
            bidFee = clampFee(req + buffer);

            // Competitive ask side: match baseline marginal buy quote.
            uint256 gammaMatch = wdiv(wmul(spot, gammaBase), fair);
            askFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
            askFee = askFee > undercut ? (askFee - undercut) : 0;
        } else {
            // Protect ask side: ensure spot >= fair*gammaAsk (no profitable buy-X arb).
            uint256 gammaReq = wdiv(spot, fair);
            uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
            askFee = clampFee(req + buffer);

            // Competitive bid side: match baseline marginal sell quote.
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
        return "ArbOracleBandMatch2";
    }
}

