// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_TOX_ACT_007","confidence":0.58,"ceiling_probability":0.33,"ev_next_5":0.017,"best_delta_seen":0.0,"reason":"promotion_edge 519.3027 baseline; T2 first-vs-follow confidence-stress rewrite with bounded fees, coherent spread behavior, and no pathological liquidity collapse.","next_mechanism":"wildcard"}

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
        uint256 flowBurstEma;
        uint256 confEma;
        uint256 stressEma;
        uint256 stepFlow;
    }

    uint256 constant ELAPSED_CAP = 10;
    uint256 constant SIGNAL_THRESHOLD = WAD / 750;

    uint256 constant DIR_DECAY = 870000000000000000;
    uint256 constant ACT_DECAY = 730000000000000000;
    uint256 constant SIZE_DECAY = 640000000000000000;
    uint256 constant TOX_DECAY = 900000000000000000;
    uint256 constant SIGMA_DECAY_FIRST = 700000000000000000;
    uint256 constant SIGMA_DECAY_FOLLOW = 920000000000000000;
    uint256 constant LAMBDA_DECAY = 994000000000000000;
    uint256 constant FLOW_BURST_DECAY = 920000000000000000;
    uint256 constant CONF_DECAY = 900000000000000000;
    uint256 constant STRESS_DECAY = 880000000000000000;

    uint256 constant ACT_BLEND_DECAY = 992000000000000000;
    uint256 constant SIZE_BLEND_DECAY = 790000000000000000;
    uint256 constant TOX_BLEND_DECAY = 120000000000000000;
    uint256 constant CONF_BLEND_DECAY = 900000000000000000;
    uint256 constant STRESS_BLEND_DECAY = 860000000000000000;

    uint256 constant PHAT_ALPHA_FIRST = 280000000000000000;
    uint256 constant PHAT_ALPHA_FIRST_ARB = 360000000000000000;
    uint256 constant PHAT_ALPHA_FOLLOW = 70000000000000000;
    uint256 constant PHAT_SHOCK_GATE = 35000000000000000;
    uint256 constant PHAT_SHOCK_DAMP = 250000000000000000;
    uint256 constant ARB_MAX_RATIO = WAD / 350;

    uint256 constant RET_CAP = WAD / 10;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant TRADE_RATIO_CAP = WAD / 5;
    uint256 constant LAMBDA_CAP = 5 * WAD;
    uint256 constant STEP_COUNT_CAP = 80;
    uint256 constant STEP_FLOW_CAP = WAD / 2;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant MID_CAP = 320 * BPS;

    uint256 constant SIGMA_COEF = 170000000000000000;
    uint256 constant LAMBDA_COEF = 11 * BPS;
    uint256 constant FLOW_SIZE_COEF = 5600 * BPS;
    uint256 constant FIRST_REVEAL_COEF = 90 * BPS;
    uint256 constant FOLLOW_REVEAL_COEF = 10 * BPS;

    uint256 constant TOX_LINEAR_COEF = 165 * BPS;
    uint256 constant TOX_QUAD_COEF = 17000 * BPS;
    uint256 constant TOX_KNEE = 11 * BPS;
    uint256 constant TOX_QUAD_CAP = 150 * BPS;
    uint256 constant TOX_FAVORABLE_MULT = 760000000000000000;
    uint256 constant ACT_COEF = 30000 * BPS;
    uint256 constant ACT_FAVORABLE_MULT = 740000000000000000;
    uint256 constant ACT_GATE_LAMBDA = 900000000000000000;
    uint256 constant ACT_GATE_SIZE = 2500000000000000;
    uint256 constant TOX_DISAGREE_MULT = 380000000000000000;

    uint256 constant DIR_COEF = 80 * BPS;
    uint256 constant DIR_STRESS_COEF = 35 * BPS;
    uint256 constant STALE_COEF = 5200 * BPS;

    uint256 constant CONF_NEUTRAL = 780000000000000000;
    uint256 constant CONF_MIN = 360000000000000000;

    uint256 constant CONF_SIGMA_KNEE = 10 * BPS;
    uint256 constant CONF_SIGMA_SPAN = 36 * BPS;
    uint256 constant CONF_TOX_KNEE = 9 * BPS;
    uint256 constant CONF_TOX_SPAN = 26 * BPS;
    uint256 constant CONF_LAMBDA_KNEE = 850000000000000000;
    uint256 constant CONF_LAMBDA_SPAN = 1800000000000000000;
    uint256 constant FLOW_CONF_KNEE = 2500000000000000;
    uint256 constant FLOW_CONF_SPAN = 12000000000000000;

    uint256 constant CONF_SIGMA_PENALTY_MAX = 450000000000000000;
    uint256 constant CONF_TOX_PENALTY_MAX = 500000000000000000;
    uint256 constant CONF_LAMBDA_PENALTY_MAX = 350000000000000000;
    uint256 constant CONF_FLOW_PENALTY_MAX = 300000000000000000;

    uint256 constant STRESS_SIGMA_COEF = 250000000000000000;
    uint256 constant STRESS_TOX_COEF = 350000000000000000;
    uint256 constant STRESS_LAMBDA_COEF = 30000000000000000;
    uint256 constant STRESS_FLOW_COEF = 150000000000000000;

    uint256 constant CONF_GUARD_COEF = 500000000000000000;
    uint256 constant STRESS_GUARD_COEF = 450000000000000000;
    uint256 constant ATTRACT_CONF_COEF = 380000000000000000;
    uint256 constant ATTRACT_STRESS_COEF = 280000000000000000;
    uint256 constant ATTRACT_MIN_MULT = 420000000000000000;

    uint256 constant TOX_DEADBAND = 9 * BPS;
    uint256 constant SIGMA_DEADBAND = 7 * BPS;
    uint256 constant LAMBDA_DEADBAND = 880000000000000000;
    uint256 constant SIZE_DEADBAND = 1300000000000000;
    uint256 constant FLOW_DEADBAND = 2500000000000000;

    uint256 constant SPREAD_MIN = 2 * BPS;
    uint256 constant SPREAD_TOX_COEF = 120 * BPS;
    uint256 constant SPREAD_STRESS_COEF = 80 * BPS;
    uint256 constant SPREAD_MAX = 220 * BPS;
    uint256 constant MID_STEP_UP_CAP = 200 * BPS;
    uint256 constant MID_STEP_DOWN_CAP = 260 * BPS;
    uint256 constant SPREAD_STEP_CAP = 160 * BPS;
    uint256 constant COMPETE_PULL_COEF = 70 * BPS;

    uint256 constant TAIL_KNEE = 700 * BPS;
    uint256 constant TAIL_SLOPE = 900000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 830000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 960000000000000000;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD;
        slots[4] = 0;
        slots[5] = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        slots[6] = 800000000000000;
        slots[7] = 780000000000000000;
        slots[8] = 1800000000000000;
        slots[9] = 0;
        slots[10] = 0;
        slots[11] = 0;
        slots[12] = CONF_NEUTRAL;
        slots[13] = 40000000000000000;
        slots[14] = 0;
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        State memory s = _loadState();

        if (trade.timestamp > s.lastTs) {
            _advanceStep(s, trade.timestamp);
        }

        bool firstInStep = s.stepTradeCount == 0;

        (uint256 spot, uint256 tradeRatio, uint256 ret) = _updatePriceAndStepSignals(s, trade, firstInStep);
        _updateDirectionalSignals(s, trade, tradeRatio);
        uint256 toxSignal = _updateToxicityBeliefAndRegime(s, spot);

        (uint256 bidFee, uint256 askFee) = _quoteFees(s, spot, tradeRatio, ret, toxSignal, firstInStep);

        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;

        _storeState(s, trade.timestamp, bidFee, askFee);

        return (bidFee, askFee);
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
        s.flowBurstEma = slots[11];
        s.confEma = slots[12];
        s.stressEma = slots[13];
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
        slots[11] = s.flowBurstEma;
        slots[12] = s.confEma;
        slots[13] = s.stressEma;
        slots[14] = s.stepFlow;
    }

    function _advanceStep(State memory s, uint256 timestamp) internal pure {
        uint256 elapsedRaw = timestamp - s.lastTs;
        uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

        s.dirState = _decayToward(s.dirState, WAD, DIR_DECAY, elapsed);
        s.actEma = wmul(s.actEma, _powWad(ACT_DECAY, elapsed));
        s.sizeHat = wmul(s.sizeHat, _powWad(SIZE_DECAY, elapsed));
        s.toxEma = wmul(s.toxEma, _powWad(TOX_DECAY, elapsed));
        s.confEma = _decayToward(s.confEma, CONF_NEUTRAL, CONF_DECAY, elapsed);
        s.stressEma = wmul(s.stressEma, _powWad(STRESS_DECAY, elapsed));
        s.flowBurstEma = wmul(s.flowBurstEma, _powWad(FLOW_BURST_DECAY, elapsed));

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

    function _updatePriceAndStepSignals(State memory s, TradeInfo calldata trade, bool firstInStep)
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

        bool likelyArb = firstInStep && tradeRatio <= ARB_MAX_RATIO;

        ret = s.pHat > 0 ? wdiv(absDiff(pImplied, s.pHat), s.pHat) : 0;
        if (ret > RET_CAP) ret = RET_CAP;

        uint256 alpha = PHAT_ALPHA_FOLLOW;
        if (firstInStep) alpha = likelyArb ? PHAT_ALPHA_FIRST_ARB : PHAT_ALPHA_FIRST;
        if (ret > PHAT_SHOCK_GATE) alpha = wmul(alpha, PHAT_SHOCK_DAMP);

        s.pHat = wmul(s.pHat, WAD - alpha) + wmul(pImplied, alpha);

        if (firstInStep) {
            uint256 sigmaInst = likelyArb ? ret : wmul(ret, 600000000000000000);
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

    function _updateToxicityBeliefAndRegime(State memory s, uint256 spot) internal pure returns (uint256 toxSignal) {
        uint256 tox = s.pHat > 0 ? wdiv(absDiff(spot, s.pHat), s.pHat) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;

        s.toxEma = wmul(s.toxEma, TOX_BLEND_DECAY) + wmul(tox, WAD - TOX_BLEND_DECAY);
        toxSignal = s.toxEma;

        uint256 confInst = _computeConfidence(s.sigmaHat, toxSignal, s.lambdaHat, s.flowBurstEma);
        s.confEma = wmul(s.confEma, CONF_BLEND_DECAY) + wmul(confInst, WAD - CONF_BLEND_DECAY);
        if (s.confEma < CONF_MIN) s.confEma = CONF_MIN;

        uint256 stressInst = _computeStress(s.sigmaHat, toxSignal, s.lambdaHat, s.flowBurstEma);
        s.stressEma = wmul(s.stressEma, STRESS_BLEND_DECAY) + wmul(stressInst, WAD - STRESS_BLEND_DECAY);
        if (s.stressEma > WAD) s.stressEma = WAD;
    }

    function _quoteFees(State memory s, uint256 spot, uint256 tradeRatio, uint256 ret, uint256 toxSignal, bool firstInStep)
        internal
        pure
        returns (uint256 bidFee, uint256 askFee)
    {
        (uint256 midTarget, uint256 splitTarget) = _computeMidAndSplit(s, tradeRatio, ret, toxSignal, firstInStep);
        (uint256 bidTarget, uint256 askTarget) = _applySkewAndShifts(s, spot, toxSignal, midTarget, splitTarget);
        (bidFee, askFee) = _finalizeQuotes(s, toxSignal, bidTarget, askTarget);
    }

    function _computeMidAndSplit(State memory s, uint256 tradeRatio, uint256 ret, uint256 toxSignal, bool firstInStep)
        internal
        pure
        returns (uint256 midTarget, uint256 splitTarget)
    {
        (uint256 fBase, uint256 toxAdd, uint256 actAdd) = _computeBaseToxAct(s, tradeRatio, ret, toxSignal, firstInStep);
        (midTarget, splitTarget) = _weightByConfidenceAndStress(s, fBase, toxAdd, actAdd);
    }

    function _computeBaseToxAct(State memory s, uint256 tradeRatio, uint256 ret, uint256 toxSignal, bool firstInStep)
        internal
        pure
        returns (uint256 fBase, uint256 toxAdd, uint256 actAdd)
    {
        bool toxAgreement = toxSignal > TOX_DEADBAND
            && (
                s.sigmaHat > SIGMA_DEADBAND || s.lambdaHat > LAMBDA_DEADBAND || s.sizeHat > SIZE_DEADBAND
                    || s.flowBurstEma > FLOW_DEADBAND
            );

        uint256 flowSize = wmul(s.lambdaHat, s.sizeHat);
        fBase = BASE_FEE + wmul(SIGMA_COEF, s.sigmaHat) + wmul(LAMBDA_COEF, s.lambdaHat) + wmul(FLOW_SIZE_COEF, flowSize);

        if (firstInStep) {
            uint256 revealSignal = ret + tradeRatio;
            if (revealSignal > WAD / 2) revealSignal = WAD / 2;
            fBase = fBase + wmul(FIRST_REVEAL_COEF, revealSignal);
        } else {
            fBase = fBase + wmul(FOLLOW_REVEAL_COEF, ret);
        }

        uint256 toxExcess = toxSignal > TOX_KNEE ? toxSignal - TOX_KNEE : 0;
        uint256 toxQuadAdd = wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        if (toxQuadAdd > TOX_QUAD_CAP) toxQuadAdd = TOX_QUAD_CAP;

        toxAdd = wmul(TOX_LINEAR_COEF, toxSignal) + toxQuadAdd;
        if (!toxAgreement) toxAdd = wmul(toxAdd, TOX_DISAGREE_MULT);

        actAdd = 0;
        if (s.lambdaHat >= ACT_GATE_LAMBDA && s.sizeHat >= ACT_GATE_SIZE && toxSignal > TOX_DEADBAND) {
            actAdd = wmul(ACT_COEF, s.actEma);
        }
    }

    function _weightByConfidenceAndStress(State memory s, uint256 fBase, uint256 toxAdd, uint256 actAdd)
        internal
        pure
        returns (uint256 midTarget, uint256 splitTarget)
    {
        uint256 favorableCore = wmul(toxAdd, TOX_FAVORABLE_MULT) + wmul(actAdd, ACT_FAVORABLE_MULT);
        uint256 protectCore = toxAdd + actAdd;

        uint256 guardMult = WAD + wmul(CONF_GUARD_COEF, WAD - s.confEma) + wmul(STRESS_GUARD_COEF, s.stressEma);
        if (guardMult > 2 * WAD) guardMult = 2 * WAD;

        uint256 attractMult = _computeAttractMult(s.confEma, s.stressEma);

        uint256 favorableAdd = wmul(favorableCore, attractMult);
        uint256 protectAdd = wmul(protectCore, guardMult);

        splitTarget = protectAdd > favorableAdd ? protectAdd - favorableAdd : 0;
        midTarget = fBase + favorableAdd;
        if (midTarget > MID_CAP) midTarget = MID_CAP;
    }

    function _computeAttractMult(uint256 confEma, uint256 stressEma) internal pure returns (uint256 attractMult) {
        uint256 confDiscount = wmul(ATTRACT_CONF_COEF, confEma);
        attractMult = WAD + wmul(ATTRACT_STRESS_COEF, stressEma);
        if (attractMult > confDiscount) {
            attractMult = attractMult - confDiscount;
        } else {
            attractMult = ATTRACT_MIN_MULT;
        }
        if (attractMult < ATTRACT_MIN_MULT) attractMult = ATTRACT_MIN_MULT;
        if (attractMult > WAD) attractMult = WAD;
    }

    function _applySkewAndShifts(State memory s, uint256 spot, uint256 toxSignal, uint256 midTarget, uint256 splitTarget)
        internal
        pure
        returns (uint256 bidTarget, uint256 askTarget)
    {
        uint256 dirDev;
        bool sellPressure;
        if (s.dirState >= WAD) {
            dirDev = s.dirState - WAD;
            sellPressure = true;
        } else {
            dirDev = WAD - s.dirState;
            sellPressure = false;
        }

        uint256 skew = wmul(DIR_COEF, dirDev) + wmul(DIR_STRESS_COEF, wmul(dirDev, s.stressEma));

        if (sellPressure) {
            bidTarget = midTarget + skew;
            askTarget = midTarget > skew ? midTarget - skew : 0;
        } else {
            askTarget = midTarget + skew;
            bidTarget = midTarget > skew ? midTarget - skew : 0;
        }

        if (splitTarget > 0) {
            if (spot >= s.pHat) {
                bidTarget = bidTarget + splitTarget;
            } else {
                askTarget = askTarget + splitTarget;
            }
        }

        uint256 staleShift = wmul(STALE_COEF, wmul(toxSignal, WAD - s.confEma));
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

    function _finalizeQuotes(State memory s, uint256 toxSignal, uint256 bidTarget, uint256 askTarget)
        internal
        pure
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 prevMid = (s.prevBidFee + s.prevAskFee) / 2;
        uint256 prevSpread = absDiff(s.prevBidFee, s.prevAskFee);

        uint256 midTarget = (bidTarget + askTarget) / 2;
        uint256 spreadTarget = absDiff(bidTarget, askTarget);

        uint256 spreadFloor = SPREAD_MIN + wmul(SPREAD_TOX_COEF, toxSignal) + wmul(SPREAD_STRESS_COEF, s.stressEma);
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

    function _computeConfidence(uint256 sigmaHat, uint256 toxSignal, uint256 lambdaHat, uint256 flowBurstEma)
        internal
        pure
        returns (uint256)
    {
        uint256 sigmaPenalty = 0;
        if (sigmaHat > CONF_SIGMA_KNEE) {
            uint256 sigmaExcess = sigmaHat - CONF_SIGMA_KNEE;
            if (sigmaExcess > CONF_SIGMA_SPAN) sigmaExcess = CONF_SIGMA_SPAN;
            sigmaPenalty = wmul(CONF_SIGMA_PENALTY_MAX, wdiv(sigmaExcess, CONF_SIGMA_SPAN));
        }

        uint256 toxPenalty = 0;
        if (toxSignal > CONF_TOX_KNEE) {
            uint256 toxExcess = toxSignal - CONF_TOX_KNEE;
            if (toxExcess > CONF_TOX_SPAN) toxExcess = CONF_TOX_SPAN;
            toxPenalty = wmul(CONF_TOX_PENALTY_MAX, wdiv(toxExcess, CONF_TOX_SPAN));
        }

        uint256 lambdaPenalty = 0;
        if (lambdaHat > CONF_LAMBDA_KNEE) {
            uint256 lambdaExcess = lambdaHat - CONF_LAMBDA_KNEE;
            if (lambdaExcess > CONF_LAMBDA_SPAN) lambdaExcess = CONF_LAMBDA_SPAN;
            lambdaPenalty = wmul(CONF_LAMBDA_PENALTY_MAX, wdiv(lambdaExcess, CONF_LAMBDA_SPAN));
        }

        uint256 flowPenalty = 0;
        if (flowBurstEma > FLOW_CONF_KNEE) {
            uint256 flowExcess = flowBurstEma - FLOW_CONF_KNEE;
            if (flowExcess > FLOW_CONF_SPAN) flowExcess = FLOW_CONF_SPAN;
            flowPenalty = wmul(CONF_FLOW_PENALTY_MAX, wdiv(flowExcess, FLOW_CONF_SPAN));
        }

        uint256 confSigma = WAD - sigmaPenalty;
        uint256 confTox = WAD - toxPenalty;
        uint256 confLambda = WAD - lambdaPenalty;
        uint256 confFlow = WAD - flowPenalty;

        uint256 weighted = 3 * confSigma + 3 * confTox + 2 * confLambda + 2 * confFlow;
        uint256 conf = weighted / 10;

        return conf < CONF_MIN ? CONF_MIN : conf;
    }

    function _computeStress(uint256 sigmaHat, uint256 toxSignal, uint256 lambdaHat, uint256 flowBurstEma)
        internal
        pure
        returns (uint256)
    {
        uint256 stress = wmul(STRESS_SIGMA_COEF, sigmaHat) + wmul(STRESS_TOX_COEF, toxSignal)
            + wmul(STRESS_LAMBDA_COEF, lambdaHat) + wmul(STRESS_FLOW_COEF, flowBurstEma);
        return stress > WAD ? WAD : stress;
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

    function getName() external pure override returns (string memory) {
        return "wildcard_mod_v276";
    }
}
