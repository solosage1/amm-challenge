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
    // 5 cooldown (steps)

    uint256 private constant ENTER_DEF_BPS = 90;
    uint256 private constant EXIT_DEF_BPS = 55;
    uint256 private constant EXIT_REC_BPS = 26;

    uint256 private constant DEF_CD = 1;
    uint256 private constant REC_CD = 1;

    uint256 private constant DEF_BUF_BPS = 3;
    uint256 private constant DEF_UNDER_BPS = 3;
    uint256 private constant REC_UNDER_BPS = 12;

    uint256 private constant DEF_TIGHT_BPS = 30;
    uint256 private constant REC_TIGHT_BPS = 27;

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
        uint256 cooldown = slots[5];

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
            slots[4] = mode;
            slots[5] = cooldown;
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

        uint256 tightBand = bpsToWad(25);

        if (mis <= tightBand) {
            uint256 tight = mode == 1 ? DEF_TIGHT_BPS : (mode == 2 ? REC_TIGHT_BPS : 28);

            // Mild timestamp-aware tightening when inactive.
            if (trade.timestamp > lastTs + 1 && tight > 26) {
                tight -= 1;
            }

            bidFee = bpsToWad(tight);
            askFee = bpsToWad(tight);
        } else {
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 gammaBaseSq = wmul(gammaBase, gammaBase);

            uint256 bufferBps = mode == 1 ? DEF_BUF_BPS : 1;
            uint256 undercutBps = mode == 1 ? DEF_UNDER_BPS : (mode == 2 ? REC_UNDER_BPS : 11);

            uint256 buffer = bpsToWad(bufferBps);
            uint256 undercut = bpsToWad(undercutBps);

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
        slots[5] = cooldown;
    }

    function getName() external pure override returns (string memory) {
        return "canary_mode3_light_l4";
    }
}
