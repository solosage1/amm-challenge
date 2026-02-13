pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_WILDCARD_273_DUAL_SURFACE","confidence":0.66,"ceiling_probability":0.31,"ev_next_5":0.08,"best_delta_seen":2.3074,"reason":"promotion_edge 519.29 supports T3 dual-objective wildcard with bounded fees, coherent spread behavior, and no pathological liquidity collapse","next_mechanism":"wildcard"}

    struct State {
        uint256 bidFee;
        uint256 askFee;
        uint256 lastTs;
        uint256 dirState;
        uint256 actEma;
        uint256 pRef;
        uint256 sigmaHat;
        uint256 lambdaHat;
        uint256 sizeHat;
        uint256 toxEma;
        uint256 stepTradeCount;
        uint256 revealEma;
        uint256 stressEma;
        uint256 confEma;
        uint256 imbalState;
    }

    struct Obs {
        bool firstInStep;
        bool likelyArb;
        uint256 spot;
        uint256 pImplied;
        uint256 tradeRatio;
        uint256 ret;
        uint256 reveal;
        uint256 prevTox;
        uint256 prevStress;
        uint256 prevConf;
    }

    struct RiskCtx {
        uint256 flow;
        uint256 riskScale;
        uint256 agreeStrength;
    }

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant STEP_COUNT_CAP = 64;

    uint256 constant TRADE_RATIO_CAP = WAD / 5;
    uint256 constant ARB_MAX_RATIO = WAD / 380;
    uint256 constant SIGNAL_THRESHOLD = WAD / 900;

    uint256 constant RET_CAP = WAD / 10;
    uint256 constant RET_DEADBAND = 4 * BPS;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant FLOW_CAP = WAD / 18;
    uint256 constant LAMBDA_CAP = 5 * WAD;

    uint256 constant DIR_DECAY = 880000000000000000;
    uint256 constant IMB_DECAY = 920000000000000000;
    uint256 constant ACT_DECAY = 720000000000000000;
    uint256 constant SIZE_DECAY = 650000000000000000;
    uint256 constant TOX_DECAY = 920000000000000000;
    uint256 constant SIGMA_DECAY = 900000000000000000;
    uint256 constant REVEAL_DECAY = 880000000000000000;
    uint256 constant STRESS_DECAY = 900000000000000000;
    uint256 constant CONF_DECAY = 930000000000000000;

    uint256 constant LAMBDA_DECAY = 994000000000000000;
    uint256 constant LAMBDA_IDLE_DECAY = 998800000000000000;

    uint256 constant ACT_BLEND_DECAY = 992000000000000000;
    uint256 constant SIZE_BLEND_DECAY = 820000000000000000;
    uint256 constant TOX_BLEND_ALPHA = 120000000000000000;

    uint256 constant PHAT_ALPHA_FIRST_ARB = 320000000000000000;
    uint256 constant PHAT_ALPHA_FIRST_FLOW = 120000000000000000;
    uint256 constant PHAT_ALPHA_FOLLOW = 50000000000000000;
    uint256 constant PHAT_SHOCK_GATE = 30 * BPS;
    uint256 constant PHAT_SHOCK_DAMP = 650000000000000000;

    uint256 constant SIGMA_ALPHA_ARB = 240000000000000000;
    uint256 constant SIGMA_ALPHA_FLOW = 110000000000000000;
    uint256 constant SIGMA_ALPHA_FOLLOW = 60000000000000000;

    uint256 constant REVEAL_ALPHA_FIRST = 260000000000000000;
    uint256 constant REVEAL_ALPHA_FOLLOW = 70000000000000000;

    uint256 constant STRESS_ALPHA = 180000000000000000;
    uint256 constant CONF_ALPHA = 160000000000000000;
    uint256 constant CONF_NEUTRAL = 760000000000000000;

    uint256 constant DIR_PUSH_CAP = WAD / 4;
    uint256 constant IMB_PUSH_CAP = WAD / 5;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant MID_FLOOR = 2 * BPS;
    uint256 constant MIN_SIDE_FEE = BPS;

    uint256 constant SIGMA_COEF = 185000000000000000;
    uint256 constant LAMBDA_COEF = 11 * BPS;
    uint256 constant FLOW_COEF = 6500 * BPS;
    uint256 constant ACT_COEF = 18000 * BPS;
    uint256 constant TOX_COEF = 170 * BPS;
    uint256 constant TOX_QUAD_COEF = 15000 * BPS;
    uint256 constant TOX_QUAD_KNEE = 12 * BPS;
    uint256 constant TOX_QUAD_CAP = 170 * BPS;

    uint256 constant STRESS_MID_COEF = 95 * BPS;
    uint256 constant LOW_CONF_MID_COEF = 70 * BPS;
    uint256 constant CONF_RELIEF_COEF = 75 * BPS;
    uint256 constant REVEAL_MID_COEF = 60 * BPS;
    uint256 constant AGREE_MID_COEF = 14 * BPS;

    uint256 constant SPREAD_BASE = 6 * BPS;
    uint256 constant SPREAD_MIN = 3 * BPS;
    uint256 constant SPREAD_MAX = 130 * BPS;
    uint256 constant SPREAD_STRESS_COEF = 120 * BPS;
    uint256 constant SPREAD_TOX_COEF = 90 * BPS;
    uint256 constant SPREAD_FLOW_COEF = 75 * BPS;
    uint256 constant SPREAD_REVEAL_COEF = 95 * BPS;
    uint256 constant SPREAD_AGREE_COEF = 16 * BPS;
    uint256 constant SPREAD_CONF_RELIEF_COEF = 70 * BPS;

    uint256 constant MID_UP_BASE = 26 * BPS;
    uint256 constant MID_UP_STRESS = 70 * BPS;
    uint256 constant MID_DOWN_BASE = 40 * BPS;
    uint256 constant MID_DOWN_CONF = 65 * BPS;

    uint256 constant SPREAD_UP_BASE = 24 * BPS;
    uint256 constant SPREAD_UP_STRESS = 85 * BPS;
    uint256 constant SPREAD_DOWN_BASE = 38 * BPS;
    uint256 constant SPREAD_DOWN_CONF = 60 * BPS;

    uint256 constant STRESS_SIGMA_W = 1200000000000000000;
    uint256 constant STRESS_TOX_W = 1750000000000000000;
    uint256 constant STRESS_FLOW_W = 900000000000000000;
    uint256 constant STRESS_REVEAL_W = 1200000000000000000;
    uint256 constant STRESS_ACT_W = 400000000000000000;

    uint256 constant CONF_SIGMA_W = 3600000000000000000;
    uint256 constant CONF_TOX_W = 4800000000000000000;
    uint256 constant CONF_FLOW_W = 1400000000000000000;
    uint256 constant CONF_REVEAL_W = 2200000000000000000;
    uint256 constant CONF_MIN = 250000000000000000;
    uint256 constant CONF_MAX = 980000000000000000;

    uint256 constant AGREE_TOX_GATE = 10 * BPS;
    uint256 constant AGREE_SIGMA_GATE = 8 * BPS;
    uint256 constant AGREE_FLOW_GATE = 1200000000000000;
    uint256 constant AGREE_REVEAL_GATE = 5 * BPS;
    uint256 constant LOW_AGREE_DAMP = 620000000000000000;

    uint256 constant DIR_COEF = 82 * BPS;
    uint256 constant DIR_TOX_COEF = 18 * BPS;
    uint256 constant IMB_COEF = 40 * BPS;
    uint256 constant DIR_STRESS_COEF = 24 * BPS;
    uint256 constant SKEW_CAP = 120 * BPS;

    uint256 constant VULN_TOX_COEF = 115 * BPS;
    uint256 constant VULN_STRESS_COEF = 105 * BPS;
    uint256 constant VULN_LOW_CONF_COEF = 95 * BPS;
    uint256 constant AGREE_SIDE_COEF = 12 * BPS;
    uint256 constant ATTRACT_COEF = 95 * BPS;
    uint256 constant REVEAL_SHIFT_COEF = 55 * BPS;
    uint256 constant SIDE_UP_CAP = 85 * BPS;
    uint256 constant SIDE_DOWN_CAP = 110 * BPS;

    uint256 constant MAX_SIDE_DIFF = 220 * BPS;
    uint256 constant LIQ_CEIL_BASE = 220 * BPS;
    uint256 constant LIQ_CEIL_STRESS = 520 * BPS;

    uint256 constant TAIL_KNEE = 700 * BPS;
    uint256 constant TAIL_SLOPE_NEUTRAL = 900000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 850000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 960000000000000000;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;

        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD;
        slots[4] = 0;
        slots[5] = p0;
        slots[6] = 9 * BPS;
        slots[7] = 800000000000000000;
        slots[8] = 2000000000000000;
        slots[9] = 0;
        slots[10] = 0;
        slots[11] = 0;
        slots[12] = 0;
        slots[13] = CONF_NEUTRAL;
        slots[14] = WAD;

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        State memory s = _loadState();

        _applyStepDecay(s, trade.timestamp);
        Obs memory o = _observeTrade(s, trade);
        _updateSignals(s, o, trade);

        (uint256 bidFee, uint256 askFee) = _computeQuotes(s, o);

        s.bidFee = bidFee;
        s.askFee = askFee;
        s.lastTs = trade.timestamp;
        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;

        _storeState(s);

        return (bidFee, askFee);
    }

    function _loadState() internal view returns (State memory s) {
        s.bidFee = slots[0];
        s.askFee = slots[1];
        s.lastTs = slots[2];
        s.dirState = slots[3];
        s.actEma = slots[4];
        s.pRef = slots[5];
        s.sigmaHat = slots[6];
        s.lambdaHat = slots[7];
        s.sizeHat = slots[8];
        s.toxEma = slots[9];
        s.stepTradeCount = slots[10];
        s.revealEma = slots[11];
        s.stressEma = slots[12];
        s.confEma = slots[13];
        s.imbalState = slots[14];
    }

    function _storeState(State memory s) internal {
        slots[0] = s.bidFee;
        slots[1] = s.askFee;
        slots[2] = s.lastTs;
        slots[3] = s.dirState;
        slots[4] = s.actEma;
        slots[5] = s.pRef;
        slots[6] = s.sigmaHat;
        slots[7] = s.lambdaHat;
        slots[8] = s.sizeHat;
        slots[9] = s.toxEma;
        slots[10] = s.stepTradeCount;
        slots[11] = s.revealEma;
        slots[12] = s.stressEma;
        slots[13] = s.confEma;
        slots[14] = s.imbalState;
    }

    function _applyStepDecay(State memory s, uint256 timestamp) internal pure {
        if (timestamp <= s.lastTs) return;

        uint256 elapsedRaw = timestamp - s.lastTs;
        uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

        s.dirState = _decayCentered(s.dirState, DIR_DECAY, elapsed);
        s.imbalState = _decayCentered(s.imbalState, IMB_DECAY, elapsed);
        s.actEma = wmul(s.actEma, _powWad(ACT_DECAY, elapsed));
        s.sizeHat = wmul(s.sizeHat, _powWad(SIZE_DECAY, elapsed));
        s.toxEma = wmul(s.toxEma, _powWad(TOX_DECAY, elapsed));
        s.sigmaHat = wmul(s.sigmaHat, _powWad(SIGMA_DECAY, elapsed));
        s.revealEma = wmul(s.revealEma, _powWad(REVEAL_DECAY, elapsed));
        s.stressEma = wmul(s.stressEma, _powWad(STRESS_DECAY, elapsed));

        uint256 confMul = _powWad(CONF_DECAY, elapsed);
        s.confEma = wmul(s.confEma, confMul) + wmul(CONF_NEUTRAL, WAD - confMul);

        if (s.stepTradeCount > 0 && elapsedRaw > 0) {
            uint256 lambdaInst = (s.stepTradeCount * WAD) / elapsedRaw;
            if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
            s.lambdaHat = wmul(s.lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
        } else {
            s.lambdaHat = wmul(s.lambdaHat, LAMBDA_IDLE_DECAY);
        }

        s.stepTradeCount = 0;
    }

    function _observeTrade(State memory s, TradeInfo calldata trade) internal pure returns (Obs memory o) {
        o.firstInStep = s.stepTradeCount == 0;

        uint256 pBase = s.pRef > 0 ? s.pRef : 100 * WAD;
        o.spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pBase;

        uint256 feeUsed = trade.isBuy ? s.bidFee : s.askFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        if (gamma == 0) {
            o.pImplied = o.spot;
        } else {
            o.pImplied = trade.isBuy ? wmul(o.spot, gamma) : wdiv(o.spot, gamma);
        }

        o.tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (o.tradeRatio > TRADE_RATIO_CAP) o.tradeRatio = TRADE_RATIO_CAP;

        o.likelyArb = o.firstInStep && o.tradeRatio <= ARB_MAX_RATIO;

        o.ret = pBase > 0 ? wdiv(absDiff(o.pImplied, pBase), pBase) : 0;
        if (o.ret > RET_CAP) o.ret = RET_CAP;

        o.reveal = o.ret > RET_DEADBAND ? o.ret - RET_DEADBAND : 0;

        o.prevTox = s.toxEma;
        o.prevStress = s.stressEma;
        o.prevConf = s.confEma;
    }

    function _updateSignals(State memory s, Obs memory o, TradeInfo calldata trade) internal pure {
        _updateReferenceSignals(s, o);
        _updateDirectionalSignals(s, o.tradeRatio, trade.isBuy);
        _updateRiskSignals(s, o.spot);
    }

    function _updateReferenceSignals(State memory s, Obs memory o) internal pure {
        if (s.pRef == 0) s.pRef = o.spot > 0 ? o.spot : 100 * WAD;

        uint256 pAlpha = o.firstInStep ? (o.likelyArb ? PHAT_ALPHA_FIRST_ARB : PHAT_ALPHA_FIRST_FLOW) : PHAT_ALPHA_FOLLOW;
        if (o.ret > PHAT_SHOCK_GATE) pAlpha = wmul(pAlpha, PHAT_SHOCK_DAMP);
        s.pRef = _blend(s.pRef, o.pImplied, pAlpha);

        uint256 sigmaInput;
        uint256 sigmaAlpha;
        if (o.firstInStep) {
            sigmaInput = o.likelyArb ? o.ret : o.ret / 3;
            sigmaAlpha = o.likelyArb ? SIGMA_ALPHA_ARB : SIGMA_ALPHA_FLOW;
        } else {
            sigmaInput = o.ret / 5;
            sigmaAlpha = SIGMA_ALPHA_FOLLOW;
        }
        s.sigmaHat = _blend(s.sigmaHat, sigmaInput, sigmaAlpha);

        uint256 revealInput = o.firstInStep ? o.reveal : o.reveal / 3;
        uint256 revealAlpha = o.firstInStep ? REVEAL_ALPHA_FIRST : REVEAL_ALPHA_FOLLOW;
        s.revealEma = _blend(s.revealEma, revealInput, revealAlpha);
    }

    function _updateDirectionalSignals(State memory s, uint256 tradeRatio, bool isBuy) internal pure {
        if (tradeRatio <= SIGNAL_THRESHOLD) return;

        uint256 push = tradeRatio;
        if (push > DIR_PUSH_CAP) push = DIR_PUSH_CAP;
        if (isBuy) {
            s.dirState = s.dirState + push;
            if (s.dirState > 2 * WAD) s.dirState = 2 * WAD;
        } else {
            s.dirState = s.dirState > push ? s.dirState - push : 0;
        }

        uint256 imbPush = tradeRatio;
        if (imbPush > IMB_PUSH_CAP) imbPush = IMB_PUSH_CAP;
        if (isBuy) {
            s.imbalState = s.imbalState + imbPush;
            if (s.imbalState > 2 * WAD) s.imbalState = 2 * WAD;
        } else {
            s.imbalState = s.imbalState > imbPush ? s.imbalState - imbPush : 0;
        }

        s.actEma = wmul(s.actEma, ACT_BLEND_DECAY) + wmul(tradeRatio, WAD - ACT_BLEND_DECAY);
        s.sizeHat = wmul(s.sizeHat, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
        if (s.sizeHat > WAD) s.sizeHat = WAD;
    }

    function _updateRiskSignals(State memory s, uint256 spot) internal pure {
        uint256 toxInst = s.pRef > 0 ? wdiv(absDiff(spot, s.pRef), s.pRef) : 0;
        if (toxInst > TOX_CAP) toxInst = TOX_CAP;
        s.toxEma = _blend(s.toxEma, toxInst, TOX_BLEND_ALPHA);

        uint256 flow = wmul(s.lambdaHat, s.sizeHat);
        if (flow > FLOW_CAP) flow = FLOW_CAP;

        uint256 stressRaw = wmul(STRESS_SIGMA_W, s.sigmaHat);
        stressRaw = stressRaw + wmul(STRESS_TOX_W, s.toxEma);
        stressRaw = stressRaw + wmul(STRESS_FLOW_W, flow);
        stressRaw = stressRaw + wmul(STRESS_REVEAL_W, s.revealEma);
        stressRaw = stressRaw + wmul(STRESS_ACT_W, s.actEma);
        if (stressRaw > WAD) stressRaw = WAD;
        s.stressEma = _blend(s.stressEma, stressRaw, STRESS_ALPHA);

        uint256 confPenalty = wmul(CONF_SIGMA_W, s.sigmaHat);
        confPenalty = confPenalty + wmul(CONF_TOX_W, s.toxEma);
        confPenalty = confPenalty + wmul(CONF_FLOW_W, flow);
        confPenalty = confPenalty + wmul(CONF_REVEAL_W, s.revealEma);
        if (confPenalty > WAD) confPenalty = WAD;

        uint256 confRaw = WAD - confPenalty;
        if (confRaw < CONF_MIN) confRaw = CONF_MIN;
        if (confRaw > CONF_MAX) confRaw = CONF_MAX;

        s.confEma = _blend(s.confEma, confRaw, CONF_ALPHA);
        if (s.confEma < CONF_MIN) s.confEma = CONF_MIN;
    }

    function _computeQuotes(State memory s, Obs memory o) internal pure returns (uint256 bidFee, uint256 askFee) {
        (uint256 mid, uint256 spread, uint256 riskScale, uint256 agreeStrength) = _midAndSpread(s, o);
        (bidFee, askFee) = _baseDirectionalQuotes(s, mid, spread);
        (bidFee, askFee) = _applyVulnerabilityAdjust(bidFee, askFee, s, o, riskScale, agreeStrength);
        (bidFee, askFee) = _sanitizeQuotes(bidFee, askFee, s.stressEma);
    }

    function _baseDirectionalQuotes(State memory s, uint256 mid, uint256 spread) internal pure returns (uint256, uint256) {
        uint256 dirDev;
        bool protectBid;
        if (s.dirState >= WAD) {
            dirDev = s.dirState - WAD;
            protectBid = true;
        } else {
            dirDev = WAD - s.dirState;
            protectBid = false;
        }

        uint256 imbDev = s.imbalState >= WAD ? s.imbalState - WAD : WAD - s.imbalState;

        uint256 skew = wmul(DIR_COEF, dirDev);
        skew = skew + wmul(DIR_TOX_COEF, wmul(dirDev, s.toxEma));
        skew = skew + wmul(IMB_COEF, imbDev);
        skew = skew + wmul(DIR_STRESS_COEF, wmul(dirDev, s.stressEma));
        if (skew > SKEW_CAP) skew = SKEW_CAP;

        uint256 center = mid + (spread / 2);
        if (protectBid) {
            return (center + skew, center > skew ? center - skew : 0);
        }
        return (center > skew ? center - skew : 0, center + skew);
    }

    function _midAndSpread(State memory s, Obs memory o)
        internal
        pure
        returns (uint256 mid, uint256 spread, uint256 riskScale, uint256 agreeStrength)
    {
        RiskCtx memory r = _riskContext(s);
        uint256 midTarget = _midTarget(s, o, r);
        uint256 spreadTarget = _spreadTarget(s, r);
        riskScale = r.riskScale;
        agreeStrength = r.agreeStrength;
        (mid, spread) = _boundMidSpread(s, midTarget, spreadTarget);
    }

    function _boundMidSpread(State memory s, uint256 midTarget, uint256 spreadTarget)
        internal
        pure
        returns (uint256 mid, uint256 spread)
    {
        uint256 prevMid = (s.bidFee + s.askFee) / 2;
        uint256 prevSpread = absDiff(s.bidFee, s.askFee);

        uint256 midUpCap = MID_UP_BASE + wmul(MID_UP_STRESS, s.stressEma);
        uint256 midDownCap = MID_DOWN_BASE + wmul(MID_DOWN_CONF, wmul(s.confEma, WAD - s.stressEma));
        uint256 spreadUpCap = SPREAD_UP_BASE + wmul(SPREAD_UP_STRESS, s.stressEma);
        uint256 spreadDownCap = SPREAD_DOWN_BASE + wmul(SPREAD_DOWN_CONF, wmul(s.confEma, WAD - s.stressEma));

        mid = _capMove(midTarget, prevMid, midUpCap, midDownCap);
        spread = _capMove(spreadTarget, prevSpread, spreadUpCap, spreadDownCap);

        if (mid < MID_FLOOR) mid = MID_FLOOR;
        if (spread < SPREAD_MIN) spread = SPREAD_MIN;
        if (spread > SPREAD_MAX) spread = SPREAD_MAX;
    }

    function _riskContext(State memory s) internal pure returns (RiskCtx memory r) {
        r.flow = wmul(s.lambdaHat, s.sizeHat);
        if (r.flow > FLOW_CAP) r.flow = FLOW_CAP;

        uint256 agreeCount;
        if (s.toxEma >= AGREE_TOX_GATE) agreeCount = agreeCount + 1;
        if (s.sigmaHat >= AGREE_SIGMA_GATE) agreeCount = agreeCount + 1;
        if (r.flow >= AGREE_FLOW_GATE) agreeCount = agreeCount + 1;
        if (s.revealEma >= AGREE_REVEAL_GATE) agreeCount = agreeCount + 1;

        r.agreeStrength = agreeCount >= 3 ? (agreeCount * WAD) / 4 : 0;
        r.riskScale = agreeCount >= 2 ? WAD : LOW_AGREE_DAMP;
    }

    function _midTarget(State memory s, Obs memory o, RiskCtx memory r) internal pure returns (uint256 midTarget) {
        uint256 toxExcess = s.toxEma > TOX_QUAD_KNEE ? s.toxEma - TOX_QUAD_KNEE : 0;
        uint256 toxQuad = wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        if (toxQuad > TOX_QUAD_CAP) toxQuad = TOX_QUAD_CAP;

        uint256 guardMid = wmul(TOX_COEF, s.toxEma);
        guardMid = guardMid + toxQuad;
        guardMid = guardMid + wmul(STRESS_MID_COEF, s.stressEma);
        guardMid = guardMid + wmul(LOW_CONF_MID_COEF, WAD - s.confEma);
        guardMid = wmul(guardMid, r.riskScale);

        midTarget = BASE_FEE;
        midTarget = midTarget + wmul(SIGMA_COEF, s.sigmaHat);
        midTarget = midTarget + wmul(LAMBDA_COEF, s.lambdaHat);
        midTarget = midTarget + wmul(FLOW_COEF, r.flow);
        midTarget = midTarget + wmul(ACT_COEF, s.actEma);
        midTarget = midTarget + guardMid;
        if (o.firstInStep && o.reveal > 0) midTarget = midTarget + wmul(REVEAL_MID_COEF, o.reveal);
        if (r.agreeStrength > 0) midTarget = midTarget + wmul(AGREE_MID_COEF, r.agreeStrength);

        uint256 midRelief = wmul(CONF_RELIEF_COEF, wmul(s.confEma, WAD - s.stressEma));
        midTarget = midTarget > midRelief ? midTarget - midRelief : MID_FLOOR;
    }

    function _spreadTarget(State memory s, RiskCtx memory r) internal pure returns (uint256 spreadTarget) {
        uint256 guardSpread = wmul(SPREAD_STRESS_COEF, s.stressEma);
        guardSpread = guardSpread + wmul(SPREAD_TOX_COEF, s.toxEma);
        guardSpread = guardSpread + wmul(SPREAD_FLOW_COEF, r.flow);
        guardSpread = guardSpread + wmul(SPREAD_REVEAL_COEF, s.revealEma);
        guardSpread = wmul(guardSpread, r.riskScale);

        spreadTarget = SPREAD_BASE + guardSpread;
        if (r.agreeStrength > 0) spreadTarget = spreadTarget + wmul(SPREAD_AGREE_COEF, r.agreeStrength);

        uint256 spreadRelief = wmul(SPREAD_CONF_RELIEF_COEF, wmul(s.confEma, WAD - s.stressEma));
        spreadTarget = spreadTarget > spreadRelief ? spreadTarget - spreadRelief : SPREAD_MIN;
    }

    function _applyVulnerabilityAdjust(
        uint256 bidFee,
        uint256 askFee,
        State memory s,
        Obs memory o,
        uint256 riskScale,
        uint256 agreeStrength
    ) internal pure returns (uint256, uint256) {
        uint256 vulnTarget = wmul(VULN_TOX_COEF, s.toxEma) + wmul(VULN_STRESS_COEF, s.stressEma)
            + wmul(VULN_LOW_CONF_COEF, WAD - s.confEma);
        if (agreeStrength > 0) vulnTarget = vulnTarget + wmul(AGREE_SIDE_COEF, agreeStrength);
        vulnTarget = wmul(vulnTarget, riskScale);

        uint256 prevVuln = wmul(VULN_TOX_COEF, o.prevTox) + wmul(VULN_STRESS_COEF, o.prevStress)
            + wmul(VULN_LOW_CONF_COEF, WAD - o.prevConf);

        uint256 vulnAdd;
        if (vulnTarget > prevVuln) {
            uint256 rise = vulnTarget - prevVuln;
            vulnAdd = rise > SIDE_UP_CAP ? prevVuln + SIDE_UP_CAP : vulnTarget;
        } else {
            uint256 drop = prevVuln - vulnTarget;
            vulnAdd = drop > SIDE_DOWN_CAP ? (prevVuln > SIDE_DOWN_CAP ? prevVuln - SIDE_DOWN_CAP : 0) : vulnTarget;
        }

        uint256 attractCut = wmul(ATTRACT_COEF, wmul(s.confEma, WAD - s.stressEma));
        uint256 revealShift = wmul(REVEAL_SHIFT_COEF, s.revealEma);

        if (o.spot >= s.pRef) {
            bidFee = bidFee + vulnAdd + revealShift;
            uint256 cut = attractCut + revealShift;
            askFee = askFee > cut ? askFee - cut : 0;
        } else {
            askFee = askFee + vulnAdd + revealShift;
            uint256 cut = attractCut + revealShift;
            bidFee = bidFee > cut ? bidFee - cut : 0;
        }

        return (bidFee, askFee);
    }

    function _sanitizeQuotes(uint256 bidFee, uint256 askFee, uint256 stressEma) internal pure returns (uint256, uint256) {
        if (bidFee > askFee) {
            uint256 diff = bidFee - askFee;
            if (diff > MAX_SIDE_DIFF) bidFee = askFee + MAX_SIDE_DIFF;
        } else {
            uint256 diff = askFee - bidFee;
            if (diff > MAX_SIDE_DIFF) askFee = bidFee + MAX_SIDE_DIFF;
        }

        uint256 liqCeil = LIQ_CEIL_BASE + wmul(LIQ_CEIL_STRESS, stressEma);
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
        return "wildcard_mod_v273";
    }
}
