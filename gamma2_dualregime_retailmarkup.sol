// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Arb-oracle dual regime with gamma^2 competitor anchoring, plus
///         a retail-only adaptive markup on the competitive side.
/// @dev Markups only update on same-timestamp trades (retail stage), avoiding arb feedback loops.
contract Strategy is AMMStrategyBase {
    // slots:
    // 0 lastTimestamp
    // 1 currentBidFee
    // 2 currentAskFee
    // 3 fairPrice (WAD, Y per X)
    // 4 bidMarkup (WAD fee addend)
    // 5 askMarkup (WAD fee addend)

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);
        slots[0] = type(uint256).max;
        slots[3] = p0;
        slots[4] = 0;
        slots[5] = 0;

        // Slightly competitive start to get routed early.
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
        uint256 fair = slots[3];
        uint256 bidMarkup = slots[4];
        uint256 askMarkup = slots[5];

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        bool newStep = trade.timestamp != lastTs;

        // Compute pre-trade spot for retail classification / markup updates.
        // Fee-on-input gamma used for this trade.
        uint256 feeUsed = trade.isBuy ? prevBid : prevAsk;
        uint256 gammaUsed = feeUsed >= WAD ? 0 : (WAD - feeUsed);

        uint256 preX;
        uint256 preY;
        if (trade.isBuy) {
            // AMM bought X: input X (net=gamma*amountX), output Y (amountY).
            uint256 netX = wmul(trade.amountX, gammaUsed);
            preX = rx >= netX ? (rx - netX) : 0;
            preY = ry + trade.amountY;
        } else {
            // AMM sold X: input Y (net=gamma*amountY), output X (amountX).
            uint256 netY = wmul(trade.amountY, gammaUsed);
            preX = rx + trade.amountX;
            preY = ry >= netY ? (ry - netY) : 0;
        }
        uint256 preSpot = preX == 0 ? 0 : wdiv(preY, preX);

        if (newStep) {
            // Inactivity decay: long gaps imply we were overpriced/uncompetitive.
            uint256 dt = 1;
            if (lastTs != type(uint256).max && trade.timestamp > lastTs) {
                dt = trade.timestamp - lastTs;
            }
            if (dt > 25) dt = 25;
            uint256 decay = dt * bpsToWad(1); // 1 bp per idle step
            bidMarkup = bidMarkup > decay ? (bidMarkup - decay) : 0;
            askMarkup = askMarkup > decay ? (askMarkup - decay) : 0;

            // Update fair once per step from first observed trade (arb when present).
            uint256 fairCandidate = fair;
            if (gammaUsed != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gammaUsed) : wdiv(spot, gammaUsed);
            }

            uint256 maxJump = 400 * BPS; // 4%
            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                if (rel > maxJump) {
                    uint256 delta = wmul(fair, maxJump);
                    fairCandidate = fairCandidate > fair ? fair + delta : fair - delta;
                }
            }

            fair = (fair * 80 + fairCandidate * 20) / 100;

            slots[0] = trade.timestamp;
            slots[3] = fair;
        } else {
            // Same-step trades are retail-only: adaptively raise markups.
            if (preSpot != 0 && fair != 0) {
                bool favorableFill = (preSpot > fair && !trade.isBuy) || (preSpot < fair && trade.isBuy);

                uint256 upGood = bpsToWad(1);
                uint256 upBad = bpsToWad(5);
                uint256 cap = bpsToWad(25);

                if (trade.isBuy) {
                    // Bid side filled.
                    bidMarkup = clamp(bidMarkup + (favorableFill ? upGood : upBad), 0, cap);
                } else {
                    // Ask side filled.
                    askMarkup = clamp(askMarkup + (favorableFill ? upGood : upBad), 0, cap);
                }
            }
        }

        if (spot == 0 || fair == 0) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
            slots[1] = bidFee;
            slots[2] = askFee;
            slots[4] = bidMarkup;
            slots[5] = askMarkup;
            return (bidFee, askFee);
        }

        uint256 mis = wdiv(absDiff(spot, fair), fair);
        uint256 tightBand = bpsToWad(25);

        if (mis <= tightBand) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
        } else {
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 gammaBaseSq = wmul(gammaBase, gammaBase);
            uint256 buffer = bpsToWad(4);

            if (spot > fair) {
                // Protect bid side.
                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer);

                // Competitive ask side: match normalizer weak ask (~p/gamma^2).
                uint256 gammaMatch = wdiv(wmul(spot, gammaBaseSq), fair);
                askFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);

                // Apply adaptive markup only when not extremely mispriced.
                if (mis < bpsToWad(200)) {
                    askFee = clampFee(askFee + askMarkup);
                }
            } else {
                // Protect ask side.
                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer);

                // Competitive bid side: match normalizer weak bid (~gamma^2 * p).
                uint256 gammaMatch = wdiv(wmul(fair, gammaBaseSq), spot);
                bidFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);

                if (mis < bpsToWad(200)) {
                    bidFee = clampFee(bidFee + bidMarkup);
                }
            }
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
        slots[4] = bidMarkup;
        slots[5] = askMarkup;
    }

    function getName() external pure override returns (string memory) {
        return "GammaSquaredDualRegime_RetailMarkup";
    }
}

