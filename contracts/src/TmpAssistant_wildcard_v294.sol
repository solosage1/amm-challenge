pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_TOX_ACT_002","confidence":0.61,"ceiling_probability":0.29,"ev_next_5":0.033,"best_delta_seen":2.3074,"reason":"promotion_edge 519.30 baseline; T10 wildcard path-dependent pressure with bounded fees, coherent spread behavior, and no pathological liquidity collapse","next_mechanism":"wildcard"}

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant STEP_COUNT_CAP = 64;

    uint256 constant TRADE_RATIO_CAP = WAD / 5;
    uint256 constant SIGNAL_THRESHOLD = WAD / 700;
    uint256 constant ARB_MAX_RATIO = WAD / 360;
    uint256 constant RET_CAP = WAD / 8;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant LAMBDA_CAP = 4 * WAD;

    uint256 constant CORE_DECAY = 860000000000000000;
    uint256 constant SIGMA_DECAY = 780000000000000000;
    uint256 constant FLOW_STEP_BLEND = 950000000000000000;
    uint256 constant FLOW_BLEND = 990000000000000000;
    uint256 constant TOX_BLEND_FIRST = 300000000000000000;
    uint256 constant TOX_BLEND_FLOW = 880000000000000000;

    uint256 constant PFAST_ALPHA_FIRST = 230000000000000000;
    uint256 constant PFAST_ALPHA_FLOW = 70000000000000000;
    uint256 constant PFAST_ARB_MULT = 1200000000000000000;
    uint256 constant PFAST_SHOCK_DAMP = 650000000000000000;
    uint256 constant PSLOW_ALPHA_FIRST = 70000000000000000;
    uint256 constant PSLOW_ALPHA_FLOW = 30000000000000000;
    uint256 constant SHOCK_GATE = 30000000000000000;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant SIGMA_COEF = 175000000000000000;
    uint256 constant FLOW_COEF = 5200 * BPS;
    uint256 constant TOX_COEF = 165 * BPS;
    uint256 constant TOX_QUAD_COEF = 15000 * BPS;
    uint256 constant TOX_KNEE = 10 * BPS;
    uint256 constant TOX_QUAD_CAP = 140 * BPS;
    uint256 constant SIGMA_RISK_COEF = 70 * BPS;
    uint256 constant FLOW_RISK_COEF = 95 * BPS;
    uint256 constant FIRST_REVEAL_COEF = 70 * BPS;

    uint256 constant TOX_DEADBAND = 6 * BPS;
    uint256 constant SIGMA_DEADBAND = 4 * BPS;
    uint256 constant FLOW_DEADBAND = 900000000000000;
    uint256 constant AGREE_TOX_SPAN = 35 * BPS;
    uint256 constant AGREE_SIGMA_SPAN = 25 * BPS;
    uint256 constant AGREE_FLOW_SPAN = 4000000000000000;
    uint256 constant AGREE_MULT = 850000000000000000;

    uint256 constant RISK_CAP = 300 * BPS;
    uint256 constant RISK_UP_BASE = 70 * BPS;
    uint256 constant RISK_UP_LOWCONF = 120 * BPS;
    uint256 constant RISK_DOWN_BASE = 90 * BPS;
    uint256 constant RISK_DOWN_CONF = 130 * BPS;

    uint256 constant CONF_MIN = 550000000000000000;
    uint256 constant CONF_NEUTRAL = 780000000000000000;
    uint256 constant CONF_SIGMA_SPAN = 45 * BPS;
    uint256 constant CONF_TOX_SPAN = 75 * BPS;
    uint256 constant CONF_GAP_SPAN = 30 * BPS;
    uint256 constant CONF_FLOW_SPAN = 6000000000000000;
    uint256 constant CONF_W_SIGMA = 330000000000000000;
    uint256 constant CONF_W_TOX = 270000000000000000;
    uint256 constant CONF_W_GAP = 220000000000000000;
    uint256 constant CONF_W_FLOW = 80000000000000000;
    uint256 constant CONF_GUARD_COEF = 95 * BPS;
    uint256 constant CONF_TIGHTEN_COEF = 65 * BPS;

    uint256 constant REF_FAST_WEIGHT = 700000000000000000;
    uint256 constant GAP_CAP = 60 * BPS;

    uint256 constant DIR_COEF = 86 * BPS;
    uint256 constant DIR_TOX_COEF = 20 * BPS;
    uint256 constant SKEW_CAP = 250 * BPS;

    uint256 constant SPREAD_BASE = 6 * BPS;
    uint256 constant SPREAD_SIGMA_COEF = 90 * BPS;
    uint256 constant SPREAD_TOX_COEF = 80 * BPS;
    uint256 constant SPREAD_RISK_COEF = 60 * BPS;
    uint256 constant SPREAD_CONF_RELIEF = 55 * BPS;
    uint256 constant SPREAD_MIN = 2 * BPS;
    uint256 constant SPREAD_MAX = 180 * BPS;

    uint256 constant ADVERSE_SPLIT_BASE = 420000000000000000;
    uint256 constant ADVERSE_SPLIT_LOWCONF = 450000000000000000;
    uint256 constant ATTRACT_SHARE_MIN = 120000000000000000;
    uint256 constant ATTRACT_SHARE_CONF = 260000000000000000;

    uint256 constant STALE_COEF = 5200 * BPS;
    uint256 constant STALE_LOWCONF_MULT = 450000000000000000;
    uint256 constant STALE_CAP = 220 * BPS;

    uint256 constant MAX_SIDE_DIFF = 240 * BPS;
    uint256 constant LIQ_CEIL_BASE = 200 * BPS;
    uint256 constant LIQ_CEIL_STRESS = 500 * BPS;

    uint256 constant TAIL_KNEE = 700 * BPS;
    uint256 constant TAIL_SLOPE_NEUTRAL = 900000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 820000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 950000000000000000;

    uint256 constant MIN_SIDE_FEE = BPS;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;

        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = p0;
        slots[4] = p0;
        slots[5] = 900000000000000;
        slots[6] = 0;
        slots[7] = 1800000000000000;
        slots[8] = WAD;
        slots[9] = 0;
        slots[10] = 0;

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 prevBidFee = slots[0];
        uint256 prevAskFee = slots[1];
        uint256 lastTs = slots[2];
        uint256 pFast = slots[3];
        uint256 pSlow = slots[4];
        uint256 sigmaHat = slots[5];
        uint256 toxEma = slots[6];
        uint256 flowEma = slots[7];
        uint256 dirState = slots[8];
        uint256 riskState = slots[9];
        uint256 stepTradeCount = slots[10];

        if (dirState == 0) dirState = WAD;

        if (trade.timestamp > lastTs) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;
            uint256 coreMul = _powWad(CORE_DECAY, elapsed);
            uint256 sigmaMul = _powWad(SIGMA_DECAY, elapsed);

            dirState = _decayCentered(dirState, coreMul);
            sigmaHat = wmul(sigmaHat, sigmaMul);
            toxEma = wmul(toxEma, coreMul);
            flowEma = wmul(flowEma, coreMul);
            riskState = wmul(riskState, coreMul);

            if (stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                uint256 burstFlow = lambdaInst / 260;
                flowEma = wmul(flowEma, FLOW_STEP_BLEND) + wmul(burstFlow, WAD - FLOW_STEP_BLEND);
            }

            stepTradeCount = 0;
        }

        bool firstInStep = stepTradeCount == 0;

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pFast;
        if (pFast == 0) pFast = spot;
        if (pSlow == 0) pSlow = pFast;

        uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied = gamma == 0 ? spot : (trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma));

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        uint256 ret = pFast > 0 ? wdiv(absDiff(pImplied, pFast), pFast) : 0;
        if (ret > RET_CAP) ret = RET_CAP;

        bool likelyArb = firstInStep && tradeRatio <= ARB_MAX_RATIO;

        uint256 alphaFast = firstInStep ? PFAST_ALPHA_FIRST : PFAST_ALPHA_FLOW;
        if (likelyArb) alphaFast = wmul(alphaFast, PFAST_ARB_MULT);
        if (ret > SHOCK_GATE) alphaFast = wmul(alphaFast, PFAST_SHOCK_DAMP);

        uint256 alphaSlow = firstInStep ? PSLOW_ALPHA_FIRST : PSLOW_ALPHA_FLOW;

        pFast = wmul(pFast, WAD - alphaFast) + wmul(pImplied, alphaFast);
        pSlow = wmul(pSlow, WAD - alphaSlow) + wmul(pImplied, alphaSlow);

        if (firstInStep) {
            sigmaHat = wmul(sigmaHat, 700000000000000000) + wmul(ret, 300000000000000000);
        } else {
            sigmaHat = wmul(sigmaHat, 960000000000000000) + wmul(ret, 40000000000000000);
        }

        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = tradeRatio;
            if (push > WAD / 4) push = WAD / 4;

            if (trade.isBuy) {
                dirState = dirState + push;
                if (dirState > 2 * WAD) dirState = 2 * WAD;
            } else {
                dirState = dirState > push ? dirState - push : 0;
            }

            flowEma = wmul(flowEma, FLOW_BLEND) + wmul(tradeRatio, WAD - FLOW_BLEND);
        }

        uint256 pRef = wmul(pFast, REF_FAST_WEIGHT) + wmul(pSlow, WAD - REF_FAST_WEIGHT);
        uint256 tox = pRef > 0 ? wdiv(absDiff(spot, pRef), pRef) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;

        uint256 toxBlend = firstInStep ? TOX_BLEND_FIRST : TOX_BLEND_FLOW;
        toxEma = wmul(toxEma, toxBlend) + wmul(tox, WAD - toxBlend);

        uint256 anchorGap = pSlow > 0 ? wdiv(absDiff(pFast, pSlow), pSlow) : 0;
        if (anchorGap > GAP_CAP) anchorGap = GAP_CAP;

        uint256 sigmaNorm = _ratioCapped(sigmaHat, CONF_SIGMA_SPAN);
        uint256 toxNorm = _ratioCapped(toxEma, CONF_TOX_SPAN);
        uint256 gapNorm = _ratioCapped(anchorGap, CONF_GAP_SPAN);
        uint256 flowNorm = _ratioCapped(flowEma, CONF_FLOW_SPAN);

        uint256 confPenalty = wmul(CONF_W_SIGMA, sigmaNorm) + wmul(CONF_W_TOX, toxNorm) + wmul(CONF_W_GAP, gapNorm)
            + wmul(CONF_W_FLOW, flowNorm);
        uint256 maxPenalty = WAD - CONF_MIN;
        if (confPenalty > maxPenalty) confPenalty = maxPenalty;
        uint256 conf = WAD - confPenalty;
        if (conf < CONF_MIN) conf = CONF_MIN;

        uint256 toxScore = toxEma > TOX_DEADBAND ? _ratioCapped(toxEma - TOX_DEADBAND, AGREE_TOX_SPAN) : 0;
        uint256 sigmaScore = sigmaHat > SIGMA_DEADBAND ? _ratioCapped(sigmaHat - SIGMA_DEADBAND, AGREE_SIGMA_SPAN) : 0;
        uint256 flowScore = flowEma > FLOW_DEADBAND ? _ratioCapped(flowEma - FLOW_DEADBAND, AGREE_FLOW_SPAN) : 0;
        uint256 agreement = wmul(toxScore, wmul(sigmaScore, flowScore));

        uint256 toxExcess = toxEma > TOX_KNEE ? toxEma - TOX_KNEE : 0;
        uint256 toxQuad = wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        if (toxQuad > TOX_QUAD_CAP) toxQuad = TOX_QUAD_CAP;

        uint256 riskTarget = wmul(TOX_COEF, toxEma) + toxQuad + wmul(SIGMA_RISK_COEF, sigmaHat) + wmul(FLOW_RISK_COEF, flowEma);
        if (firstInStep) riskTarget = riskTarget + wmul(FIRST_REVEAL_COEF, ret);
        riskTarget = riskTarget + wmul(riskTarget, wmul(AGREE_MULT, agreement));
        if (riskTarget > RISK_CAP) riskTarget = RISK_CAP;

        uint256 lowConf = WAD - conf;
        if (riskTarget > riskState) {
            uint256 upCap = RISK_UP_BASE + wmul(RISK_UP_LOWCONF, lowConf);
            uint256 rise = riskTarget - riskState;
            riskState = rise > upCap ? riskState + upCap : riskTarget;
        } else {
            uint256 downCap = RISK_DOWN_BASE + wmul(RISK_DOWN_CONF, conf);
            uint256 drop = riskState - riskTarget;
            riskState = drop > downCap ? riskState - downCap : riskTarget;
        }

        uint256 mid = BASE_FEE + wmul(SIGMA_COEF, sigmaHat) + wmul(FLOW_COEF, flowEma) + riskState;

        if (conf < CONF_NEUTRAL) {
            mid = mid + wmul(CONF_GUARD_COEF, CONF_NEUTRAL - conf);
        } else {
            uint256 tighten = wmul(CONF_TIGHTEN_COEF, conf - CONF_NEUTRAL);
            mid = mid > tighten + BASE_FEE ? mid - tighten : BASE_FEE;
        }

        uint256 dirDev = dirState >= WAD ? dirState - WAD : WAD - dirState;
        uint256 skew = wmul(DIR_COEF, dirDev) + wmul(DIR_TOX_COEF, wmul(dirDev, toxEma));
        if (skew > SKEW_CAP) skew = SKEW_CAP;

        uint256 spread = SPREAD_BASE + wmul(SPREAD_SIGMA_COEF, sigmaHat) + wmul(SPREAD_TOX_COEF, toxEma)
            + wmul(SPREAD_RISK_COEF, riskState);
        uint256 spreadRelief = wmul(SPREAD_CONF_RELIEF, conf);
        if (spread > spreadRelief + SPREAD_MIN) {
            spread = spread - spreadRelief;
        } else {
            spread = SPREAD_MIN;
        }
        if (spread > SPREAD_MAX) spread = SPREAD_MAX;

        uint256 halfSpread = spread / 2;
        uint256 bidFee;
        uint256 askFee;

        if (dirState >= WAD) {
            bidFee = mid + halfSpread + skew;
            askFee = mid > halfSpread ? mid - halfSpread : 0;
        } else {
            askFee = mid + halfSpread + skew;
            bidFee = mid > halfSpread ? mid - halfSpread : 0;
        }

        uint256 splitMult = ADVERSE_SPLIT_BASE + wmul(ADVERSE_SPLIT_LOWCONF, lowConf);
        if (splitMult > WAD) splitMult = WAD;
        uint256 adverseAdd = wmul(riskState, splitMult);

        uint256 attractShare = ATTRACT_SHARE_MIN + wmul(ATTRACT_SHARE_CONF, conf);
        if (attractShare > WAD) attractShare = WAD;
        uint256 attractShift = wmul(adverseAdd, attractShare);

        if (spot >= pRef) {
            bidFee = bidFee + adverseAdd;
            askFee = askFee > attractShift ? askFee - attractShift : 0;
        } else {
            askFee = askFee + adverseAdd;
            bidFee = bidFee > attractShift ? bidFee - attractShift : 0;
        }

        uint256 staleShift = wmul(STALE_COEF, toxEma);
        staleShift = wmul(staleShift, WAD + wmul(STALE_LOWCONF_MULT, lowConf));
        if (staleShift > STALE_CAP) staleShift = STALE_CAP;

        if (spot >= pRef) {
            bidFee = bidFee + staleShift;
            askFee = askFee > staleShift ? askFee - staleShift : 0;
        } else {
            askFee = askFee + staleShift;
            bidFee = bidFee > staleShift ? bidFee - staleShift : 0;
        }

        if (bidFee > askFee) {
            uint256 diff = bidFee - askFee;
            if (diff > MAX_SIDE_DIFF) bidFee = bidFee - (diff - MAX_SIDE_DIFF);
        } else {
            uint256 diff = askFee - bidFee;
            if (diff > MAX_SIDE_DIFF) askFee = askFee - (diff - MAX_SIDE_DIFF);
        }

        uint256 liqCeil = LIQ_CEIL_BASE + wmul(LIQ_CEIL_STRESS, lowConf);
        if (liqCeil > MAX_FEE) liqCeil = MAX_FEE;

        uint256 minSide = bidFee < askFee ? bidFee : askFee;
        if (minSide > liqCeil) {
            uint256 cut = minSide - liqCeil;
            bidFee = bidFee > cut ? bidFee - cut : 0;
            askFee = askFee > cut ? askFee - cut : 0;
        }

        if (bidFee > askFee) {
            bidFee = _compressTail(bidFee, TAIL_SLOPE_PROTECT);
            askFee = _compressTail(askFee, TAIL_SLOPE_ATTRACT);
        } else if (askFee > bidFee) {
            bidFee = _compressTail(bidFee, TAIL_SLOPE_ATTRACT);
            askFee = _compressTail(askFee, TAIL_SLOPE_PROTECT);
        } else {
            bidFee = _compressTail(bidFee, TAIL_SLOPE_NEUTRAL);
            askFee = _compressTail(askFee, TAIL_SLOPE_NEUTRAL);
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);

        if (bidFee < MIN_SIDE_FEE) bidFee = MIN_SIDE_FEE;
        if (askFee < MIN_SIDE_FEE) askFee = MIN_SIDE_FEE;

        stepTradeCount = stepTradeCount + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = pFast;
        slots[4] = pSlow;
        slots[5] = sigmaHat;
        slots[6] = toxEma;
        slots[7] = flowEma;
        slots[8] = dirState;
        slots[9] = riskState;
        slots[10] = stepTradeCount;

        return (bidFee, askFee);
    }

    function _compressTail(uint256 fee, uint256 slope) internal pure returns (uint256) {
        if (fee <= TAIL_KNEE) return fee;
        return TAIL_KNEE + wmul(fee - TAIL_KNEE, slope);
    }

    function _powWad(uint256 factor, uint256 exp) internal pure returns (uint256 result) {
        result = WAD;
        while (exp > 0) {
            if ((exp & 1) == 1) result = wmul(result, factor);
            factor = wmul(factor, factor);
            exp >>= 1;
        }
    }

    function _decayCentered(uint256 centered, uint256 mul) internal pure returns (uint256) {
        if (centered >= WAD) {
            return WAD + wmul(centered - WAD, mul);
        }
        uint256 below = wmul(WAD - centered, mul);
        return below < WAD ? WAD - below : 0;
    }

    function _ratioCapped(uint256 value, uint256 span) internal pure returns (uint256) {
        if (value >= span) return WAD;
        return wdiv(value, span);
    }

    function getName() external pure override returns (string memory) {
        return "wildcard_mod_v294";
    }
}
