pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"pivot","hypothesis_id":"H_WILDCARD_120","confidence":0.74,"ceiling_probability":0.23,"ev_next_5":0.22,"best_delta_seen":0.15,"reason":"Replace first-trade inference with continuous dual-anchor risk surface and adaptive asymmetric tails to reduce starvation while preserving adverse-selection defense.","next_mechanism":"continuous_dual_anchor_surface"}

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant STEP_COUNT_CAP = 96;

    uint256 constant SIGNAL_THRESHOLD = WAD / 850;
    uint256 constant TRADE_RATIO_CAP = WAD / 4;
    uint256 constant RET_CAP = WAD / 8;
    uint256 constant TOX_CAP = WAD / 4;
    uint256 constant GAP_CAP = WAD / 4;
    uint256 constant LAMBDA_CAP = 6 * WAD;

    uint256 constant DIR_DECAY = 860000000000000000;
    uint256 constant ACT_DECAY = 740000000000000000;
    uint256 constant SIZE_DECAY = 700000000000000000;
    uint256 constant TOX_DECAY = 900000000000000000;
    uint256 constant VFAST_DECAY = 760000000000000000;
    uint256 constant VSLOW_DECAY = 940000000000000000;
    uint256 constant GAP_DECAY = 900000000000000000;
    uint256 constant LAMBDA_DECAY = 992000000000000000;

    uint256 constant ACT_BLEND_DECAY = 992000000000000000;
    uint256 constant SIZE_BLEND_DECAY = 840000000000000000;
    uint256 constant TOX_BLEND_DECAY = 250000000000000000;
    uint256 constant VFAST_BLEND_DECAY = 680000000000000000;
    uint256 constant VSLOW_BLEND_DECAY = 930000000000000000;
    uint256 constant GAP_BLEND_DECAY = 720000000000000000;

    uint256 constant ALPHA_FAST_BASE = 115000000000000000;
    uint256 constant ALPHA_FAST_SIZE_COEF = 620000000000000000;
    uint256 constant ALPHA_FAST_MAX = 420000000000000000;
    uint256 constant ALPHA_SLOW_BASE = 12000000000000000;
    uint256 constant ALPHA_SLOW_SIZE_COEF = 70000000000000000;
    uint256 constant ALPHA_SLOW_MAX = 85000000000000000;
    uint256 constant ALPHA_DAMP_KNEE = 20000000000000000;
    uint256 constant ALPHA_DAMP_SLOPE = 1200000000000000000;
    uint256 constant ALPHA_DAMP_CAP = 800000000000000000;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant VFAST_COEF = 100000000000000000;
    uint256 constant VSLOW_COEF = 80000000000000000;
    uint256 constant VGAP_COEF = 140000000000000000;
    uint256 constant LAMBDA_COEF = 8 * BPS;
    uint256 constant FLOW_SIZE_COEF = 5200 * BPS;
    uint256 constant TOX_COEF = 210 * BPS;
    uint256 constant TOX_QUAD_COEF = 18500 * BPS;
    uint256 constant TOX_QUAD_KNEE = 11 * BPS;
    uint256 constant ACT_COEF = 30000 * BPS;
    uint256 constant GAP_COEF = 70 * BPS;

    uint256 constant DIR_COEF = 105 * BPS;
    uint256 constant DIR_TOX_COEF = 35 * BPS;
    uint256 constant DIR_GAP_COEF = 26 * BPS;
    uint256 constant STALE_TOX_COEF = 5200 * BPS;
    uint256 constant STALE_GAP_COEF = 80 * BPS;
    uint256 constant TREND_COEF = 55 * BPS;

    uint256 constant TAIL_KNEE_BASE = 620 * BPS;
    uint256 constant TAIL_KNEE_VOL_COEF = 1800 * BPS;
    uint256 constant TAIL_KNEE_TOX_COEF = 1400 * BPS;
    uint256 constant TAIL_KNEE_GAP_COEF = 1000 * BPS;
    uint256 constant TAIL_KNEE_MAX = WAD / 8;

    uint256 constant TAIL_SLOPE_PROTECT_BASE = 790000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT_BASE = 950000000000000000;
    uint256 constant TAIL_SLOPE_TOX_ADJ = 220000000000000000;
    uint256 constant TAIL_SLOPE_VOL_ADJ = 80000000000000000;
    uint256 constant TAIL_SLOPE_GAP_ADJ = 70000000000000000;

    uint256 constant SIDE_FLOOR = 1 * BPS;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;

        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD;
        slots[4] = 0;
        slots[5] = p0;
        slots[6] = p0;
        slots[7] = 1000000000000000;
        slots[8] = 800000000000000;
        slots[9] = 900000000000000000;
        slots[10] = 1600000000000000;
        slots[11] = 0;
        slots[12] = 0;
        slots[13] = 0;

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 bidFee = slots[0];
        uint256 askFee = slots[1];
        uint256 lastTs = slots[2];
        uint256 dirState = slots[3];
        uint256 actEma = slots[4];
        uint256 pFast = slots[5];
        uint256 pSlow = slots[6];
        uint256 volFast = slots[7];
        uint256 volSlow = slots[8];
        uint256 lambdaHat = slots[9];
        uint256 sizeHat = slots[10];
        uint256 toxEma = slots[11];
        uint256 gapEma = slots[12];
        uint256 stepTradeCount = slots[13];

        if (trade.timestamp > lastTs) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            dirState = _decayCentered(dirState, DIR_DECAY, elapsed);
            actEma = wmul(actEma, _powWad(ACT_DECAY, elapsed));
            sizeHat = wmul(sizeHat, _powWad(SIZE_DECAY, elapsed));
            toxEma = wmul(toxEma, _powWad(TOX_DECAY, elapsed));
            volFast = wmul(volFast, _powWad(VFAST_DECAY, elapsed));
            volSlow = wmul(volSlow, _powWad(VSLOW_DECAY, elapsed));
            gapEma = wmul(gapEma, _powWad(GAP_DECAY, elapsed));

            if (stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                lambdaHat = wmul(lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
            }
            stepTradeCount = 0;
        }

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pSlow;
        if (pSlow == 0) pSlow = spot;
        if (pFast == 0) pFast = spot;
        if (spot == 0) spot = pSlow;

        uint256 feeUsed = trade.isBuy ? bidFee : askFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied = gamma == 0 ? spot : (trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma));

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        actEma = wmul(actEma, ACT_BLEND_DECAY) + wmul(tradeRatio, WAD - ACT_BLEND_DECAY);
        sizeHat = wmul(sizeHat, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
        if (sizeHat > WAD) sizeHat = WAD;

        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = tradeRatio;
            if (push > WAD / 4) push = WAD / 4;

            if (trade.isBuy) {
                dirState = dirState + push;
                if (dirState > 2 * WAD) dirState = 2 * WAD;
            } else {
                dirState = dirState > push ? dirState - push : 0;
            }
        }

        uint256 alphaFast = ALPHA_FAST_BASE + wmul(ALPHA_FAST_SIZE_COEF, tradeRatio);
        if (alphaFast > ALPHA_FAST_MAX) alphaFast = ALPHA_FAST_MAX;

        uint256 alphaSlow = ALPHA_SLOW_BASE + wmul(ALPHA_SLOW_SIZE_COEF, tradeRatio);
        if (alphaSlow > ALPHA_SLOW_MAX) alphaSlow = ALPHA_SLOW_MAX;

        uint256 dampSignal = toxEma + gapEma;
        if (dampSignal > ALPHA_DAMP_KNEE) {
            uint256 damp = wmul(ALPHA_DAMP_SLOPE, dampSignal - ALPHA_DAMP_KNEE);
            if (damp > ALPHA_DAMP_CAP) damp = ALPHA_DAMP_CAP;
            alphaFast = wmul(alphaFast, WAD - damp);
            alphaSlow = wmul(alphaSlow, WAD - wmul(damp, 700000000000000000));
        }

        pFast = wmul(pFast, WAD - alphaFast) + wmul(pImplied, alphaFast);
        pSlow = wmul(pSlow, WAD - alphaSlow) + wmul(pImplied, alphaSlow);

        uint256 retFast = pFast > 0 ? wdiv(absDiff(pImplied, pFast), pFast) : 0;
        uint256 retSlow = pSlow > 0 ? wdiv(absDiff(pImplied, pSlow), pSlow) : 0;
        if (retFast > RET_CAP) retFast = RET_CAP;
        if (retSlow > RET_CAP) retSlow = RET_CAP;

        volFast = wmul(volFast, VFAST_BLEND_DECAY) + wmul(retFast, WAD - VFAST_BLEND_DECAY);
        volSlow = wmul(volSlow, VSLOW_BLEND_DECAY) + wmul(retSlow, WAD - VSLOW_BLEND_DECAY);

        uint256 tox = pSlow > 0 ? wdiv(absDiff(spot, pSlow), pSlow) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;
        toxEma = wmul(toxEma, TOX_BLEND_DECAY) + wmul(tox, WAD - TOX_BLEND_DECAY);

        uint256 gapInst = pSlow > 0 ? wdiv(absDiff(pFast, pSlow), pSlow) : 0;
        if (gapInst > GAP_CAP) gapInst = GAP_CAP;
        gapEma = wmul(gapEma, GAP_BLEND_DECAY) + wmul(gapInst, WAD - GAP_BLEND_DECAY);

        uint256 flowSize = wmul(lambdaHat, sizeHat);
        if (flowSize > WAD) flowSize = WAD;

        uint256 volGap = volFast > volSlow ? volFast - volSlow : 0;
        uint256 toxExcess = toxEma > TOX_QUAD_KNEE ? toxEma - TOX_QUAD_KNEE : 0;

        uint256 fMid = BASE_FEE
            + wmul(VFAST_COEF, volFast)
            + wmul(VSLOW_COEF, volSlow)
            + wmul(VGAP_COEF, volGap)
            + wmul(LAMBDA_COEF, lambdaHat)
            + wmul(FLOW_SIZE_COEF, flowSize)
            + wmul(TOX_COEF, toxEma)
            + wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess))
            + wmul(ACT_COEF, actEma)
            + wmul(GAP_COEF, gapEma);

        uint256 dirDev;
        bool sellPressure;
        if (dirState >= WAD) {
            dirDev = dirState - WAD;
            sellPressure = true;
        } else {
            dirDev = WAD - dirState;
            sellPressure = false;
        }

        uint256 skew = wmul(DIR_COEF, dirDev)
            + wmul(DIR_TOX_COEF, wmul(dirDev, toxEma))
            + wmul(DIR_GAP_COEF, wmul(dirDev, gapEma));

        if (sellPressure) {
            bidFee = fMid + skew;
            askFee = fMid > skew ? fMid - skew : 0;
        } else {
            askFee = fMid + skew;
            bidFee = fMid > skew ? fMid - skew : 0;
        }

        uint256 staleShift = wmul(STALE_TOX_COEF, toxEma) + wmul(STALE_GAP_COEF, gapEma);
        if (spot >= pSlow) {
            bidFee = bidFee + staleShift;
            askFee = askFee > staleShift ? askFee - staleShift : 0;
        } else {
            askFee = askFee + staleShift;
            bidFee = bidFee > staleShift ? bidFee - staleShift : 0;
        }

        uint256 trendShift = wmul(TREND_COEF, gapEma);
        if (pFast >= pSlow) {
            bidFee = bidFee + trendShift;
            askFee = askFee > trendShift ? askFee - trendShift : 0;
        } else {
            askFee = askFee + trendShift;
            bidFee = bidFee > trendShift ? bidFee - trendShift : 0;
        }

        if (bidFee < SIDE_FLOOR) bidFee = SIDE_FLOOR;
        if (askFee < SIDE_FLOOR) askFee = SIDE_FLOOR;

        uint256 tailKnee = TAIL_KNEE_BASE
            + wmul(TAIL_KNEE_VOL_COEF, volSlow)
            + wmul(TAIL_KNEE_TOX_COEF, toxEma)
            + wmul(TAIL_KNEE_GAP_COEF, gapEma);
        if (tailKnee > TAIL_KNEE_MAX) tailKnee = TAIL_KNEE_MAX;

        uint256 slopeCut = wmul(TAIL_SLOPE_TOX_ADJ, toxEma)
            + wmul(TAIL_SLOPE_VOL_ADJ, volFast)
            + wmul(TAIL_SLOPE_GAP_ADJ, gapEma);

        uint256 protectSlope = TAIL_SLOPE_PROTECT_BASE > slopeCut ? TAIL_SLOPE_PROTECT_BASE - slopeCut : WAD / 2;
        if (protectSlope < WAD / 2) protectSlope = WAD / 2;

        uint256 attractSlope = TAIL_SLOPE_ATTRACT_BASE + (slopeCut / 2);
        if (attractSlope > WAD) attractSlope = WAD;

        if (bidFee > askFee) {
            bidFee = clampFee(_compressTail(bidFee, tailKnee, protectSlope));
            askFee = clampFee(_compressTail(askFee, tailKnee, attractSlope));
        } else if (askFee > bidFee) {
            bidFee = clampFee(_compressTail(bidFee, tailKnee, attractSlope));
            askFee = clampFee(_compressTail(askFee, tailKnee, protectSlope));
        } else {
            uint256 midSlope = (protectSlope + attractSlope) / 2;
            bidFee = clampFee(_compressTail(bidFee, tailKnee, midSlope));
            askFee = clampFee(_compressTail(askFee, tailKnee, midSlope));
        }

        stepTradeCount = stepTradeCount + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = dirState;
        slots[4] = actEma;
        slots[5] = pFast;
        slots[6] = pSlow;
        slots[7] = volFast;
        slots[8] = volSlow;
        slots[9] = lambdaHat;
        slots[10] = sizeHat;
        slots[11] = toxEma;
        slots[12] = gapEma;
        slots[13] = stepTradeCount;

        return (bidFee, askFee);
    }

    function _compressTail(uint256 fee, uint256 knee, uint256 slope) internal pure returns (uint256) {
        if (fee <= knee) return fee;
        return knee + wmul(fee - knee, slope);
    }

    function _powWad(uint256 factor, uint256 exp) internal pure returns (uint256 result) {
        result = WAD;
        while (exp > 0) {
            if ((exp & 1) == 1) result = wmul(result, factor);
            factor = wmul(factor, factor);
            exp >>= 1;
        }
    }

    function _decayCentered(uint256 centered, uint256 decayFactor, uint256 elapsed) internal pure returns (uint256) {
        uint256 mul = _powWad(decayFactor, elapsed);
        if (centered >= WAD) {
            return WAD + wmul(centered - WAD, mul);
        }
        uint256 below = wmul(WAD - centered, mul);
        return below < WAD ? WAD - below : 0;
    }

    function getName() external pure override returns (string memory) {
        return "wildcard_mod_v120";
    }
}
