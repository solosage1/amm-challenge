// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Dual-regime arb-oracle with:
///         (1) competitive-side anchoring to the normalizer's weaker quote (~γ^2),
///         (2) fill-rate-based markup that slowly ratchets fees up when we keep getting hit
///             (leaving money on the table) and decays down after inactivity.
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

        // Start with zero markups.
        slots[4] = 0;
        slots[5] = 0;

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

        uint256 bidMarkup = slots[4];
        uint256 askMarkup = slots[5];

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        uint256 fair = slots[3];

        bool newStep = trade.timestamp != lastTs;
        if (newStep) {
            // Inactivity decay: if we weren't traded for dt steps, reduce markups to regain routing.
            uint256 dt = 1;
            if (lastTs != type(uint256).max && trade.timestamp > lastTs) {
                dt = trade.timestamp - lastTs;
            }
            if (dt > 25) dt = 25;

            uint256 decay = dt * bpsToWad(1); // 1 bp per idle step (capped by dt cap)
            bidMarkup = bidMarkup > decay ? (bidMarkup - decay) : 0;
            askMarkup = askMarkup > decay ? (askMarkup - decay) : 0;

            // Fair update from arb boundary (when present).
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate = fair;
            if (gamma != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            // Clamp per-step fair jumps.
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

        // Fill-based ratchet: if we get filled on a side, nudge that side's markup up.
        // Favorable side gets a smaller increment; adverse side gets a larger increment to deter.
        bool spotAbove = spot > fair;
        bool favorableIsAsk = spotAbove;
        bool filledAsk = !trade.isBuy;

        uint256 upGood = bpsToWad(1);
        uint256 upBad = bpsToWad(4);
        uint256 markupCap = bpsToWad(60);

        if (filledAsk) {
            if (favorableIsAsk) {
                askMarkup = clamp(askMarkup + upGood, 0, markupCap);
            } else {
                askMarkup = clamp(askMarkup + upBad, 0, markupCap);
            }
        } else {
            if (!favorableIsAsk) {
                bidMarkup = clamp(bidMarkup + upGood, 0, markupCap);
            } else {
                bidMarkup = clamp(bidMarkup + upBad, 0, markupCap);
            }
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

            if (spotAbove) {
                // Protect bid side.
                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer);

                // Competitive ask side: normalizer-weak anchor (~p/γ^2).
                uint256 gammaMatch = wdiv(wmul(spot, gammaBaseSq), fair);
                askFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
            } else {
                // Protect ask side.
                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer);

                // Competitive bid side: normalizer-weak anchor (~γ^2·p).
                uint256 gammaMatch = wdiv(wmul(fair, gammaBaseSq), spot);
                bidFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
            }
        }

        // Apply markups to the side we want to attract (and thus can "take" a bit more).
        // Leave the protected side un-marked to avoid accidental flow on the wrong side.
        if (spotAbove) {
            askFee = clampFee(askFee + askMarkup);
        } else {
            bidFee = clampFee(bidFee + bidMarkup);
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);

        slots[1] = bidFee;
        slots[2] = askFee;
        slots[4] = bidMarkup;
        slots[5] = askMarkup;
    }

    function getName() external pure override returns (string memory) {
        return "GammaSquaredDualRegime_Markup";
    }
}

