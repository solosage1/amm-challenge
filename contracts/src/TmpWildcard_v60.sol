pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"pivot","hypothesis_id":"H_WILDCARD_060","confidence":0.71,"ceiling_probability":0.29,"ev_next_5":0.19,"best_delta_seen":0.15,"reason":"Replace step-gated recentering with continuous dual-anchor pricing plus signed-flow pressure and shock-adaptive piecewise fee shaping.","next_mechanism":"continuous_dual_anchor_surface"}

    struct State {
        uint256 bidFee;
        uint256 askFee;
        uint256 lastTs;
        uint256 pSlow;
        uint256 pFast;
        uint256 volEma;
        uint256 shockEma;
        uint256 toxEma;
        uint256 flowSigned;
        uint256 flowAbsEma;
        uint256 sizeEma;
        uint256 lambdaHat;
        uint256 burstEma;
        uint256 staleSigned;
        uint256 actEma;
        uint256 stepTradeCount;
        uint256 lastSpot;
    }

    uint256 constant ELAPSED_CAP = 10;
    uint256 constant SIGNAL_THRESHOLD = WAD / 900;
    uint256 constant TRADE_RATIO_CAP = WAD / 4;
    uint256 constant RET_CAP = WAD / 6;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant LAMBDA_CAP = 6 * WAD;
    uint256 constant STEP_COUNT_CAP = 96;
    uint256 constant BURST_NORM = 16;
    uint256 constant FLOW_PUSH_CAP = WAD / 3;
    uint256 constant FLOW_NORM_FLOOR = 6 * BPS;

    uint256 constant FLOW_SIGNED_DECAY = 880000000000000000;
    uint256 constant FLOW_ABS_DECAY = 780000000000000000;
    uint256 constant ACT_DECAY = 730000000000000000;
    uint256 constant SIZE_DECAY = 700000000000000000;
    uint256 constant VOL_DECAY = 860000000000000000;
    uint256 constant SHOCK_DECAY = 900000000000000000;
    uint256 constant TOX_DECAY = 880000000000000000;
    uint256 constant STALE_DECAY = 900000000000000000;
    uint256 constant LAMBDA_DECAY = 993000000000000000;
    uint256 constant BURST_DECAY = 900000000000000000;

    uint256 constant FLOW_ABS_BLEND_DECAY = 920000000000000000;
    uint256 constant ACT_BLEND_DECAY = 990000000000000000;
    uint256 constant SIZE_BLEND_DECAY = 830000000000000000;
    uint256 constant VOL_BLEND_DECAY = 760000000000000000;
    uint256 constant SHOCK_BLEND_DECAY = 860000000000000000;
    uint256 constant TOX_BLEND_DECAY = 420000000000000000;
    uint256 constant STALE_BLEND_DECAY = 820000000000000000;

    uint256 constant ALPHA_FAST_BASE = 170000000000000000;
    uint256 constant ALPHA_FAST_SIZE_COEF = 500000000000000000;
    uint256 constant ALPHA_FAST_CAP = 420000000000000000;
    uint256 constant ALPHA_SLOW_BASE = 35000000000000000;
    uint256 constant ALPHA_SLOW_VOL_COEF = 300000000000000000;
    uint256 constant ALPHA_SLOW_SIZE_COEF = 90000000000000000;
    uint256 constant ALPHA_SLOW_CAP = 180000000000000000;
    uint256 constant ALPHA_TOX_DAMP = 1000000000000000000;
    uint256 constant ALPHA_SHOCK_DAMP = 1200000000000000000;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant VOL_COEF = 230000000000000000;
    uint256 constant SHOCK_COEF = 120000000000000000;
    uint256 constant TOX_COEF = 240 * BPS;
    uint256 constant TOX_QUAD_COEF = 17000 * BPS;
    uint256 constant TOX_QUAD_KNEE = 10 * BPS;
    uint256 constant FLOW_COEF = 5600 * BPS;
    uint256 constant ACT_COEF = 26000 * BPS;
    uint256 constant LAMBDA_COEF = 10 * BPS;
    uint256 constant BURST_COEF = 45 * BPS;

    uint256 constant PRESSURE_COEF = 95 * BPS;
    uint256 constant PRESSURE_TOX_COEF = 45 * BPS;
    uint256 constant STALE_COEF = 4200 * BPS;
    uint256 constant STALE_TOX_COEF = 1500 * BPS;

    uint256 constant KNEE_1 = 600 * BPS;
    uint256 constant KNEE_2 = 1100 * BPS;
    uint256 constant SLOPE1_PROTECT = 760000000000000000;
    uint256 constant SLOPE1_ATTRACT = 910000000000000000;
    uint256 constant SLOPE2_PROTECT = 420000000000000000;
    uint256 constant SLOPE2_ATTRACT = 620000000000000000;
    uint256 constant SHAPE_SHOCK_SLOPE = 280000000000000000;

    uint256 constant RATE_UP_CAP = 90 * BPS;
    uint256 constant RATE_DOWN_CAP = 130 * BPS;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;

        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = p0;
        slots[4] = p0;
        slots[5] = 12 * BPS;
        slots[6] = 0;
        slots[7] = 0;
        slots[8] = WAD;
        slots[9] = 0;
        slots[10] = 15 * BPS;
        slots[11] = 900000000000000000;
        slots[12] = 0;
        slots[13] = WAD;
        slots[14] = 0;
        slots[15] = 0;
        slots[16] = p0;

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        State memory s = State({
            bidFee: slots[0],
            askFee: slots[1],
            lastTs: slots[2],
            pSlow: slots[3],
            pFast: slots[4],
            volEma: slots[5],
            shockEma: slots[6],
            toxEma: slots[7],
            flowSigned: slots[8],
            flowAbsEma: slots[9],
            sizeEma: slots[10],
            lambdaHat: slots[11],
            burstEma: slots[12],
            staleSigned: slots[13],
            actEma: slots[14],
            stepTradeCount: slots[15],
            lastSpot: slots[16]
        });

        uint256 prevBidFee = s.bidFee;
        uint256 prevAskFee = s.askFee;

        if (trade.timestamp > s.lastTs) {
            uint256 elapsedRaw = trade.timestamp - s.lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            s.flowSigned = _decayCentered(s.flowSigned, FLOW_SIGNED_DECAY, elapsed);
            s.staleSigned = _decayCentered(s.staleSigned, STALE_DECAY, elapsed);
            s.flowAbsEma = wmul(s.flowAbsEma, _powWad(FLOW_ABS_DECAY, elapsed));
            s.actEma = wmul(s.actEma, _powWad(ACT_DECAY, elapsed));
            s.sizeEma = wmul(s.sizeEma, _powWad(SIZE_DECAY, elapsed));
            s.volEma = wmul(s.volEma, _powWad(VOL_DECAY, elapsed));
            s.shockEma = wmul(s.shockEma, _powWad(SHOCK_DECAY, elapsed));
            s.toxEma = wmul(s.toxEma, _powWad(TOX_DECAY, elapsed));

            if (s.stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (s.stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                s.lambdaHat = wmul(s.lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);

                uint256 burstInst = (s.stepTradeCount * WAD) / BURST_NORM;
                if (burstInst > WAD) burstInst = WAD;
                s.burstEma = wmul(s.burstEma, BURST_DECAY) + wmul(burstInst, WAD - BURST_DECAY);
            }

            s.stepTradeCount = 0;
        }

        uint256 spot = _resolveSpot(trade.reserveX, trade.reserveY, s.pSlow, s.pFast);
        if (s.pSlow == 0) s.pSlow = spot;
        if (s.pFast == 0) s.pFast = spot;

        uint256 pTrade = _resolveTradePrice(spot, trade.isBuy, prevBidFee, prevAskFee);
        if (pTrade == 0) pTrade = spot;

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = tradeRatio;
            if (push > FLOW_PUSH_CAP) push = FLOW_PUSH_CAP;

            if (trade.isBuy) {
                s.flowSigned = s.flowSigned + push;
                if (s.flowSigned > 2 * WAD) s.flowSigned = 2 * WAD;
            } else {
                s.flowSigned = s.flowSigned > push ? s.flowSigned - push : 0;
            }

            s.flowAbsEma = wmul(s.flowAbsEma, FLOW_ABS_BLEND_DECAY) + wmul(push, WAD - FLOW_ABS_BLEND_DECAY);
            s.actEma = wmul(s.actEma, ACT_BLEND_DECAY) + wmul(tradeRatio, WAD - ACT_BLEND_DECAY);
            s.sizeEma = wmul(s.sizeEma, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
            if (s.sizeEma > WAD) s.sizeEma = WAD;
        }

        {
            uint256 volPrev = s.volEma;
            uint256 ret = s.pFast > 0 ? wdiv(absDiff(pTrade, s.pFast), s.pFast) : 0;
            if (ret > RET_CAP) ret = RET_CAP;
            s.volEma = wmul(s.volEma, VOL_BLEND_DECAY) + wmul(ret, WAD - VOL_BLEND_DECAY);

            uint256 shockIn = ret > volPrev ? ret - volPrev : 0;
            if (s.lastSpot > 0) {
                uint256 stepMove = wdiv(absDiff(spot, s.lastSpot), s.lastSpot);
                if (stepMove > RET_CAP) stepMove = RET_CAP;
                uint256 stepShock = wmul(stepMove, 400000000000000000);
                if (stepShock > shockIn) shockIn = stepShock;
            }
            s.shockEma = wmul(s.shockEma, SHOCK_BLEND_DECAY) + wmul(shockIn, WAD - SHOCK_BLEND_DECAY);
        }

        {
            uint256 tox = s.pSlow > 0 ? wdiv(absDiff(spot, s.pSlow), s.pSlow) : 0;
            if (tox > TOX_CAP) tox = TOX_CAP;
            s.toxEma = wmul(s.toxEma, TOX_BLEND_DECAY) + wmul(tox, WAD - TOX_BLEND_DECAY);

            uint256 staleBump = wmul(tox, WAD - STALE_BLEND_DECAY);
            if (spot >= s.pSlow) {
                s.staleSigned = s.staleSigned + staleBump;
                if (s.staleSigned > 2 * WAD) s.staleSigned = 2 * WAD;
            } else {
                s.staleSigned = s.staleSigned > staleBump ? s.staleSigned - staleBump : 0;
            }
        }

        {
            uint256 alphaFast = ALPHA_FAST_BASE + wmul(ALPHA_FAST_SIZE_COEF, tradeRatio);
            if (alphaFast > ALPHA_FAST_CAP) alphaFast = ALPHA_FAST_CAP;
            s.pFast = wmul(s.pFast, WAD - alphaFast) + wmul(pTrade, alphaFast);

            uint256 alphaSlow = ALPHA_SLOW_BASE + wmul(ALPHA_SLOW_VOL_COEF, s.volEma) + wmul(ALPHA_SLOW_SIZE_COEF, s.sizeEma);
            if (alphaSlow > ALPHA_SLOW_CAP) alphaSlow = ALPHA_SLOW_CAP;

            uint256 damp = wmul(ALPHA_TOX_DAMP, s.toxEma) + wmul(ALPHA_SHOCK_DAMP, s.shockEma);
            uint256 maxDamp = (9 * WAD) / 10;
            if (damp > maxDamp) damp = maxDamp;
            alphaSlow = wmul(alphaSlow, WAD - damp);

            s.pSlow = wmul(s.pSlow, WAD - alphaSlow) + wmul(pTrade, alphaSlow);
        }

        (s.bidFee, s.askFee) = _computeRawFees(s);
        (s.bidFee, s.askFee) = _shapePair(s.bidFee, s.askFee, s.shockEma);

        s.bidFee = clampFee(s.bidFee);
        s.askFee = clampFee(s.askFee);

        s.bidFee = _rateLimit(s.bidFee, prevBidFee, RATE_UP_CAP, RATE_DOWN_CAP);
        s.askFee = _rateLimit(s.askFee, prevAskFee, RATE_UP_CAP, RATE_DOWN_CAP);

        s.bidFee = clampFee(s.bidFee);
        s.askFee = clampFee(s.askFee);

        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;
        s.lastTs = trade.timestamp;
        s.lastSpot = spot;

        slots[0] = s.bidFee;
        slots[1] = s.askFee;
        slots[2] = s.lastTs;
        slots[3] = s.pSlow;
        slots[4] = s.pFast;
        slots[5] = s.volEma;
        slots[6] = s.shockEma;
        slots[7] = s.toxEma;
        slots[8] = s.flowSigned;
        slots[9] = s.flowAbsEma;
        slots[10] = s.sizeEma;
        slots[11] = s.lambdaHat;
        slots[12] = s.burstEma;
        slots[13] = s.staleSigned;
        slots[14] = s.actEma;
        slots[15] = s.stepTradeCount;
        slots[16] = s.lastSpot;

        return (s.bidFee, s.askFee);
    }

    function _resolveSpot(uint256 reserveX, uint256 reserveY, uint256 pSlow, uint256 pFast) internal pure returns (uint256) {
        if (reserveX > 0) return wdiv(reserveY, reserveX);
        if (pSlow > 0) return pSlow;
        if (pFast > 0) return pFast;
        return WAD;
    }

    function _resolveTradePrice(uint256 spot, bool isBuy, uint256 prevBidFee, uint256 prevAskFee) internal pure returns (uint256) {
        uint256 feeUsed = isBuy ? prevBidFee : prevAskFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        if (gamma == 0) return spot;
        return isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
    }

    function _computeRawFees(State memory s) internal pure returns (uint256 bidFee, uint256 askFee) {
        uint256 pressure = _computePressure(s.flowSigned, s.flowAbsEma);
        uint256 fMid = _computeMid(s);
        uint256 skew = _computeSkew(pressure, s.toxEma);

        if (s.flowSigned >= WAD) {
            bidFee = fMid + skew;
            askFee = fMid > skew ? fMid - skew : 0;
        } else {
            askFee = fMid + skew;
            bidFee = fMid > skew ? fMid - skew : 0;
        }

        (bidFee, askFee) = _applyStaleShift(bidFee, askFee, s.staleSigned, s.toxEma);
    }

    function _shapePair(uint256 bidFee, uint256 askFee, uint256 shockEma) internal pure returns (uint256, uint256) {
        uint256 shockAdj = wmul(SHAPE_SHOCK_SLOPE, shockEma);
        uint256 slope1Protect = _subFloor(SLOPE1_PROTECT, shockAdj, 550000000000000000);
        uint256 slope1Attract = _subFloor(SLOPE1_ATTRACT, wmul(shockAdj, 500000000000000000), 700000000000000000);
        uint256 slope2Protect = _subFloor(SLOPE2_PROTECT, shockAdj, 300000000000000000);
        uint256 slope2Attract = _subFloor(SLOPE2_ATTRACT, wmul(shockAdj, 700000000000000000), 420000000000000000);

        if (bidFee > askFee) {
            bidFee = _shapeFee(bidFee, slope1Protect, slope2Protect);
            askFee = _shapeFee(askFee, slope1Attract, slope2Attract);
        } else if (askFee > bidFee) {
            bidFee = _shapeFee(bidFee, slope1Attract, slope2Attract);
            askFee = _shapeFee(askFee, slope1Protect, slope2Protect);
        } else {
            uint256 slope1Mid = (slope1Protect + slope1Attract) / 2;
            uint256 slope2Mid = (slope2Protect + slope2Attract) / 2;
            bidFee = _shapeFee(bidFee, slope1Mid, slope2Mid);
            askFee = _shapeFee(askFee, slope1Mid, slope2Mid);
        }

        return (bidFee, askFee);
    }

    function _computePressure(uint256 flowSigned, uint256 flowAbsEma) internal pure returns (uint256) {
        uint256 flowDev = flowSigned >= WAD ? flowSigned - WAD : WAD - flowSigned;
        uint256 flowNorm = wdiv(flowDev, flowAbsEma + FLOW_NORM_FLOOR);
        if (flowNorm > WAD) flowNorm = WAD;
        return wmul(600000000000000000, flowDev) + wmul(400000000000000000, flowNorm);
    }

    function _computeMid(State memory s) internal pure returns (uint256) {
        uint256 activity = wmul(s.lambdaHat, s.sizeEma);
        if (activity > WAD) activity = WAD;

        uint256 toxExcess = s.toxEma > TOX_QUAD_KNEE ? s.toxEma - TOX_QUAD_KNEE : 0;
        uint256 volMix = s.volEma + wmul(s.shockEma, 500000000000000000);
        if (volMix > RET_CAP) volMix = RET_CAP;

        uint256 fMid = BASE_FEE;
        fMid = fMid + wmul(VOL_COEF, volMix);
        fMid = fMid + wmul(SHOCK_COEF, s.shockEma);
        fMid = fMid + wmul(TOX_COEF, s.toxEma);
        fMid = fMid + wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        fMid = fMid + wmul(FLOW_COEF, activity);
        fMid = fMid + wmul(ACT_COEF, s.actEma);
        fMid = fMid + wmul(LAMBDA_COEF, s.lambdaHat);
        fMid = fMid + wmul(BURST_COEF, s.burstEma);
        return fMid;
    }

    function _computeSkew(uint256 pressure, uint256 toxEma) internal pure returns (uint256) {
        uint256 skew = wmul(PRESSURE_COEF, pressure);
        skew = skew + wmul(PRESSURE_TOX_COEF, wmul(pressure, toxEma));
        return skew;
    }

    function _applyStaleShift(uint256 bidFee, uint256 askFee, uint256 staleSigned, uint256 toxEma)
        internal
        pure
        returns (uint256, uint256)
    {
        uint256 staleDev = staleSigned >= WAD ? staleSigned - WAD : WAD - staleSigned;
        uint256 staleShift = wmul(STALE_COEF, staleDev) + wmul(STALE_TOX_COEF, wmul(staleDev, toxEma));

        if (staleSigned >= WAD) {
            bidFee = bidFee + staleShift;
            askFee = askFee > staleShift ? askFee - staleShift : 0;
        } else {
            askFee = askFee + staleShift;
            bidFee = bidFee > staleShift ? bidFee - staleShift : 0;
        }

        return (bidFee, askFee);
    }

    function _shapeFee(uint256 fee, uint256 slope1, uint256 slope2) internal pure returns (uint256) {
        if (fee <= KNEE_1) return fee;

        if (fee <= KNEE_2) {
            return KNEE_1 + wmul(fee - KNEE_1, slope1);
        }

        uint256 first = KNEE_1 + wmul(KNEE_2 - KNEE_1, slope1);
        return first + wmul(fee - KNEE_2, slope2);
    }

    function _rateLimit(uint256 nextFee, uint256 prevFee, uint256 upCap, uint256 downCap) internal pure returns (uint256) {
        if (nextFee > prevFee) {
            uint256 upper = prevFee + upCap;
            return nextFee > upper ? upper : nextFee;
        }

        uint256 lower = prevFee > downCap ? prevFee - downCap : 0;
        return nextFee < lower ? lower : nextFee;
    }

    function _subFloor(uint256 value, uint256 amount, uint256 floor) internal pure returns (uint256) {
        if (value <= floor) return floor;
        uint256 room = value - floor;
        if (amount >= room) return floor;
        return value - amount;
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
        return "wildcard_mod_v60";
    }
}
