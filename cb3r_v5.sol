// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // slots:
    // 0 lastTimestamp
    // 1 currentBidFee
    // 2 currentAskFee
    // 3 fairPrice
    // 4 lastArm (0..2)
    // 5 lastContext (0 calm, 1 stress)
    // 6 lastStepSpot
    // 7 ewmaMis
    // 8 packed calm scores [arm0|arm1|arm2], 16 bits each
    // 9 packed stress scores [arm0|arm1|arm2], 16 bits each

    uint256 private constant EXPLORE_PERIOD = 1000003;
    uint256 private constant SCORE_DECAY_PCT = 98;
    uint256 private constant STICKY_SCORE_BONUS = 90;

    uint256 private constant POS_EDGE_BPS = 2;
    uint256 private constant NEG_EDGE_BPS = 2;
    uint256 private constant QUALITY_MIS_BPS = 30;

    uint256 private constant CALM_MIS_BPS = 26;
    uint256 private constant CALM_VOL_BPS = 22;
    uint256 private constant CALM_SIZE_BPS = 90;
    uint256 private constant STRESS_MIS_BPS = 70;
    uint256 private constant STRESS_VOL_BPS = 55;
    uint256 private constant STRESS_SIZE_BPS = 150;

    uint256 private constant CALM_BIAS_ARM1 = 0;
    uint256 private constant CALM_BIAS_ARM2 = 5;
    uint256 private constant STRESS_BIAS_ARM0 = 15;
    uint256 private constant STRESS_BIAS_ARM1 = 8;

    uint256 private constant CALM_UNDERCUT_ADD_CENTI_BPS = 15;
    uint256 private constant CALM_BUFFER_CUT_CENTI_BPS = 5;
    uint256 private constant STRESS_UNDERCUT_CUT_CENTI_BPS = 150;
    uint256 private constant STRESS_BUFFER_ADD_CENTI_BPS = 40;
    uint256 private constant STRESS_BAND_CUT_BPS = 2;

    uint256 private constant ARM0_BAND_BPS = 24;
    uint256 private constant ARM0_TIGHT_CENTI_BPS = 2865;
    uint256 private constant ARM0_UNDERCUT_CENTI_BPS = 920;
    uint256 private constant ARM0_BUFFER_CENTI_BPS = 80;

    uint256 private constant ARM1_BAND_BPS = 26;
    uint256 private constant ARM1_TIGHT_CENTI_BPS = 2788;
    uint256 private constant ARM1_UNDERCUT_CENTI_BPS = 1000;
    uint256 private constant ARM1_BUFFER_CENTI_BPS = 35;

    uint256 private constant ARM2_BAND_BPS = 27;
    uint256 private constant ARM2_TIGHT_CENTI_BPS = 2770;
    uint256 private constant ARM2_UNDERCUT_CENTI_BPS = 1040;
    uint256 private constant ARM2_BUFFER_CENTI_BPS = 5;

    uint256 private constant EWMA_MIS_NEW_PCT = 16;

    // Frozen fair-update core.
    uint256 private constant BASE_ALPHA_NEW_PCT = 19;
    uint256 private constant QUIET_ALPHA_NEW_PCT = 15;
    uint256 private constant QUIET_MIS_BPS = 15;
    uint256 private constant FAST_ALPHA_NEW_PCT = 19;
    uint256 private constant FAST_MIS_BPS = 9999;
    uint256 private constant MAX_ALPHA_NEW_PCT = 19;
    uint256 private constant JUMP_UP_BPS = 400;
    uint256 private constant JUMP_DOWN_BPS = 400;

    function centiBpsToWad(uint256 centiBps) internal pure returns (uint256) {
        return (centiBps * BPS) / 100;
    }

    function _getScore(uint256 packed, uint256 arm) internal pure returns (uint256) {
        if (arm == 0) return packed & 0xFFFF;
        if (arm == 1) return (packed >> 16) & 0xFFFF;
        return (packed >> 32) & 0xFFFF;
    }

    function _setScore(uint256 packed, uint256 arm, uint256 score) internal pure returns (uint256) {
        if (score > 0xFFFF) score = 0xFFFF;
        if (arm == 0) {
            return (packed & ~uint256(0xFFFF)) | score;
        }
        if (arm == 1) {
            return (packed & ~(uint256(0xFFFF) << 16)) | (score << 16);
        }
        return (packed & ~(uint256(0xFFFF) << 32)) | (score << 32);
    }

    function _armParams(uint256 arm)
        internal
        pure
        returns (uint256 bandBps, uint256 tightCenti, uint256 undercutCenti, uint256 bufferCenti)
    {
        if (arm == 0) {
            return (ARM0_BAND_BPS, ARM0_TIGHT_CENTI_BPS, ARM0_UNDERCUT_CENTI_BPS, ARM0_BUFFER_CENTI_BPS);
        }
        if (arm == 1) {
            return (ARM1_BAND_BPS, ARM1_TIGHT_CENTI_BPS, ARM1_UNDERCUT_CENTI_BPS, ARM1_BUFFER_CENTI_BPS);
        }
        return (ARM2_BAND_BPS, ARM2_TIGHT_CENTI_BPS, ARM2_UNDERCUT_CENTI_BPS, ARM2_BUFFER_CENTI_BPS);
    }

    function _chooseArm(uint256 ctx, uint256 packed, uint256 prevCtx, uint256 prevArm, uint256 ts)
        internal
        pure
        returns (uint256 arm)
    {
        if (EXPLORE_PERIOD > 0 && ts % EXPLORE_PERIOD == 0) {
            return (prevArm + 1) % 3;
        }

        uint256 s0 = _getScore(packed, 0);
        uint256 s1 = _getScore(packed, 1);
        uint256 s2 = _getScore(packed, 2);

        if (ctx == 0) {
            s1 += CALM_BIAS_ARM1;
            s2 += CALM_BIAS_ARM2;
        } else {
            s0 += STRESS_BIAS_ARM0;
            s1 += STRESS_BIAS_ARM1;
        }

        if (ctx == prevCtx) {
            if (prevArm == 0) s0 += STICKY_SCORE_BONUS;
            else if (prevArm == 1) s1 += STICKY_SCORE_BONUS;
            else if (prevArm == 2) s2 += STICKY_SCORE_BONUS;
        }

        arm = 0;
        uint256 best = s0;
        if (s1 > best) {
            best = s1;
            arm = 1;
        }
        if (s2 > best) {
            arm = 2;
        }
    }

    function _updatePackedScore(
        uint256 packed,
        uint256 arm,
        uint256 fairRef,
        uint256 spotRef,
        TradeInfo calldata trade
    ) internal pure returns (uint256) {
        if (fairRef == 0 || trade.amountY == 0 || arm > 2) return packed;

        uint256 fairNotionalY = wmul(trade.amountX, fairRef);
        bool positive;
        uint256 mag;

        if (trade.isBuy) {
            if (fairNotionalY >= trade.amountY) {
                positive = true;
                mag = fairNotionalY - trade.amountY;
            } else {
                mag = trade.amountY - fairNotionalY;
            }
        } else {
            if (trade.amountY >= fairNotionalY) {
                positive = true;
                mag = trade.amountY - fairNotionalY;
            } else {
                mag = fairNotionalY - trade.amountY;
            }
        }

        uint256 reward = 500;
        uint256 posThresh = wmul(trade.amountY, bpsToWad(POS_EDGE_BPS));
        uint256 negThresh = wmul(trade.amountY, bpsToWad(NEG_EDGE_BPS));

        if (positive && mag >= posThresh) reward = 700;
        else if (!positive && mag >= negThresh) reward = 300;

        uint256 mis = wdiv(absDiff(spotRef, fairRef), fairRef);
        if (mis <= bpsToWad(QUALITY_MIS_BPS)) {
            if (positive) reward += 120;
            else if (reward > 150) reward -= 120;
        }

        if (reward > 950) reward = 950;

        uint256 oldScore = _getScore(packed, arm);
        if (oldScore == 0) oldScore = 500;
        uint256 newScore = (oldScore * SCORE_DECAY_PCT + reward * (100 - SCORE_DECAY_PCT)) / 100;

        return _setScore(packed, arm, newScore);
    }

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);

        slots[0] = type(uint256).max;
        slots[3] = p0;
        slots[4] = 1;
        slots[5] = 0;
        slots[6] = p0;
        slots[7] = 0;

        // calm:   [470, 540, 620]
        // stress: [620, 550, 460]
        slots[8] = 550 | (580 << 16) | (590 << 32);
        slots[9] = 610 | (570 << 16) | (540 << 32);

        uint256 initFee = centiBpsToWad(2788);
        bidFee = initFee;
        askFee = initFee;
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
        uint256 prevArm = slots[4];
        uint256 prevCtx = slots[5];

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        // Bandit reward update for the arm that produced this trade.
        if (spot != 0 && fair != 0 && prevArm <= 2 && prevCtx <= 1) {
            uint256 pIdx = prevCtx == 0 ? 8 : 9;
            slots[pIdx] = _updatePackedScore(slots[pIdx], prevArm, fair, spot, trade);
        }

        bool isNewStep = trade.timestamp != lastTs;
        if (isNewStep) {
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate = fair;
            if (gamma != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                uint256 upCap = bpsToWad(JUMP_UP_BPS);
                uint256 downCap = bpsToWad(JUMP_DOWN_BPS);

                if (fairCandidate > fair && rel > upCap) {
                    fairCandidate = fair + wmul(fair, upCap);
                    rel = upCap;
                } else if (fairCandidate < fair && rel > downCap) {
                    fairCandidate = fair - wmul(fair, downCap);
                    rel = downCap;
                }

                uint256 alpha = BASE_ALPHA_NEW_PCT;
                if (rel <= bpsToWad(QUIET_MIS_BPS) && QUIET_ALPHA_NEW_PCT < alpha) {
                    alpha = QUIET_ALPHA_NEW_PCT;
                }
                if (rel >= bpsToWad(FAST_MIS_BPS) && FAST_ALPHA_NEW_PCT > alpha) {
                    alpha = FAST_ALPHA_NEW_PCT;
                }
                if (alpha > MAX_ALPHA_NEW_PCT) alpha = MAX_ALPHA_NEW_PCT;

                fair = (fair * (100 - alpha) + fairCandidate * alpha) / 100;
            } else {
                fair = fairCandidate;
            }

            slots[0] = trade.timestamp;
            slots[3] = fair;
        }

        if (spot == 0 || fair == 0) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
            slots[1] = bidFee;
            slots[2] = askFee;
            if (spot != 0 && isNewStep) slots[6] = spot;
            return (bidFee, askFee);
        }

        uint256 ctx = prevCtx;
        uint256 arm = prevArm;

        if (isNewStep) {
            uint256 mis = wdiv(absDiff(spot, fair), fair);

            uint256 ewmaMis = slots[7];
            if (ewmaMis == 0) ewmaMis = mis;
            else ewmaMis = (ewmaMis * (100 - EWMA_MIS_NEW_PCT) + mis * EWMA_MIS_NEW_PCT) / 100;
            slots[7] = ewmaMis;

            uint256 lastSpot = slots[6];
            uint256 volRel = 0;
            if (lastSpot != 0) {
                volRel = wdiv(absDiff(spot, lastSpot), lastSpot);
            }

            uint256 sizeRel = 0;
            if (trade.reserveY != 0) {
                sizeRel = wdiv(trade.amountY, trade.reserveY);
            }

            if (prevCtx == 0) {
                if (
                    ewmaMis >= bpsToWad(STRESS_MIS_BPS)
                        || volRel >= bpsToWad(STRESS_VOL_BPS)
                        || sizeRel >= bpsToWad(STRESS_SIZE_BPS)
                ) {
                    ctx = 1;
                }
            } else {
                if (
                    ewmaMis <= bpsToWad(CALM_MIS_BPS)
                        && volRel <= bpsToWad(CALM_VOL_BPS)
                        && sizeRel <= bpsToWad(CALM_SIZE_BPS)
                ) {
                    ctx = 0;
                }
            }

            uint256 packed = slots[ctx == 0 ? 8 : 9];
            arm = _chooseArm(ctx, packed, prevCtx, prevArm, trade.timestamp);

            slots[5] = ctx;
            slots[4] = arm;
            slots[6] = spot;
        }

        (uint256 tightBandBps, uint256 tightFeeCenti, uint256 undercutCenti, uint256 bufferCenti) = _armParams(arm);

        if (ctx == 0) {
            undercutCenti += CALM_UNDERCUT_ADD_CENTI_BPS;
            if (bufferCenti > CALM_BUFFER_CUT_CENTI_BPS) bufferCenti -= CALM_BUFFER_CUT_CENTI_BPS;
            else bufferCenti = 0;
        } else {
            if (undercutCenti > STRESS_UNDERCUT_CUT_CENTI_BPS) undercutCenti -= STRESS_UNDERCUT_CUT_CENTI_BPS;
            else undercutCenti = 0;
            bufferCenti += STRESS_BUFFER_ADD_CENTI_BPS;
            if (tightBandBps > STRESS_BAND_CUT_BPS) tightBandBps -= STRESS_BAND_CUT_BPS;
            else tightBandBps = 1;
        }

        uint256 undercut = centiBpsToWad(undercutCenti);
        uint256 buffer = centiBpsToWad(bufferCenti);

        uint256 misNow = wdiv(absDiff(spot, fair), fair);
        if (misNow <= bpsToWad(tightBandBps)) {
            uint256 tight = centiBpsToWad(tightFeeCenti);
            bidFee = tight;
            askFee = tight;
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
    }

    function getName() external pure override returns (string memory) {
        return "cb3r_v5";
    }
}
