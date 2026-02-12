pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_WILDCARD_160","confidence":0.78,"ceiling_probability":0.22,"ev_next_5":0.21,"best_delta_seen":0.15,"reason":"Use continuous dual-anchor risk surface with multi-horizon flow pressure, impact-aware tail shaping, and risk-normalized rate limits to improve mixed-flow edge.","next_mechanism":"dual_anchor_flow_surface"}

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant STEP_COUNT_CAP = 96;

    uint256 constant SIGNAL_THRESHOLD = WAD / 1000;
    uint256 constant TRADE_RATIO_CAP = WAD / 4;
    uint256 constant RET_CAP = WAD / 7;
    uint256 constant TOX_CAP = WAD / 4;
    uint256 constant IMPACT_CAP = WAD / 5;
    uint256 constant GAP_CAP = WAD / 3;
    uint256 constant LAMBDA_CAP = 6 * WAD;

    uint256 constant PUSH_CAP_FAST = WAD / 6;
    uint256 constant PUSH_SLOW_MULT = 420000000000000000;

    uint256 constant FLOW_FAST_DECAY = 875000000000000000;
    uint256 constant FLOW_SLOW_DECAY = 952000000000000000;
    uint256 constant ACT_DECAY = 760000000000000000;
    uint256 constant SIZE_DECAY = 720000000000000000;
    uint256 constant TOX_DECAY = 910000000000000000;
    uint256 constant VOL_FAST_DECAY = 760000000000000000;
    uint256 constant VOL_SLOW_DECAY = 945000000000000000;
    uint256 constant IMPACT_DECAY = 890000000000000000;
    uint256 constant GAP_DECAY = 905000000000000000;
    uint256 constant LAMBDA_DECAY = 993000000000000000;

    uint256 constant ACT_BLEND_DECAY = 993000000000000000;
    uint256 constant SIZE_BLEND_DECAY = 860000000000000000;
    uint256 constant VOL_FAST_BLEND_DECAY = 680000000000000000;
    uint256 constant VOL_SLOW_BLEND_DECAY = 935000000000000000;
    uint256 constant TOX_BLEND_DECAY = 280000000000000000;
    uint256 constant IMPACT_BLEND_DECAY = 580000000000000000;
    uint256 constant GAP_BLEND_DECAY = 750000000000000000;
    uint256 constant LAMBDA_BLEND_DECAY = 988000000000000000;

    uint256 constant ALPHA_FAST_BASE = 100000000000000000;
    uint256 constant ALPHA_FAST_SIZE_COEF = 620000000000000000;
    uint256 constant ALPHA_FAST_GAP_COEF = 220000000000000000;
    uint256 constant ALPHA_FAST_IMPACT_COEF = 180000000000000000;
    uint256 constant ALPHA_FAST_MAX = 450000000000000000;

    uint256 constant ALPHA_SLOW_BASE = 13000000000000000;
    uint256 constant ALPHA_SLOW_SIZE_COEF = 80000000000000000;
    uint256 constant ALPHA_SLOW_GAP_COEF = 55000000000000000;
    uint256 constant ALPHA_SLOW_IMPACT_COEF = 40000000000000000;
    uint256 constant ALPHA_SLOW_MAX = 95000000000000000;

    uint256 constant ALPHA_DAMP_KNEE = 24000000000000000;
    uint256 constant ALPHA_DAMP_SLOPE = 1500000000000000000;
    uint256 constant ALPHA_DAMP_CAP = 840000000000000000;
    uint256 constant ALPHA_SLOW_DAMP_MULT = 680000000000000000;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant VOL_FAST_COEF = 120000000000000000;
    uint256 constant VOL_SLOW_COEF = 85000000000000000;
    uint256 constant VOL_GAP_COEF = 190000000000000000;

    uint256 constant TOX_COEF = 220 * BPS;
    uint256 constant TOX_QUAD_COEF = 19500 * BPS;
    uint256 constant TOX_KNEE = 10 * BPS;

    uint256 constant IMPACT_COEF = 5000 * BPS;
    uint256 constant IMPACT_QUAD_COEF = 8500 * BPS;
    uint256 constant IMPACT_KNEE = 8 * BPS;

    uint256 constant ACT_COEF = 30000 * BPS;
    uint256 constant SIZE_COEF = 7000 * BPS;
    uint256 constant LAMBDA_COEF = 9 * BPS;
    uint256 constant FLOW_COEF = 4300 * BPS;
    uint256 constant GAP_COEF = 95 * BPS;

    uint256 constant DIR_FAST_WEIGHT = 660000000000000000;
    uint256 constant DIR_COEF = 112 * BPS;
    uint256 constant DIR_TOX_COEF = 38 * BPS;
    uint256 constant DIR_GAP_COEF = 32 * BPS;
    uint256 constant DIR_IMPACT_COEF = 26 * BPS;
    uint256 constant DIR_LEAD_COEF = 46 * BPS;

    uint256 constant STALE_TOX_COEF = 5000 * BPS;
    uint256 constant STALE_GAP_COEF = 80 * BPS;
    uint256 constant STALE_IMPACT_COEF = 2300 * BPS;
    uint256 constant TREND_COEF = 75 * BPS;

    uint256 constant TAIL_KNEE_BASE = 610 * BPS;
    uint256 constant TAIL_KNEE_VOL_COEF = 2200 * BPS;
    uint256 constant TAIL_KNEE_TOX_COEF = 1600 * BPS;
    uint256 constant TAIL_KNEE_GAP_COEF = 1200 * BPS;
    uint256 constant TAIL_KNEE_IMPACT_COEF = 1200 * BPS;
    uint256 constant TAIL_KNEE_MAX = WAD / 8;

    uint256 constant TAIL_SLOPE_PROTECT_BASE = 750000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT_BASE = 950000000000000000;
    uint256 constant TAIL_SLOPE_TOX_ADJ = 240000000000000000;
    uint256 constant TAIL_SLOPE_VOL_ADJ = 110000000000000000;
    uint256 constant TAIL_SLOPE_GAP_ADJ = 90000000000000000;
    uint256 constant TAIL_SLOPE_IMPACT_ADJ = 100000000000000000;

    uint256 constant RATE_UP_MIN = 45 * BPS;
    uint256 constant RATE_UP_RISK_RANGE = 175 * BPS;
    uint256 constant RATE_DOWN_MIN = 30 * BPS;
    uint256 constant RATE_DOWN_RISK_RANGE = 150 * BPS;

    uint256 constant SIDE_FLOOR = 1 * BPS;

    struct State {
        uint256 bidFee;
        uint256 askFee;
        uint256 flowFast;
        uint256 flowSlow;
        uint256 actEma;
        uint256 pFast;
        uint256 pSlow;
        uint256 volFast;
        uint256 volSlow;
        uint256 toxEma;
        uint256 sizeEma;
        uint256 lambdaEma;
        uint256 impactEma;
        uint256 gapEma;
        uint256 stepTradeCount;
        uint256 lastSpot;
    }

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;

        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD;
        slots[4] = WAD;
        slots[5] = 0;
        slots[6] = p0;
        slots[7] = p0;
        slots[8] = 900000000000000;
        slots[9] = 700000000000000;
        slots[10] = 0;
        slots[11] = 1500000000000000;
        slots[12] = 900000000000000000;
        slots[13] = 0;
        slots[14] = 0;
        slots[15] = 0;
        slots[16] = p0;

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        State memory s = _loadState();
        uint256 lastTs = slots[2];

        if (trade.timestamp > lastTs) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            _decayState(s, elapsed);
            _updateLambdaFromStepCount(s, elapsedRaw);
            s.stepTradeCount = 0;
        }

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : s.pSlow;
        if (spot == 0) spot = s.pFast;
        if (spot == 0) spot = WAD;

        if (s.pSlow == 0) s.pSlow = spot;
        if (s.pFast == 0) s.pFast = spot;
        if (s.lastSpot == 0) s.lastSpot = spot;

        uint256 feeUsed = trade.isBuy ? s.bidFee : s.askFee;
        uint256 pImplied = _calcImpliedPrice(spot, feeUsed, trade.isBuy);
        uint256 tradeRatio = _tradeRatio(trade);

        _updateFlowSignals(s, trade.isBuy, tradeRatio);
        _updateRiskSignals(s, pImplied, spot);
        _updateAnchors(s, pImplied, tradeRatio);

        uint256 fMid = _computeMidFee(s);
        (uint256 bidFee, uint256 askFee) = _computeRawSideFees(s, fMid);
        (bidFee, askFee) = _applyContextShifts(s, bidFee, askFee, spot);
        (bidFee, askFee) = _applyTailCompression(s, bidFee, askFee);

        uint256 riskNorm = _riskNorm(s);
        bidFee = _applyRateLimit(s.bidFee, bidFee, riskNorm);
        askFee = _applyRateLimit(s.askFee, askFee, riskNorm);

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        if (bidFee < SIDE_FLOOR) bidFee = SIDE_FLOOR;
        if (askFee < SIDE_FLOOR) askFee = SIDE_FLOOR;

        s.bidFee = bidFee;
        s.askFee = askFee;
        s.lastSpot = spot;

        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;

        _storeState(s, trade.timestamp);
        return (bidFee, askFee);
    }

    function _loadState() internal view returns (State memory s) {
        s.bidFee = slots[0];
        s.askFee = slots[1];
        s.flowFast = slots[3];
        s.flowSlow = slots[4];
        s.actEma = slots[5];
        s.pFast = slots[6];
        s.pSlow = slots[7];
        s.volFast = slots[8];
        s.volSlow = slots[9];
        s.toxEma = slots[10];
        s.sizeEma = slots[11];
        s.lambdaEma = slots[12];
        s.impactEma = slots[13];
        s.gapEma = slots[14];
        s.stepTradeCount = slots[15];
        s.lastSpot = slots[16];
    }

    function _storeState(State memory s, uint256 ts) internal {
        slots[0] = s.bidFee;
        slots[1] = s.askFee;
        slots[2] = ts;
        slots[3] = s.flowFast;
        slots[4] = s.flowSlow;
        slots[5] = s.actEma;
        slots[6] = s.pFast;
        slots[7] = s.pSlow;
        slots[8] = s.volFast;
        slots[9] = s.volSlow;
        slots[10] = s.toxEma;
        slots[11] = s.sizeEma;
        slots[12] = s.lambdaEma;
        slots[13] = s.impactEma;
        slots[14] = s.gapEma;
        slots[15] = s.stepTradeCount;
        slots[16] = s.lastSpot;
    }

    function _decayState(State memory s, uint256 elapsed) internal pure {
        s.flowFast = _decayCentered(s.flowFast, FLOW_FAST_DECAY, elapsed);
        s.flowSlow = _decayCentered(s.flowSlow, FLOW_SLOW_DECAY, elapsed);

        s.actEma = wmul(s.actEma, _powWad(ACT_DECAY, elapsed));
        s.sizeEma = wmul(s.sizeEma, _powWad(SIZE_DECAY, elapsed));
        s.toxEma = wmul(s.toxEma, _powWad(TOX_DECAY, elapsed));
        s.volFast = wmul(s.volFast, _powWad(VOL_FAST_DECAY, elapsed));
        s.volSlow = wmul(s.volSlow, _powWad(VOL_SLOW_DECAY, elapsed));
        s.impactEma = wmul(s.impactEma, _powWad(IMPACT_DECAY, elapsed));
        s.gapEma = wmul(s.gapEma, _powWad(GAP_DECAY, elapsed));
        s.lambdaEma = wmul(s.lambdaEma, _powWad(LAMBDA_DECAY, elapsed));
    }

    function _updateLambdaFromStepCount(State memory s, uint256 elapsedRaw) internal pure {
        if (s.stepTradeCount == 0 || elapsedRaw == 0) return;

        uint256 lambdaInst = (s.stepTradeCount * WAD) / elapsedRaw;
        if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;

        s.lambdaEma = wmul(s.lambdaEma, LAMBDA_BLEND_DECAY) + wmul(lambdaInst, WAD - LAMBDA_BLEND_DECAY);
    }

    function _tradeRatio(TradeInfo calldata trade) internal pure returns (uint256 ratio) {
        ratio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (ratio > TRADE_RATIO_CAP) ratio = TRADE_RATIO_CAP;
    }

    function _calcImpliedPrice(uint256 spot, uint256 feeUsed, bool isBuy) internal pure returns (uint256) {
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        if (gamma == 0) return spot;
        return isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
    }

    function _updateFlowSignals(State memory s, bool isBuy, uint256 tradeRatio) internal pure {
        s.actEma = wmul(s.actEma, ACT_BLEND_DECAY) + wmul(tradeRatio, WAD - ACT_BLEND_DECAY);
        s.sizeEma = wmul(s.sizeEma, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
        if (s.sizeEma > WAD) s.sizeEma = WAD;

        if (tradeRatio <= SIGNAL_THRESHOLD) return;

        uint256 pushFast = tradeRatio > PUSH_CAP_FAST ? PUSH_CAP_FAST : tradeRatio;
        uint256 pushSlow = wmul(pushFast, PUSH_SLOW_MULT);

        if (isBuy) {
            s.flowFast = s.flowFast + pushFast;
            if (s.flowFast > 2 * WAD) s.flowFast = 2 * WAD;

            s.flowSlow = s.flowSlow + pushSlow;
            if (s.flowSlow > 2 * WAD) s.flowSlow = 2 * WAD;
        } else {
            s.flowFast = s.flowFast > pushFast ? s.flowFast - pushFast : 0;
            s.flowSlow = s.flowSlow > pushSlow ? s.flowSlow - pushSlow : 0;
        }
    }

    function _updateRiskSignals(State memory s, uint256 pImplied, uint256 spot) internal pure {
        uint256 retFast = s.pFast > 0 ? wdiv(absDiff(pImplied, s.pFast), s.pFast) : 0;
        uint256 retSlow = s.pSlow > 0 ? wdiv(absDiff(pImplied, s.pSlow), s.pSlow) : 0;
        if (retFast > RET_CAP) retFast = RET_CAP;
        if (retSlow > RET_CAP) retSlow = RET_CAP;

        s.volFast = wmul(s.volFast, VOL_FAST_BLEND_DECAY) + wmul(retFast, WAD - VOL_FAST_BLEND_DECAY);
        s.volSlow = wmul(s.volSlow, VOL_SLOW_BLEND_DECAY) + wmul(retSlow, WAD - VOL_SLOW_BLEND_DECAY);

        uint256 tox = s.pSlow > 0 ? wdiv(absDiff(spot, s.pSlow), s.pSlow) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;
        s.toxEma = wmul(s.toxEma, TOX_BLEND_DECAY) + wmul(tox, WAD - TOX_BLEND_DECAY);

        uint256 moveInst = s.lastSpot > 0 ? wdiv(absDiff(spot, s.lastSpot), s.lastSpot) : 0;
        uint256 impactInst = moveInst + (tox / 2);
        if (impactInst > IMPACT_CAP) impactInst = IMPACT_CAP;
        s.impactEma = wmul(s.impactEma, IMPACT_BLEND_DECAY) + wmul(impactInst, WAD - IMPACT_BLEND_DECAY);

        uint256 gapInst = s.pSlow > 0 ? wdiv(absDiff(s.pFast, s.pSlow), s.pSlow) : 0;
        if (gapInst > GAP_CAP) gapInst = GAP_CAP;
        s.gapEma = wmul(s.gapEma, GAP_BLEND_DECAY) + wmul(gapInst, WAD - GAP_BLEND_DECAY);
    }

    function _updateAnchors(State memory s, uint256 pImplied, uint256 tradeRatio) internal pure {
        uint256 alphaFast = ALPHA_FAST_BASE
            + wmul(ALPHA_FAST_SIZE_COEF, tradeRatio)
            + wmul(ALPHA_FAST_GAP_COEF, s.gapEma)
            + wmul(ALPHA_FAST_IMPACT_COEF, s.impactEma);
        if (alphaFast > ALPHA_FAST_MAX) alphaFast = ALPHA_FAST_MAX;

        uint256 alphaSlow = ALPHA_SLOW_BASE
            + wmul(ALPHA_SLOW_SIZE_COEF, tradeRatio)
            + wmul(ALPHA_SLOW_GAP_COEF, s.gapEma)
            + wmul(ALPHA_SLOW_IMPACT_COEF, s.impactEma);
        if (alphaSlow > ALPHA_SLOW_MAX) alphaSlow = ALPHA_SLOW_MAX;

        uint256 riskMix = s.toxEma + s.impactEma + s.gapEma;
        if (riskMix > WAD) riskMix = WAD;

        if (riskMix > ALPHA_DAMP_KNEE) {
            uint256 damp = wmul(ALPHA_DAMP_SLOPE, riskMix - ALPHA_DAMP_KNEE);
            if (damp > ALPHA_DAMP_CAP) damp = ALPHA_DAMP_CAP;

            alphaFast = wmul(alphaFast, WAD - damp);
            uint256 slowDamp = wmul(damp, ALPHA_SLOW_DAMP_MULT);
            alphaSlow = wmul(alphaSlow, WAD - slowDamp);
        }

        if (alphaFast > 0) s.pFast = wmul(s.pFast, WAD - alphaFast) + wmul(pImplied, alphaFast);
        if (alphaSlow > 0) s.pSlow = wmul(s.pSlow, WAD - alphaSlow) + wmul(pImplied, alphaSlow);
    }

    function _computeMidFee(State memory s) internal pure returns (uint256 fMid) {
        uint256 flowSize = wmul(s.lambdaEma, s.sizeEma);
        if (flowSize > WAD) flowSize = WAD;

        uint256 volGap = s.volFast > s.volSlow ? s.volFast - s.volSlow : 0;
        uint256 toxExcess = s.toxEma > TOX_KNEE ? s.toxEma - TOX_KNEE : 0;
        uint256 impactExcess = s.impactEma > IMPACT_KNEE ? s.impactEma - IMPACT_KNEE : 0;

        fMid = BASE_FEE;
        fMid = fMid + wmul(VOL_FAST_COEF, s.volFast);
        fMid = fMid + wmul(VOL_SLOW_COEF, s.volSlow);
        fMid = fMid + wmul(VOL_GAP_COEF, volGap);
        fMid = fMid + wmul(TOX_COEF, s.toxEma);
        fMid = fMid + wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        fMid = fMid + wmul(IMPACT_COEF, s.impactEma);
        fMid = fMid + wmul(IMPACT_QUAD_COEF, wmul(impactExcess, impactExcess));
        fMid = fMid + wmul(ACT_COEF, s.actEma);
        fMid = fMid + wmul(SIZE_COEF, s.sizeEma);
        fMid = fMid + wmul(LAMBDA_COEF, s.lambdaEma);
        fMid = fMid + wmul(FLOW_COEF, flowSize);
        fMid = fMid + wmul(GAP_COEF, s.gapEma);
    }

    function _computeRawSideFees(State memory s, uint256 fMid) internal pure returns (uint256 bidFee, uint256 askFee) {
        uint256 dirBlend = wmul(s.flowFast, DIR_FAST_WEIGHT) + wmul(s.flowSlow, WAD - DIR_FAST_WEIGHT);

        uint256 dirDev;
        bool sellPressure;
        if (dirBlend >= WAD) {
            dirDev = dirBlend - WAD;
            sellPressure = true;
        } else {
            dirDev = WAD - dirBlend;
            sellPressure = false;
        }

        uint256 flowLead = s.flowFast > s.flowSlow ? s.flowFast - s.flowSlow : s.flowSlow - s.flowFast;

        uint256 skew = wmul(DIR_COEF, dirDev)
            + wmul(DIR_TOX_COEF, wmul(dirDev, s.toxEma))
            + wmul(DIR_GAP_COEF, wmul(dirDev, s.gapEma))
            + wmul(DIR_IMPACT_COEF, wmul(dirDev, s.impactEma))
            + wmul(DIR_LEAD_COEF, wmul(dirDev, flowLead));

        if (sellPressure) {
            bidFee = fMid + skew;
            askFee = fMid > skew ? fMid - skew : 0;
        } else {
            askFee = fMid + skew;
            bidFee = fMid > skew ? fMid - skew : 0;
        }
    }

    function _applyContextShifts(
        State memory s,
        uint256 bidFee,
        uint256 askFee,
        uint256 spot
    ) internal pure returns (uint256, uint256) {
        uint256 staleShift = wmul(STALE_TOX_COEF, s.toxEma)
            + wmul(STALE_GAP_COEF, s.gapEma)
            + wmul(STALE_IMPACT_COEF, s.impactEma);

        if (spot >= s.pSlow) {
            bidFee = bidFee + staleShift;
            askFee = askFee > staleShift ? askFee - staleShift : 0;
        } else {
            askFee = askFee + staleShift;
            bidFee = bidFee > staleShift ? bidFee - staleShift : 0;
        }

        uint256 trendShift = wmul(TREND_COEF, s.gapEma);
        if (s.pFast >= s.pSlow) {
            bidFee = bidFee + trendShift;
            askFee = askFee > trendShift ? askFee - trendShift : 0;
        } else {
            askFee = askFee + trendShift;
            bidFee = bidFee > trendShift ? bidFee - trendShift : 0;
        }

        return (bidFee, askFee);
    }

    function _applyTailCompression(
        State memory s,
        uint256 bidFee,
        uint256 askFee
    ) internal pure returns (uint256, uint256) {
        uint256 tailKnee = TAIL_KNEE_BASE
            + wmul(TAIL_KNEE_VOL_COEF, s.volSlow)
            + wmul(TAIL_KNEE_TOX_COEF, s.toxEma)
            + wmul(TAIL_KNEE_GAP_COEF, s.gapEma)
            + wmul(TAIL_KNEE_IMPACT_COEF, s.impactEma);
        if (tailKnee > TAIL_KNEE_MAX) tailKnee = TAIL_KNEE_MAX;

        uint256 slopeCut = wmul(TAIL_SLOPE_TOX_ADJ, s.toxEma)
            + wmul(TAIL_SLOPE_VOL_ADJ, s.volFast)
            + wmul(TAIL_SLOPE_GAP_ADJ, s.gapEma)
            + wmul(TAIL_SLOPE_IMPACT_ADJ, s.impactEma);

        uint256 protectSlope = TAIL_SLOPE_PROTECT_BASE > slopeCut ? TAIL_SLOPE_PROTECT_BASE - slopeCut : WAD / 2;
        if (protectSlope < WAD / 2) protectSlope = WAD / 2;

        uint256 attractSlope = TAIL_SLOPE_ATTRACT_BASE + (slopeCut / 2);
        if (attractSlope > WAD) attractSlope = WAD;

        if (bidFee > askFee) {
            bidFee = _compressTail(bidFee, tailKnee, protectSlope);
            askFee = _compressTail(askFee, tailKnee, attractSlope);
        } else if (askFee > bidFee) {
            bidFee = _compressTail(bidFee, tailKnee, attractSlope);
            askFee = _compressTail(askFee, tailKnee, protectSlope);
        } else {
            uint256 midSlope = (protectSlope + attractSlope) / 2;
            bidFee = _compressTail(bidFee, tailKnee, midSlope);
            askFee = _compressTail(askFee, tailKnee, midSlope);
        }

        return (bidFee, askFee);
    }

    function _riskNorm(State memory s) internal pure returns (uint256 riskNorm) {
        uint256 volGap = s.volFast > s.volSlow ? s.volFast - s.volSlow : 0;
        riskNorm = s.toxEma + s.impactEma + s.gapEma + s.volSlow + (volGap / 2) + (s.actEma / 3);
        if (riskNorm > WAD) riskNorm = WAD;
    }

    function _applyRateLimit(uint256 prevFee, uint256 targetFee, uint256 riskNorm) internal pure returns (uint256) {
        uint256 upCap = RATE_UP_MIN + wmul(RATE_UP_RISK_RANGE, riskNorm);
        uint256 downCap = RATE_DOWN_MIN + wmul(RATE_DOWN_RISK_RANGE, WAD - riskNorm);

        if (targetFee > prevFee) {
            uint256 upMove = targetFee - prevFee;
            if (upMove > upCap) return prevFee + upCap;
            return targetFee;
        }

        uint256 downMove = prevFee - targetFee;
        if (downMove > downCap) return prevFee - downCap;
        return targetFee;
    }

    function _compressTail(uint256 fee, uint256 knee, uint256 slope) internal pure returns (uint256) {
        if (fee <= knee) return fee;
        return knee + wmul(fee - knee, slope);
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
        return "wildcard_mod_v160";
    }
}
