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

    uint256 private constant TIGHT_BAND_BPS = 25;
    uint256 private constant TIGHT_FEE_BPS = 28;
    uint256 private constant IDLE_TIGHTEN_BPS = 0;

    uint256 private constant BASE_UNDERCUT_BPS = 11;
    uint256 private constant PROTECT_BUFFER_BPS = 1;

    uint256 private constant INV_THRESH_BPS = 200;
    uint256 private constant INV_ADJ_BPS = 0;
    uint256 private constant TIGHT_SKEW_BPS = 1;

    uint256 private constant UNDER_MORE_BAND_BPS = 1;
    uint256 private constant UNDER_MORE_BPS = 0;
    uint256 private constant UNDER_LESS_BAND_BPS = 10000;
    uint256 private constant UNDER_LESS_BPS = 0;

    uint256 private constant MAX_JUMP_BPS = 400;

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);
        slots[0] = type(uint256).max;
        slots[3] = p0;
        slots[4] = initialX;

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

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        if (trade.timestamp != lastTs) {
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate = fair;
            if (gamma != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                uint256 maxJump = bpsToWad(MAX_JUMP_BPS);
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
            return (bidFee, askFee);
        }

        bool longX;
        bool shortX;
        if (initX != 0 && INV_THRESH_BPS < 10000) {
            uint256 scaledX = rx * 10000;
            longX = scaledX > initX * (10000 + INV_THRESH_BPS);
            shortX = scaledX < initX * (10000 - INV_THRESH_BPS);
        }

        uint256 mis = wdiv(absDiff(spot, fair), fair);
        if (mis <= bpsToWad(TIGHT_BAND_BPS)) {
            uint256 tight = TIGHT_FEE_BPS;
            if (IDLE_TIGHTEN_BPS > 0 && trade.timestamp > lastTs + 1 && tight > IDLE_TIGHTEN_BPS) {
                tight -= IDLE_TIGHTEN_BPS;
            }

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
            uint256 undercutBps = BASE_UNDERCUT_BPS;

            if (UNDER_MORE_BPS > 0 && mis < bpsToWad(UNDER_MORE_BAND_BPS)) {
                undercutBps += UNDER_MORE_BPS;
            }
            if (UNDER_LESS_BPS > 0 && mis > bpsToWad(UNDER_LESS_BAND_BPS)) {
                undercutBps = undercutBps > UNDER_LESS_BPS ? undercutBps - UNDER_LESS_BPS : 0;
            }

            uint256 buffer = bpsToWad(PROTECT_BUFFER_BPS);

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
    }

    function getName() external pure override returns (string memory) {
        return "U11Plus_v9";
    }
}
