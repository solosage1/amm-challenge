pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_TOX_ACT_002","confidence":0.74,"ceiling_probability":0.28,"ev_next_5":0.054,"best_delta_seen":2.3074,"reason":"promotion_edge 519.30 with T5 reliability scaling and wildcard sanity: bounded fees, coherent spread behavior, no pathological liquidity collapse","next_mechanism":"wildcard"}

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant STEP_COUNT_CAP = 64;

    uint256 constant TRADE_RATIO_CAP = WAD / 5;
    uint256 constant ARB_MAX_RATIO = WAD / 360;
    uint256 constant SIGNAL_THRESHOLD = WAD / 850;

    uint256 constant RET_CAP = WAD / 10;
    uint256 constant RET_DEADBAND = 5 * BPS;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant FLOW_CAP = WAD / 20;
    uint256 constant LAMBDA_CAP = 5 * WAD;
    uint256 constant IMB_CAP = WAD / 4;

    uint256 constant DIR_DECAY = 890000000000000000;
    uint256 constant SIGMA_DECAY = 920000000000000000;
    uint256 constant TOX_DECAY = 940000000000000000;
    uint256 constant SIZE_DECAY = 900000000000000000;
    uint256 constant REVEAL_DECAY = 920000000000000000;
    uint256 constant IMB_DECAY = 940000000000000000;
    uint256 constant LAMBDA_DECAY = 994000000000000000;
    uint256 constant LAMBDA_IDLE_DECAY = 998500000000000000;

    uint256 constant PHAT_ALPHA_FIRST_ARB = 280000000000000000;
    uint256 constant PHAT_ALPHA_FIRST_FLOW = 120000000000000000;
    uint256 constant PHAT_ALPHA_FOLLOW = 50000000000000000;
    uint256 constant SIGMA_ALPHA_FIRST_ARB = 240000000000000000;
    uint256 constant SIGMA_ALPHA_FIRST_FLOW = 110000000000000000;
    uint256 constant SIGMA_ALPHA_FOLLOW = 50000000000000000;
    uint256 constant TOX_ALPHA = 160000000000000000;
    uint256 constant SIZE_ALPHA = 200000000000000000;
    uint256 constant REVEAL_ALPHA_FIRST = 260000000000000000;
    uint256 constant REVEAL_ALPHA_FOLLOW = 80000000000000000;
    uint256 constant IMB_ALPHA = 140000000000000000;
    uint256 constant SHOCK_GATE = 35 * BPS;
    uint256 constant SHOCK_DAMP = 550000000000000000;

    uint256 constant DIR_PUSH_CAP = WAD / 4;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant MID_FLOOR = 2 * BPS;
    uint256 constant MIN_SIDE_FEE = BPS;

    uint256 constant SIGMA_COEF = 190000000000000000;
    uint256 constant LAMBDA_COEF = 9 * BPS;
    uint256 constant FLOW_COEF = 5800 * BPS;
    uint256 constant TOX_COEF = 170 * BPS;
    uint256 constant TOX_KNEE = 10 * BPS;
    uint256 constant TOX_QUAD_COEF = 10000 * BPS;
    uint256 constant TOX_QUAD_CAP = 170 * BPS;

    uint256 constant STRESS_SIGMA_W = 1200000000000000000;
    uint256 constant STRESS_TOX_W = 1600000000000000000;
    uint256 constant STRESS_FLOW_W = 900000000000000000;
    uint256 constant STRESS_REVEAL_W = 1100000000000000000;
    uint256 constant STRESS_IMB_W = 700000000000000000;

    uint256 constant CONF_SIGMA_W = 3500000000000000000;
    uint256 constant CONF_REVEAL_W = 2800000000000000000;
    uint256 constant CONF_GAP_W = 1500000000000000000;
    uint256 constant CONF_LOW_FLOW_W = 1500000000000000000;
    uint256 constant CONF_FLOW_FLOOR = 6000000000000000;
    uint256 constant CONF_MIN = 300000000000000000;

    uint256 constant TOX_REL_SIGMA_W = 2800000000000000000;
    uint256 constant TOX_REL_GAP_W = 1600000000000000000;
    uint256 constant TOX_REL_MIN = 350000000000000000;

    uint256 constant AGREE_TOX_GATE = 8 * BPS;
    uint256 constant AGREE_SIGMA_GATE = 8 * BPS;
    uint256 constant AGREE_FLOW_GATE = 1200000000000000;
    uint256 constant AGREE_REVEAL_GATE = 4 * BPS;
    uint256 constant AGREE_IMB_GATE = 4 * BPS;

    uint256 constant STRESS_MID_COEF = 90 * BPS;
    uint256 constant LOW_CONF_MID_COEF = 65 * BPS;
    uint256 constant FIRST_REVEAL_MID_COEF = 65 * BPS;
    uint256 constant AGREE_MID_COEF = 16 * BPS;
    uint256 constant CONF_RELIEF_COEF = 75 * BPS;

    uint256 constant SPREAD_BASE = 5 * BPS;
    uint256 constant SPREAD_MIN = 2 * BPS;
    uint256 constant SPREAD_MAX = 130 * BPS;
    uint256 constant SPREAD_STRESS_COEF = 130 * BPS;
    uint256 constant SPREAD_SIGMA_COEF = 80 * BPS;
    uint256 constant SPREAD_TOX_COEF = 90 * BPS;
    uint256 constant SPREAD_FLOW_COEF = 70 * BPS;
    uint256 constant SPREAD_REVEAL_COEF = 100 * BPS;
    uint256 constant SPREAD_AGREE_COEF = 20 * BPS;
    uint256 constant SPREAD_RELIEF_COEF = 85 * BPS;

    uint256 constant MID_UP_BASE = 24 * BPS;
    uint256 constant MID_UP_STRESS = 65 * BPS;
    uint256 constant MID_DOWN_BASE = 40 * BPS;
    uint256 constant MID_DOWN_CONF = 70 * BPS;

    uint256 constant SPREAD_UP_BASE = 22 * BPS;
    uint256 constant SPREAD_UP_STRESS = 80 * BPS;
    uint256 constant SPREAD_DOWN_BASE = 40 * BPS;
    uint256 constant SPREAD_DOWN_CONF = 65 * BPS;

    uint256 constant NO_AGREE_CAP_MULT = 650000000000000000;

    uint256 constant DIR_COEF = 75 * BPS;
    uint256 constant DIR_TOX_COEF = 12 * BPS;
    uint256 constant DIR_STRESS_COEF = 20 * BPS;
    uint256 constant SKEW_CAP = 110 * BPS;

    uint256 constant VULN_TOX_COEF = 100 * BPS;
    uint256 constant VULN_STRESS_COEF = 90 * BPS;
    uint256 constant VULN_REVEAL_COEF = 100 * BPS;
    uint256 constant AGREE_SIDE_COEF = 16 * BPS;
    uint256 constant ATTRACT_COEF = 85 * BPS;
    uint256 constant IMB_REBAL_COEF = 70 * BPS;
    uint256 constant SIDE_UP_CAP = 70 * BPS;
    uint256 constant SIDE_DOWN_CAP = 95 * BPS;

    uint256 constant MAX_SIDE_DIFF = 200 * BPS;
    uint256 constant LIQ_CEIL_BASE = 220 * BPS;
    uint256 constant LIQ_CEIL_STRESS = 520 * BPS;

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
        slots[4] = 10 * BPS;
        slots[5] = 0;
        slots[6] = 800000000000000000;
        slots[7] = 2000000000000000;
        slots[8] = WAD;
        slots[9] = 0;
        slots[10] = 0;
        slots[11] = 0;

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
        uint256 revealHat = slots[10];
        uint256 imbalanceHat = slots[11];

        uint256 gapScore = 0;

        if (trade.timestamp > lastTs) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            dirState = _decayCentered(dirState, DIR_DECAY, elapsed);
            sigmaHat = wmul(sigmaHat, _powWad(SIGMA_DECAY, elapsed));
            toxHat = wmul(toxHat, _powWad(TOX_DECAY, elapsed));
            sizeHat = wmul(sizeHat, _powWad(SIZE_DECAY, elapsed));
            revealHat = wmul(revealHat, _powWad(REVEAL_DECAY, elapsed));
            imbalanceHat = wmul(imbalanceHat, _powWad(IMB_DECAY, elapsed));

            if (stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                lambdaHat = wmul(lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
            } else {
                lambdaHat = wmul(lambdaHat, LAMBDA_IDLE_DECAY);
            }

            if (elapsedRaw > 1) {
                uint256 lag = elapsedRaw - 1;
                if (lag > ELAPSED_CAP) lag = ELAPSED_CAP;
                gapScore = (lag * WAD) / ELAPSED_CAP;
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
        uint256 revealInst = ret > RET_DEADBAND ? ret - RET_DEADBAND : 0;

        uint256 alphaP;
        uint256 alphaS;
        if (firstInStep) {
            alphaP = likelyArb ? PHAT_ALPHA_FIRST_ARB : PHAT_ALPHA_FIRST_FLOW;
            alphaS = likelyArb ? SIGMA_ALPHA_FIRST_ARB : SIGMA_ALPHA_FIRST_FLOW;
        } else {
            alphaP = PHAT_ALPHA_FOLLOW;
            alphaS = SIGMA_ALPHA_FOLLOW;
        }

        if (ret > SHOCK_GATE) {
            alphaP = wmul(alphaP, SHOCK_DAMP);
            alphaS = wmul(alphaS, SHOCK_DAMP);
        }

        pRef = _blend(pRef, pImplied, alphaP);

        uint256 sigmaInput = firstInStep ? ret : ret / 2;
        sigmaHat = _blend(sigmaHat, sigmaInput, alphaS);

        uint256 revealAlpha = firstInStep ? REVEAL_ALPHA_FIRST : REVEAL_ALPHA_FOLLOW;
        revealHat = _blend(revealHat, revealInst, revealAlpha);

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
        uint256 revealPrev = revealHat;

        uint256 toxInst = pRef > 0 ? wdiv(absDiff(spot, pRef), pRef) : 0;
        if (toxInst > TOX_CAP) toxInst = TOX_CAP;
        toxHat = _blend(toxHat, toxInst, TOX_ALPHA);

        (uint256 imbalanceInst, bool rebalanceTowardBid) = _inventoryImbalance(trade.reserveX, trade.reserveY, pRef);
        if (imbalanceInst > IMB_CAP) imbalanceInst = IMB_CAP;
        imbalanceHat = _blend(imbalanceHat, imbalanceInst, IMB_ALPHA);

        uint256 flow = wmul(lambdaHat, sizeHat);
        if (flow > FLOW_CAP) flow = FLOW_CAP;

        uint256 confPenalty =
            wmul(CONF_SIGMA_W, sigmaHat) + wmul(CONF_REVEAL_W, revealHat) + wmul(CONF_GAP_W, gapScore);
        if (flow < CONF_FLOW_FLOOR) {
            confPenalty = confPenalty + wmul(CONF_LOW_FLOW_W, CONF_FLOW_FLOOR - flow);
        }
        if (confPenalty > WAD) confPenalty = WAD;
        uint256 conf = WAD - confPenalty;
        if (conf < CONF_MIN) conf = CONF_MIN;

        uint256 toxRelPenalty = wmul(TOX_REL_SIGMA_W, sigmaHat) + wmul(TOX_REL_GAP_W, gapScore);
        uint256 toxRelMaxPenalty = WAD - TOX_REL_MIN;
        if (toxRelPenalty > toxRelMaxPenalty) toxRelPenalty = toxRelMaxPenalty;
        uint256 toxReliability = WAD - toxRelPenalty;

        uint256 toxEff = wmul(toxHat, toxReliability);
        uint256 revealEff = wmul(revealHat, toxReliability);
        uint256 toxPrevEff = wmul(toxPrev, toxReliability);
        uint256 revealPrevEff = wmul(revealPrev, toxReliability);

        uint256 stress =
            wmul(STRESS_SIGMA_W, sigmaHat) + wmul(STRESS_TOX_W, toxEff) + wmul(STRESS_FLOW_W, flow)
                + wmul(STRESS_REVEAL_W, revealEff) + wmul(STRESS_IMB_W, imbalanceHat);
        if (stress > WAD) stress = WAD;

        uint256 agreeCount = 0;
        if (toxEff >= AGREE_TOX_GATE) agreeCount = agreeCount + 1;
        if (sigmaHat >= AGREE_SIGMA_GATE) agreeCount = agreeCount + 1;
        if (flow >= AGREE_FLOW_GATE) agreeCount = agreeCount + 1;
        if (revealEff >= AGREE_REVEAL_GATE) agreeCount = agreeCount + 1;
        if (imbalanceHat >= AGREE_IMB_GATE) agreeCount = agreeCount + 1;

        uint256 agree = agreeCount >= 3 ? (agreeCount * WAD) / 5 : 0;

        uint256 toxExcess = toxEff > TOX_KNEE ? toxEff - TOX_KNEE : 0;
        uint256 toxQuad = wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        if (toxQuad > TOX_QUAD_CAP) toxQuad = TOX_QUAD_CAP;

        uint256 mid = BASE_FEE + wmul(SIGMA_COEF, sigmaHat) + wmul(LAMBDA_COEF, lambdaHat) + wmul(FLOW_COEF, flow)
            + wmul(TOX_COEF, toxEff) + toxQuad;

        if (firstInStep && revealEff > 0) mid = mid + wmul(FIRST_REVEAL_MID_COEF, revealEff);
        mid = mid + wmul(STRESS_MID_COEF, stress) + wmul(LOW_CONF_MID_COEF, WAD - conf);
        if (agree > 0) mid = mid + wmul(AGREE_MID_COEF, agree);

        uint256 midRelief = wmul(CONF_RELIEF_COEF, wmul(conf, WAD - stress));
        mid = mid > midRelief ? mid - midRelief : MID_FLOOR;

        uint256 spread = SPREAD_BASE + wmul(SPREAD_STRESS_COEF, stress) + wmul(SPREAD_SIGMA_COEF, sigmaHat)
            + wmul(SPREAD_TOX_COEF, toxEff) + wmul(SPREAD_FLOW_COEF, flow) + wmul(SPREAD_REVEAL_COEF, revealEff);
        if (agree > 0) spread = spread + wmul(SPREAD_AGREE_COEF, agree);

        uint256 spreadRelief = wmul(SPREAD_RELIEF_COEF, wmul(conf, WAD - stress));
        spread = spread > spreadRelief ? spread - spreadRelief : SPREAD_MIN;

        uint256 prevMid = (prevBidFee + prevAskFee) / 2;
        uint256 prevSpread = absDiff(prevBidFee, prevAskFee);

        uint256 midUpCap = MID_UP_BASE + wmul(MID_UP_STRESS, stress);
        uint256 midDownCap = MID_DOWN_BASE + wmul(MID_DOWN_CONF, wmul(conf, WAD - stress));
        uint256 spreadUpCap = SPREAD_UP_BASE + wmul(SPREAD_UP_STRESS, stress);
        uint256 spreadDownCap = SPREAD_DOWN_BASE + wmul(SPREAD_DOWN_CONF, wmul(conf, WAD - stress));

        if (agree == 0) {
            midUpCap = wmul(midUpCap, NO_AGREE_CAP_MULT);
            spreadUpCap = wmul(spreadUpCap, NO_AGREE_CAP_MULT);
        }

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
            wmul(DIR_COEF, dirDev) + wmul(DIR_TOX_COEF, wmul(dirDev, toxEff)) + wmul(DIR_STRESS_COEF, wmul(dirDev, stress));
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

        uint256 sideNow = wmul(VULN_TOX_COEF, toxEff) + wmul(VULN_REVEAL_COEF, revealEff);
        uint256 sidePrev = wmul(VULN_TOX_COEF, toxPrevEff) + wmul(VULN_REVEAL_COEF, revealPrevEff);

        if (sideNow > sidePrev) {
            uint256 rise = sideNow - sidePrev;
            if (rise > SIDE_UP_CAP) sideNow = sidePrev + SIDE_UP_CAP;
        } else {
            uint256 drop = sidePrev - sideNow;
            if (drop > SIDE_DOWN_CAP) {
                sideNow = sidePrev > SIDE_DOWN_CAP ? sidePrev - SIDE_DOWN_CAP : 0;
            }
        }

        uint256 vulnAdd = sideNow + wmul(VULN_STRESS_COEF, stress);
        if (agree > 0) vulnAdd = vulnAdd + wmul(AGREE_SIDE_COEF, agree);

        uint256 attractCut = wmul(ATTRACT_COEF, wmul(conf, WAD - stress));

        if (spot >= pRef) {
            bidFee = bidFee + vulnAdd;
            askFee = askFee > attractCut ? askFee - attractCut : 0;
        } else {
            askFee = askFee + vulnAdd;
            bidFee = bidFee > attractCut ? bidFee - attractCut : 0;
        }

        uint256 rebalanceShift = wmul(IMB_REBAL_COEF, wmul(imbalanceHat, wmul(conf, WAD - stress)));
        if (rebalanceTowardBid) {
            askFee = askFee + rebalanceShift;
            bidFee = bidFee > rebalanceShift ? bidFee - rebalanceShift : 0;
        } else {
            bidFee = bidFee + rebalanceShift;
            askFee = askFee > rebalanceShift ? askFee - rebalanceShift : 0;
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
        slots[10] = revealHat;
        slots[11] = imbalanceHat;

        return (bidFee, askFee);
    }

    function _inventoryImbalance(uint256 reserveX, uint256 reserveY, uint256 pRef)
        internal
        pure
        returns (uint256 imbalance, bool towardBid)
    {
        if (reserveX == 0 || pRef == 0) return (0, true);

        uint256 xNotionalY = wmul(reserveX, pRef);
        uint256 denom = reserveY + xNotionalY;
        if (denom == 0) return (0, true);

        imbalance = wdiv(absDiff(reserveY, xNotionalY), denom);
        towardBid = reserveY >= xNotionalY;
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

    function _decayCentered(uint256 centered, uint256 decayFactor, uint256 elapsed) internal pure returns (uint256) {
        uint256 mul = _powWad(decayFactor, elapsed);
        if (centered >= WAD) {
            return WAD + wmul(centered - WAD, mul);
        }
        uint256 below = wmul(WAD - centered, mul);
        return below < WAD ? WAD - below : 0;
    }

    function getName() external pure override returns (string memory) {
        return "wildcard_mod_v308";
    }
}
