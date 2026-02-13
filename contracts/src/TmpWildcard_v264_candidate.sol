pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_WILDCARD_264_CONF_SURFACE","confidence":0.69,"ceiling_probability":0.28,"ev_next_5":0.07,"best_delta_seen":2.3074,"reason":"promotion_edge 519.26 with T1 confidence-led adverse-selection control; bounded fees, coherent spread behavior, no pathological liquidity collapse","next_mechanism":"wildcard"}

    struct State {
        uint256 bidFee;
        uint256 askFee;
        uint256 pRef;
        uint256 sigmaHat;
        uint256 lambdaHat;
        uint256 sizeHat;
        uint256 toxFast;
        uint256 toxSlow;
        uint256 actEma;
        uint256 dirState;
        uint256 confEma;
        uint256 stepTradeCount;
    }

    struct Runtime {
        bool firstInStep;
        bool likelyArb;
        bool agree;
        uint256 spot;
        uint256 pImplied;
        uint256 tradeRatio;
        uint256 ret;
        uint256 toxInst;
        uint256 flowPressure;
        uint256 toxGap;
        uint256 stress;
        uint256 prevMid;
        uint256 prevSpread;
    }

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant STEP_COUNT_CAP = 64;

    uint256 constant SIGNAL_THRESHOLD = WAD / 900;
    uint256 constant TRADE_RATIO_CAP = WAD / 5;
    uint256 constant ARB_MAX_RATIO = WAD / 360;
    uint256 constant RET_CAP = WAD / 10;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant LAMBDA_CAP = 5 * WAD;
    uint256 constant FLOW_CAP = WAD / 18;

    uint256 constant DIR_DECAY = 860000000000000000;
    uint256 constant ACT_DECAY = 760000000000000000;
    uint256 constant SIZE_DECAY = 690000000000000000;
    uint256 constant TOX_FAST_DECAY = 830000000000000000;
    uint256 constant TOX_SLOW_DECAY = 920000000000000000;
    uint256 constant SIGMA_DECAY = 760000000000000000;
    uint256 constant CONF_DECAY = 910000000000000000;
    uint256 constant LAMBDA_KEEP = 994000000000000000;
    uint256 constant LAMBDA_IDLE_DECAY = 998000000000000000;

    uint256 constant REF_ALPHA_FIRST_ARB = 240000000000000000;
    uint256 constant REF_ALPHA_FIRST_RETAIL = 130000000000000000;
    uint256 constant REF_ALPHA_FOLLOW = 70000000000000000;
    uint256 constant REF_ALPHA_CONF_FLOOR = 550000000000000000;
    uint256 constant REF_ALPHA_CONF_SPAN = 450000000000000000;
    uint256 constant SHOCK_GATE = 30 * BPS;
    uint256 constant SHOCK_DAMP = 350000000000000000;

    uint256 constant SIGMA_ALPHA_FIRST = 220000000000000000;
    uint256 constant SIGMA_ALPHA_FOLLOW = 90000000000000000;
    uint256 constant TOX_FAST_ALPHA = 240000000000000000;
    uint256 constant TOX_SLOW_ALPHA_FIRST = 140000000000000000;
    uint256 constant TOX_SLOW_ALPHA_FOLLOW = 90000000000000000;
    uint256 constant ACT_ALPHA_FIRST = 150000000000000000;
    uint256 constant ACT_ALPHA_FOLLOW = 90000000000000000;
    uint256 constant SIZE_ALPHA_FIRST = 180000000000000000;
    uint256 constant SIZE_ALPHA_FOLLOW = 120000000000000000;

    uint256 constant CONF_ALPHA = 170000000000000000;
    uint256 constant CONF_NEUTRAL = 760000000000000000;
    uint256 constant CONF_FLOOR = 300000000000000000;

    uint256 constant DIR_PUSH_MULT = 2;
    uint256 constant DIR_PUSH_CAP = WAD / 4;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant SIGMA_COEF = 190000000000000000;
    uint256 constant LAMBDA_COEF = 10 * BPS;
    uint256 constant FLOW_COEF = 6200 * BPS;
    uint256 constant TOX_COEF = 170 * BPS;
    uint256 constant TOX_QUAD_COEF = 15000 * BPS;
    uint256 constant TOX_KNEE = 11 * BPS;
    uint256 constant TOX_QUAD_CAP = 260 * BPS;
    uint256 constant STRESS_GUARD_COEF = 130 * BPS;
    uint256 constant LOW_CONF_GUARD_COEF = 120 * BPS;
    uint256 constant CONF_RELIEF_COEF = 95 * BPS;

    uint256 constant MID_FLOOR = 2 * BPS;
    uint256 constant MID_UP_CAP_SOFT = 55 * BPS;
    uint256 constant MID_DOWN_CAP_SOFT = 75 * BPS;
    uint256 constant MID_UP_CAP_HARD = 110 * BPS;
    uint256 constant MID_DOWN_CAP_HARD = 140 * BPS;

    uint256 constant SPREAD_BASE = 7 * BPS;
    uint256 constant SPREAD_STRESS_COEF = 150 * BPS;
    uint256 constant SPREAD_TOX_COEF = 120 * BPS;
    uint256 constant SPREAD_FLOW_COEF = 130 * BPS;
    uint256 constant SPREAD_RET_COEF = 110 * BPS;
    uint256 constant SPREAD_ACT_COEF = 90 * BPS;
    uint256 constant SPREAD_CONF_RELIEF_COEF = 80 * BPS;
    uint256 constant SPREAD_MIN = 3 * BPS;
    uint256 constant SPREAD_MAX = 170 * BPS;
    uint256 constant SPREAD_UP_CAP_SOFT = 55 * BPS;
    uint256 constant SPREAD_DOWN_CAP_SOFT = 75 * BPS;
    uint256 constant SPREAD_UP_CAP_HARD = 110 * BPS;
    uint256 constant SPREAD_DOWN_CAP_HARD = 130 * BPS;
    uint256 constant FIRST_REVEAL_SPREAD_ADD = 14 * BPS;
    uint256 constant FIRST_REVEAL_MID_ADD = 10 * BPS;
    uint256 constant AGREE_SPREAD_ADD = 18 * BPS;
    uint256 constant AGREE_MID_ADD = 12 * BPS;

    uint256 constant AGREE_TOX_GATE = 9 * BPS;
    uint256 constant AGREE_SIGMA_GATE = 8 * BPS;
    uint256 constant AGREE_FLOW_GATE = 1000000000000000;
    uint256 constant AGREE_GAP_GATE = 4 * BPS;
    uint256 constant RET_DEADBAND = 5 * BPS;

    uint256 constant DIR_COEF = 85 * BPS;
    uint256 constant DIR_STRESS_COEF = 30 * BPS;
    uint256 constant SKEW_CAP = 130 * BPS;

    uint256 constant VULN_TOX_COEF = 150 * BPS;
    uint256 constant VULN_STRESS_COEF = 170 * BPS;
    uint256 constant ATTRACT_COEF = 120 * BPS;
    uint256 constant MAX_SIDE_DIFF = 220 * BPS;
    uint256 constant MIN_SIDE_FEE = BPS;
    uint256 constant LIQUIDITY_CEIL_BASE = 220 * BPS;
    uint256 constant LIQUIDITY_CEIL_STRESS = 1000 * BPS;

    uint256 constant STRESS_TOX_W = 1900000000000000000;
    uint256 constant STRESS_VOL_W = 1300000000000000000;
    uint256 constant STRESS_FLOW_W = 800000000000000000;
    uint256 constant STRESS_GAP_W = 1000000000000000000;
    uint256 constant STRESS_CONF_W = 700000000000000000;
    uint256 constant STRESS_RET_W = 600000000000000000;
    uint256 constant STRESS_ACT_W = 500000000000000000;

    uint256 constant CONF_TOX_W = 2000000000000000000;
    uint256 constant CONF_VOL_W = 1100000000000000000;
    uint256 constant CONF_FLOW_W = 800000000000000000;
    uint256 constant CONF_GAP_W = 900000000000000000;
    uint256 constant CONF_ACT_W = 600000000000000000;
    uint256 constant CONF_RET_W = 700000000000000000;

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
        slots[5] = 800000000000000000;
        slots[6] = 1800000000000000;
        slots[7] = 0;
        slots[8] = 0;
        slots[9] = 0;
        slots[10] = WAD;
        slots[11] = CONF_NEUTRAL;
        slots[12] = 0;

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        State memory s = _loadState();
        Runtime memory r;

        _rollStep(s, slots[2], trade.timestamp);

        r.firstInStep = s.stepTradeCount == 0;
        r.spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : s.pRef;
        if (s.pRef == 0) s.pRef = r.spot > 0 ? r.spot : 100 * WAD;

        r.pImplied = _impliedPrice(r.spot, trade.isBuy ? s.bidFee : s.askFee, trade.isBuy);
        r.tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (r.tradeRatio > TRADE_RATIO_CAP) r.tradeRatio = TRADE_RATIO_CAP;

        r.likelyArb = r.firstInStep && r.tradeRatio <= ARB_MAX_RATIO;

        r.ret = s.pRef > 0 ? wdiv(absDiff(r.pImplied, s.pRef), s.pRef) : 0;
        if (r.ret > RET_CAP) r.ret = RET_CAP;

        _updateReferenceAndVol(s, r.pImplied, r.ret, r.firstInStep, r.likelyArb);
        _updateFlowSignals(s, r.tradeRatio, trade.isBuy, r.firstInStep);

        r.toxInst = s.pRef > 0 ? wdiv(absDiff(r.spot, s.pRef), s.pRef) : 0;
        if (r.toxInst > TOX_CAP) r.toxInst = TOX_CAP;

        (r.flowPressure, r.toxGap, r.stress) = _updateToxicityConfidenceStress(s, r.toxInst, r.ret, r.firstInStep);
        r.agree = _hasAgreement(s, r.flowPressure, r.toxGap, r.ret);

        r.prevMid = (s.bidFee + s.askFee) / 2;
        r.prevSpread = absDiff(s.bidFee, s.askFee);

        uint256 midTarget = _computeMidTarget(s, r.flowPressure, r.stress, r.ret, r.firstInStep, r.agree);
        uint256 spreadTarget = _computeSpreadTarget(s, r.flowPressure, r.stress, r.ret, r.firstInStep, r.agree);

        uint256 mid = _capMove(
            midTarget,
            r.prevMid,
            r.agree ? MID_UP_CAP_HARD : MID_UP_CAP_SOFT,
            r.agree ? MID_DOWN_CAP_HARD : MID_DOWN_CAP_SOFT
        );
        uint256 spread = _capMove(
            spreadTarget,
            r.prevSpread,
            r.agree ? SPREAD_UP_CAP_HARD : SPREAD_UP_CAP_SOFT,
            r.agree ? SPREAD_DOWN_CAP_HARD : SPREAD_DOWN_CAP_SOFT
        );

        if (mid < MID_FLOOR) mid = MID_FLOOR;
        if (spread < SPREAD_MIN) spread = SPREAD_MIN;
        if (spread > SPREAD_MAX) spread = SPREAD_MAX;

        (uint256 bidFee, uint256 askFee) = _quoteSides(s, mid, spread, r.stress, r.spot);
        (bidFee, askFee) = _enforceCoherence(bidFee, askFee, r.stress);
        (bidFee, askFee) = _tailAndClamp(bidFee, askFee);

        if (bidFee < MIN_SIDE_FEE) bidFee = MIN_SIDE_FEE;
        if (askFee < MIN_SIDE_FEE) askFee = MIN_SIDE_FEE;

        s.bidFee = bidFee;
        s.askFee = askFee;

        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;

        _storeState(s, trade.timestamp);
        return (bidFee, askFee);
    }

    function _rollStep(State memory s, uint256 lastTs, uint256 ts) internal pure {
        if (ts <= lastTs) return;

        uint256 elapsedRaw = ts - lastTs;
        uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

        s.dirState = _decayCentered(s.dirState, DIR_DECAY, elapsed);
        s.actEma = wmul(s.actEma, _powWad(ACT_DECAY, elapsed));
        s.sizeHat = wmul(s.sizeHat, _powWad(SIZE_DECAY, elapsed));
        s.toxFast = wmul(s.toxFast, _powWad(TOX_FAST_DECAY, elapsed));
        s.toxSlow = wmul(s.toxSlow, _powWad(TOX_SLOW_DECAY, elapsed));
        s.sigmaHat = wmul(s.sigmaHat, _powWad(SIGMA_DECAY, elapsed));

        uint256 confKeep = _powWad(CONF_DECAY, elapsed);
        s.confEma = wmul(s.confEma, confKeep) + wmul(CONF_NEUTRAL, WAD - confKeep);

        if (s.stepTradeCount > 0 && elapsedRaw > 0) {
            uint256 lambdaInst = (s.stepTradeCount * WAD) / elapsedRaw;
            if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
            s.lambdaHat = wmul(s.lambdaHat, LAMBDA_KEEP) + wmul(lambdaInst, WAD - LAMBDA_KEEP);
        } else {
            s.lambdaHat = wmul(s.lambdaHat, LAMBDA_IDLE_DECAY);
        }

        s.stepTradeCount = 0;
    }

    function _updateReferenceAndVol(State memory s, uint256 pImplied, uint256 ret, bool firstInStep, bool likelyArb)
        internal
        pure
    {
        uint256 alphaBase;
        if (firstInStep) {
            alphaBase = likelyArb ? REF_ALPHA_FIRST_ARB : REF_ALPHA_FIRST_RETAIL;
        } else {
            alphaBase = REF_ALPHA_FOLLOW;
        }

        uint256 confMult = REF_ALPHA_CONF_FLOOR + wmul(REF_ALPHA_CONF_SPAN, s.confEma);
        uint256 alpha = wmul(alphaBase, confMult);

        if (ret > SHOCK_GATE) alpha = wmul(alpha, SHOCK_DAMP);

        uint256 sigmaAlpha = firstInStep ? SIGMA_ALPHA_FIRST : SIGMA_ALPHA_FOLLOW;
        uint256 sigmaInput = firstInStep ? ret : ret / 3;

        s.pRef = _blendAlpha(s.pRef, pImplied, alpha);
        s.sigmaHat = _blendAlpha(s.sigmaHat, sigmaInput, sigmaAlpha);
    }

    function _updateFlowSignals(State memory s, uint256 tradeRatio, bool isBuy, bool firstInStep) internal pure {
        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = tradeRatio * DIR_PUSH_MULT;
            if (push > DIR_PUSH_CAP) push = DIR_PUSH_CAP;

            if (isBuy) {
                s.dirState = s.dirState + push;
                if (s.dirState > 2 * WAD) s.dirState = 2 * WAD;
            } else {
                s.dirState = s.dirState > push ? s.dirState - push : 0;
            }
        }

        s.actEma = _blendAlpha(s.actEma, tradeRatio, firstInStep ? ACT_ALPHA_FIRST : ACT_ALPHA_FOLLOW);
        s.sizeHat = _blendAlpha(s.sizeHat, tradeRatio, firstInStep ? SIZE_ALPHA_FIRST : SIZE_ALPHA_FOLLOW);
        if (s.sizeHat > WAD) s.sizeHat = WAD;
    }

    function _updateToxicityConfidenceStress(State memory s, uint256 toxInst, uint256 ret, bool firstInStep)
        internal
        pure
        returns (uint256 flowPressure, uint256 toxGap, uint256 stress)
    {
        s.toxFast = _blendAlpha(s.toxFast, toxInst, TOX_FAST_ALPHA);
        s.toxSlow = _blendAlpha(s.toxSlow, toxInst, firstInStep ? TOX_SLOW_ALPHA_FIRST : TOX_SLOW_ALPHA_FOLLOW);

        flowPressure = wmul(s.lambdaHat, s.sizeHat);
        if (flowPressure > FLOW_CAP) flowPressure = FLOW_CAP;

        toxGap = absDiff(s.toxFast, s.toxSlow);

        uint256 retTerm = firstInStep ? ret : ret / 3;
        uint256 confPenalty = _computeConfPenalty(s, flowPressure, toxGap, retTerm);
        if (confPenalty > WAD) confPenalty = WAD;

        uint256 confInst = WAD - confPenalty;
        if (confInst < CONF_FLOOR) confInst = CONF_FLOOR;
        s.confEma = _blendAlpha(s.confEma, confInst, CONF_ALPHA);

        stress = _computeStress(s, flowPressure, toxGap, retTerm);
        if (stress > WAD) stress = WAD;
    }

    function _computeConfPenalty(State memory s, uint256 flowPressure, uint256 toxGap, uint256 retTerm)
        internal
        pure
        returns (uint256)
    {
        uint256 penalty = wmul(CONF_TOX_W, s.toxSlow);
        penalty = penalty + wmul(CONF_VOL_W, s.sigmaHat);
        penalty = penalty + wmul(CONF_FLOW_W, flowPressure);
        penalty = penalty + wmul(CONF_GAP_W, toxGap);
        penalty = penalty + wmul(CONF_ACT_W, s.actEma);
        penalty = penalty + wmul(CONF_RET_W, retTerm);
        return penalty;
    }

    function _computeStress(State memory s, uint256 flowPressure, uint256 toxGap, uint256 retTerm)
        internal
        pure
        returns (uint256)
    {
        uint256 stressValue = wmul(STRESS_TOX_W, s.toxSlow);
        stressValue = stressValue + wmul(STRESS_VOL_W, s.sigmaHat);
        stressValue = stressValue + wmul(STRESS_FLOW_W, flowPressure);
        stressValue = stressValue + wmul(STRESS_GAP_W, toxGap);
        stressValue = stressValue + wmul(STRESS_CONF_W, WAD - s.confEma);
        stressValue = stressValue + wmul(STRESS_RET_W, retTerm);
        stressValue = stressValue + wmul(STRESS_ACT_W, s.actEma);
        return stressValue;
    }

    function _hasAgreement(State memory s, uint256 flowPressure, uint256 toxGap, uint256 ret)
        internal
        pure
        returns (bool)
    {
        return
            s.toxSlow >= AGREE_TOX_GATE && s.sigmaHat >= AGREE_SIGMA_GATE && flowPressure >= AGREE_FLOW_GATE
                && (toxGap >= AGREE_GAP_GATE || ret >= RET_DEADBAND);
    }

    function _computeMidTarget(State memory s, uint256 flowPressure, uint256 stress, uint256 ret, bool firstInStep, bool agree)
        internal
        pure
        returns (uint256 midTarget)
    {
        uint256 toxExcess = s.toxSlow > TOX_KNEE ? s.toxSlow - TOX_KNEE : 0;
        uint256 toxQuad = wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        if (toxQuad > TOX_QUAD_CAP) toxQuad = TOX_QUAD_CAP;

        midTarget = BASE_FEE;
        midTarget = midTarget + wmul(SIGMA_COEF, s.sigmaHat);
        midTarget = midTarget + wmul(LAMBDA_COEF, s.lambdaHat);
        midTarget = midTarget + wmul(FLOW_COEF, flowPressure);
        midTarget = midTarget + wmul(TOX_COEF, s.toxSlow);
        midTarget = midTarget + toxQuad;
        midTarget = midTarget + wmul(STRESS_GUARD_COEF, stress);
        midTarget = midTarget + wmul(LOW_CONF_GUARD_COEF, WAD - s.confEma);

        if (firstInStep && ret >= RET_DEADBAND) midTarget = midTarget + FIRST_REVEAL_MID_ADD;
        if (agree) midTarget = midTarget + AGREE_MID_ADD;

        uint256 relief = wmul(CONF_RELIEF_COEF, wmul(s.confEma, WAD - stress));
        midTarget = midTarget > relief ? midTarget - relief : MID_FLOOR;
        if (midTarget < MID_FLOOR) midTarget = MID_FLOOR;
    }

    function _computeSpreadTarget(
        State memory s,
        uint256 flowPressure,
        uint256 stress,
        uint256 ret,
        bool firstInStep,
        bool agree
    ) internal pure returns (uint256 spreadTarget) {
        uint256 retTerm = firstInStep ? ret : ret / 4;

        spreadTarget = SPREAD_BASE;
        spreadTarget = spreadTarget + wmul(SPREAD_STRESS_COEF, stress);
        spreadTarget = spreadTarget + wmul(SPREAD_TOX_COEF, s.toxFast);
        spreadTarget = spreadTarget + wmul(SPREAD_FLOW_COEF, flowPressure);
        spreadTarget = spreadTarget + wmul(SPREAD_RET_COEF, retTerm);
        spreadTarget = spreadTarget + wmul(SPREAD_ACT_COEF, s.actEma);

        if (firstInStep && ret >= RET_DEADBAND) spreadTarget = spreadTarget + FIRST_REVEAL_SPREAD_ADD;
        if (agree) spreadTarget = spreadTarget + AGREE_SPREAD_ADD;

        uint256 relief = wmul(SPREAD_CONF_RELIEF_COEF, wmul(s.confEma, WAD - s.toxSlow));
        spreadTarget = spreadTarget > relief ? spreadTarget - relief : SPREAD_MIN;

        if (spreadTarget < SPREAD_MIN) spreadTarget = SPREAD_MIN;
        if (spreadTarget > SPREAD_MAX) spreadTarget = SPREAD_MAX;
    }

    function _quoteSides(State memory s, uint256 mid, uint256 spread, uint256 stress, uint256 spot)
        internal
        pure
        returns (uint256 bidFee, uint256 askFee)
    {
        (uint256 dirDev, bool protectBid) = _direction(s.dirState);
        uint256 skew = wmul(DIR_COEF, dirDev) + wmul(DIR_STRESS_COEF, wmul(dirDev, stress));
        if (skew > SKEW_CAP) skew = SKEW_CAP;

        uint256 halfSpread = spread / 2;

        if (protectBid) {
            bidFee = mid + halfSpread + skew;
            askFee = mid > halfSpread ? mid - halfSpread : 0;
        } else {
            askFee = mid + halfSpread + skew;
            bidFee = mid > halfSpread ? mid - halfSpread : 0;
        }

        uint256 vulnAdd = wmul(VULN_TOX_COEF, s.toxFast) + wmul(VULN_STRESS_COEF, wmul(stress, WAD - s.confEma));
        uint256 attractCut = wmul(ATTRACT_COEF, wmul(s.confEma, WAD - stress));

        if (spot >= s.pRef) {
            bidFee = bidFee + vulnAdd;
            askFee = askFee > attractCut ? askFee - attractCut : 0;
        } else {
            askFee = askFee + vulnAdd;
            bidFee = bidFee > attractCut ? bidFee - attractCut : 0;
        }
    }

    function _enforceCoherence(uint256 bidFee, uint256 askFee, uint256 stress) internal pure returns (uint256, uint256) {
        if (bidFee > askFee) {
            uint256 diff = bidFee - askFee;
            if (diff > MAX_SIDE_DIFF) {
                uint256 cut = diff - MAX_SIDE_DIFF;
                bidFee = bidFee > cut ? bidFee - cut : 0;
            }
        } else {
            uint256 diff = askFee - bidFee;
            if (diff > MAX_SIDE_DIFF) {
                uint256 cut = diff - MAX_SIDE_DIFF;
                askFee = askFee > cut ? askFee - cut : 0;
            }
        }

        uint256 minSide = bidFee < askFee ? bidFee : askFee;
        uint256 liqCeil = LIQUIDITY_CEIL_BASE + wmul(LIQUIDITY_CEIL_STRESS, stress);
        if (liqCeil > MAX_FEE) liqCeil = MAX_FEE;

        if (minSide > liqCeil) {
            uint256 cutBoth = minSide - liqCeil;
            bidFee = bidFee > cutBoth ? bidFee - cutBoth : 0;
            askFee = askFee > cutBoth ? askFee - cutBoth : 0;
        }

        if (bidFee < MIN_SIDE_FEE) bidFee = MIN_SIDE_FEE;
        if (askFee < MIN_SIDE_FEE) askFee = MIN_SIDE_FEE;

        return (bidFee, askFee);
    }

    function _tailAndClamp(uint256 bidFee, uint256 askFee) internal pure returns (uint256, uint256) {
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
        return (bidFee, askFee);
    }

    function _loadState() internal view returns (State memory s) {
        s.bidFee = slots[0];
        s.askFee = slots[1];
        s.pRef = slots[3];
        s.sigmaHat = slots[4];
        s.lambdaHat = slots[5];
        s.sizeHat = slots[6];
        s.toxFast = slots[7];
        s.toxSlow = slots[8];
        s.actEma = slots[9];
        s.dirState = slots[10];
        s.confEma = slots[11];
        s.stepTradeCount = slots[12];
    }

    function _storeState(State memory s, uint256 timestamp) internal {
        slots[0] = s.bidFee;
        slots[1] = s.askFee;
        slots[2] = timestamp;
        slots[3] = s.pRef;
        slots[4] = s.sigmaHat;
        slots[5] = s.lambdaHat;
        slots[6] = s.sizeHat;
        slots[7] = s.toxFast;
        slots[8] = s.toxSlow;
        slots[9] = s.actEma;
        slots[10] = s.dirState;
        slots[11] = s.confEma;
        slots[12] = s.stepTradeCount;
    }

    function _direction(uint256 dirState) internal pure returns (uint256 dirDev, bool protectBid) {
        if (dirState >= WAD) {
            dirDev = dirState - WAD;
            protectBid = true;
        } else {
            dirDev = WAD - dirState;
            protectBid = false;
        }
    }

    function _impliedPrice(uint256 spot, uint256 feeUsed, bool isBuy) internal pure returns (uint256) {
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        if (gamma == 0) return spot;
        return isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
    }

    function _blendAlpha(uint256 prev, uint256 value, uint256 alpha) internal pure returns (uint256) {
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
        return "wildcard_mod_v264";
    }
}
