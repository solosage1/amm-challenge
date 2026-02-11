// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Lightweight contextual bandit over 3 aggressiveness arms.
///         Contexts: calm vs stress, inferred from mispricing/velocity/size.
contract Strategy is AMMStrategyBase {
    // slots:
    // 0 lastTimestamp
    // 1 currentBidFee
    // 2 currentAskFee
    // 3 fairPrice
    // 4 lastArm (0..2)
    // 5 lastContext (0 calm, 1 stress)
    // 6 lastSpot
    // 7 ewmaMis
    // 8..10 score calm arm0..2
    // 11..13 score stress arm0..2
    // 14..16 count calm arm0..2
    // 17..19 count stress arm0..2

    uint256 private constant EXPLORE_MIN_TRIES = 6;
    uint256 private constant SCORE_DECAY_PCT = 92;
    uint256 private constant STICKY_SCORE_BONUS = 40;

    uint256 private constant POS_EDGE_BPS = 2;
    uint256 private constant NEG_EDGE_BPS = 2;
    uint256 private constant QUALITY_MIS_BPS = 30;

    uint256 private constant CALM_MIS_BPS = 26;
    uint256 private constant CALM_VOL_BPS = 22;
    uint256 private constant CALM_SIZE_BPS = 90;
    uint256 private constant STRESS_MIS_BPS = 70;
    uint256 private constant STRESS_VOL_BPS = 55;
    uint256 private constant STRESS_SIZE_BPS = 150;

    uint256 private constant CALM_BIAS_ARM1 = 25;
    uint256 private constant CALM_BIAS_ARM2 = 65;
    uint256 private constant STRESS_BIAS_ARM0 = 70;
    uint256 private constant STRESS_BIAS_ARM1 = 35;

    uint256 private constant CALM_UNDERCUT_ADD_CENTI_BPS = 70;
    uint256 private constant CALM_BUFFER_CUT_CENTI_BPS = 20;
    uint256 private constant STRESS_UNDERCUT_CUT_CENTI_BPS = 170;
    uint256 private constant STRESS_BUFFER_ADD_CENTI_BPS = 60;
    uint256 private constant STRESS_BAND_CUT_BPS = 4;

    uint256 private constant ARM0_BAND_BPS = 22;
    uint256 private constant ARM0_TIGHT_CENTI_BPS = 2890;
    uint256 private constant ARM0_UNDERCUT_CENTI_BPS = 820;
    uint256 private constant ARM0_BUFFER_CENTI_BPS = 140;

    uint256 private constant ARM1_BAND_BPS = 26;
    uint256 private constant ARM1_TIGHT_CENTI_BPS = 2788;
    uint256 private constant ARM1_UNDERCUT_CENTI_BPS = 1000;
    uint256 private constant ARM1_BUFFER_CENTI_BPS = 35;

    uint256 private constant ARM2_BAND_BPS = 31;
    uint256 private constant ARM2_TIGHT_CENTI_BPS = 2700;
    uint256 private constant ARM2_UNDERCUT_CENTI_BPS = 1210;
    uint256 private constant ARM2_BUFFER_CENTI_BPS = 0;

    uint256 private constant EWMA_MIS_NEW_PCT = 20;

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

    function _scoreIndex(uint256 ctx, uint256 arm) internal pure returns (uint256) {
        return ctx == 0 ? (8 + arm) : (11 + arm);
    }

    function _countIndex(uint256 ctx, uint256 arm) internal pure returns (uint256) {
        return ctx == 0 ? (14 + arm) : (17 + arm);
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

    function _chooseArm(uint256 ctx, uint256 prevCtx, uint256 prevArm) internal view returns (uint256 arm) {
        uint256 c0 = slots[_countIndex(ctx, 0)];
        uint256 c1 = slots[_countIndex(ctx, 1)];
        uint256 c2 = slots[_countIndex(ctx, 2)];

        if (c0 < EXPLORE_MIN_TRIES) return 0;
        if (c1 < EXPLORE_MIN_TRIES) return 1;
        if (c2 < EXPLORE_MIN_TRIES) return 2;

        uint256 s0 = slots[_scoreIndex(ctx, 0)];
        uint256 s1 = slots[_scoreIndex(ctx, 1)];
        uint256 s2 = slots[_scoreIndex(ctx, 2)];

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

    function _updateBandit(
        uint256 ctx,
        uint256 arm,
        uint256 fairRef,
        uint256 spotRef,
        TradeInfo calldata trade
    ) internal {
        if (ctx > 1 || arm > 2 || fairRef == 0 || trade.amountY == 0) return;

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

        uint256 sIdx = _scoreIndex(ctx, arm);
        uint256 cIdx = _countIndex(ctx, arm);
        uint256 score = slots[sIdx];
        if (score == 0) score = 500;

        score = (score * SCORE_DECAY_PCT + reward * (100 - SCORE_DECAY_PCT)) / 100;
        slots[sIdx] = score;

        uint256 cnt = slots[cIdx] + 1;
        if (cnt > 2000) cnt = 2000;
        slots[cIdx] = cnt;
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

        // Prior scores: calm prefers arm2, stress prefers arm0.
        slots[8] = 470;
        slots[9] = 540;
        slots[10] = 620;

        slots[11] = 620;
        slots[12] = 550;
        slots[13] = 460;

        // Seed counts to avoid cold-start lockups.
        slots[14] = 3;
        slots[15] = 3;
        slots[16] = 3;
        slots[17] = 3;
        slots[18] = 3;
        slots[19] = 3;

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
        uint256 fairForReward = fair;

        uint256 prevArm = slots[4];
        uint256 prevCtx = slots[5];
        uint256 lastSpot = slots[6];

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        if (spot != 0 && fairForReward != 0 && prevArm <= 2 && prevCtx <= 1) {
            _updateBandit(prevCtx, prevArm, fairForReward, spot, trade);
        }

        if (trade.timestamp != lastTs) {
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
            if (spot != 0) slots[6] = spot;
            return (bidFee, askFee);
        }

        uint256 mis = wdiv(absDiff(spot, fair), fair);
        uint256 ewmaMis = slots[7];
        if (ewmaMis == 0) ewmaMis = mis;
        else ewmaMis = (ewmaMis * (100 - EWMA_MIS_NEW_PCT) + mis * EWMA_MIS_NEW_PCT) / 100;
        slots[7] = ewmaMis;

        uint256 volRel = 0;
        if (lastSpot != 0) {
            volRel = wdiv(absDiff(spot, lastSpot), lastSpot);
        }

        uint256 sizeRel = 0;
        if (trade.reserveY != 0) {
            sizeRel = wdiv(trade.amountY, trade.reserveY);
        }

        uint256 ctx = prevCtx;
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

        uint256 arm = _chooseArm(ctx, prevCtx, prevArm);

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

        if (mis <= bpsToWad(tightBandBps)) {
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
        slots[4] = arm;
        slots[5] = ctx;
        slots[6] = spot;
    }

    function getName() external pure override returns (string memory) {
        return "cb2_v1";
    }
}
