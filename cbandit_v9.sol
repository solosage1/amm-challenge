// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Contextual bandit over quote aggressiveness with gamma^2 competitive anchoring.
///         Context is inferred from mispricing, spot velocity, and trade-size burst.
contract Strategy is AMMStrategyBase {
    uint256 private constant N_ARMS = 4;
    uint256 private constant N_CTX = 3;
    uint256 private constant ALPHA_BASE = 8;
    uint256 private constant BETA_BASE = 20;

    // Frozen fair-value update core.
    uint256 private constant BASE_ALPHA_NEW_PCT = 19;
    uint256 private constant QUIET_ALPHA_NEW_PCT = 15;
    uint256 private constant QUIET_MIS_BPS = 15;
    uint256 private constant FAST_ALPHA_NEW_PCT = 19;
    uint256 private constant FAST_MIS_BPS = 9999;
    uint256 private constant MAX_ALPHA_NEW_PCT = 19;
    uint256 private constant JUMP_UP_BPS = 400;
    uint256 private constant JUMP_DOWN_BPS = 400;

    // Bandit controls.
    uint256 private constant EXPLORE_MILLI = 105000;
    uint256 private constant STICKY_BONUS_MILLI = 16000;
    uint256 private constant BANDIT_COUNT_CAP = 700;
    uint256 private constant BANDIT_DECAY_PCT = 93;

    // Reward shaping.
    uint256 private constant POS_EDGE_BPS = 2;
    uint256 private constant NEG_EDGE_BPS = 2;
    uint256 private constant QUALITY_MIS_BPS = 34;

    // Context thresholds.
    uint256 private constant CALM_MIS_BPS = 28;
    uint256 private constant CALM_VOL_BPS = 20;
    uint256 private constant CALM_SIZE_BPS = 80;
    uint256 private constant STRESS_MIS_BPS = 72;
    uint256 private constant STRESS_VOL_BPS = 55;
    uint256 private constant STRESS_SIZE_BPS = 150;

    // Context-specific nudges.
    uint256 private constant CALM_UNDERCUT_ADD_CENTI_BPS = 40;
    uint256 private constant CALM_BUFFER_CUT_CENTI_BPS = 10;
    uint256 private constant STRESS_UNDERCUT_CUT_CENTI_BPS = 180;
    uint256 private constant STRESS_BUFFER_ADD_CENTI_BPS = 60;
    uint256 private constant STRESS_BAND_CUT_BPS = 4;

    // Arm parameters: (tightBandBps, tightFeeCentiBps, undercutCentiBps, bufferCentiBps)
    uint256 private constant ARM0_BAND_BPS = 22;
    uint256 private constant ARM0_TIGHT_CENTI_BPS = 2890;
    uint256 private constant ARM0_UNDERCUT_CENTI_BPS = 800;
    uint256 private constant ARM0_BUFFER_CENTI_BPS = 140;

    uint256 private constant ARM1_BAND_BPS = 26;
    uint256 private constant ARM1_TIGHT_CENTI_BPS = 2788;
    uint256 private constant ARM1_UNDERCUT_CENTI_BPS = 1000;
    uint256 private constant ARM1_BUFFER_CENTI_BPS = 35;

    uint256 private constant ARM2_BAND_BPS = 28;
    uint256 private constant ARM2_TIGHT_CENTI_BPS = 2720;
    uint256 private constant ARM2_UNDERCUT_CENTI_BPS = 1120;
    uint256 private constant ARM2_BUFFER_CENTI_BPS = 0;

    uint256 private constant ARM3_BAND_BPS = 31;
    uint256 private constant ARM3_TIGHT_CENTI_BPS = 2660;
    uint256 private constant ARM3_UNDERCUT_CENTI_BPS = 1240;
    uint256 private constant ARM3_BUFFER_CENTI_BPS = 0;

    // Context-arm score bonuses (scale: 1e6 = +1.0 score).
    uint256 private constant CALM_BIAS_ARM1_MILLI = 6000;
    uint256 private constant CALM_BIAS_ARM2_MILLI = 15000;
    uint256 private constant CALM_BIAS_ARM3_MILLI = 18000;

    uint256 private constant NORMAL_BIAS_ARM1_MILLI = 12000;
    uint256 private constant NORMAL_BIAS_ARM2_MILLI = 2000;

    uint256 private constant STRESS_BIAS_ARM0_MILLI = 22000;
    uint256 private constant STRESS_BIAS_ARM1_MILLI = 9000;

    // slots:
    // 0 lastTimestamp
    // 1 currentBidFee
    // 2 currentAskFee
    // 3 fairPrice
    // 4 lastArm
    // 5 lastContext
    // 6 ewmaMispricing
    // 7 lastSpot
    // 8..19 alpha counts (ctx-major, 4 arms each)
    // 20..31 beta counts (ctx-major, 4 arms each)

    function centiBpsToWad(uint256 centiBps) internal pure returns (uint256) {
        return (centiBps * BPS) / 100;
    }

    function _statIndex(uint256 base, uint256 ctx, uint256 arm) internal pure returns (uint256) {
        return base + ctx * N_ARMS + arm;
    }

    function _priorAlpha(uint256 ctx, uint256 arm) internal pure returns (uint256) {
        if (ctx == 0) {
            if (arm == 0) return 9;
            if (arm == 1) return 12;
            if (arm == 2) return 15;
            return 16;
        }
        if (ctx == 1) {
            if (arm == 0) return 10;
            if (arm == 1) return 16;
            if (arm == 2) return 13;
            return 9;
        }
        if (arm == 0) return 16;
        if (arm == 1) return 13;
        if (arm == 2) return 10;
        return 8;
    }

    function _priorBeta(uint256 ctx, uint256 arm) internal pure returns (uint256) {
        if (ctx == 0) {
            if (arm == 0) return 12;
            if (arm == 1) return 10;
            if (arm == 2) return 9;
            return 9;
        }
        if (ctx == 1) {
            if (arm == 0) return 10;
            if (arm == 1) return 9;
            if (arm == 2) return 10;
            return 12;
        }
        if (arm == 0) return 9;
        if (arm == 1) return 10;
        if (arm == 2) return 12;
        return 14;
    }

    function _armBias(uint256 ctx, uint256 arm) internal pure returns (uint256 biasMilli) {
        if (ctx == 0) {
            if (arm == 1) return CALM_BIAS_ARM1_MILLI;
            if (arm == 2) return CALM_BIAS_ARM2_MILLI;
            if (arm == 3) return CALM_BIAS_ARM3_MILLI;
            return 0;
        }
        if (ctx == 1) {
            if (arm == 1) return NORMAL_BIAS_ARM1_MILLI;
            if (arm == 2) return NORMAL_BIAS_ARM2_MILLI;
            return 0;
        }
        if (arm == 0) return STRESS_BIAS_ARM0_MILLI;
        if (arm == 1) return STRESS_BIAS_ARM1_MILLI;
        return 0;
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
        if (arm == 2) {
            return (ARM2_BAND_BPS, ARM2_TIGHT_CENTI_BPS, ARM2_UNDERCUT_CENTI_BPS, ARM2_BUFFER_CENTI_BPS);
        }
        return (ARM3_BAND_BPS, ARM3_TIGHT_CENTI_BPS, ARM3_UNDERCUT_CENTI_BPS, ARM3_BUFFER_CENTI_BPS);
    }

    function _classifyContext(uint256 mis, uint256 volRel, uint256 sizeRel) internal pure returns (uint256) {
        if (
            mis <= bpsToWad(CALM_MIS_BPS)
                && volRel <= bpsToWad(CALM_VOL_BPS)
                && sizeRel <= bpsToWad(CALM_SIZE_BPS)
        ) {
            return 0;
        }

        if (
            mis >= bpsToWad(STRESS_MIS_BPS)
                || volRel >= bpsToWad(STRESS_VOL_BPS)
                || sizeRel >= bpsToWad(STRESS_SIZE_BPS)
        ) {
            return 2;
        }

        return 1;
    }

    function _updateBandit(
        uint256 ctx,
        uint256 arm,
        uint256 fairRef,
        uint256 spotRef,
        TradeInfo calldata trade
    ) internal {
        if (ctx >= N_CTX || arm >= N_ARMS || fairRef == 0 || trade.amountY == 0) {
            return;
        }

        uint256 alphaIdx = _statIndex(ALPHA_BASE, ctx, arm);
        uint256 betaIdx = _statIndex(BETA_BASE, ctx, arm);

        uint256 a = slots[alphaIdx];
        uint256 b = slots[betaIdx];

        uint256 fairNotionalY = wmul(trade.amountX, fairRef);
        bool positiveEdge;
        uint256 edgeMag;

        if (trade.isBuy) {
            if (fairNotionalY >= trade.amountY) {
                positiveEdge = true;
                edgeMag = fairNotionalY - trade.amountY;
            } else {
                edgeMag = trade.amountY - fairNotionalY;
            }
        } else {
            if (trade.amountY >= fairNotionalY) {
                positiveEdge = true;
                edgeMag = trade.amountY - fairNotionalY;
            } else {
                edgeMag = fairNotionalY - trade.amountY;
            }
        }

        uint256 posThresh = wmul(trade.amountY, bpsToWad(POS_EDGE_BPS));
        uint256 negThresh = wmul(trade.amountY, bpsToWad(NEG_EDGE_BPS));

        uint256 mis = wdiv(absDiff(spotRef, fairRef), fairRef);
        uint256 weight = mis <= bpsToWad(QUALITY_MIS_BPS) ? 2 : 1;

        if (positiveEdge && edgeMag >= posThresh) {
            a += weight;
        } else if (!positiveEdge && edgeMag >= negThresh) {
            b += weight;
        } else {
            a += 1;
            b += 1;
        }

        uint256 total = a + b;
        if (total > BANDIT_COUNT_CAP) {
            a = (a * BANDIT_DECAY_PCT) / 100;
            b = (b * BANDIT_DECAY_PCT) / 100;
            if (a == 0) a = 1;
            if (b == 0) b = 1;
        }

        slots[alphaIdx] = a;
        slots[betaIdx] = b;
    }

    function _selectArm(uint256 ctx, uint256 prevCtx, uint256 prevArm) internal view returns (uint256 bestArm) {
        uint256 bestScore = 0;
        bestArm = 1;

        for (uint256 arm = 0; arm < N_ARMS; arm++) {
            uint256 a = slots[_statIndex(ALPHA_BASE, ctx, arm)];
            uint256 b = slots[_statIndex(BETA_BASE, ctx, arm)];
            uint256 n = a + b;
            if (n == 0) n = 1;

            uint256 meanMilli = (a * 1_000_000) / n;
            // Cheaper than sqrt-based UCB and avoids runtime gas blowups.
            uint256 bonusMilli = EXPLORE_MILLI / (n + 2);

            uint256 score = meanMilli + bonusMilli + _armBias(ctx, arm);
            if (ctx == prevCtx && arm == prevArm) {
                score += STICKY_BONUS_MILLI;
            }

            if (score > bestScore) {
                bestScore = score;
                bestArm = arm;
            }
        }
    }

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);

        slots[0] = type(uint256).max;
        slots[3] = p0;
        slots[4] = 1; // start from balanced arm
        slots[5] = 1; // normal context
        slots[6] = 0;
        slots[7] = p0;

        for (uint256 ctx = 0; ctx < N_CTX; ctx++) {
            for (uint256 arm = 0; arm < N_ARMS; arm++) {
                slots[_statIndex(ALPHA_BASE, ctx, arm)] = _priorAlpha(ctx, arm);
                slots[_statIndex(BETA_BASE, ctx, arm)] = _priorBeta(ctx, arm);
            }
        }

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
        uint256 lastSpot = slots[7];

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        if (spot != 0 && fairForReward != 0 && prevCtx < N_CTX && prevArm < N_ARMS) {
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
            slots[4] = 1;
            slots[5] = 1;
            if (spot != 0) slots[7] = spot;
            return (bidFee, askFee);
        }

        uint256 mis = wdiv(absDiff(spot, fair), fair);

        uint256 ewmaMis = slots[6];
        if (ewmaMis == 0) ewmaMis = mis;
        else ewmaMis = (ewmaMis * 80 + mis * 20) / 100;
        slots[6] = ewmaMis;

        uint256 volRel = 0;
        if (lastSpot != 0) {
            volRel = wdiv(absDiff(spot, lastSpot), lastSpot);
        }

        uint256 sizeRel = 0;
        if (trade.reserveY != 0) {
            sizeRel = wdiv(trade.amountY, trade.reserveY);
        }

        uint256 ctx = _classifyContext(ewmaMis, volRel, sizeRel);
        uint256 arm = _selectArm(ctx, prevCtx, prevArm);

        (uint256 tightBandBps, uint256 tightFeeCenti, uint256 undercutCenti, uint256 bufferCenti) = _armParams(arm);

        if (ctx == 0) {
            undercutCenti += CALM_UNDERCUT_ADD_CENTI_BPS;
            if (bufferCenti > CALM_BUFFER_CUT_CENTI_BPS) {
                bufferCenti -= CALM_BUFFER_CUT_CENTI_BPS;
            } else {
                bufferCenti = 0;
            }
        } else if (ctx == 2) {
            if (undercutCenti > STRESS_UNDERCUT_CUT_CENTI_BPS) {
                undercutCenti -= STRESS_UNDERCUT_CUT_CENTI_BPS;
            } else {
                undercutCenti = 0;
            }
            bufferCenti += STRESS_BUFFER_ADD_CENTI_BPS;
            if (tightBandBps > STRESS_BAND_CUT_BPS) {
                tightBandBps -= STRESS_BAND_CUT_BPS;
            } else {
                tightBandBps = 1;
            }
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
        slots[7] = spot;
    }

    function getName() external pure override returns (string memory) {
        return "cbandit_v9";
    }
}
