pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"pivot","hypothesis_id":"H_WILDCARD_030","confidence":0.74,"ceiling_probability":0.27,"ev_next_5":0.13,"best_delta_seen":0.15,"reason":"Pivot to multi-horizon toxicity and flow-trend fusion with adaptive tail shaping to improve robustness under mixed informed flow.","next_mechanism":"multi_horizon_toxicity_flow_fusion"}

    uint256 constant ELAPSED_CAP = 12;
    uint256 constant SIGNAL_THRESHOLD = WAD / 900;

    uint256 constant DIR_FAST_DECAY = 840000000000000000;
    uint256 constant DIR_SLOW_DECAY = 950000000000000000;
    uint256 constant ACT_DECAY = 760000000000000000;
    uint256 constant SIZE_DECAY = 700000000000000000;
    uint256 constant VOL_FAST_DECAY = 820000000000000000;
    uint256 constant VOL_SLOW_DECAY = 950000000000000000;
    uint256 constant TOX_FAST_DECAY = 840000000000000000;
    uint256 constant TOX_SLOW_DECAY = 950000000000000000;
    uint256 constant SHOCK_DECAY = 900000000000000000;
    uint256 constant LAMBDA_DECAY = 993000000000000000;
    uint256 constant BURST_DECAY = 880000000000000000;

    uint256 constant VOL_FAST_BLEND_DECAY = 650000000000000000;
    uint256 constant VOL_SLOW_BLEND_DECAY = 930000000000000000;
    uint256 constant TOX_FAST_BLEND_DECAY = 420000000000000000;
    uint256 constant TOX_SLOW_BLEND_DECAY = 940000000000000000;
    uint256 constant SIZE_BLEND_DECAY = 820000000000000000;
    uint256 constant ACT_BLEND_DECAY = 988000000000000000;
    uint256 constant SHOCK_BLEND_DECAY = 860000000000000000;

    uint256 constant DIR_SLOW_PUSH_MULT = 350000000000000000;
    uint256 constant TREND_PUSH_MULT = 700000000000000000;

    uint256 constant ALPHA_BASE = 70000000000000000;
    uint256 constant ALPHA_VOL_COEF = 550000000000000000;
    uint256 constant ALPHA_SIZE_COEF = 150000000000000000;
    uint256 constant ALPHA_CAP = 220000000000000000;
    uint256 constant ALPHA_TOX_DAMP = 1200000000000000000;
    uint256 constant ALPHA_SHOCK_DAMP = 1800000000000000000;

    uint256 constant RET_CAP = WAD / 6;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant TRADE_RATIO_CAP = WAD / 4;
    uint256 constant LAMBDA_CAP = 6 * WAD;
    uint256 constant STEP_COUNT_CAP = 64;
    uint256 constant BURST_NORM = 12;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant VOL_COEF = 220000000000000000;
    uint256 constant TOX_COEF = 220 * BPS;
    uint256 constant TOX_ACCEL_COEF = 17000 * BPS;
    uint256 constant ACT_COEF = 1600 * BPS;
    uint256 constant ACT_EMA_COEF = 26000 * BPS;
    uint256 constant BURST_COEF = 35 * BPS;
    uint256 constant SHOCK_COEF = 220 * BPS;

    uint256 constant VOL_FAST_WEIGHT = 600000000000000000;
    uint256 constant VOL_SLOW_WEIGHT = 400000000000000000;
    uint256 constant TOX_FAST_WEIGHT = 700000000000000000;
    uint256 constant TOX_SLOW_WEIGHT = 300000000000000000;
    uint256 constant FLOW_FAST_WEIGHT = 750000000000000000;
    uint256 constant FLOW_SLOW_WEIGHT = 250000000000000000;

    uint256 constant DIR_COEF = 75 * BPS;
    uint256 constant DIR_TOX_COEF = 45 * BPS;
    uint256 constant DISAGREE_DAMP = 620000000000000000;
    uint256 constant STALE_COEF = 4200 * BPS;
    uint256 constant STALE_GATE = 3 * BPS;

    uint256 constant TAIL_KNEE_1 = 650 * BPS;
    uint256 constant TAIL_KNEE_2 = 900 * BPS;
    uint256 constant TAIL_SLOPE_PROTECT = 800000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 930000000000000000;
    uint256 constant TAIL_SLOPE_SECOND = 450000000000000000;
    uint256 constant TAIL_SHOCK_SLOPE = 250000000000000000;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;

        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = p0;
        slots[4] = 12 * BPS;
        slots[5] = 10 * BPS;
        slots[6] = 0;
        slots[7] = 0;
        slots[8] = WAD;
        slots[9] = WAD;
        slots[10] = 18 * BPS;
        slots[11] = 900000000000000000;
        slots[12] = 0;
        slots[13] = 0;
        slots[14] = p0;
        slots[15] = 0;
        slots[16] = 0;

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 prevBidFee = slots[0];
        uint256 prevAskFee = slots[1];
        uint256 lastTs = slots[2];
        uint256 pRef = slots[3];
        uint256 volFast = slots[4];
        uint256 volSlow = slots[5];
        uint256 toxFast = slots[6];
        uint256 toxSlow = slots[7];
        uint256 dirFast = slots[8];
        uint256 dirSlow = slots[9];
        uint256 sizeEma = slots[10];
        uint256 lambdaHat = slots[11];
        uint256 burstEma = slots[12];
        uint256 shockEma = slots[13];
        uint256 lastSpot = slots[14];
        uint256 stepTradeCount = slots[15];
        uint256 actEma = slots[16];

        bool isNewStep = trade.timestamp > lastTs;
        if (isNewStep) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            dirFast = _decayCentered(dirFast, DIR_FAST_DECAY, elapsed);
            dirSlow = _decayCentered(dirSlow, DIR_SLOW_DECAY, elapsed);
            actEma = wmul(actEma, _powWad(ACT_DECAY, elapsed));
            sizeEma = wmul(sizeEma, _powWad(SIZE_DECAY, elapsed));
            volFast = wmul(volFast, _powWad(VOL_FAST_DECAY, elapsed));
            volSlow = wmul(volSlow, _powWad(VOL_SLOW_DECAY, elapsed));
            toxFast = wmul(toxFast, _powWad(TOX_FAST_DECAY, elapsed));
            toxSlow = wmul(toxSlow, _powWad(TOX_SLOW_DECAY, elapsed));
            shockEma = wmul(shockEma, _powWad(SHOCK_DECAY, elapsed));

            if (stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                lambdaHat = wmul(lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);

                uint256 burstInst = (stepTradeCount * WAD) / BURST_NORM;
                if (burstInst > WAD) burstInst = WAD;
                burstEma = wmul(burstEma, BURST_DECAY) + wmul(burstInst, WAD - BURST_DECAY);
            }

            stepTradeCount = 0;
        }

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pRef;
        if (pRef == 0) pRef = spot;

        uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pTrade = gamma == 0 ? spot : (trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma));

        uint256 ret = pRef > 0 ? wdiv(absDiff(pTrade, pRef), pRef) : 0;
        if (ret > RET_CAP) ret = RET_CAP;

        volFast = wmul(volFast, VOL_FAST_BLEND_DECAY) + wmul(ret, WAD - VOL_FAST_BLEND_DECAY);
        volSlow = wmul(volSlow, VOL_SLOW_BLEND_DECAY) + wmul(ret, WAD - VOL_SLOW_BLEND_DECAY);

        uint256 tox = pRef > 0 ? wdiv(absDiff(spot, pRef), pRef) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;
        toxFast = wmul(toxFast, TOX_FAST_BLEND_DECAY) + wmul(tox, WAD - TOX_FAST_BLEND_DECAY);
        toxSlow = wmul(toxSlow, TOX_SLOW_BLEND_DECAY) + wmul(tox, WAD - TOX_SLOW_BLEND_DECAY);

        uint256 toxAccel = toxFast > toxSlow ? toxFast - toxSlow : 0;
        uint256 volAccel = volFast > volSlow ? volFast - volSlow : 0;
        uint256 shockInput = toxAccel + volAccel;
        if (shockInput > TOX_CAP) shockInput = TOX_CAP;
        shockEma = wmul(shockEma, SHOCK_BLEND_DECAY) + wmul(shockInput, WAD - SHOCK_BLEND_DECAY);

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 pushFast = tradeRatio;
            if (pushFast > WAD / 3) pushFast = WAD / 3;
            uint256 pushSlow = wmul(pushFast, DIR_SLOW_PUSH_MULT);

            if (trade.isBuy) {
                dirFast = dirFast + pushFast;
                if (dirFast > 2 * WAD) dirFast = 2 * WAD;

                dirSlow = dirSlow + pushSlow;
                if (dirSlow > 2 * WAD) dirSlow = 2 * WAD;
            } else {
                dirFast = dirFast > pushFast ? dirFast - pushFast : 0;
                dirSlow = dirSlow > pushSlow ? dirSlow - pushSlow : 0;
            }

            actEma = wmul(actEma, ACT_BLEND_DECAY) + wmul(tradeRatio, WAD - ACT_BLEND_DECAY);
            sizeEma = wmul(sizeEma, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
            if (sizeEma > WAD) sizeEma = WAD;
        }

        if (lastSpot > 0) {
            uint256 stepMove = wdiv(absDiff(spot, lastSpot), lastSpot);
            if (stepMove > RET_CAP) stepMove = RET_CAP;

            uint256 trendPush = wmul(stepMove, TREND_PUSH_MULT);
            if (trendPush > WAD / 5) trendPush = WAD / 5;

            if (spot >= lastSpot) {
                dirSlow = dirSlow + trendPush;
                if (dirSlow > 2 * WAD) dirSlow = 2 * WAD;
            } else {
                dirSlow = dirSlow > trendPush ? dirSlow - trendPush : 0;
            }
        }
        lastSpot = spot;

        uint256 alpha = ALPHA_BASE + wmul(ALPHA_VOL_COEF, volSlow) + wmul(ALPHA_SIZE_COEF, sizeEma);
        if (alpha > ALPHA_CAP) alpha = ALPHA_CAP;

        uint256 damp = wmul(ALPHA_TOX_DAMP, toxFast) + wmul(ALPHA_SHOCK_DAMP, shockEma);
        uint256 maxDamp = (9 * WAD) / 10;
        if (damp > maxDamp) damp = maxDamp;
        alpha = wmul(alpha, WAD - damp);

        pRef = wmul(pRef, WAD - alpha) + wmul(pTrade, alpha);

        uint256 flowFast = dirFast >= WAD ? dirFast - WAD : WAD - dirFast;
        uint256 flowSlow = dirSlow >= WAD ? dirSlow - WAD : WAD - dirSlow;
        uint256 flowImb = wmul(FLOW_FAST_WEIGHT, flowFast) + wmul(FLOW_SLOW_WEIGHT, flowSlow);

        uint256 volMix = wmul(VOL_FAST_WEIGHT, volFast) + wmul(VOL_SLOW_WEIGHT, volSlow);
        uint256 toxMix = wmul(TOX_FAST_WEIGHT, toxFast) + wmul(TOX_SLOW_WEIGHT, toxSlow);

        uint256 activity = wmul(lambdaHat, sizeEma);
        if (activity > WAD) activity = WAD;

        uint256 fMid = BASE_FEE
            + wmul(VOL_COEF, volMix)
            + wmul(TOX_COEF, toxMix)
            + wmul(TOX_ACCEL_COEF, wmul(toxAccel, toxAccel))
            + wmul(ACT_COEF, activity)
            + wmul(ACT_EMA_COEF, actEma)
            + wmul(BURST_COEF, burstEma)
            + wmul(SHOCK_COEF, shockEma);

        uint256 skew = wmul(DIR_COEF, flowImb) + wmul(DIR_TOX_COEF, wmul(flowImb, toxMix));
        if ((dirFast >= WAD) != (dirSlow >= WAD)) {
            skew = wmul(skew, DISAGREE_DAMP);
        }

        uint256 bidFee;
        uint256 askFee;
        if (dirFast >= WAD) {
            bidFee = fMid + skew;
            askFee = fMid > skew ? fMid - skew : 0;
        } else {
            askFee = fMid + skew;
            bidFee = fMid > skew ? fMid - skew : 0;
        }

        if (toxFast > STALE_GATE) {
            uint256 staleShift = wmul(STALE_COEF, toxFast - STALE_GATE);
            if (spot >= pRef) {
                bidFee = bidFee + staleShift;
                askFee = askFee > staleShift ? askFee - staleShift : 0;
            } else {
                askFee = askFee + staleShift;
                bidFee = bidFee > staleShift ? bidFee - staleShift : 0;
            }
        }

        uint256 shockAdjust = wmul(TAIL_SHOCK_SLOPE, shockEma);
        uint256 slopeProtect = shockAdjust < TAIL_SLOPE_PROTECT ? TAIL_SLOPE_PROTECT - shockAdjust : WAD / 2;
        uint256 halfAdjust = wmul(shockAdjust, 500000000000000000);
        uint256 slopeAttract = halfAdjust < TAIL_SLOPE_ATTRACT ? TAIL_SLOPE_ATTRACT - halfAdjust : 600000000000000000;

        if (bidFee > askFee) {
            bidFee = clampFee(_compressTail(bidFee, slopeProtect));
            askFee = clampFee(_compressTail(askFee, slopeAttract));
        } else if (askFee > bidFee) {
            bidFee = clampFee(_compressTail(bidFee, slopeAttract));
            askFee = clampFee(_compressTail(askFee, slopeProtect));
        } else {
            uint256 midSlope = (slopeProtect + slopeAttract) / 2;
            bidFee = clampFee(_compressTail(bidFee, midSlope));
            askFee = clampFee(_compressTail(askFee, midSlope));
        }

        stepTradeCount = stepTradeCount + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = pRef;
        slots[4] = volFast;
        slots[5] = volSlow;
        slots[6] = toxFast;
        slots[7] = toxSlow;
        slots[8] = dirFast;
        slots[9] = dirSlow;
        slots[10] = sizeEma;
        slots[11] = lambdaHat;
        slots[12] = burstEma;
        slots[13] = shockEma;
        slots[14] = lastSpot;
        slots[15] = stepTradeCount;
        slots[16] = actEma;

        return (bidFee, askFee);
    }

    function _compressTail(uint256 fee, uint256 slopePrimary) internal pure returns (uint256) {
        if (fee <= TAIL_KNEE_1) return fee;

        uint256 firstSegmentEnd = fee > TAIL_KNEE_2 ? TAIL_KNEE_2 : fee;
        uint256 shaped = TAIL_KNEE_1 + wmul(firstSegmentEnd - TAIL_KNEE_1, slopePrimary);

        if (fee > TAIL_KNEE_2) {
            shaped = shaped + wmul(fee - TAIL_KNEE_2, TAIL_SLOPE_SECOND);
        }

        return shaped;
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
        return "wildcard_mod_v30";
    }
}
