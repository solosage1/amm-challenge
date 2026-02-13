pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_TOX_ACT_005","confidence":0.73,"ceiling_probability":0.24,"ev_next_5":0.06,"best_delta_seen":2.3074,"reason":"promotion_edge 519.26 supports T6 bounded adaptation with wildcard sanity: bounded fees, coherent spread behavior, no pathological liquidity collapse","next_mechanism":"wildcard"}

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant STEP_COUNT_CAP = 64;

    uint256 constant TRADE_RATIO_CAP = WAD / 5;
    uint256 constant ARB_MAX_RATIO = WAD / 360;
    uint256 constant SIGNAL_THRESHOLD = WAD / 900;

    uint256 constant RET_CAP = WAD / 10;
    uint256 constant RET_DEADBAND = 5 * BPS;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant FLOW_CAP = WAD / 20;
    uint256 constant LAMBDA_CAP = 5 * WAD;

    uint256 constant DIR_DECAY = 900000000000000000;
    uint256 constant SIGMA_DECAY = 920000000000000000;
    uint256 constant TOX_DECAY = 940000000000000000;
    uint256 constant SIZE_DECAY = 900000000000000000;
    uint256 constant HAZARD_DECAY = 930000000000000000;
    uint256 constant LAMBDA_KEEP = 994000000000000000;
    uint256 constant LAMBDA_IDLE_DECAY = 998500000000000000;

    uint256 constant P_ALPHA_FIRST_ARB = 220000000000000000;
    uint256 constant P_ALPHA_FIRST_FLOW = 100000000000000000;
    uint256 constant P_ALPHA_FOLLOW = 40000000000000000;
    uint256 constant SIGMA_ALPHA_FIRST_ARB = 240000000000000000;
    uint256 constant SIGMA_ALPHA_FIRST_FLOW = 120000000000000000;
    uint256 constant SIGMA_ALPHA_FOLLOW = 40000000000000000;
    uint256 constant TOX_ALPHA = 180000000000000000;
    uint256 constant SIZE_ALPHA = 180000000000000000;
    uint256 constant HAZARD_ALPHA_FIRST = 260000000000000000;
    uint256 constant HAZARD_ALPHA_FOLLOW = 80000000000000000;
    uint256 constant SHOCK_GATE = 30 * BPS;
    uint256 constant SHOCK_DAMP = 600000000000000000;

    uint256 constant DIR_PUSH_CAP = WAD / 4;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant MID_FLOOR = 2 * BPS;
    uint256 constant MIN_SIDE_FEE = BPS;

    uint256 constant SIGMA_COEF = 190000000000000000;
    uint256 constant LAMBDA_COEF = 10 * BPS;
    uint256 constant FLOW_COEF = 6200 * BPS;
    uint256 constant TOX_COEF = 200 * BPS;
    uint256 constant TOX_KNEE = 10 * BPS;
    uint256 constant TOX_QUAD_COEF = 12000 * BPS;
    uint256 constant TOX_QUAD_CAP = 200 * BPS;

    uint256 constant STRESS_MID_COEF = 100 * BPS;
    uint256 constant LOW_CONF_MID_COEF = 75 * BPS;
    uint256 constant CONF_RELIEF_COEF = 70 * BPS;
    uint256 constant FIRST_REVEAL_MID_COEF = 70 * BPS;
    uint256 constant AGREE_MID_COEF = 12 * BPS;

    uint256 constant SPREAD_BASE = 6 * BPS;
    uint256 constant SPREAD_MIN = 3 * BPS;
    uint256 constant SPREAD_MAX = 140 * BPS;
    uint256 constant SPREAD_STRESS_COEF = 130 * BPS;
    uint256 constant SPREAD_TOX_COEF = 100 * BPS;
    uint256 constant SPREAD_FLOW_COEF = 80 * BPS;
    uint256 constant SPREAD_HAZARD_COEF = 120 * BPS;
    uint256 constant FIRST_REVEAL_SPREAD_COEF = 90 * BPS;
    uint256 constant AGREE_SPREAD_COEF = 15 * BPS;
    uint256 constant SPREAD_CONF_RELIEF_COEF = 80 * BPS;

    uint256 constant MID_UP_BASE = 28 * BPS;
    uint256 constant MID_UP_STRESS = 70 * BPS;
    uint256 constant MID_DOWN_BASE = 42 * BPS;
    uint256 constant MID_DOWN_CONF = 70 * BPS;

    uint256 constant SPREAD_UP_BASE = 25 * BPS;
    uint256 constant SPREAD_UP_STRESS = 80 * BPS;
    uint256 constant SPREAD_DOWN_BASE = 42 * BPS;
    uint256 constant SPREAD_DOWN_CONF = 65 * BPS;

    uint256 constant STRESS_SIGMA_W = 1200000000000000000;
    uint256 constant STRESS_TOX_W = 1800000000000000000;
    uint256 constant STRESS_FLOW_W = 900000000000000000;
    uint256 constant STRESS_HAZARD_W = 1200000000000000000;

    uint256 constant CONF_SIGMA_W = 4000000000000000000;
    uint256 constant CONF_TOX_W = 5000000000000000000;
    uint256 constant CONF_FLOW_W = 1500000000000000000;
    uint256 constant CONF_HAZARD_W = 2500000000000000000;
    uint256 constant CONF_MIN = 250000000000000000;

    uint256 constant AGREE_TOX_GATE = 10 * BPS;
    uint256 constant AGREE_SIGMA_GATE = 8 * BPS;
    uint256 constant AGREE_FLOW_GATE = 1200000000000000;
    uint256 constant AGREE_HAZARD_GATE = 4 * BPS;
    uint256 constant AGREE_REVEAL_GATE = 5 * BPS;

    uint256 constant DIR_COEF = 80 * BPS;
    uint256 constant DIR_TOX_COEF = 15 * BPS;
    uint256 constant DIR_STRESS_COEF = 25 * BPS;
    uint256 constant SKEW_CAP = 120 * BPS;

    uint256 constant VULN_TOX_COEF = 120 * BPS;
    uint256 constant VULN_STRESS_COEF = 120 * BPS;
    uint256 constant AGREE_SIDE_COEF = 12 * BPS;
    uint256 constant ATTRACT_COEF = 90 * BPS;
    uint256 constant STALE_SHIFT_COEF = 70 * BPS;
    uint256 constant SIDE_TOX_UP_CAP = 80 * BPS;
    uint256 constant SIDE_TOX_DOWN_CAP = 100 * BPS;

    uint256 constant MAX_SIDE_DIFF = 220 * BPS;
    uint256 constant LIQ_CEIL_BASE = 230 * BPS;
    uint256 constant LIQ_CEIL_STRESS = 500 * BPS;

    uint256 constant TAIL_KNEE = 700 * BPS;
    uint256 constant TAIL_SLOPE_NEUTRAL = 900000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 840000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 960000000000000000;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;

        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = p0;
        slots[4] = 9 * BPS;
        slots[5] = 5 * BPS;
        slots[6] = 800000000000000000;
        slots[7] = 2000000000000000;
        slots[8] = WAD;
        slots[9] = 0;
        slots[10] = 0;

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 prevBidFee = slots[0];
        uint256 prevAskFee = slots[1];
        uint256 lastTs = slots[2];
        uint256 pRef = slots[3];
        uint256 sigmaHat = slots[4];
        uint256 toxHat = slots[5];
        uint256 lambdaHat = slots[6];
        uint256 sizeHat = slots[7];
        uint256 dirState = slots[8];
        uint256 stepTradeCount = slots[9];
        uint256 hazardHat = slots[10];

        if (trade.timestamp > lastTs) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            uint256 dirMul = _linearMul(DIR_DECAY, elapsed);
            dirState = _decayCenteredMul(dirState, dirMul);
            sigmaHat = wmul(sigmaHat, _linearMul(SIGMA_DECAY, elapsed));
            toxHat = wmul(toxHat, _linearMul(TOX_DECAY, elapsed));
            sizeHat = wmul(sizeHat, _linearMul(SIZE_DECAY, elapsed));
            hazardHat = wmul(hazardHat, _linearMul(HAZARD_DECAY, elapsed));

            if (stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                lambdaHat = wmul(lambdaHat, LAMBDA_KEEP) + wmul(lambdaInst, WAD - LAMBDA_KEEP);
            } else {
                lambdaHat = wmul(lambdaHat, LAMBDA_IDLE_DECAY);
            }

            stepTradeCount = 0;
        }

        bool firstInStep = stepTradeCount == 0;

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pRef;
        if (pRef == 0) pRef = spot > 0 ? spot : 100 * WAD;

        uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied;
        if (gamma == 0) {
            pImplied = spot;
        } else {
            pImplied = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
        }

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        bool likelyArb = firstInStep && tradeRatio <= ARB_MAX_RATIO;

        uint256 ret = pRef > 0 ? wdiv(absDiff(pImplied, pRef), pRef) : 0;
        if (ret > RET_CAP) ret = RET_CAP;
        uint256 reveal = ret > RET_DEADBAND ? ret - RET_DEADBAND : 0;

        uint256 alphaP;
        uint256 alphaS;
        if (firstInStep) {
            alphaP = likelyArb ? P_ALPHA_FIRST_ARB : P_ALPHA_FIRST_FLOW;
            alphaS = likelyArb ? SIGMA_ALPHA_FIRST_ARB : SIGMA_ALPHA_FIRST_FLOW;
        } else {
            alphaP = P_ALPHA_FOLLOW;
            alphaS = SIGMA_ALPHA_FOLLOW;
        }

        if (ret > SHOCK_GATE) {
            alphaP = wmul(alphaP, SHOCK_DAMP);
            alphaS = wmul(alphaS, SHOCK_DAMP);
        }

        pRef = _blend(pRef, pImplied, alphaP);
        uint256 sigmaInput = firstInStep ? ret : ret / 2;
        sigmaHat = _blend(sigmaHat, sigmaInput, alphaS);

        uint256 hzAlpha = firstInStep ? HAZARD_ALPHA_FIRST : HAZARD_ALPHA_FOLLOW;
        hazardHat = _blend(hazardHat, reveal, hzAlpha);

        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = tradeRatio;
            if (push > DIR_PUSH_CAP) push = DIR_PUSH_CAP;

            if (trade.isBuy) {
                dirState = dirState + push;
                if (dirState > 2 * WAD) dirState = 2 * WAD;
            } else {
                dirState = dirState > push ? dirState - push : 0;
            }

            sizeHat = _blend(sizeHat, tradeRatio, SIZE_ALPHA);
            if (sizeHat > WAD) sizeHat = WAD;
        }

        uint256 toxPrev = toxHat;
        uint256 toxInst = pRef > 0 ? wdiv(absDiff(spot, pRef), pRef) : 0;
        if (toxInst > TOX_CAP) toxInst = TOX_CAP;
        toxHat = _blend(toxHat, toxInst, TOX_ALPHA);

        uint256 flow = wmul(lambdaHat, sizeHat);
        if (flow > FLOW_CAP) flow = FLOW_CAP;

        uint256 stress =
            wmul(STRESS_SIGMA_W, sigmaHat) + wmul(STRESS_TOX_W, toxHat) + wmul(STRESS_FLOW_W, flow)
                + wmul(STRESS_HAZARD_W, hazardHat);
        if (stress > WAD) stress = WAD;

        uint256 confPenalty =
            wmul(CONF_SIGMA_W, sigmaHat) + wmul(CONF_TOX_W, toxHat) + wmul(CONF_FLOW_W, flow)
                + wmul(CONF_HAZARD_W, hazardHat);
        if (confPenalty > WAD) confPenalty = WAD;
        uint256 conf = WAD - confPenalty;
        if (conf < CONF_MIN) conf = CONF_MIN;

        uint256 agreeCount;
        if (toxHat >= AGREE_TOX_GATE) agreeCount = agreeCount + 1;
        if (sigmaHat >= AGREE_SIGMA_GATE) agreeCount = agreeCount + 1;
        if (flow >= AGREE_FLOW_GATE) agreeCount = agreeCount + 1;
        if (hazardHat >= AGREE_HAZARD_GATE || (firstInStep && reveal >= AGREE_REVEAL_GATE)) {
            agreeCount = agreeCount + 1;
        }
        uint256 agree = agreeCount >= 3 ? (agreeCount * WAD) / 4 : 0;

        uint256 toxExcess = toxHat > TOX_KNEE ? toxHat - TOX_KNEE : 0;
        uint256 toxQuad = wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        if (toxQuad > TOX_QUAD_CAP) toxQuad = TOX_QUAD_CAP;

        uint256 mid = BASE_FEE + wmul(SIGMA_COEF, sigmaHat) + wmul(LAMBDA_COEF, lambdaHat) + wmul(FLOW_COEF, flow)
            + wmul(TOX_COEF, toxHat) + toxQuad;
        if (firstInStep && reveal > 0) mid = mid + wmul(FIRST_REVEAL_MID_COEF, reveal);
        mid = mid + wmul(STRESS_MID_COEF, stress) + wmul(LOW_CONF_MID_COEF, WAD - conf);
        if (agree > 0) mid = mid + wmul(AGREE_MID_COEF, agree);

        uint256 midRelief = wmul(CONF_RELIEF_COEF, wmul(conf, WAD - stress));
        mid = mid > midRelief ? mid - midRelief : MID_FLOOR;

        uint256 spread = SPREAD_BASE + wmul(SPREAD_STRESS_COEF, stress) + wmul(SPREAD_TOX_COEF, toxHat)
            + wmul(SPREAD_FLOW_COEF, flow) + wmul(SPREAD_HAZARD_COEF, hazardHat);
        if (firstInStep && reveal > 0) spread = spread + wmul(FIRST_REVEAL_SPREAD_COEF, reveal);
        if (agree > 0) spread = spread + wmul(AGREE_SPREAD_COEF, agree);

        uint256 spreadRelief = wmul(SPREAD_CONF_RELIEF_COEF, wmul(conf, WAD - stress));
        spread = spread > spreadRelief ? spread - spreadRelief : SPREAD_MIN;

        uint256 prevMid = (prevBidFee + prevAskFee) / 2;
        uint256 prevSpread = absDiff(prevBidFee, prevAskFee);

        uint256 midUpCap = MID_UP_BASE + wmul(MID_UP_STRESS, stress);
        uint256 midDownCap = MID_DOWN_BASE + wmul(MID_DOWN_CONF, wmul(conf, WAD - stress));
        uint256 spreadUpCap = SPREAD_UP_BASE + wmul(SPREAD_UP_STRESS, stress);
        uint256 spreadDownCap = SPREAD_DOWN_BASE + wmul(SPREAD_DOWN_CONF, wmul(conf, WAD - stress));

        mid = _capMove(mid, prevMid, midUpCap, midDownCap);
        spread = _capMove(spread, prevSpread, spreadUpCap, spreadDownCap);

        if (mid < MID_FLOOR) mid = MID_FLOOR;
        if (spread < SPREAD_MIN) spread = SPREAD_MIN;
        if (spread > SPREAD_MAX) spread = SPREAD_MAX;

        uint256 dirDev;
        bool protectBid;
        if (dirState >= WAD) {
            dirDev = dirState - WAD;
            protectBid = true;
        } else {
            dirDev = WAD - dirState;
            protectBid = false;
        }

        uint256 skew =
            wmul(DIR_COEF, dirDev) + wmul(DIR_TOX_COEF, wmul(dirDev, toxHat)) + wmul(DIR_STRESS_COEF, wmul(dirDev, stress));
        if (skew > SKEW_CAP) skew = SKEW_CAP;

        uint256 halfSpread = spread / 2;
        uint256 center = mid + halfSpread;

        uint256 bidFee;
        uint256 askFee;
        if (protectBid) {
            bidFee = center + skew;
            askFee = center > skew ? center - skew : 0;
        } else {
            askFee = center + skew;
            bidFee = center > skew ? center - skew : 0;
        }

        uint256 toxSideAdd = wmul(VULN_TOX_COEF, toxHat);
        uint256 prevToxSideAdd = wmul(VULN_TOX_COEF, toxPrev);
        if (toxSideAdd > prevToxSideAdd) {
            uint256 rise = toxSideAdd - prevToxSideAdd;
            if (rise > SIDE_TOX_UP_CAP) toxSideAdd = prevToxSideAdd + SIDE_TOX_UP_CAP;
        } else {
            uint256 drop = prevToxSideAdd - toxSideAdd;
            if (drop > SIDE_TOX_DOWN_CAP) {
                toxSideAdd = prevToxSideAdd > SIDE_TOX_DOWN_CAP ? prevToxSideAdd - SIDE_TOX_DOWN_CAP : 0;
            }
        }

        uint256 vulnAdd = toxSideAdd + wmul(VULN_STRESS_COEF, stress);
        if (agree > 0) vulnAdd = vulnAdd + wmul(AGREE_SIDE_COEF, agree);

        uint256 attractCut = wmul(ATTRACT_COEF, wmul(conf, WAD - stress));
        uint256 staleShift = wmul(STALE_SHIFT_COEF, hazardHat);

        if (spot >= pRef) {
            bidFee = bidFee + vulnAdd + staleShift;
            uint256 cut = attractCut + staleShift;
            askFee = askFee > cut ? askFee - cut : 0;
        } else {
            askFee = askFee + vulnAdd + staleShift;
            uint256 cut = attractCut + staleShift;
            bidFee = bidFee > cut ? bidFee - cut : 0;
        }

        if (bidFee > askFee) {
            uint256 diff = bidFee - askFee;
            if (diff > MAX_SIDE_DIFF) bidFee = askFee + MAX_SIDE_DIFF;
        } else {
            uint256 diff = askFee - bidFee;
            if (diff > MAX_SIDE_DIFF) askFee = bidFee + MAX_SIDE_DIFF;
        }

        uint256 liqCeil = LIQ_CEIL_BASE + wmul(LIQ_CEIL_STRESS, stress);
        if (liqCeil > MAX_FEE) liqCeil = MAX_FEE;

        if (bidFee > liqCeil) bidFee = liqCeil;
        if (askFee > liqCeil) askFee = liqCeil;

        if (bidFee > askFee) {
            bidFee = clampFee(_compressTail(bidFee, TAIL_SLOPE_PROTECT));
            askFee = clampFee(_compressTail(askFee, TAIL_SLOPE_ATTRACT));
        } else if (askFee > bidFee) {
            bidFee = clampFee(_compressTail(bidFee, TAIL_SLOPE_ATTRACT));
            askFee = clampFee(_compressTail(askFee, TAIL_SLOPE_PROTECT));
        } else {
            bidFee = clampFee(_compressTail(bidFee, TAIL_SLOPE_NEUTRAL));
            askFee = clampFee(_compressTail(askFee, TAIL_SLOPE_NEUTRAL));
        }

        if (bidFee < MIN_SIDE_FEE) bidFee = MIN_SIDE_FEE;
        if (askFee < MIN_SIDE_FEE) askFee = MIN_SIDE_FEE;

        stepTradeCount = stepTradeCount + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = pRef;
        slots[4] = sigmaHat;
        slots[5] = toxHat;
        slots[6] = lambdaHat;
        slots[7] = sizeHat;
        slots[8] = dirState;
        slots[9] = stepTradeCount;
        slots[10] = hazardHat;

        return (bidFee, askFee);
    }

    function _blend(uint256 prev, uint256 value, uint256 alpha) internal pure returns (uint256) {
        if (alpha >= WAD) return value;
        return wmul(prev, WAD - alpha) + wmul(value, alpha);
    }

    function _capMove(uint256 target, uint256 prev, uint256 upCap, uint256 downCap) internal pure returns (uint256) {
        if (target > prev) {
            uint256 rise = target - prev;
            return rise > upCap ? prev + upCap : target;
        }
        uint256 drop = prev - target;
        if (drop <= downCap) return target;
        return prev > downCap ? prev - downCap : 0;
    }

    function _linearMul(uint256 decayFactor, uint256 elapsed) internal pure returns (uint256) {
        if (elapsed == 0) return WAD;
        uint256 loss = (WAD - decayFactor) * elapsed;
        if (loss > WAD) return 0;
        return WAD - loss;
    }

    function _decayCenteredMul(uint256 centered, uint256 mul) internal pure returns (uint256) {
        if (centered >= WAD) {
            return WAD + wmul(centered - WAD, mul);
        }
        uint256 below = wmul(WAD - centered, mul);
        return below < WAD ? WAD - below : 0;
    }

    function _compressTail(uint256 fee, uint256 slope) internal pure returns (uint256) {
        if (fee <= TAIL_KNEE) return fee;
        return TAIL_KNEE + wmul(fee - TAIL_KNEE, slope);
    }

    function getName() external pure override returns (string memory) {
        return "wildcard_mod_v270";
    }
}
