// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Uses arb-implied fair price to "protect" the currently mispriced side (higher fee)
///         while slightly discounting the favorable side to win routed retail.
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

        bidFee = bpsToWad(80);
        askFee = bpsToWad(80);
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

        if (trade.timestamp != lastTs) {
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate;
            if (gamma == 0 || spot == 0) {
                fairCandidate = fair;
            } else if (trade.isBuy) {
                fairCandidate = wmul(spot, gamma);
            } else {
                fairCandidate = wdiv(spot, gamma);
            }

            // Clamp per-step fair jumps (first trade can be retail when no arb).
            uint256 maxJump = 200 * BPS; // 200 bps
            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                if (rel > maxJump) {
                    uint256 delta = wmul(fair, maxJump);
                    fairCandidate = fairCandidate > fair ? fair + delta : fair - delta;
                }
            }

            // Slow EWMA: arb anchors are clean, but first trade can be retail.
            fair = (fair * 73 + fairCandidate * 27) / 100;

            slots[0] = trade.timestamp;
            slots[3] = fair;
        }

        // Base fee around the empirically-good constant.
        uint256 base = bpsToWad(25);

        // Mispricing magnitude (cap 1%).
        uint256 skewCap = WAD / 100; // 1%
        uint256 skew = 0;
        bool spotAbove = false;
        if (fair != 0 && spot != 0) {
            if (spot > fair) {
                spotAbove = true;
                skew = wdiv(spot - fair, fair);
            } else {
                skew = wdiv(fair - spot, fair);
            }
            if (skew > skewCap) skew = skewCap;
        }

        // Protection ramp: up to +120 bps on the "arb side" when skew maxed.
        uint256 maxProtect = bpsToWad(100);
        uint256 factor = skewCap == 0 ? 0 : wdiv(skew, skewCap); // [0, 1] in WAD
        uint256 protect = wmul(maxProtect, factor);

        // Discount on the favorable side to win routing when skewed.
        uint256 maxDiscount = bpsToWad(60);
        uint256 discount = wmul(maxDiscount, factor);

        if (spotAbove) {
            // Spot > fair: arb would SELL X to us => protect bid side.
            bidFee = base + protect;
            askFee = base > discount ? base - discount : 0;
        } else {
            // Spot < fair: arb would BUY X from us => protect ask side.
            askFee = base + protect;
            bidFee = base > discount ? base - discount : 0;
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function getName() external pure override returns (string memory) {
        return "ArbInferredProtect";
    }
}
