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
    // 4 mode (0 normal, 1 defensive)

    uint256 private constant TIGHT_BAND_BPS = 26;
    uint256 private constant TIGHT_FEE_BPS = 28;

    uint256 private constant BASE_UNDERCUT_BPS = 13;
    uint256 private constant BASE_BUFFER_BPS = 1;

    uint256 private constant DEF_ENTER_BPS = 75;
    uint256 private constant DEF_EXIT_BPS = 50;
    uint256 private constant DEF_UNDERCUT_REDUCE_BPS = 2;
    uint256 private constant DEF_BUFFER_ADD_BPS = 1;

    uint256 private constant RETAIL_UNDERCUT_INC_BPS = 1;
    uint256 private constant ARB_UNDERCUT_DEC_BPS = 1;
    uint256 private constant RETAIL_TIGHTEN_BPS = 1;

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
        bool isNewStep = trade.timestamp != lastTs;

        if (isNewStep) {
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
            if (mis > bpsToWad(DEF_ENTER_BPS)) mode = 1;
        } else {
            if (mis < bpsToWad(DEF_EXIT_BPS)) mode = 0;
        }

        if (mis <= bpsToWad(TIGHT_BAND_BPS)) {
            uint256 tightBps = TIGHT_FEE_BPS;

            if (!isNewStep && RETAIL_TIGHTEN_BPS > 0 && tightBps > RETAIL_TIGHTEN_BPS) {
                tightBps -= RETAIL_TIGHTEN_BPS;
            }
            if (mode == 1 && tightBps < 30) {
                tightBps += 1;
            }

            bidFee = bpsToWad(tightBps);
            askFee = bpsToWad(tightBps);
        } else {
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 gammaBaseSq = wmul(gammaBase, gammaBase);

            uint256 undercutBps = BASE_UNDERCUT_BPS;
            uint256 bufferBps = BASE_BUFFER_BPS;

            if (mode == 1) {
                if (undercutBps > DEF_UNDERCUT_REDUCE_BPS) {
                    undercutBps -= DEF_UNDERCUT_REDUCE_BPS;
                } else {
                    undercutBps = 0;
                }
                bufferBps += DEF_BUFFER_ADD_BPS;
            }

            if (isNewStep) {
                if (undercutBps > ARB_UNDERCUT_DEC_BPS) {
                    undercutBps -= ARB_UNDERCUT_DEC_BPS;
                } else {
                    undercutBps = 0;
                }
            } else {
                undercutBps += RETAIL_UNDERCUT_INC_BPS;
            }

            uint256 undercut = bpsToWad(undercutBps);
            uint256 buffer = bpsToWad(bufferBps);

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
        return "adaptive_u2_v6";
    }
}
