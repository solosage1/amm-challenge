pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_TOX_ACT_002","confidence":0.64,"ceiling_probability":0.26,"ev_next_5":0.034,"best_delta_seen":2.3074,"reason":"promotion_edge 519.30 and T3: confidence-weighted asymmetry with bounded fees, coherent spread behavior, and no pathological liquidity collapse.","next_mechanism":"wildcard"}

    struct State {
        uint256 bidFee;
        uint256 askFee;
        uint256 lastTs;
        uint256 pRef;
        uint256 sigmaHat;
        uint256 toxEma;
        uint256 dirState;
        uint256 lambdaHat;
        uint256 sizeHat;
        uint256 riskState;
        uint256 stepTradeCount;
    }

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant STEP_COUNT_CAP = 64;

    uint256 constant SIGNAL_THRESHOLD = WAD / 900;
    uint256 constant TRADE_RATIO_CAP = WAD / 5;
    uint256 constant ARB_MAX_RATIO = WAD / 360;
    uint256 constant RET_CAP = WAD / 8;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant LAMBDA_CAP = 5 * WAD;

    uint256 constant DIR_DECAY = 860000000000000000;
    uint256 constant SIZE_DECAY = 640000000000000000;
    uint256 constant TOX_DECAY = 900000000000000000;
    uint256 constant RISK_DECAY = 960000000000000000;
    uint256 constant LAMBDA_DECAY = 994000000000000000;

    uint256 constant SIZE_BLEND_DECAY = 810000000000000000;
    uint256 constant TOX_BLEND_FIRST = 320000000000000000;
    uint256 constant TOX_BLEND_FLOW = 900000000000000000;

    uint256 constant PREF_ALPHA_FIRST_ARB = 320000000000000000;
    uint256 constant PREF_ALPHA_FIRST_RETAIL = 120000000000000000;
    uint256 constant PREF_ALPHA_FOLLOW = 45000000000000000;
    uint256 constant PREF_SHOCK_GATE = 26000000000000000;
    uint256 constant PREF_SHOCK_DAMP = 350000000000000000;

    uint256 constant SIGMA_DECAY_FIRST = 700000000000000000;
    uint256 constant SIGMA_DECAY_FOLLOW = 985000000000000000;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant MID_CAP = 340 * BPS;

    uint256 constant SIGMA_COEF = 170000000000000000;
    uint256 constant LAMBDA_COEF = 11 * BPS;
    uint256 constant FLOW_SIZE_COEF = 6200 * BPS;

    uint256 constant TOX_COEF = 165 * BPS;
    uint256 constant TOX_QUAD_COEF = 15000 * BPS;
    uint256 constant TOX_KNEE = 10 * BPS;
    uint256 constant TOX_QUAD_ADD_CAP = 145 * BPS;

    uint256 constant ACT_COEF = 28000 * BPS;
    uint256 constant ACT_GATE_LAMBDA = 920000000000000000;
    uint256 constant ACT_GATE_SIZE = 2500000000000000;

    uint256 constant AGREE_BOOST = 650000000000000000;
    uint256 constant TOX_DEADBAND = 8 * BPS;
    uint256 constant TOX_SPAN = 30 * BPS;
    uint256 constant SIGMA_DEADBAND = 5 * BPS;
    uint256 constant SIGMA_SPAN = 24 * BPS;
    uint256 constant FLOW_DEADBAND = 1200000000000000;
    uint256 constant FLOW_SPAN = 5000000000000000;

    uint256 constant RISK_CAP = 320 * BPS;
    uint256 constant RISK_STEP_UP_BASE = 90 * BPS;
    uint256 constant RISK_STEP_UP_STRESS = 140 * BPS;
    uint256 constant RISK_STEP_DOWN_BASE = 130 * BPS;
    uint256 constant RISK_STEP_DOWN_CONF = 140 * BPS;

    uint256 constant CONF_MIN = 420000000000000000;
    uint256 constant CONF_NEUTRAL = 780000000000000000;
    uint256 constant CONF_SIGMA_SPAN = 42 * BPS;
    uint256 constant CONF_TOX_SPAN = 60 * BPS;
    uint256 constant CONF_FLOW_SPAN = 12000000000000000;
    uint256 constant CONF_W_SIGMA = 420000000000000000;
    uint256 constant CONF_W_TOX = 360000000000000000;
    uint256 constant CONF_W_FLOW = 220000000000000000;

    uint256 constant STRESS_W_SIGMA = 320000000000000000;
    uint256 constant STRESS_W_TOX = 420000000000000000;
    uint256 constant STRESS_W_FLOW = 260000000000000000;

    uint256 constant FIRST_REVEAL_COEF = 60 * BPS;
    uint256 constant FOLLOW_REVEAL_COEF = 10 * BPS;
    uint256 constant LOW_CONF_GUARD = 90 * BPS;
    uint256 constant STRESS_GUARD = 85 * BPS;
    uint256 constant CONF_RELIEF = 60 * BPS;

    uint256 constant DIR_COEF = 78 * BPS;
    uint256 constant DIR_TOX_COEF = 16 * BPS;
    uint256 constant DIR_STRESS_COEF = 24 * BPS;
    uint256 constant SKEW_CAP = 250 * BPS;

    uint256 constant SPREAD_BASE = 6 * BPS;
    uint256 constant SPREAD_TOX_COEF = 95 * BPS;
    uint256 constant SPREAD_STRESS_COEF = 90 * BPS;
    uint256 constant SPREAD_CONF_RELIEF = 55 * BPS;
    uint256 constant SPREAD_MIN = 2 * BPS;
    uint256 constant SPREAD_MAX = 170 * BPS;

    uint256 constant ADVERSE_SPLIT_BASE = 420000000000000000;
    uint256 constant ADVERSE_SPLIT_STRESS = 500000000000000000;
    uint256 constant ATTRACT_MIN = 140000000000000000;
    uint256 constant ATTRACT_SPAN = 260000000000000000;

    uint256 constant STALE_COEF = 5600 * BPS;
    uint256 constant LOW_CONF_STALE_MULT = 420000000000000000;
    uint256 constant STALE_CAP_ADD = 230 * BPS;

    uint256 constant MAX_SIDE_DIFF = 240 * BPS;
    uint256 constant LIQ_CEIL_BASE = 210 * BPS;
    uint256 constant LIQ_CEIL_STRESS = 900 * BPS;

    uint256 constant TAIL_KNEE = 700 * BPS;
    uint256 constant TAIL_SLOPE_NEUTRAL = 890000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 820000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 960000000000000000;

    uint256 constant MIN_SIDE_FEE = BPS;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;

        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = p0;
        slots[4] = 900000000000000;
        slots[5] = 0;
        slots[6] = WAD;
        slots[7] = 800000000000000000;
        slots[8] = 1800000000000000;
        slots[9] = 0;
        slots[10] = 0;

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        State memory s = _loadState();

        if (s.dirState == 0) s.dirState = WAD;
        if (trade.timestamp > s.lastTs) _rollStep(s, trade.timestamp);

        bool firstInStep = s.stepTradeCount == 0;
        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : s.pRef;
        if (s.pRef == 0) s.pRef = spot;

        uint256 ret = _updateBeliefAndDirection(s, trade, spot, firstInStep);
        _updateTox(s, spot, firstInStep);

        uint256 flowSize = wmul(s.lambdaHat, s.sizeHat);
        (uint256 stress, uint256 conf) = _stressAndConf(s.sigmaHat, s.toxEma, flowSize);

        uint256 riskTarget = _riskTarget(s, flowSize, ret, stress, conf, firstInStep);
        _smoothRisk(s, riskTarget, stress, conf);

        uint256 mid = BASE_FEE + wmul(SIGMA_COEF, s.sigmaHat) + wmul(LAMBDA_COEF, s.lambdaHat) + wmul(FLOW_SIZE_COEF, flowSize)
            + s.riskState;
        if (conf > CONF_NEUTRAL) {
            uint256 relief = wmul(CONF_RELIEF, conf - CONF_NEUTRAL);
            if (mid > relief + BASE_FEE) {
                mid = mid - relief;
            } else {
                mid = BASE_FEE;
            }
        }
        if (mid > MID_CAP) mid = MID_CAP;

        (s.bidFee, s.askFee) = _quote(s, mid, stress, conf, spot);

        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;

        _storeState(s, trade.timestamp);
        return (s.bidFee, s.askFee);
    }

    function _updateBeliefAndDirection(State memory s, TradeInfo calldata trade, uint256 spot, bool firstInStep)
        internal
        pure
        returns (uint256 ret)
    {
        uint256 feeUsed = trade.isBuy ? s.bidFee : s.askFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied = gamma == 0 ? spot : (trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma));

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        ret = s.pRef > 0 ? wdiv(absDiff(pImplied, s.pRef), s.pRef) : 0;
        if (ret > RET_CAP) ret = RET_CAP;

        uint256 alpha;
        if (firstInStep) {
            bool likelyArb = tradeRatio <= ARB_MAX_RATIO;
            alpha = likelyArb ? PREF_ALPHA_FIRST_ARB : PREF_ALPHA_FIRST_RETAIL;
            if (ret > PREF_SHOCK_GATE) alpha = wmul(alpha, PREF_SHOCK_DAMP);
            s.sigmaHat = wmul(s.sigmaHat, SIGMA_DECAY_FIRST) + wmul(ret, WAD - SIGMA_DECAY_FIRST);
        } else {
            alpha = PREF_ALPHA_FOLLOW;
            if (ret > PREF_SHOCK_GATE) alpha = wmul(alpha, PREF_SHOCK_DAMP);
            s.sigmaHat = wmul(s.sigmaHat, SIGMA_DECAY_FOLLOW) + wmul(ret / 2, WAD - SIGMA_DECAY_FOLLOW);
        }

        s.pRef = wmul(s.pRef, WAD - alpha) + wmul(pImplied, alpha);

        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = tradeRatio;
            if (push > WAD / 4) push = WAD / 4;

            if (trade.isBuy) {
                s.dirState = s.dirState + push;
                if (s.dirState > 2 * WAD) s.dirState = 2 * WAD;
            } else {
                s.dirState = s.dirState > push ? s.dirState - push : 0;
            }

            s.sizeHat = wmul(s.sizeHat, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
            if (s.sizeHat > WAD) s.sizeHat = WAD;
        }
    }

    function _updateTox(State memory s, uint256 spot, bool firstInStep) internal pure {
        uint256 tox = s.pRef > 0 ? wdiv(absDiff(spot, s.pRef), s.pRef) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;

        uint256 toxBlend = firstInStep ? TOX_BLEND_FIRST : TOX_BLEND_FLOW;
        s.toxEma = wmul(s.toxEma, toxBlend) + wmul(tox, WAD - toxBlend);
    }

    function _stressAndConf(uint256 sigmaHat, uint256 toxEma, uint256 flowSize)
        internal
        pure
        returns (uint256 stress, uint256 conf)
    {
        uint256 sigmaNorm = _ratioCapped(sigmaHat, CONF_SIGMA_SPAN);
        uint256 toxNorm = _ratioCapped(toxEma, CONF_TOX_SPAN);
        uint256 flowNorm = _ratioCapped(flowSize, CONF_FLOW_SPAN);

        stress = wmul(STRESS_W_SIGMA, sigmaNorm) + wmul(STRESS_W_TOX, toxNorm) + wmul(STRESS_W_FLOW, flowNorm);
        if (stress > WAD) stress = WAD;

        uint256 confPenalty = wmul(CONF_W_SIGMA, sigmaNorm) + wmul(CONF_W_TOX, toxNorm) + wmul(CONF_W_FLOW, flowNorm);
        uint256 maxPenalty = WAD - CONF_MIN;
        if (confPenalty > maxPenalty) confPenalty = maxPenalty;

        conf = WAD - confPenalty;
        if (conf < CONF_MIN) conf = CONF_MIN;
    }

    function _riskTarget(State memory s, uint256 flowSize, uint256 ret, uint256 stress, uint256 conf, bool firstInStep)
        internal
        pure
        returns (uint256 riskTarget)
    {
        uint256 toxExcess = s.toxEma > TOX_KNEE ? s.toxEma - TOX_KNEE : 0;
        uint256 toxQuadAdd = wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        if (toxQuadAdd > TOX_QUAD_ADD_CAP) toxQuadAdd = TOX_QUAD_ADD_CAP;

        riskTarget = wmul(TOX_COEF, s.toxEma) + toxQuadAdd;
        if (s.lambdaHat >= ACT_GATE_LAMBDA && s.sizeHat >= ACT_GATE_SIZE) {
            riskTarget = riskTarget + wmul(ACT_COEF, s.sizeHat);
        }

        uint256 toxAgree = _deadbandRatio(s.toxEma, TOX_DEADBAND, TOX_SPAN);
        uint256 sigmaAgree = _deadbandRatio(s.sigmaHat, SIGMA_DEADBAND, SIGMA_SPAN);
        uint256 flowAgree = _deadbandRatio(flowSize, FLOW_DEADBAND, FLOW_SPAN);
        uint256 agree = wmul(toxAgree, wmul(sigmaAgree, flowAgree));

        if (agree > 0) {
            riskTarget = riskTarget + wmul(riskTarget, wmul(AGREE_BOOST, agree));
        }

        riskTarget = riskTarget + (firstInStep ? wmul(FIRST_REVEAL_COEF, ret) : wmul(FOLLOW_REVEAL_COEF, ret));

        if (conf < CONF_NEUTRAL) {
            riskTarget = riskTarget + wmul(LOW_CONF_GUARD, CONF_NEUTRAL - conf);
        }

        riskTarget = riskTarget + wmul(STRESS_GUARD, stress);
        if (riskTarget > RISK_CAP) riskTarget = RISK_CAP;
    }

    function _smoothRisk(State memory s, uint256 riskTarget, uint256 stress, uint256 conf) internal pure {
        if (riskTarget > s.riskState) {
            uint256 upCap = RISK_STEP_UP_BASE + wmul(RISK_STEP_UP_STRESS, stress);
            uint256 rise = riskTarget - s.riskState;
            s.riskState = rise > upCap ? s.riskState + upCap : riskTarget;
        } else {
            uint256 downCap = RISK_STEP_DOWN_BASE + wmul(RISK_STEP_DOWN_CONF, conf);
            uint256 drop = s.riskState - riskTarget;
            s.riskState = drop > downCap ? s.riskState - downCap : riskTarget;
        }
    }

    function _quote(State memory s, uint256 mid, uint256 stress, uint256 conf, uint256 spot)
        internal
        pure
        returns (uint256 bidFee, uint256 askFee)
    {
        (bidFee, askFee) = _coreDirectional(s, mid, stress, conf);
        (bidFee, askFee) = _applyRiskAsymmetry(s, bidFee, askFee, stress, conf, spot);
        (bidFee, askFee) = _applyStaleShift(s, bidFee, askFee, conf, spot);

        (bidFee, askFee) = _cohere(bidFee, askFee, stress);

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
    }

    function _coreDirectional(State memory s, uint256 mid, uint256 stress, uint256 conf)
        internal
        pure
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 dirDev;
        bool defendBid;
        if (s.dirState >= WAD) {
            dirDev = s.dirState - WAD;
            defendBid = true;
        } else {
            dirDev = WAD - s.dirState;
            defendBid = false;
        }

        uint256 skew =
            wmul(DIR_COEF, dirDev) + wmul(DIR_TOX_COEF, wmul(dirDev, s.toxEma)) + wmul(DIR_STRESS_COEF, wmul(dirDev, stress));
        if (skew > SKEW_CAP) skew = SKEW_CAP;

        uint256 spread = SPREAD_BASE + wmul(SPREAD_TOX_COEF, s.toxEma) + wmul(SPREAD_STRESS_COEF, stress);
        uint256 spreadRelief = wmul(SPREAD_CONF_RELIEF, conf);
        if (spread > spreadRelief + SPREAD_MIN) {
            spread = spread - spreadRelief;
        } else {
            spread = SPREAD_MIN;
        }
        if (spread > SPREAD_MAX) spread = SPREAD_MAX;

        uint256 half = spread / 2;
        if (defendBid) {
            bidFee = mid + half + skew;
            askFee = mid > half ? mid - half : 0;
        } else {
            askFee = mid + half + skew;
            bidFee = mid > half ? mid - half : 0;
        }
    }

    function _applyRiskAsymmetry(State memory s, uint256 bidFee, uint256 askFee, uint256 stress, uint256 conf, uint256 spot)
        internal
        pure
        returns (uint256, uint256)
    {
        uint256 splitMult = ADVERSE_SPLIT_BASE + wmul(ADVERSE_SPLIT_STRESS, stress);
        if (splitMult > WAD) splitMult = WAD;
        uint256 splitAdd = wmul(s.riskState, splitMult);

        uint256 attractShare = ATTRACT_MIN + wmul(ATTRACT_SPAN, conf);
        if (attractShare > WAD) attractShare = WAD;
        uint256 attractShift = wmul(splitAdd, attractShare);

        if (spot >= s.pRef) {
            bidFee = bidFee + splitAdd;
            askFee = askFee > attractShift ? askFee - attractShift : 0;
        } else {
            askFee = askFee + splitAdd;
            bidFee = bidFee > attractShift ? bidFee - attractShift : 0;
        }

        return (bidFee, askFee);
    }

    function _applyStaleShift(State memory s, uint256 bidFee, uint256 askFee, uint256 conf, uint256 spot)
        internal
        pure
        returns (uint256, uint256)
    {
        uint256 staleShift = wmul(STALE_COEF, s.toxEma);
        if (conf < CONF_NEUTRAL) {
            staleShift = wmul(staleShift, WAD + wmul(LOW_CONF_STALE_MULT, CONF_NEUTRAL - conf));
        }
        if (staleShift > STALE_CAP_ADD) staleShift = STALE_CAP_ADD;

        if (spot >= s.pRef) {
            bidFee = bidFee + staleShift;
            askFee = askFee > staleShift ? askFee - staleShift : 0;
        } else {
            askFee = askFee + staleShift;
            bidFee = bidFee > staleShift ? bidFee - staleShift : 0;
        }

        return (bidFee, askFee);
    }

    function _cohere(uint256 bidFee, uint256 askFee, uint256 stress) internal pure returns (uint256, uint256) {
        if (bidFee > askFee) {
            uint256 diff = bidFee - askFee;
            if (diff > MAX_SIDE_DIFF) bidFee = askFee + MAX_SIDE_DIFF;
        } else {
            uint256 diff = askFee - bidFee;
            if (diff > MAX_SIDE_DIFF) askFee = bidFee + MAX_SIDE_DIFF;
        }

        uint256 minSide = bidFee < askFee ? bidFee : askFee;
        uint256 liqCeil = LIQ_CEIL_BASE + wmul(LIQ_CEIL_STRESS, stress);
        if (liqCeil > MAX_FEE) liqCeil = MAX_FEE;

        if (minSide > liqCeil) {
            uint256 cut = minSide - liqCeil;
            bidFee = bidFee > cut ? bidFee - cut : 0;
            askFee = askFee > cut ? askFee - cut : 0;
        }

        return (bidFee, askFee);
    }

    function _rollStep(State memory s, uint256 timestamp) internal pure {
        uint256 elapsedRaw = timestamp - s.lastTs;
        uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

        s.dirState = _decayCentered(s.dirState, DIR_DECAY, elapsed);
        s.sizeHat = wmul(s.sizeHat, _powWad(SIZE_DECAY, elapsed));
        s.toxEma = wmul(s.toxEma, _powWad(TOX_DECAY, elapsed));
        s.riskState = wmul(s.riskState, _powWad(RISK_DECAY, elapsed));

        if (s.stepTradeCount > 0 && elapsedRaw > 0) {
            uint256 lambdaInst = (s.stepTradeCount * WAD) / elapsedRaw;
            if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
            s.lambdaHat = wmul(s.lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
        }

        s.stepTradeCount = 0;
    }

    function _loadState() internal view returns (State memory s) {
        s.bidFee = slots[0];
        s.askFee = slots[1];
        s.lastTs = slots[2];
        s.pRef = slots[3];
        s.sigmaHat = slots[4];
        s.toxEma = slots[5];
        s.dirState = slots[6];
        s.lambdaHat = slots[7];
        s.sizeHat = slots[8];
        s.riskState = slots[9];
        s.stepTradeCount = slots[10];
    }

    function _storeState(State memory s, uint256 timestamp) internal {
        slots[0] = s.bidFee;
        slots[1] = s.askFee;
        slots[2] = timestamp;
        slots[3] = s.pRef;
        slots[4] = s.sigmaHat;
        slots[5] = s.toxEma;
        slots[6] = s.dirState;
        slots[7] = s.lambdaHat;
        slots[8] = s.sizeHat;
        slots[9] = s.riskState;
        slots[10] = s.stepTradeCount;
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

    function _ratioCapped(uint256 value, uint256 span) internal pure returns (uint256) {
        if (value >= span) return WAD;
        return wdiv(value, span);
    }

    function _deadbandRatio(uint256 value, uint256 deadband, uint256 span) internal pure returns (uint256) {
        if (value <= deadband) return 0;
        uint256 excess = value - deadband;
        if (excess >= span) return WAD;
        return wdiv(excess, span);
    }

    function getName() external pure override returns (string memory) {
        return "wildcard_mod_v288";
    }
}
