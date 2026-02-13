pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_TOX_ACT_002","confidence":0.58,"ceiling_probability":0.31,"ev_next_5":0.034,"best_delta_seen":2.3074,"reason":"promotion_edge=519.30 high bar; T10 inventory path plus T9 agreement gating with bounded slew targets robust lift","next_mechanism":"wildcard"}

    uint256 constant IDX_BID = 0;
    uint256 constant IDX_ASK = 1;
    uint256 constant IDX_TS = 2;
    uint256 constant IDX_DIR = 3;
    uint256 constant IDX_FLOW = 4;
    uint256 constant IDX_PHAT = 5;
    uint256 constant IDX_SIGMA = 6;
    uint256 constant IDX_LAMBDA = 7;
    uint256 constant IDX_SIZE = 8;
    uint256 constant IDX_TOX = 9;
    uint256 constant IDX_STEP = 10;
    uint256 constant IDX_INV = 11;
    uint256 constant IDX_CONF = 12;
    uint256 constant IDX_AGREE = 13;

    uint256 constant ELAPSED_CAP = 12;
    uint256 constant SIGNAL_THRESHOLD = WAD / 900;

    uint256 constant DIR_DECAY = 860000000000000000;
    uint256 constant INV_DECAY = 920000000000000000;
    uint256 constant FLOW_DECAY = 760000000000000000;
    uint256 constant SIZE_DECAY = 650000000000000000;
    uint256 constant TOX_DECAY = 910000000000000000;
    uint256 constant SIGMA_DECAY = 840000000000000000;
    uint256 constant LAMBDA_DECAY = 994000000000000000;
    uint256 constant CONF_GAP_DECAY = 960000000000000000;
    uint256 constant AGREE_DECAY = 840000000000000000;

    uint256 constant SIZE_BLEND_DECAY = 820000000000000000;
    uint256 constant FLOW_BLEND_DECAY = 992000000000000000;
    uint256 constant TOX_BLEND_DECAY = 180000000000000000;
    uint256 constant SIGMA_BLEND_FIRST = 780000000000000000;
    uint256 constant SIGMA_BLEND_FOLLOW = 930000000000000000;
    uint256 constant AGREE_BLEND_DECAY = 860000000000000000;
    uint256 constant CONF_BLEND_DECAY = 900000000000000000;

    uint256 constant PHAT_ALPHA_ARB = 300000000000000000;
    uint256 constant PHAT_ALPHA_FLOW = 130000000000000000;
    uint256 constant PHAT_ALPHA_FOLLOW_MULT = 550000000000000000;
    uint256 constant PHAT_SHOCK_GATE = 35000000000000000;
    uint256 constant PHAT_SHOCK_MULT = 420000000000000000;
    uint256 constant PHAT_CONF_DAMP = 600000000000000000;
    uint256 constant PHAT_MIN_ALPHA = 6000000000000000;

    uint256 constant DIR_IMPACT_MULT = 1;
    uint256 constant INV_PUSH_MULT = 1200000000000000000;
    uint256 constant ARB_MAX_RATIO = WAD / 340;
    uint256 constant TOX_ARB_GATE = 7 * BPS;

    uint256 constant RET_CAP = WAD / 9;
    uint256 constant TOX_CAP = WAD / 4;
    uint256 constant TRADE_RATIO_CAP = WAD / 4;
    uint256 constant LAMBDA_CAP = 5 * WAD;
    uint256 constant FLOW_SIGNAL_CAP = 5 * WAD;
    uint256 constant STEP_COUNT_CAP = 96;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant SIGMA_COEF = 230000000000000000;
    uint256 constant LAMBDA_COEF = 10 * BPS;
    uint256 constant FLOW_SIZE_COEF = 6000 * BPS;
    uint256 constant FLOW_EMA_COEF = 2600 * BPS;
    uint256 constant TOX_COEF = 165 * BPS;
    uint256 constant TOX_QUAD_COEF = 17500 * BPS;
    uint256 constant TOX_QUAD_KNEE = 11 * BPS;
    uint256 constant TOX_QUAD_ADD_CAP = 155 * BPS;
    uint256 constant RISK_LIFT_COEF = 44 * BPS;

    uint256 constant PROTECT_MIN_MULT = 620000000000000000;
    uint256 constant PROTECT_AGREE_MULT = 920000000000000000;
    uint256 constant PROTECT_SINGLE_MULT = 700000000000000000;
    uint256 constant SPLIT_PROTECT_MULT = 420000000000000000;

    uint256 constant ATTRACT_COEF = 24 * BPS;
    uint256 constant ATTRACT_CAP = 90 * BPS;
    uint256 constant ATTRACT_TOX_DAMP = 700000000000000000;

    uint256 constant PRICE_TOX_COEF = 125 * BPS;
    uint256 constant DIR_COEF = 88 * BPS;
    uint256 constant INV_COEF = 118 * BPS;
    uint256 constant DIR_TOX_COEF = 18 * BPS;
    uint256 constant SKEW_CAP = 260 * BPS;

    uint256 constant TOX_AGREE_KNEE = 14 * BPS;
    uint256 constant SIGMA_AGREE_KNEE = 10 * BPS;
    uint256 constant FLOW_AGREE_KNEE = 2200000000000000;

    uint256 constant TOX_NORM = 120 * BPS;
    uint256 constant SIGMA_NORM = 50 * BPS;
    uint256 constant FLOW_NORM = 12000000000000000;
    uint256 constant AGREE_SINGLE_MULT = 350000000000000000;

    uint256 constant CONF_NEUTRAL = 760000000000000000;
    uint256 constant CONF_MIN = 380000000000000000;
    uint256 constant CONF_MAX = 940000000000000000;
    uint256 constant CONF_TOX_W = 420000000000000000;
    uint256 constant CONF_SIGMA_W = 340000000000000000;
    uint256 constant CONF_AGREE_W = 240000000000000000;
    uint256 constant CONF_FLOW_KNEE = 2000000000000000;
    uint256 constant CONF_FLOW_NORM = 12000000000000000;
    uint256 constant CONF_FLOW_BOOST = 180000000000000000;
    uint256 constant CONF_UNCERTAINTY_GATE = 550000000000000000;

    uint256 constant STEP_UP_BASE = 26 * BPS;
    uint256 constant STEP_UP_AGREE_MULT = 120 * BPS;
    uint256 constant STEP_DOWN_BASE = 34 * BPS;
    uint256 constant STEP_DOWN_CONF_MULT = 80 * BPS;
    uint256 constant STEP_DOWN_AGREE_DAMP = 500000000000000000;

    uint256 constant TAIL_KNEE = 650 * BPS;
    uint256 constant TAIL_SLOPE = 880000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 810000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 950000000000000000;

    uint256 constant TOX_CONF_SIGMA_KNEE = 12 * BPS;
    uint256 constant TOX_CONF_SIGMA_SPAN = 38 * BPS;
    uint256 constant TOX_CONF_MIN_MULT = 620000000000000000;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        slots[IDX_BID] = BASE_FEE;
        slots[IDX_ASK] = BASE_FEE;
        slots[IDX_TS] = 0;
        slots[IDX_DIR] = WAD;
        slots[IDX_FLOW] = 0;
        slots[IDX_PHAT] = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        slots[IDX_SIGMA] = 950000000000000;
        slots[IDX_LAMBDA] = 800000000000000000;
        slots[IDX_SIZE] = 2000000000000000;
        slots[IDX_TOX] = 0;
        slots[IDX_STEP] = 0;
        slots[IDX_INV] = WAD;
        slots[IDX_CONF] = CONF_NEUTRAL;
        slots[IDX_AGREE] = 0;
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256[14] memory s;
        s[IDX_BID] = slots[IDX_BID];
        s[IDX_ASK] = slots[IDX_ASK];
        s[IDX_TS] = slots[IDX_TS];
        s[IDX_DIR] = slots[IDX_DIR];
        s[IDX_FLOW] = slots[IDX_FLOW];
        s[IDX_PHAT] = slots[IDX_PHAT];
        s[IDX_SIGMA] = slots[IDX_SIGMA];
        s[IDX_LAMBDA] = slots[IDX_LAMBDA];
        s[IDX_SIZE] = slots[IDX_SIZE];
        s[IDX_TOX] = slots[IDX_TOX];
        s[IDX_STEP] = slots[IDX_STEP];
        s[IDX_INV] = slots[IDX_INV];
        s[IDX_CONF] = slots[IDX_CONF];
        s[IDX_AGREE] = slots[IDX_AGREE];

        uint256 prevBidFee = s[IDX_BID];
        uint256 prevAskFee = s[IDX_ASK];

        _onNewStep(s, trade.timestamp);

        uint256 spot = _updateFairAndFlowFromTrade(s, trade, prevBidFee, prevAskFee);

        (uint256 toxSignal, uint256 nTox, uint256 agreeCount) = _updateRiskAgreementConfidence(s, spot);

        (uint256 bidTarget, uint256 askTarget) = _computeFeeTargets(s, spot, toxSignal, nTox, agreeCount);
        (uint256 bidFee, uint256 askFee) = _finalizeFees(s, prevBidFee, prevAskFee, bidTarget, askTarget);

        s[IDX_STEP] = s[IDX_STEP] + 1;
        if (s[IDX_STEP] > STEP_COUNT_CAP) s[IDX_STEP] = STEP_COUNT_CAP;

        slots[IDX_BID] = bidFee;
        slots[IDX_ASK] = askFee;
        slots[IDX_TS] = trade.timestamp;
        slots[IDX_DIR] = s[IDX_DIR];
        slots[IDX_FLOW] = s[IDX_FLOW];
        slots[IDX_PHAT] = s[IDX_PHAT];
        slots[IDX_SIGMA] = s[IDX_SIGMA];
        slots[IDX_LAMBDA] = s[IDX_LAMBDA];
        slots[IDX_SIZE] = s[IDX_SIZE];
        slots[IDX_TOX] = s[IDX_TOX];
        slots[IDX_STEP] = s[IDX_STEP];
        slots[IDX_INV] = s[IDX_INV];
        slots[IDX_CONF] = s[IDX_CONF];
        slots[IDX_AGREE] = s[IDX_AGREE];

        return (bidFee, askFee);
    }

    function _onNewStep(uint256[14] memory s, uint256 timestamp) internal pure {
        if (timestamp <= s[IDX_TS]) return;

        uint256 elapsedRaw = timestamp - s[IDX_TS];
        uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

        s[IDX_DIR] = _decayCentered(s[IDX_DIR], DIR_DECAY, elapsed);
        s[IDX_INV] = _decayCentered(s[IDX_INV], INV_DECAY, elapsed);
        s[IDX_FLOW] = wmul(s[IDX_FLOW], _powWad(FLOW_DECAY, elapsed));
        s[IDX_SIZE] = wmul(s[IDX_SIZE], _powWad(SIZE_DECAY, elapsed));
        s[IDX_TOX] = wmul(s[IDX_TOX], _powWad(TOX_DECAY, elapsed));
        s[IDX_SIGMA] = wmul(s[IDX_SIGMA], _powWad(SIGMA_DECAY, elapsed));
        s[IDX_AGREE] = wmul(s[IDX_AGREE], _powWad(AGREE_DECAY, elapsed));

        uint256 confGapMul = _powWad(CONF_GAP_DECAY, elapsed);
        s[IDX_CONF] = wmul(s[IDX_CONF], confGapMul) + wmul(CONF_NEUTRAL, WAD - confGapMul);

        if (s[IDX_STEP] > 0 && elapsedRaw > 0) {
            uint256 lambdaInst = (s[IDX_STEP] * WAD) / elapsedRaw;
            if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
            s[IDX_LAMBDA] = wmul(s[IDX_LAMBDA], LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
        }

        s[IDX_STEP] = 0;
    }

    function _updateFairAndFlowFromTrade(
        uint256[14] memory s,
        TradeInfo calldata trade,
        uint256 prevBidFee,
        uint256 prevAskFee
    ) internal pure returns (uint256 spot) {
        spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : s[IDX_PHAT];
        if (s[IDX_PHAT] == 0) s[IDX_PHAT] = spot;

        uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied = gamma == 0 ? spot : (trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma));

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        _updateFairValueState(s, pImplied, tradeRatio);
        _updateFlowState(s, trade.isBuy, tradeRatio);
        return spot;
    }

    function _updateFairValueState(uint256[14] memory s, uint256 pImplied, uint256 tradeRatio) internal pure {
        bool firstInStep = s[IDX_STEP] == 0;
        bool likelyArb = firstInStep && tradeRatio <= ARB_MAX_RATIO && s[IDX_TOX] <= TOX_ARB_GATE;

        uint256 ret = s[IDX_PHAT] > 0 ? wdiv(absDiff(pImplied, s[IDX_PHAT]), s[IDX_PHAT]) : 0;
        if (ret > RET_CAP) ret = RET_CAP;

        uint256 sigmaBlend = firstInStep ? SIGMA_BLEND_FIRST : SIGMA_BLEND_FOLLOW;
        s[IDX_SIGMA] = wmul(s[IDX_SIGMA], sigmaBlend) + wmul(ret, WAD - sigmaBlend);

        uint256 alphaBase = likelyArb ? PHAT_ALPHA_ARB : PHAT_ALPHA_FLOW;
        if (!firstInStep) alphaBase = wmul(alphaBase, PHAT_ALPHA_FOLLOW_MULT);
        if (ret > PHAT_SHOCK_GATE) alphaBase = wmul(alphaBase, PHAT_SHOCK_MULT);
        uint256 alphaDamp = wmul(PHAT_CONF_DAMP, s[IDX_CONF]);
        uint256 alpha = wmul(alphaBase, WAD > alphaDamp ? WAD - alphaDamp : 0);
        if (alpha < PHAT_MIN_ALPHA) alpha = PHAT_MIN_ALPHA;
        s[IDX_PHAT] = wmul(s[IDX_PHAT], WAD - alpha) + wmul(pImplied, alpha);
    }

    function _updateFlowState(uint256[14] memory s, bool isBuy, uint256 tradeRatio) internal pure {
        s[IDX_FLOW] = wmul(s[IDX_FLOW], FLOW_BLEND_DECAY) + wmul(tradeRatio, WAD - FLOW_BLEND_DECAY);

        if (tradeRatio <= SIGNAL_THRESHOLD) return;

        uint256 push = tradeRatio * DIR_IMPACT_MULT;
        if (push > WAD / 4) push = WAD / 4;

        if (isBuy) {
            s[IDX_DIR] = s[IDX_DIR] + push;
            if (s[IDX_DIR] > 2 * WAD) s[IDX_DIR] = 2 * WAD;
        } else {
            s[IDX_DIR] = s[IDX_DIR] > push ? s[IDX_DIR] - push : 0;
        }

        uint256 invPush = wmul(push, INV_PUSH_MULT);
        if (isBuy) {
            s[IDX_INV] = s[IDX_INV] + invPush;
            if (s[IDX_INV] > 2 * WAD) s[IDX_INV] = 2 * WAD;
        } else {
            s[IDX_INV] = s[IDX_INV] > invPush ? s[IDX_INV] - invPush : 0;
        }

        s[IDX_SIZE] = wmul(s[IDX_SIZE], SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
        if (s[IDX_SIZE] > WAD) s[IDX_SIZE] = WAD;
    }

    function _updateRiskAgreementConfidence(uint256[14] memory s, uint256 spot)
        internal
        pure
        returns (uint256 toxSignal, uint256 nTox, uint256 agreeCount)
    {
        uint256 tox = s[IDX_PHAT] > 0 ? wdiv(absDiff(spot, s[IDX_PHAT]), s[IDX_PHAT]) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;
        s[IDX_TOX] = wmul(s[IDX_TOX], TOX_BLEND_DECAY) + wmul(tox, WAD - TOX_BLEND_DECAY);
        toxSignal = _capToxSignalBySigma(s[IDX_TOX], s[IDX_SIGMA]);

        uint256 flowSignal = wmul(s[IDX_LAMBDA], s[IDX_SIZE]) + s[IDX_FLOW];
        if (flowSignal > FLOW_SIGNAL_CAP) flowSignal = FLOW_SIGNAL_CAP;

        nTox = _normCap(toxSignal, TOX_NORM);
        uint256 nSigma = _normCap(s[IDX_SIGMA], SIGMA_NORM);
        uint256 nFlow = _normCap(flowSignal, FLOW_NORM);

        agreeCount = 0;
        if (toxSignal > TOX_AGREE_KNEE) agreeCount = agreeCount + 1;
        if (s[IDX_SIGMA] > SIGMA_AGREE_KNEE) agreeCount = agreeCount + 1;
        if (flowSignal > FLOW_AGREE_KNEE) agreeCount = agreeCount + 1;

        uint256 agreeRaw = (nTox + nSigma + nFlow) / 3;
        if (agreeCount < 2) agreeRaw = wmul(agreeRaw, AGREE_SINGLE_MULT);
        s[IDX_AGREE] = wmul(s[IDX_AGREE], AGREE_BLEND_DECAY) + wmul(agreeRaw, WAD - AGREE_BLEND_DECAY);

        uint256 uncertainty = wmul(CONF_TOX_W, nTox) + wmul(CONF_SIGMA_W, nSigma) + wmul(CONF_AGREE_W, s[IDX_AGREE]);
        if (uncertainty > WAD) uncertainty = WAD;

        uint256 confTarget = WAD > uncertainty ? WAD - uncertainty : 0;
        if (flowSignal > CONF_FLOW_KNEE && uncertainty < CONF_UNCERTAINTY_GATE) {
            uint256 flowBoost = wmul(CONF_FLOW_BOOST, wmul(_normCap(flowSignal, CONF_FLOW_NORM), WAD - uncertainty));
            confTarget = confTarget + flowBoost;
            if (confTarget > WAD) confTarget = WAD;
        }

        if (confTarget < CONF_MIN) confTarget = CONF_MIN;
        if (confTarget > CONF_MAX) confTarget = CONF_MAX;
        s[IDX_CONF] = wmul(s[IDX_CONF], CONF_BLEND_DECAY) + wmul(confTarget, WAD - CONF_BLEND_DECAY);
    }

    function _computeFeeTargets(
        uint256[14] memory s,
        uint256 spot,
        uint256 toxSignal,
        uint256 nTox,
        uint256 agreeCount
    ) internal pure returns (uint256 bidTarget, uint256 askTarget) {
        (uint256 fMid, uint256 splitProtect) = _computeMidAndSplitProtect(s, toxSignal, agreeCount);
        (uint256 bidPressure, uint256 askPressure) = _computeSidePressures(s, spot, toxSignal);
        return _assembleTargets(s, nTox, fMid, splitProtect, bidPressure, askPressure);
    }

    function _assembleTargets(
        uint256[14] memory s,
        uint256 nTox,
        uint256 fMid,
        uint256 splitProtect,
        uint256 bidPressure,
        uint256 askPressure
    ) internal pure returns (uint256 bidTarget, uint256 askTarget) {
        uint256 skew = bidPressure >= askPressure ? bidPressure - askPressure : askPressure - bidPressure;
        if (skew > SKEW_CAP) skew = SKEW_CAP;

        uint256 attract = wmul(ATTRACT_COEF, wmul(s[IDX_CONF], WAD - s[IDX_AGREE]));
        attract = wmul(attract, WAD - wmul(ATTRACT_TOX_DAMP, nTox));
        if (attract > ATTRACT_CAP) attract = ATTRACT_CAP;

        if (bidPressure >= askPressure) {
            bidTarget = fMid + skew + splitProtect;
            askTarget = fMid > attract ? fMid - attract : 0;
        } else {
            askTarget = fMid + skew + splitProtect;
            bidTarget = fMid > attract ? fMid - attract : 0;
        }
    }

    function _computeMidAndSplitProtect(uint256[14] memory s, uint256 toxSignal, uint256 agreeCount)
        internal
        pure
        returns (uint256 fMid, uint256 splitProtect)
    {
        uint256 flowSize = wmul(s[IDX_LAMBDA], s[IDX_SIZE]);
        uint256 fBase = BASE_FEE + wmul(SIGMA_COEF, s[IDX_SIGMA]) + wmul(LAMBDA_COEF, s[IDX_LAMBDA])
            + wmul(FLOW_SIZE_COEF, flowSize) + wmul(FLOW_EMA_COEF, s[IDX_FLOW]);

        uint256 toxExcess = toxSignal > TOX_QUAD_KNEE ? toxSignal - TOX_QUAD_KNEE : 0;
        uint256 toxQuadAdd = wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        if (toxQuadAdd > TOX_QUAD_ADD_CAP) toxQuadAdd = TOX_QUAD_ADD_CAP;

        uint256 toxAdd = wmul(TOX_COEF, toxSignal) + toxQuadAdd;
        uint256 protectAdd = wmul(toxAdd, PROTECT_MIN_MULT) + wmul(toxAdd, wmul(PROTECT_AGREE_MULT, s[IDX_AGREE]));
        if (agreeCount < 2) protectAdd = wmul(protectAdd, PROTECT_SINGLE_MULT);
        splitProtect = wmul(protectAdd, SPLIT_PROTECT_MULT);

        fMid = fBase + (protectAdd > splitProtect ? protectAdd - splitProtect : 0) + wmul(RISK_LIFT_COEF, s[IDX_AGREE]);
    }

    function _computeSidePressures(uint256[14] memory s, uint256 spot, uint256 toxSignal)
        internal
        pure
        returns (uint256 bidPressure, uint256 askPressure)
    {
        bidPressure = 0;
        askPressure = 0;

        uint256 dirDev = s[IDX_DIR] >= WAD ? s[IDX_DIR] - WAD : WAD - s[IDX_DIR];
        uint256 invDev = s[IDX_INV] >= WAD ? s[IDX_INV] - WAD : WAD - s[IDX_INV];

        uint256 pricePressure = wmul(PRICE_TOX_COEF, toxSignal);
        if (spot >= s[IDX_PHAT]) {
            bidPressure = bidPressure + pricePressure;
        } else {
            askPressure = askPressure + pricePressure;
        }

        uint256 dirPressure = wmul(DIR_COEF, dirDev);
        if (s[IDX_DIR] >= WAD) {
            bidPressure = bidPressure + dirPressure;
        } else {
            askPressure = askPressure + dirPressure;
        }

        uint256 invPressure = wmul(INV_COEF, invDev);
        if (s[IDX_INV] >= WAD) {
            bidPressure = bidPressure + invPressure;
        } else {
            askPressure = askPressure + invPressure;
        }

        uint256 jointPressure = wmul(DIR_TOX_COEF, wmul(dirDev, toxSignal));
        if (s[IDX_DIR] >= WAD && s[IDX_INV] >= WAD) {
            bidPressure = bidPressure + jointPressure;
        } else if (s[IDX_DIR] < WAD && s[IDX_INV] < WAD) {
            askPressure = askPressure + jointPressure;
        }
    }

    function _finalizeFees(
        uint256[14] memory s,
        uint256 prevBidFee,
        uint256 prevAskFee,
        uint256 bidTarget,
        uint256 askTarget
    ) internal pure returns (uint256 bidFee, uint256 askFee) {
        uint256 upCap = STEP_UP_BASE + wmul(STEP_UP_AGREE_MULT, s[IDX_AGREE]);
        uint256 downCap = STEP_DOWN_BASE + wmul(STEP_DOWN_CONF_MULT, s[IDX_CONF]);
        downCap = wmul(downCap, WAD - wmul(STEP_DOWN_AGREE_DAMP, s[IDX_AGREE]));
        uint256 downFloor = 8 * BPS;
        if (downCap < downFloor) downCap = downFloor;

        bidTarget = _slew(prevBidFee, bidTarget, upCap, downCap);
        askTarget = _slew(prevAskFee, askTarget, upCap, downCap);

        if (bidTarget > askTarget) {
            bidFee = clampFee(_compressTail(bidTarget, TAIL_SLOPE_PROTECT));
            askFee = clampFee(_compressTail(askTarget, TAIL_SLOPE_ATTRACT));
        } else if (askTarget > bidTarget) {
            bidFee = clampFee(_compressTail(bidTarget, TAIL_SLOPE_ATTRACT));
            askFee = clampFee(_compressTail(askTarget, TAIL_SLOPE_PROTECT));
        } else {
            bidFee = clampFee(_compressTail(bidTarget, TAIL_SLOPE));
            askFee = clampFee(_compressTail(askTarget, TAIL_SLOPE));
        }
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

    function _normCap(uint256 value, uint256 cap) internal pure returns (uint256) {
        if (value >= cap) return WAD;
        return wdiv(value, cap);
    }

    function _slew(uint256 prevFee, uint256 targetFee, uint256 upCap, uint256 downCap) internal pure returns (uint256) {
        if (targetFee >= prevFee) {
            uint256 rise = targetFee - prevFee;
            return rise > upCap ? prevFee + upCap : targetFee;
        }
        uint256 drop = prevFee - targetFee;
        return drop > downCap ? prevFee - downCap : targetFee;
    }

    function _capToxSignalBySigma(uint256 toxSignal, uint256 sigmaHat) internal pure returns (uint256) {
        if (sigmaHat <= TOX_CONF_SIGMA_KNEE) return toxSignal;
        uint256 sigmaExcess = sigmaHat - TOX_CONF_SIGMA_KNEE;
        if (sigmaExcess > TOX_CONF_SIGMA_SPAN) sigmaExcess = TOX_CONF_SIGMA_SPAN;
        uint256 confidenceMult = WAD - wmul(WAD - TOX_CONF_MIN_MULT, wdiv(sigmaExcess, TOX_CONF_SIGMA_SPAN));
        uint256 toxSignalCap = wmul(TOX_CAP, confidenceMult);
        return toxSignal > toxSignalCap ? toxSignalCap : toxSignal;
    }

    function getName() external pure override returns (string memory) {
        return "wildcard_mod_v291";
    }
}
