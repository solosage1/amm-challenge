// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice ArbBandProtect with a larger safety buffer on the protected side.
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

            uint256 maxJump = 500 * BPS; // 5.0%
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
            bidFee = bpsToWad(50);
            askFee = bpsToWad(50);
            slots[1] = bidFee;
            slots[2] = askFee;
            return (bidFee, askFee);
        }

        bool spotAbove = spot > fair;

        uint256 base = bpsToWad(10);
        uint256 minComp = bpsToWad(5);
        uint256 buffer = bpsToWad(20);

        if (spotAbove) {
            uint256 gammaReq = wdiv(fair, spot);
            uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
            bidFee = clampFee(req + buffer);
            askFee = base;
            if (askFee < minComp) askFee = minComp;
        } else {
            uint256 gammaReq = wdiv(spot, fair);
            uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
            askFee = clampFee(req + buffer);
            bidFee = base;
            if (bidFee < minComp) bidFee = minComp;
        }

        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function getName() external pure override returns (string memory) {
        return "ArbBandProtect_Buf20";
    }
}

