// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // slots: 0 lastTimestamp, 1 bid, 2 ask, 3 fair

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);
        slots[0] = type(uint256).max;
        slots[3] = p0;

        bidFee = bpsToWad(20);
        askFee = bpsToWad(20);
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
            uint256 fairCandidate = fair;
            if (gamma != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            uint256 maxJump = 600 * BPS;
            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                if (rel > maxJump) {
                    uint256 delta = wmul(fair, maxJump);
                    fairCandidate = fairCandidate > fair ? fair + delta : fair - delta;
                }
            }

            fair = (fair * (100 - 10) + fairCandidate * 10) / 100;
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

        uint256 mis = wdiv(absDiff(spot, fair), fair);
        uint256 tightBand = 30 * BPS;

        if (tightBand != 0 && mis <= tightBand) {
            uint256 tightFee = 30 * BPS;
            bidFee = tightFee;
            askFee = tightFee;
        } else {
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 buffer = 6 * BPS;
            int256 compAdj = int256(4);

            if (spot > fair) {
                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer);

                uint256 gammaMatch = wdiv(wmul(spot, gammaBase), fair);
                uint256 compFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                if (compAdj >= 0) {
                    compFee = compFee + bpsToWad(uint256(compAdj));
                } else {
                    uint256 d = bpsToWad(uint256(-compAdj));
                    compFee = compFee > d ? (compFee - d) : 0;
                }
                askFee = compFee;
            } else {
                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer);

                uint256 gammaMatch = wdiv(wmul(fair, gammaBase), spot);
                uint256 compFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                if (compAdj >= 0) {
                    compFee = compFee + bpsToWad(uint256(compAdj));
                } else {
                    uint256 d = bpsToWad(uint256(-compAdj));
                    compFee = compFee > d ? (compFee - d) : 0;
                }
                bidFee = compFee;
            }
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function getName() external pure override returns (string memory) {
        return "Candidate";
    }
}
