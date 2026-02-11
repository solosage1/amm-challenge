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
    // 4 mode (0 normal, 1 defensive, 2 recovery)
    // 5 cooldown (steps remaining)
    // 6 initialX

    uint256 private constant ENTER_MIS_BPS = 41;
    uint256 private constant EXIT_MIS_BPS = 27;
    uint256 private constant NORMAL_MIS_BPS = 19;

    uint256 private constant ENTER_INV_BPS = 165;
    uint256 private constant EXIT_INV_BPS = 125;
    uint256 private constant NORMAL_INV_BPS = 110;

    uint256 private constant DEF_COOLDOWN = 2;
    uint256 private constant REC_COOLDOWN = 2;

    uint256 private constant TIGHT_BAND_BPS = 24;
    uint256 private constant NORM_TIGHT_BPS = 28;
    uint256 private constant REC_TIGHT_BPS = 27;
    uint256 private constant DEF_TIGHT_BPS = 30;

    uint256 private constant NORM_BUF_BPS = 1;
    uint256 private constant REC_BUF_BPS = 1;
    uint256 private constant DEF_BUF_BPS = 4;

    uint256 private constant NORM_UNDER_BPS = 12;
    uint256 private constant REC_UNDER_BPS = 15;
    uint256 private constant DEF_UNDER_BPS = 1;

    uint256 private constant TILT_TRIGGER_BPS = 145;
    uint256 private constant TILT_NORM_BPS = 3;
    uint256 private constant TILT_DEF_BPS = 4;

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
        slots[6] = initialX;

        bidFee = bpsToWad(NORM_TIGHT_BPS);
        askFee = bpsToWad(NORM_TIGHT_BPS);
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
        uint256 cooldown = slots[5];
        uint256 initX = slots[6];

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        bool newStep = trade.timestamp != lastTs;
        uint256 dt = 0;

        if (newStep) {
            dt = 1;
            if (lastTs != type(uint256).max && trade.timestamp > lastTs) {
                dt = trade.timestamp - lastTs;
            }
            if (dt > 50) dt = 50;

            if (cooldown > dt) cooldown -= dt;
            else cooldown = 0;

            uint256 gammaUsed = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate = fair;
            if (gammaUsed != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gammaUsed) : wdiv(spot, gammaUsed);
            }

            uint256 maxJump = (320 + 4 * dt) * BPS;
            if (maxJump > 500 * BPS) maxJump = 500 * BPS;
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
            slots[5] = cooldown;
            return (bidFee, askFee);
        }

        uint256 mis = wdiv(absDiff(spot, fair), fair);

        uint256 inv = 0;
        if (initX != 0) {
            inv = wdiv(absDiff(rx, initX), initX);
        }

        bool stress = mis > bpsToWad(ENTER_MIS_BPS) || inv > bpsToWad(ENTER_INV_BPS);
        bool calm = mis < bpsToWad(EXIT_MIS_BPS) && inv < bpsToWad(EXIT_INV_BPS);

        if (mode == 0) {
            if (stress) {
                mode = 1;
                cooldown = DEF_COOLDOWN;
            }
        } else if (mode == 1) {
            if (stress) {
                cooldown = DEF_COOLDOWN;
            } else if (calm && cooldown == 0) {
                mode = 2;
                cooldown = REC_COOLDOWN;
            }
        } else {
            if (stress) {
                mode = 1;
                cooldown = DEF_COOLDOWN;
            } else if (
                cooldown == 0
                    && mis < bpsToWad(NORMAL_MIS_BPS)
                    && inv < bpsToWad(NORMAL_INV_BPS)
            ) {
                mode = 0;
            }
        }

        uint256 tightFeeBps = mode == 1
            ? DEF_TIGHT_BPS
            : (mode == 2 ? REC_TIGHT_BPS : NORM_TIGHT_BPS);
        if (newStep && dt > 2 && tightFeeBps > 24) {
            tightFeeBps -= 1;
        }

        if (mis <= bpsToWad(TIGHT_BAND_BPS)) {
            bidFee = bpsToWad(tightFeeBps);
            askFee = bpsToWad(tightFeeBps);
        } else {
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 gammaBaseSq = wmul(gammaBase, gammaBase);

            uint256 bufferBps = mode == 1 ? DEF_BUF_BPS : (mode == 2 ? REC_BUF_BPS : NORM_BUF_BPS);
            uint256 undercutBps =
                mode == 1 ? DEF_UNDER_BPS : (mode == 2 ? REC_UNDER_BPS : NORM_UNDER_BPS);

            uint256 buffer = bpsToWad(bufferBps);
            uint256 undercut = bpsToWad(undercutBps);

            if (spot > fair) {
                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer);

                uint256 gammaMatch = wdiv(wmul(spot, gammaBaseSq), fair);
                uint256 askRaw = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                askFee = askRaw > undercut ? (askRaw - undercut) : 0;
            } else {
                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer);

                uint256 gammaMatch = wdiv(wmul(fair, gammaBaseSq), spot);
                uint256 bidRaw = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                bidFee = bidRaw > undercut ? (bidRaw - undercut) : 0;
            }
        }

        if (initX != 0) {
            uint256 tiltBps = mode == 1 ? TILT_DEF_BPS : TILT_NORM_BPS;
            uint256 tilt = bpsToWad(tiltBps);
            uint256 tiltTrigger = bpsToWad(TILT_TRIGGER_BPS);

            if (rx > initX) {
                uint256 longX = wdiv(rx - initX, initX);
                if (longX > tiltTrigger) {
                    bidFee = clampFee(bidFee + tilt);
                    askFee = askFee > tilt ? (askFee - tilt) : 0;
                }
            } else {
                uint256 shortX = wdiv(initX - rx, initX);
                if (shortX > tiltTrigger) {
                    askFee = clampFee(askFee + tilt);
                    bidFee = bidFee > tilt ? (bidFee - tilt) : 0;
                }
            }
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);

        slots[1] = bidFee;
        slots[2] = askFee;
        slots[4] = mode;
        slots[5] = cooldown;
    }

    function getName() external pure override returns (string memory) {
        return "canary_mode3_v9";
    }
}
