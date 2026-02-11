// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // slots:
    // 0 lastTimestamp
    // 1 currentBidFee
    // 2 currentAskFee
    // 3 fairPrice (WAD, Y per X)
    // 4 mode (0 normal, 1 defensive)

    uint256 private constant TIGHT_BAND_BPS = 25;
    uint256 private constant TIGHT_FEE_TENTHS_BPS = 279;

    uint256 private constant BASE_UNDERCUT_TENTHS_BPS = 109;
    uint256 private constant DEF_UNDERCUT_TENTHS_BPS = 109;

    uint256 private constant BASE_BUFFER_TENTHS_BPS = 10;
    uint256 private constant DEF_BUFFER_TENTHS_BPS = 10;

    uint256 private constant ENTER_DEF_BPS = 9999;
    uint256 private constant EXIT_DEF_BPS = 9998;

    function tenthsBpsToWad(uint256 tenthsBps) internal pure returns (uint256) {
        return (tenthsBps * BPS) / 10;
    }

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);
        slots[0] = type(uint256).max;
        slots[3] = p0;
        slots[4] = 0;

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
        uint256 mode = slots[4];

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        if (trade.timestamp != lastTs) {
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate = fair;
            if (gamma != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            uint256 maxJump = 400 * BPS;
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
            slots[4] = mode;
            return (bidFee, askFee);
        }

        uint256 mis = wdiv(absDiff(spot, fair), fair);

        if (mode == 0) {
            if (mis > bpsToWad(ENTER_DEF_BPS)) mode = 1;
        } else {
            if (mis < bpsToWad(EXIT_DEF_BPS)) mode = 0;
        }

        uint256 undercut = tenthsBpsToWad(mode == 0 ? BASE_UNDERCUT_TENTHS_BPS : DEF_UNDERCUT_TENTHS_BPS);
        uint256 buffer = tenthsBpsToWad(mode == 0 ? BASE_BUFFER_TENTHS_BPS : DEF_BUFFER_TENTHS_BPS);

        if (mis <= bpsToWad(TIGHT_BAND_BPS)) {
            uint256 tightFee = tenthsBpsToWad(TIGHT_FEE_TENTHS_BPS);
            bidFee = tightFee;
            askFee = tightFee;
        } else {
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 gammaBaseSq = wmul(gammaBase, gammaBase);

            if (spot > fair) {
                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer);

                uint256 gammaMatch = wdiv(wmul(spot, gammaBaseSq), fair);
                uint256 askRaw = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                askFee = askRaw > undercut ? askRaw - undercut : 0;
            } else {
                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer);

                uint256 gammaMatch = wdiv(wmul(fair, gammaBaseSq), spot);
                uint256 bidRaw = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                bidFee = bidRaw > undercut ? bidRaw - undercut : 0;
            }
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
        slots[4] = mode;
    }

    function getName() external pure override returns (string memory) {
        return "micro_v10";
    }
}
