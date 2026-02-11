// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // slots:
    // 0 lastTimestamp
    // 1 currentBidFee
    // 2 currentAskFee
    // 3 fairPrice (WAD)
    // 4 initialX
    // 5 mode (0 normal, 1 defensive, 2 recovery)
    // 6 cooldown (steps)

    uint256 private constant ENTER_DEF_BPS = 80;
    uint256 private constant EXIT_DEF_BPS = 50;
    uint256 private constant EXIT_REC_BPS = 25;

    uint256 private constant DEF_CD = 2;
    uint256 private constant REC_CD = 1;

    uint256 private constant DEF_BUF_BPS = 2;
    uint256 private constant DEF_UNDER_BPS = 9;
    uint256 private constant REC_UNDER_BPS = 13;

    uint256 private constant DEF_TIGHT_BPS = 29;
    uint256 private constant REC_TIGHT_BPS = 27;

    uint256 private constant INV_THRESH_BPS = 150;
    uint256 private constant INV_ADJ_BPS = 2;
    uint256 private constant TIGHT_SKEW_BPS = 1;

    uint256 private constant UNDER_MORE_BAND_BPS = 50;
    uint256 private constant UNDER_MORE_BPS = 1;
    uint256 private constant UNDER_LESS_BAND_BPS = 95;
    uint256 private constant UNDER_LESS_BPS = 2;

    uint256 private constant BUFFER_UP_BAND_BPS = 110;
    uint256 private constant BUFFER_UP_BPS = 1;

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);
        slots[0] = type(uint256).max;
        slots[3] = p0;
        slots[4] = initialX;
        slots[5] = 0;
        slots[6] = 0;

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
        uint256 initX = slots[4];
        uint256 mode = slots[5];
        uint256 cooldown = slots[6];

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        if (trade.timestamp != lastTs) {
            uint256 dt = 1;
            if (lastTs != type(uint256).max && trade.timestamp > lastTs) {
                dt = trade.timestamp - lastTs;
            }
            if (dt > 20) dt = 20;

            if (cooldown > dt) cooldown -= dt;
            else cooldown = 0;

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
            slots[5] = mode;
            slots[6] = cooldown;
            return (bidFee, askFee);
        }

        uint256 mis = wdiv(absDiff(spot, fair), fair);

        if (mode == 0) {
            if (mis > bpsToWad(ENTER_DEF_BPS)) {
                mode = 1;
                cooldown = DEF_CD;
            }
        } else if (mode == 1) {
            if (mis > bpsToWad(ENTER_DEF_BPS)) {
                cooldown = DEF_CD;
            } else if (mis < bpsToWad(EXIT_DEF_BPS) && cooldown == 0) {
                mode = 2;
                cooldown = REC_CD;
            }
        } else {
            if (mis > bpsToWad(ENTER_DEF_BPS)) {
                mode = 1;
                cooldown = DEF_CD;
            } else if (mis < bpsToWad(EXIT_REC_BPS) && cooldown == 0) {
                mode = 0;
            }
        }

        bool longX;
        bool shortX;
        if (initX != 0 && INV_THRESH_BPS < 10000) {
            uint256 scaledX = rx * 10000;
            longX = scaledX > initX * (10000 + INV_THRESH_BPS);
            shortX = scaledX < initX * (10000 - INV_THRESH_BPS);
        }

        uint256 tightBand = bpsToWad(25);

        if (mis <= tightBand) {
            uint256 tight = mode == 1 ? DEF_TIGHT_BPS : (mode == 2 ? REC_TIGHT_BPS : 28);
            uint256 bidBps = tight;
            uint256 askBps = tight;

            if (TIGHT_SKEW_BPS > 0) {
                if (longX) {
                    bidBps += TIGHT_SKEW_BPS;
                    askBps = askBps > TIGHT_SKEW_BPS ? askBps - TIGHT_SKEW_BPS : 0;
                } else if (shortX) {
                    askBps += TIGHT_SKEW_BPS;
                    bidBps = bidBps > TIGHT_SKEW_BPS ? bidBps - TIGHT_SKEW_BPS : 0;
                }
            }

            bidFee = bpsToWad(bidBps);
            askFee = bpsToWad(askBps);
        } else {
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 gammaBaseSq = wmul(gammaBase, gammaBase);

            uint256 bufferBps = mode == 1 ? DEF_BUF_BPS : 1;
            uint256 undercutBps = mode == 1 ? DEF_UNDER_BPS : (mode == 2 ? REC_UNDER_BPS : 11);

            if (mis < bpsToWad(UNDER_MORE_BAND_BPS)) {
                undercutBps += UNDER_MORE_BPS;
            }
            if (mis > bpsToWad(UNDER_LESS_BAND_BPS)) {
                undercutBps = undercutBps > UNDER_LESS_BPS ? undercutBps - UNDER_LESS_BPS : 0;
            }
            if (mis > bpsToWad(BUFFER_UP_BAND_BPS)) {
                bufferBps += BUFFER_UP_BPS;
            }

            uint256 buffer = bpsToWad(bufferBps);

            if (spot > fair) {
                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer);

                uint256 compUnderBps = undercutBps;
                if (longX) {
                    compUnderBps += INV_ADJ_BPS;
                } else if (shortX) {
                    compUnderBps = compUnderBps > INV_ADJ_BPS ? compUnderBps - INV_ADJ_BPS : 0;
                }

                uint256 gammaMatch = wdiv(wmul(spot, gammaBaseSq), fair);
                uint256 askRaw = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                uint256 undercut = bpsToWad(compUnderBps);
                askFee = askRaw > undercut ? askRaw - undercut : 0;
            } else {
                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer);

                uint256 compUnderBps = undercutBps;
                if (shortX) {
                    compUnderBps += INV_ADJ_BPS;
                } else if (longX) {
                    compUnderBps = compUnderBps > INV_ADJ_BPS ? compUnderBps - INV_ADJ_BPS : 0;
                }

                uint256 gammaMatch = wdiv(wmul(fair, gammaBaseSq), spot);
                uint256 bidRaw = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                uint256 undercut = bpsToWad(compUnderBps);
                bidFee = bidRaw > undercut ? bidRaw - undercut : 0;
            }
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
        slots[5] = mode;
        slots[6] = cooldown;
    }

    function getName() external pure override returns (string memory) {
        return "RegInv_v3";
    }
}
