pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_TOX_ACT_007","confidence":0.61,"ceiling_probability":0.29,"ev_next_5":0.019,"best_delta_seen":2.3074,"reason":"promotion_edge 519.30 with T6 bounded adaptation: bounded fees, coherent spread behavior, and no pathological liquidity collapse.","next_mechanism":"wildcard"}

    struct State {
        uint256 prevBidFee;
        uint256 prevAskFee;
        uint256 lastTs;
        uint256 dirState;
        uint256 actEma;
        uint256 pHat;
        uint256 sigmaHat;
        uint256 lambdaHat;
        uint256 sizeHat;
        uint256 toxEma;
        uint256 stepTradeCount;
        uint256 confEma;
        uint256 stressEma;
        uint256 flowBurstEma;
        uint256 stepFlow;
        uint256 prevActSignal;
        uint256 prevToxSignal;
        uint256 prevSizeSignal;
        uint256 prevLambdaSignal;
        uint256 prevSigmaSignal;
        uint256 prevFlowBurstSignal;
        uint256 prevConfSignal;
        uint256 prevStressSignal;
    }

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant SIGNAL_THRESHOLD = WAD / 700;

    uint256 constant DIR_DECAY = 850000000000000000;
    uint256 constant ACT_DECAY = 700000000000000000;
    uint256 constant SIZE_DECAY = 600000000000000000;
    uint256 constant TOX_DECAY = 900000000000000000;
    uint256 constant SIGMA_DECAY_FIRST = 660000000000000000;
    uint256 constant SIGMA_DECAY_FOLLOW = 998000000000000000;
    uint256 constant LAMBDA_DECAY = 994000000000000000;
    uint256 constant FLOW_BURST_DECAY = 920000000000000000;
    uint256 constant CONF_DECAY = 920000000000000000;
    uint256 constant STRESS_DECAY = 880000000000000000;

    uint256 constant SIZE_BLEND_DECAY = 800000000000000000;
    uint256 constant TOX_BLEND_DECAY = 150000000000000000;
    uint256 constant ACT_BLEND_DECAY = 993000000000000000;
    uint256 constant CONF_BLEND_DECAY = 900000000000000000;
    uint256 constant STRESS_BLEND_DECAY = 860000000000000000;

    uint256 constant PHAT_ALPHA_ARB = 330000000000000000;
    uint256 constant PHAT_ALPHA_RETAIL = 115000000000000000;
    uint256 constant PHAT_ALPHA_FOLLOW = 40000000000000000;
    uint256 constant PHAT_SHOCK_GATE = 30000000000000000;
    uint256 constant PHAT_SHOCK_DAMP = 300000000000000000;
    uint256 constant ARB_MAX_RATIO = WAD / 360;

    uint256 constant RET_CAP = WAD / 10;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant TRADE_RATIO_CAP = WAD / 5;
    uint256 constant LAMBDA_CAP = 5 * WAD;
    uint256 constant STEP_COUNT_CAP = 64;
    uint256 constant STEP_FLOW_CAP = WAD / 2;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant MID_CAP = 330 * BPS;

    uint256 constant SIGMA_COEF = 190000000000000000;
    uint256 constant LAMBDA_COEF = 12 * BPS;
    uint256 constant FLOW_SIZE_COEF = 6400 * BPS;
    uint256 constant FIRST_REVEAL_COEF = 55 * BPS;
    uint256 constant FOLLOW_REVEAL_COEF = 8 * BPS;

    uint256 constant TOX_COEF = 175 * BPS;
    uint256 constant TOX_QUAD_COEF = 17500 * BPS;
    uint256 constant TOX_QUAD_KNEE = 12 * BPS;
    uint256 constant TOX_QUAD_ADD_CAP = 155 * BPS;
    uint256 constant TOX_FAVORABLE_MULT = 820000000000000000;
    uint256 constant TOX_ADVERSE_MULT = 1110000000000000000;
    uint256 constant ACT_COEF = 40000 * BPS;
    uint256 constant ACT_FAVORABLE_MULT = 780000000000000000;
    uint256 constant ACT_GATE_LAMBDA = 950000000000000000;
    uint256 constant ACT_GATE_SIZE = 3000000000000000;
    uint256 constant TOX_DISAGREE_MULT = 450000000000000000;
    uint256 constant TOX_ACT_STEP_UP_CAP = 210 * BPS;
    uint256 constant TOX_ACT_STEP_DOWN_CAP = 300 * BPS;
    uint256 constant SPLIT_STEP_CAP = 180 * BPS;

    uint256 constant TOX_DEADBAND = 10 * BPS;
    uint256 constant SIGMA_DEADBAND = 7 * BPS;
    uint256 constant LAMBDA_DEADBAND = 900000000000000000;
    uint256 constant SIZE_DEADBAND = 2500000000000000;
    uint256 constant FLOW_DEADBAND = 2500000000000000;

    uint256 constant DIR_COEF = 90 * BPS;
    uint256 constant DIR_TOX_COEF = 18 * BPS;
    uint256 constant DIR_STRESS_COEF = 26 * BPS;
    uint256 constant STALE_DIR_COEF = 6200 * BPS;
    uint256 constant COMPETE_PULL_COEF = 65 * BPS;

    uint256 constant CONF_NEUTRAL = 780000000000000000;
    uint256 constant CONF_MIN = 380000000000000000;

    uint256 constant CONF_SIGMA_KNEE = 11 * BPS;
    uint256 constant CONF_SIGMA_SPAN = 36 * BPS;
    uint256 constant CONF_TOX_KNEE = 9 * BPS;
    uint256 constant CONF_TOX_SPAN = 26 * BPS;
    uint256 constant CONF_LAMBDA_KNEE = 850000000000000000;
    uint256 constant CONF_LAMBDA_SPAN = 1800000000000000000;
    uint256 constant CONF_FLOW_KNEE = 3000000000000000;
    uint256 constant CONF_FLOW_SPAN = 12000000000000000;

    uint256 constant CONF_SIGMA_PENALTY_MAX = 420000000000000000;
    uint256 constant CONF_TOX_PENALTY_MAX = 460000000000000000;
    uint256 constant CONF_LAMBDA_PENALTY_MAX = 320000000000000000;
    uint256 constant CONF_FLOW_PENALTY_MAX = 260000000000000000;

    uint256 constant STRESS_SIGMA_COEF = 230000000000000000;
    uint256 constant STRESS_TOX_COEF = 300000000000000000;
    uint256 constant STRESS_LAMBDA_COEF = 28000000000000000;
    uint256 constant STRESS_FLOW_COEF = 140000000000000000;

    uint256 constant CONF_GUARD_COEF = 480000000000000000;
    uint256 constant STRESS_GUARD_COEF = 420000000000000000;
    uint256 constant ATTRACT_CONF_COEF = 360000000000000000;
    uint256 constant ATTRACT_STRESS_COEF = 260000000000000000;
    uint256 constant ATTRACT_MIN_MULT = 450000000000000000;

    uint256 constant SPREAD_MIN = 2 * BPS;
    uint256 constant SPREAD_TOX_COEF = 110 * BPS;
    uint256 constant SPREAD_STRESS_COEF = 75 * BPS;
    uint256 constant SPREAD_MAX = 210 * BPS;
    uint256 constant MID_STEP_UP_CAP = 170 * BPS;
    uint256 constant MID_STEP_DOWN_CAP = 240 * BPS;
    uint256 constant SPREAD_STEP_CAP = 140 * BPS;

    uint256 constant TAIL_KNEE = 700 * BPS;
    uint256 constant TAIL_SLOPE = 900000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 830000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 960000000000000000;

    uint256 constant TOX_CONF_SIGMA_KNEE = 12 * BPS;
    uint256 constant TOX_CONF_SIGMA_SPAN = 40 * BPS;
    uint256 constant TOX_CONF_MIN_MULT = 620000000000000000;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD;
        slots[4] = 0;
        slots[5] = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        slots[6] = 950000000000000;
        slots[7] = 800000000000000000;
        slots[8] = 2000000000000000;
        slots[9] = 0;
        slots[10] = 0;
        slots[11] = CONF_NEUTRAL;
        slots[12] = 45000000000000000;
        slots[13] = 0;
        slots[14] = 0;
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        State memory s = _loadState();

        if (trade.timestamp > s.lastTs) {
            _advanceStep(s, trade.timestamp);
        }

        bool firstInStep = s.stepTradeCount == 0;

        s.prevActSignal = s.actEma;
        s.prevToxSignal = s.toxEma;
        s.prevSizeSignal = s.sizeHat;
        s.prevLambdaSignal = s.lambdaHat;
        s.prevSigmaSignal = s.sigmaHat;
        s.prevFlowBurstSignal = s.flowBurstEma;
        s.prevConfSignal = s.confEma;
        s.prevStressSignal = s.stressEma;

        (uint256 spot, uint256 tradeRatio, uint256 ret) = _updatePriceBelief(s, trade, firstInStep);
        _updateDirectionalSignals(s, trade, tradeRatio);

        uint256 toxSignal = _updateRiskBeliefs(s, spot);
        (uint256 midTarget, uint256 toxActSplitAdd) = _computeMidAndSplit(s, tradeRatio, ret, toxSignal, firstInStep);
        (uint256 bidFee, uint256 askFee) = _quoteFromMid(s, spot, toxSignal, midTarget, toxActSplitAdd);

        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;

        _storeState(s, trade.timestamp, bidFee, askFee);
        return (bidFee, askFee);
    }

    function _computeMidAndSplit(State memory s, uint256 tradeRatio, uint256 ret, uint256 toxSignal, bool firstInStep)
        internal
        pure
        returns (uint256 midTarget, uint256 toxActSplitAdd)
    {
        uint256 fBase = _computeBaseFeeCore(s, tradeRatio, ret, firstInStep);
        (uint256 toxActAdd, uint256 splitAdd) = _computeAdaptiveAdds(s, toxSignal);
        midTarget = fBase + toxActAdd;
        if (midTarget > MID_CAP) midTarget = MID_CAP;
        toxActSplitAdd = splitAdd;
    }

    function _quoteFromMid(State memory s, uint256 spot, uint256 toxSignal, uint256 midTarget, uint256 toxActSplitAdd)
        internal
        pure
        returns (uint256 bidFee, uint256 askFee)
    {
        (uint256 bidTarget, uint256 askTarget) = _applyDirectionalAndShifts(s, spot, toxSignal, midTarget, toxActSplitAdd);
        (bidFee, askFee) = _finalizeQuotes(s.prevBidFee, s.prevAskFee, bidTarget, askTarget, toxSignal, s.stressEma);
    }

    function _loadState() internal view returns (State memory s) {
        s.prevBidFee = slots[0];
        s.prevAskFee = slots[1];
        s.lastTs = slots[2];
        s.dirState = slots[3];
        s.actEma = slots[4];
        s.pHat = slots[5];
        s.sigmaHat = slots[6];
        s.lambdaHat = slots[7];
        s.sizeHat = slots[8];
        s.toxEma = slots[9];
        s.stepTradeCount = slots[10];
        s.confEma = slots[11];
        s.stressEma = slots[12];
        s.flowBurstEma = slots[13];
        s.stepFlow = slots[14];
    }

    function _storeState(State memory s, uint256 ts, uint256 bidFee, uint256 askFee) internal {
        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = ts;
        slots[3] = s.dirState;
        slots[4] = s.actEma;
        slots[5] = s.pHat;
        slots[6] = s.sigmaHat;
        slots[7] = s.lambdaHat;
        slots[8] = s.sizeHat;
        slots[9] = s.toxEma;
        slots[10] = s.stepTradeCount;
        slots[11] = s.confEma;
        slots[12] = s.stressEma;
        slots[13] = s.flowBurstEma;
        slots[14] = s.stepFlow;
    }

    function _advanceStep(State memory s, uint256 timestamp) internal pure {
        uint256 elapsedRaw = timestamp - s.lastTs;
        uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

        s.dirState = _decayCentered(s.dirState, DIR_DECAY, elapsed);
        s.actEma = wmul(s.actEma, _powWad(ACT_DECAY, elapsed));
        s.sizeHat = wmul(s.sizeHat, _powWad(SIZE_DECAY, elapsed));
        s.toxEma = wmul(s.toxEma, _powWad(TOX_DECAY, elapsed));
        s.flowBurstEma = wmul(s.flowBurstEma, _powWad(FLOW_BURST_DECAY, elapsed));
        s.stressEma = wmul(s.stressEma, _powWad(STRESS_DECAY, elapsed));
        s.confEma = _decayToward(s.confEma, CONF_NEUTRAL, CONF_DECAY, elapsed);

        if (s.stepTradeCount > 0 && elapsedRaw > 0) {
            uint256 lambdaInst = (s.stepTradeCount * WAD) / elapsedRaw;
            if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
            s.lambdaHat = wmul(s.lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);

            uint256 stepFlowInst = s.stepFlow;
            if (stepFlowInst > STEP_FLOW_CAP) stepFlowInst = STEP_FLOW_CAP;
            s.flowBurstEma = wmul(s.flowBurstEma, FLOW_BURST_DECAY) + wmul(stepFlowInst, WAD - FLOW_BURST_DECAY);
        }

        s.stepTradeCount = 0;
        s.stepFlow = 0;
    }

    function _updatePriceBelief(State memory s, TradeInfo calldata trade, bool firstInStep)
        internal
        pure
        returns (uint256 spot, uint256 tradeRatio, uint256 ret)
    {
        spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : s.pHat;
        if (s.pHat == 0) s.pHat = spot;

        uint256 feeUsed = trade.isBuy ? s.prevBidFee : s.prevAskFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied = gamma == 0 ? spot : (trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma));

        tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        s.stepFlow = s.stepFlow + tradeRatio;
        if (s.stepFlow > STEP_FLOW_CAP) s.stepFlow = STEP_FLOW_CAP;

        ret = s.pHat > 0 ? wdiv(absDiff(pImplied, s.pHat), s.pHat) : 0;
        if (ret > RET_CAP) ret = RET_CAP;

        bool likelyArb = firstInStep && tradeRatio <= ARB_MAX_RATIO;

        uint256 alpha;
        if (firstInStep) {
            alpha = likelyArb ? PHAT_ALPHA_ARB : PHAT_ALPHA_RETAIL;
        } else {
            alpha = PHAT_ALPHA_FOLLOW;
        }
        if (ret > PHAT_SHOCK_GATE) alpha = wmul(alpha, PHAT_SHOCK_DAMP);

        s.pHat = wmul(s.pHat, WAD - alpha) + wmul(pImplied, alpha);

        if (firstInStep) {
            uint256 sigmaInst = likelyArb ? ret : wmul(ret, 650000000000000000);
            s.sigmaHat = wmul(s.sigmaHat, SIGMA_DECAY_FIRST) + wmul(sigmaInst, WAD - SIGMA_DECAY_FIRST);
        } else {
            s.sigmaHat = wmul(s.sigmaHat, SIGMA_DECAY_FOLLOW) + wmul(ret, WAD - SIGMA_DECAY_FOLLOW);
        }
    }

    function _updateDirectionalSignals(State memory s, TradeInfo calldata trade, uint256 tradeRatio) internal pure {
        if (tradeRatio <= SIGNAL_THRESHOLD) return;

        uint256 push = tradeRatio;
        if (push > WAD / 4) push = WAD / 4;

        if (trade.isBuy) {
            s.dirState = s.dirState + push;
            if (s.dirState > 2 * WAD) s.dirState = 2 * WAD;
        } else {
            s.dirState = s.dirState > push ? s.dirState - push : 0;
        }

        s.actEma = wmul(s.actEma, ACT_BLEND_DECAY) + wmul(tradeRatio, WAD - ACT_BLEND_DECAY);
        s.sizeHat = wmul(s.sizeHat, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
        if (s.sizeHat > WAD) s.sizeHat = WAD;
    }

    function _updateRiskBeliefs(State memory s, uint256 spot) internal pure returns (uint256 toxSignal) {
        uint256 tox = s.pHat > 0 ? wdiv(absDiff(spot, s.pHat), s.pHat) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;

        s.toxEma = wmul(s.toxEma, TOX_BLEND_DECAY) + wmul(tox, WAD - TOX_BLEND_DECAY);
        toxSignal = _capToxSignalBySigma(s.toxEma, s.sigmaHat);

        uint256 confInst = _computeConfidence(s.sigmaHat, toxSignal, s.lambdaHat, s.flowBurstEma);
        s.confEma = wmul(s.confEma, CONF_BLEND_DECAY) + wmul(confInst, WAD - CONF_BLEND_DECAY);
        if (s.confEma < CONF_MIN) s.confEma = CONF_MIN;

        uint256 stressInst = _computeStress(s.sigmaHat, toxSignal, s.lambdaHat, s.flowBurstEma);
        s.stressEma = wmul(s.stressEma, STRESS_BLEND_DECAY) + wmul(stressInst, WAD - STRESS_BLEND_DECAY);
        if (s.stressEma > WAD) s.stressEma = WAD;
    }

    function _computeBaseFeeCore(State memory s, uint256 tradeRatio, uint256 ret, bool firstInStep)
        internal
        pure
        returns (uint256 fBase)
    {
        uint256 flowSize = wmul(s.lambdaHat, s.sizeHat);
        if (flowSize > WAD) flowSize = WAD;

        fBase =
            BASE_FEE + wmul(SIGMA_COEF, s.sigmaHat) + wmul(LAMBDA_COEF, s.lambdaHat) + wmul(FLOW_SIZE_COEF, flowSize);

        if (firstInStep) {
            uint256 reveal = ret + tradeRatio;
            if (reveal > WAD / 2) reveal = WAD / 2;
            fBase = fBase + wmul(FIRST_REVEAL_COEF, reveal);
        } else {
            fBase = fBase + wmul(FOLLOW_REVEAL_COEF, ret);
        }
    }

    function _computeAdaptiveAdds(State memory s, uint256 toxSignal)
        internal
        pure
        returns (uint256 toxActAdd, uint256 toxActSplitAdd)
    {
        (uint256 scaledFavNow, uint256 scaledSplitNow) = _scaledCoreNow(s, toxSignal);

        uint256 prevToxCapped = _capToxSignalBySigma(s.prevToxSignal, s.prevSigmaSignal);
        (uint256 scaledFavPrev, uint256 scaledSplitPrev) = _scaledCorePrev(s, prevToxCapped);

        toxActAdd = _boundStep(scaledFavPrev, scaledFavNow, TOX_ACT_STEP_UP_CAP, TOX_ACT_STEP_DOWN_CAP);
        toxActSplitAdd = _boundSymmetric(scaledSplitPrev, scaledSplitNow, SPLIT_STEP_CAP);
    }

    function _scaledCoreNow(State memory s, uint256 toxSignal)
        internal
        pure
        returns (uint256 scaledFav, uint256 scaledSplit)
    {
        bool agree = _hasRiskAgreement(toxSignal, s.sigmaHat, s.lambdaHat, s.sizeHat, s.flowBurstEma);
        (uint256 coreFav, uint256 coreSplit) = _coreFavSplit(s.actEma, s.lambdaHat, s.sizeHat, toxSignal, agree);
        (scaledFav, scaledSplit) = _scaleCore(coreFav, coreSplit, s.confEma, s.stressEma);
    }

    function _scaledCorePrev(State memory s, uint256 toxSignal)
        internal
        pure
        returns (uint256 scaledFav, uint256 scaledSplit)
    {
        bool agree = _hasRiskAgreement(
            toxSignal, s.prevSigmaSignal, s.prevLambdaSignal, s.prevSizeSignal, s.prevFlowBurstSignal
        );
        (uint256 coreFav, uint256 coreSplit) =
            _coreFavSplit(s.prevActSignal, s.prevLambdaSignal, s.prevSizeSignal, toxSignal, agree);
        (scaledFav, scaledSplit) = _scaleCore(coreFav, coreSplit, s.prevConfSignal, s.prevStressSignal);
    }

    function _scaleCore(uint256 coreFav, uint256 coreSplit, uint256 confSignal, uint256 stressSignal)
        internal
        pure
        returns (uint256 scaledFav, uint256 scaledSplit)
    {
        scaledFav = wmul(coreFav, _attractMult(confSignal, stressSignal));
        scaledSplit = wmul(coreSplit, _protectMult(confSignal, stressSignal));
    }

    function _coreFavSplit(uint256 actSignal, uint256 lambdaSignal, uint256 sizeSignal, uint256 toxSignal, bool agree)
        internal
        pure
        returns (uint256 fav, uint256 split)
    {
        (uint256 toxFav, uint256 toxSplit) = _toxComponents(toxSignal, agree);
        (uint256 actFav, uint256 actSplit) = _actComponents(actSignal, lambdaSignal, sizeSignal, toxSignal, agree);
        fav = toxFav + actFav;
        split = toxSplit + actSplit;
    }

    function _applyDirectionalAndShifts(
        State memory s,
        uint256 spot,
        uint256 toxSignal,
        uint256 midTarget,
        uint256 toxActSplitAdd
    ) internal pure returns (uint256 bidTarget, uint256 askTarget) {
        uint256 dirDev;
        bool sellPressure;
        if (s.dirState >= WAD) {
            dirDev = s.dirState - WAD;
            sellPressure = true;
        } else {
            dirDev = WAD - s.dirState;
            sellPressure = false;
        }

        uint256 skew = wmul(DIR_COEF, dirDev) + wmul(DIR_TOX_COEF, wmul(dirDev, toxSignal))
            + wmul(DIR_STRESS_COEF, wmul(dirDev, s.stressEma));

        if (sellPressure) {
            bidTarget = midTarget + skew;
            askTarget = midTarget > skew ? midTarget - skew : 0;
        } else {
            askTarget = midTarget + skew;
            bidTarget = midTarget > skew ? midTarget - skew : 0;
        }

        if (toxActSplitAdd > 0) {
            if (spot >= s.pHat) {
                bidTarget = bidTarget + toxActSplitAdd;
            } else {
                askTarget = askTarget + toxActSplitAdd;
            }
        }

        uint256 staleShift = wmul(STALE_DIR_COEF, wmul(toxSignal, WAD - s.confEma));
        if (staleShift > 0) {
            if (spot >= s.pHat) {
                bidTarget = bidTarget + staleShift;
                askTarget = askTarget > staleShift ? askTarget - staleShift : 0;
            } else {
                askTarget = askTarget + staleShift;
                bidTarget = bidTarget > staleShift ? bidTarget - staleShift : 0;
            }
        }

        uint256 competePull = wmul(COMPETE_PULL_COEF, wmul(s.confEma, WAD - s.stressEma));
        if (bidTarget > askTarget) {
            askTarget = askTarget > competePull ? askTarget - competePull : 0;
        } else if (askTarget > bidTarget) {
            bidTarget = bidTarget > competePull ? bidTarget - competePull : 0;
        }
    }

    function _finalizeQuotes(
        uint256 prevBid,
        uint256 prevAsk,
        uint256 bidTarget,
        uint256 askTarget,
        uint256 toxSignal,
        uint256 stressSignal
    ) internal pure returns (uint256 bidFee, uint256 askFee) {
        uint256 prevMid = (prevBid + prevAsk) / 2;
        uint256 prevSpread = absDiff(prevBid, prevAsk);

        uint256 midTarget = (bidTarget + askTarget) / 2;
        uint256 spreadTarget = absDiff(bidTarget, askTarget);

        uint256 spreadFloor = SPREAD_MIN + wmul(SPREAD_TOX_COEF, toxSignal) + wmul(SPREAD_STRESS_COEF, stressSignal);
        if (spreadFloor > SPREAD_MAX) spreadFloor = SPREAD_MAX;

        if (spreadTarget < spreadFloor) spreadTarget = spreadFloor;
        if (spreadTarget > SPREAD_MAX) spreadTarget = SPREAD_MAX;

        midTarget = _boundStep(prevMid, midTarget, MID_STEP_UP_CAP, MID_STEP_DOWN_CAP);
        spreadTarget = _boundSymmetric(prevSpread, spreadTarget, SPREAD_STEP_CAP);

        if (spreadTarget < spreadFloor) spreadTarget = spreadFloor;
        if (spreadTarget > SPREAD_MAX) spreadTarget = SPREAD_MAX;
        if (midTarget > MID_CAP) midTarget = MID_CAP;

        uint256 halfSpread = spreadTarget / 2;
        if (midTarget < halfSpread + SPREAD_MIN) midTarget = halfSpread + SPREAD_MIN;

        if (bidTarget >= askTarget) {
            bidFee = midTarget + halfSpread;
            askFee = midTarget > halfSpread ? midTarget - halfSpread : 0;
        } else {
            askFee = midTarget + halfSpread;
            bidFee = midTarget > halfSpread ? midTarget - halfSpread : 0;
        }

        if (bidFee > askFee) {
            bidFee = clampFee(_compressTail(bidFee, TAIL_SLOPE_PROTECT));
            askFee = clampFee(_compressTail(askFee, TAIL_SLOPE_ATTRACT));
        } else if (askFee > bidFee) {
            bidFee = clampFee(_compressTail(bidFee, TAIL_SLOPE_ATTRACT));
            askFee = clampFee(_compressTail(askFee, TAIL_SLOPE_PROTECT));
        } else {
            bidFee = clampFee(_compressTail(bidFee, TAIL_SLOPE));
            askFee = clampFee(_compressTail(askFee, TAIL_SLOPE));
        }
    }

    function _toxComponents(uint256 toxSignal, bool agree) internal pure returns (uint256 fav, uint256 split) {
        uint256 toxExcess = toxSignal > TOX_QUAD_KNEE ? toxSignal - TOX_QUAD_KNEE : 0;
        uint256 toxQuadAdd = wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        if (toxQuadAdd > TOX_QUAD_ADD_CAP) toxQuadAdd = TOX_QUAD_ADD_CAP;

        uint256 toxAdd = wmul(TOX_COEF, toxSignal) + toxQuadAdd;
        if (!agree) toxAdd = wmul(toxAdd, TOX_DISAGREE_MULT);

        uint256 toxFav = wmul(toxAdd, TOX_FAVORABLE_MULT);
        uint256 toxAdverse = wmul(toxAdd, TOX_ADVERSE_MULT);

        fav = toxFav;
        split = toxAdverse > toxFav ? toxAdverse - toxFav : 0;
    }

    function _actComponents(uint256 actSignal, uint256 lambdaSignal, uint256 sizeSignal, uint256 toxSignal, bool agree)
        internal
        pure
        returns (uint256 fav, uint256 split)
    {
        uint256 actAdd = 0;
        if (lambdaSignal >= ACT_GATE_LAMBDA && sizeSignal >= ACT_GATE_SIZE && toxSignal > TOX_QUAD_KNEE) {
            actAdd = wmul(ACT_COEF, actSignal);
            if (!agree) actAdd = wmul(actAdd, TOX_DISAGREE_MULT);
        }

        uint256 actFav = wmul(actAdd, ACT_FAVORABLE_MULT);
        fav = actFav;
        split = actAdd > actFav ? actAdd - actFav : 0;
    }

    function _hasRiskAgreement(uint256 toxSignal, uint256 sigmaSignal, uint256 lambdaSignal, uint256 sizeSignal, uint256 flowSignal)
        internal
        pure
        returns (bool)
    {
        if (toxSignal <= TOX_DEADBAND) return false;
        return sigmaSignal > SIGMA_DEADBAND || lambdaSignal > LAMBDA_DEADBAND || sizeSignal > SIZE_DEADBAND
            || flowSignal > FLOW_DEADBAND;
    }

    function _protectMult(uint256 confSignal, uint256 stressSignal) internal pure returns (uint256 mult) {
        mult = WAD + wmul(CONF_GUARD_COEF, WAD - confSignal) + wmul(STRESS_GUARD_COEF, stressSignal);
        if (mult > 2 * WAD) mult = 2 * WAD;
    }

    function _attractMult(uint256 confSignal, uint256 stressSignal) internal pure returns (uint256 mult) {
        uint256 confCut = wmul(ATTRACT_CONF_COEF, confSignal);
        uint256 stressLift = wmul(ATTRACT_STRESS_COEF, stressSignal);

        mult = WAD + stressLift;
        if (mult > confCut) {
            mult = mult - confCut;
        } else {
            mult = ATTRACT_MIN_MULT;
        }

        if (mult < ATTRACT_MIN_MULT) mult = ATTRACT_MIN_MULT;
        if (mult > WAD) mult = WAD;
    }

    function _computeConfidence(uint256 sigmaSignal, uint256 toxSignal, uint256 lambdaSignal, uint256 flowSignal)
        internal
        pure
        returns (uint256 conf)
    {
        uint256 sigmaPenalty = _linearPenalty(sigmaSignal, CONF_SIGMA_KNEE, CONF_SIGMA_SPAN, CONF_SIGMA_PENALTY_MAX);
        uint256 toxPenalty = _linearPenalty(toxSignal, CONF_TOX_KNEE, CONF_TOX_SPAN, CONF_TOX_PENALTY_MAX);
        uint256 lambdaPenalty =
            _linearPenalty(lambdaSignal, CONF_LAMBDA_KNEE, CONF_LAMBDA_SPAN, CONF_LAMBDA_PENALTY_MAX);
        uint256 flowPenalty = _linearPenalty(flowSignal, CONF_FLOW_KNEE, CONF_FLOW_SPAN, CONF_FLOW_PENALTY_MAX);

        uint256 confSigma = WAD - sigmaPenalty;
        uint256 confTox = WAD - toxPenalty;
        uint256 confLambda = WAD - lambdaPenalty;
        uint256 confFlow = WAD - flowPenalty;

        conf = (3 * confSigma + 3 * confTox + 2 * confLambda + 2 * confFlow) / 10;
        if (conf < CONF_MIN) conf = CONF_MIN;
    }

    function _computeStress(uint256 sigmaSignal, uint256 toxSignal, uint256 lambdaSignal, uint256 flowSignal)
        internal
        pure
        returns (uint256 stress)
    {
        stress = wmul(STRESS_SIGMA_COEF, sigmaSignal) + wmul(STRESS_TOX_COEF, toxSignal)
            + wmul(STRESS_LAMBDA_COEF, lambdaSignal) + wmul(STRESS_FLOW_COEF, flowSignal);
        if (stress > WAD) stress = WAD;
    }

    function _linearPenalty(uint256 signal, uint256 knee, uint256 span, uint256 maxPenalty)
        internal
        pure
        returns (uint256)
    {
        if (signal <= knee) return 0;
        uint256 excess = signal - knee;
        if (excess > span) excess = span;
        return wmul(maxPenalty, wdiv(excess, span));
    }

    function _boundStep(uint256 prev, uint256 next, uint256 upCap, uint256 downCap) internal pure returns (uint256) {
        if (next > prev) {
            uint256 rise = next - prev;
            return rise > upCap ? prev + upCap : next;
        }

        uint256 drop = prev - next;
        if (drop > downCap) return prev > downCap ? prev - downCap : 0;
        return next;
    }

    function _boundSymmetric(uint256 prev, uint256 next, uint256 cap) internal pure returns (uint256) {
        if (next > prev) {
            uint256 rise = next - prev;
            return rise > cap ? prev + cap : next;
        }

        uint256 drop = prev - next;
        return drop > cap ? prev - cap : next;
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

    function _decayToward(uint256 value, uint256 anchor, uint256 decayFactor, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        uint256 mul = _powWad(decayFactor, elapsed);
        if (value >= anchor) return anchor + wmul(value - anchor, mul);

        uint256 below = wmul(anchor - value, mul);
        return below < anchor ? anchor - below : 0;
    }

    function _capToxSignalBySigma(uint256 toxSignal, uint256 sigmaSignal) internal pure returns (uint256) {
        if (sigmaSignal <= TOX_CONF_SIGMA_KNEE) return toxSignal;
        uint256 sigmaExcess = sigmaSignal - TOX_CONF_SIGMA_KNEE;
        if (sigmaExcess > TOX_CONF_SIGMA_SPAN) sigmaExcess = TOX_CONF_SIGMA_SPAN;
        uint256 confidenceMult = WAD - wmul(WAD - TOX_CONF_MIN_MULT, wdiv(sigmaExcess, TOX_CONF_SIGMA_SPAN));
        uint256 toxSignalCap = wmul(TOX_CAP, confidenceMult);
        return toxSignal > toxSignalCap ? toxSignalCap : toxSignal;
    }

    function getName() external pure override returns (string memory) {
        return "wildcard_mod_v279";
    }
}
