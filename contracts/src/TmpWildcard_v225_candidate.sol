pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_WILDCARD_225","confidence":0.76,"ceiling_probability":0.2,"ev_next_5":0.16,"best_delta_seen":0.27,"reason":"Shift to continuous dual-anchor plus explicit impact-per-size state and inventory/trend surface for stronger adverse-selection response without calm-period over-widening.","next_mechanism":"impact_inventory_surface"}

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant SIGNAL_THRESHOLD = WAD / 700;

    uint256 constant SIZE_DECAY = 620000000000000000;
    uint256 constant TOX_DECAY = 900000000000000000;
    uint256 constant TOXVAR_DECAY = 890000000000000000;
    uint256 constant FLOW_DECAY = 930000000000000000;
    uint256 constant BURST_DECAY = 770000000000000000;
    uint256 constant DISAGREE_DECAY = 880000000000000000;
    uint256 constant INV_DECAY = 940000000000000000;
    uint256 constant JUMP_DECAY = 820000000000000000;
    uint256 constant IMPACT_DECAY = 870000000000000000;
    uint256 constant SIGMA_FAST_DECAY = 720000000000000000;
    uint256 constant SIGMA_SLOW_DECAY = 940000000000000000;
    uint256 constant LAMBDA_IDLE_DECAY = 965000000000000000;
    uint256 constant LAMBDA_BLEND_DECAY = 992000000000000000;

    uint256 constant SIZE_BLEND_DECAY = 790000000000000000;
    uint256 constant TOX_BLEND_DECAY = 120000000000000000;
    uint256 constant TOXVAR_BLEND_DECAY = 850000000000000000;
    uint256 constant FLOW_BLEND_DECAY = 930000000000000000;
    uint256 constant BURST_BLEND_DECAY = 770000000000000000;
    uint256 constant DISAGREE_BLEND_DECAY = 860000000000000000;
    uint256 constant INV_BLEND_DECAY = 940000000000000000;
    uint256 constant JUMP_BLEND_DECAY = 800000000000000000;
    uint256 constant IMPACT_BLEND_DECAY = 820000000000000000;
    uint256 constant SIGMA_FAST_BLEND = 690000000000000000;
    uint256 constant SIGMA_SLOW_BLEND = 960000000000000000;

    uint256 constant FAST_ALPHA_BASE = 70000000000000000;
    uint256 constant FAST_ALPHA_SIZE = 300000000000000000;
    uint256 constant FAST_ALPHA_DISAGREE = 120000000000000000;
    uint256 constant FAST_ALPHA_MAX = 360000000000000000;

    uint256 constant SLOW_ALPHA_BASE = 12000000000000000;
    uint256 constant SLOW_ALPHA_SIZE = 110000000000000000;
    uint256 constant SLOW_ALPHA_MAX = 130000000000000000;

    uint256 constant FAST_MOVE_CAP = 170 * BPS;
    uint256 constant SLOW_MOVE_CAP = 65 * BPS;

    uint256 constant RET_CAP = WAD / 10;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant DISAGREE_CAP = WAD / 4;
    uint256 constant TRADE_RATIO_CAP = WAD / 5;
    uint256 constant IMPACT_CAP = WAD / 2;
    uint256 constant IMPACT_DENOM_FLOOR = 15 * BPS;
    uint256 constant LAMBDA_CAP = 5 * WAD;
    uint256 constant STEP_COUNT_CAP = 64;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant SIGMA_FAST_WEIGHT = 680000000000000000;
    uint256 constant SIGMA_COEF = 205000000000000000;
    uint256 constant LAMBDA_COEF = 10 * BPS;
    uint256 constant FLOW_SIZE_COEF = 7000 * BPS;

    uint256 constant TOX_COEF = 165 * BPS;
    uint256 constant TOX_QUAD_COEF = 16500 * BPS;
    uint256 constant TOX_QUAD_KNEE = 12 * BPS;
    uint256 constant TOXVAR_COEF = 7600 * BPS;
    uint256 constant DISAGREE_COEF = 12000 * BPS;
    uint256 constant BURST_COEF = 10500 * BPS;
    uint256 constant JUMP_COEF = 8200 * BPS;
    uint256 constant IMPACT_COEF = 145 * BPS;
    uint256 constant TWOSIDE_COEF = 2400 * BPS;
    uint256 constant INV_MID_COEF = 3300 * BPS;

    uint256 constant DIR_FLOW_COEF = 95 * BPS;
    uint256 constant DIR_TOX_COEF = 24 * BPS;
    uint256 constant DIR_DISAGREE_COEF = 56 * BPS;
    uint256 constant DIR_IMPACT_COEF = 42 * BPS;
    uint256 constant INV_SKEW_COEF = 84 * BPS;
    uint256 constant TREND_SKEW_COEF = 66 * BPS;
    uint256 constant STALE_SHIFT_COEF = 5400 * BPS;

    uint256 constant TAIL_KNEE_BASE = 680 * BPS;
    uint256 constant TAIL_KNEE_TOX_COEF = 2100 * BPS;
    uint256 constant TAIL_KNEE_VOL_COEF = 1500 * BPS;
    uint256 constant TAIL_KNEE_DISAGREE_COEF = 1700 * BPS;
    uint256 constant TAIL_KNEE_JUMP_COEF = 1600 * BPS;
    uint256 constant TAIL_KNEE_IMPACT_COEF = 1900 * BPS;
    uint256 constant TAIL_KNEE_MAX = 1250 * BPS;

    uint256 constant TAIL_SLOPE = 900000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 820000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 965000000000000000;

    uint256 constant RATE_UP_MIN = 34 * BPS;
    uint256 constant RATE_UP_RISK_RANGE = 185 * BPS;
    uint256 constant RATE_DOWN_MIN = 22 * BPS;
    uint256 constant RATE_DOWN_CALM_RANGE = 150 * BPS;

    uint256 constant HALF_WAD = WAD / 2;
    uint256 constant SIDE_FLOOR = 1 * BPS;

    struct SwapState {
        uint256 prevBidFee;
        uint256 prevAskFee;
        uint256 pFast;
        uint256 pSlow;
        uint256 sigmaFast;
        uint256 sigmaSlow;
        uint256 lambdaHat;
        uint256 sizeHat;
        uint256 toxEma;
        uint256 toxVar;
        uint256 sellXFlow;
        uint256 buyXFlow;
        uint256 burstEma;
        uint256 disagreeEma;
        uint256 invSkewEma;
        uint256 stepTradeCount;
        uint256 jumpEma;
        uint256 prevSpot;
        uint256 impactEma;
    }

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;

        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = p0;
        slots[4] = p0;
        slots[5] = 1000000000000000;
        slots[6] = 1000000000000000;
        slots[7] = 800000000000000000;
        slots[8] = 2000000000000000;
        slots[9] = 0;
        slots[10] = 0;
        slots[11] = 0;
        slots[12] = 0;
        slots[13] = 0;
        slots[14] = 0;
        slots[15] = 0;
        slots[16] = 0;
        slots[17] = 0;
        slots[18] = p0;
        slots[19] = 0;

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        SwapState memory s = _loadState();

        _decayOnNewStep(s, trade.timestamp, slots[2]);

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : s.pFast;
        if (s.pFast == 0) s.pFast = spot;
        if (s.pSlow == 0) s.pSlow = spot;
        if (s.prevSpot == 0) s.prevSpot = spot;

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        uint256 pImplied = _calcImplied(spot, trade.isBuy ? s.prevBidFee : s.prevAskFee, trade.isBuy);

        _updateFlowState(s, trade.isBuy, tradeRatio);
        _updatePriceState(s, spot, pImplied, tradeRatio);
        (bool invSellPressure, uint256 trendGap, bool trendSellPressure) = _updateInventoryAndTrend(s, trade.reserveX, trade.reserveY);

        (uint256 bidFee, uint256 askFee, uint256 volMix) = _rawQuote(s, spot, invSellPressure, trendGap, trendSellPressure);

        uint256 riskNorm = _riskNorm(s, volMix);

        bidFee = _applyRateLimit(s.prevBidFee, bidFee, riskNorm);
        askFee = _applyRateLimit(s.prevAskFee, askFee, riskNorm);

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        if (bidFee < SIDE_FLOOR) bidFee = SIDE_FLOOR;
        if (askFee < SIDE_FLOOR) askFee = SIDE_FLOOR;

        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;

        s.prevSpot = spot;

        _storeState(s, trade.timestamp, bidFee, askFee);
        return (bidFee, askFee);
    }

    function _loadState() internal view returns (SwapState memory s) {
        s.prevBidFee = slots[0];
        s.prevAskFee = slots[1];
        s.pFast = slots[3];
        s.pSlow = slots[4];
        s.sigmaFast = slots[5];
        s.sigmaSlow = slots[6];
        s.lambdaHat = slots[7];
        s.sizeHat = slots[8];
        s.toxEma = slots[9];
        s.toxVar = slots[10];
        s.sellXFlow = slots[11];
        s.buyXFlow = slots[12];
        s.burstEma = slots[13];
        s.disagreeEma = slots[14];
        s.invSkewEma = slots[15];
        s.stepTradeCount = slots[16];
        s.jumpEma = slots[17];
        s.prevSpot = slots[18];
        s.impactEma = slots[19];
    }

    function _storeState(SwapState memory s, uint256 ts, uint256 bidFee, uint256 askFee) internal {
        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = ts;
        slots[3] = s.pFast;
        slots[4] = s.pSlow;
        slots[5] = s.sigmaFast;
        slots[6] = s.sigmaSlow;
        slots[7] = s.lambdaHat;
        slots[8] = s.sizeHat;
        slots[9] = s.toxEma;
        slots[10] = s.toxVar;
        slots[11] = s.sellXFlow;
        slots[12] = s.buyXFlow;
        slots[13] = s.burstEma;
        slots[14] = s.disagreeEma;
        slots[15] = s.invSkewEma;
        slots[16] = s.stepTradeCount;
        slots[17] = s.jumpEma;
        slots[18] = s.prevSpot;
        slots[19] = s.impactEma;
    }

    function _decayOnNewStep(SwapState memory s, uint256 ts, uint256 lastTs) internal pure {
        if (ts <= lastTs) return;

        uint256 elapsedRaw = ts - lastTs;
        uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

        s.sizeHat = wmul(s.sizeHat, _powWad(SIZE_DECAY, elapsed));
        s.toxEma = wmul(s.toxEma, _powWad(TOX_DECAY, elapsed));
        s.toxVar = wmul(s.toxVar, _powWad(TOXVAR_DECAY, elapsed));
        s.sellXFlow = wmul(s.sellXFlow, _powWad(FLOW_DECAY, elapsed));
        s.buyXFlow = wmul(s.buyXFlow, _powWad(FLOW_DECAY, elapsed));
        s.burstEma = wmul(s.burstEma, _powWad(BURST_DECAY, elapsed));
        s.disagreeEma = wmul(s.disagreeEma, _powWad(DISAGREE_DECAY, elapsed));
        s.invSkewEma = wmul(s.invSkewEma, _powWad(INV_DECAY, elapsed));
        s.jumpEma = wmul(s.jumpEma, _powWad(JUMP_DECAY, elapsed));
        s.impactEma = wmul(s.impactEma, _powWad(IMPACT_DECAY, elapsed));
        s.sigmaFast = wmul(s.sigmaFast, _powWad(SIGMA_FAST_DECAY, elapsed));
        s.sigmaSlow = wmul(s.sigmaSlow, _powWad(SIGMA_SLOW_DECAY, elapsed));
        s.lambdaHat = wmul(s.lambdaHat, _powWad(LAMBDA_IDLE_DECAY, elapsed));

        if (s.stepTradeCount > 0 && elapsedRaw > 0) {
            uint256 lambdaInst = (s.stepTradeCount * WAD) / elapsedRaw;
            if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
            s.lambdaHat = wmul(s.lambdaHat, LAMBDA_BLEND_DECAY) + wmul(lambdaInst, WAD - LAMBDA_BLEND_DECAY);
        }
        if (s.lambdaHat > LAMBDA_CAP) s.lambdaHat = LAMBDA_CAP;

        s.stepTradeCount = 0;
    }

    function _updateFlowState(SwapState memory s, bool isBuy, uint256 tradeRatio) internal pure {
        s.sizeHat = wmul(s.sizeHat, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
        if (s.sizeHat > WAD) s.sizeHat = WAD;

        uint256 signal = tradeRatio > SIGNAL_THRESHOLD ? tradeRatio : 0;
        s.burstEma = wmul(s.burstEma, BURST_BLEND_DECAY) + wmul(signal, WAD - BURST_BLEND_DECAY);

        if (isBuy) {
            s.sellXFlow = wmul(s.sellXFlow, FLOW_BLEND_DECAY) + wmul(tradeRatio, WAD - FLOW_BLEND_DECAY);
            s.buyXFlow = wmul(s.buyXFlow, FLOW_BLEND_DECAY);
        } else {
            s.buyXFlow = wmul(s.buyXFlow, FLOW_BLEND_DECAY) + wmul(tradeRatio, WAD - FLOW_BLEND_DECAY);
            s.sellXFlow = wmul(s.sellXFlow, FLOW_BLEND_DECAY);
        }
    }

    function _updatePriceState(SwapState memory s, uint256 spot, uint256 pImplied, uint256 tradeRatio) internal pure {
        _updateAnchorsAndVol(s, pImplied, tradeRatio);
        _updateToxicityAndImpact(s, spot, tradeRatio);
    }

    function _updateAnchorsAndVol(SwapState memory s, uint256 pImplied, uint256 tradeRatio) internal pure {
        uint256 retFast = s.pFast > 0 ? wdiv(absDiff(pImplied, s.pFast), s.pFast) : 0;
        if (retFast > RET_CAP) retFast = RET_CAP;

        uint256 retSlow = s.pSlow > 0 ? wdiv(absDiff(pImplied, s.pSlow), s.pSlow) : 0;
        if (retSlow > RET_CAP) retSlow = RET_CAP;

        s.sigmaFast = wmul(s.sigmaFast, SIGMA_FAST_BLEND) + wmul(retFast, WAD - SIGMA_FAST_BLEND);
        s.sigmaSlow = wmul(s.sigmaSlow, SIGMA_SLOW_BLEND) + wmul(retSlow, WAD - SIGMA_SLOW_BLEND);

        uint256 disagreeInst = s.pSlow > 0 ? wdiv(absDiff(s.pFast, s.pSlow), s.pSlow) : 0;
        if (disagreeInst > DISAGREE_CAP) disagreeInst = DISAGREE_CAP;

        uint256 alphaFast = FAST_ALPHA_BASE + wmul(FAST_ALPHA_SIZE, tradeRatio) + wmul(FAST_ALPHA_DISAGREE, disagreeInst);
        if (alphaFast > FAST_ALPHA_MAX) alphaFast = FAST_ALPHA_MAX;

        uint256 alphaSlow = SLOW_ALPHA_BASE + wmul(SLOW_ALPHA_SIZE, tradeRatio);
        if (alphaSlow > SLOW_ALPHA_MAX) alphaSlow = SLOW_ALPHA_MAX;

        uint256 targetFast = _boundedTarget(s.pFast, pImplied, FAST_MOVE_CAP);
        uint256 targetSlow = _boundedTarget(s.pSlow, pImplied, SLOW_MOVE_CAP);

        s.pFast = wmul(s.pFast, WAD - alphaFast) + wmul(targetFast, alphaFast);
        s.pSlow = wmul(s.pSlow, WAD - alphaSlow) + wmul(targetSlow, alphaSlow);
    }

    function _updateToxicityAndImpact(SwapState memory s, uint256 spot, uint256 tradeRatio) internal pure {
        uint256 tox = s.pFast > 0 ? wdiv(absDiff(spot, s.pFast), s.pFast) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;

        s.toxEma = wmul(s.toxEma, TOX_BLEND_DECAY) + wmul(tox, WAD - TOX_BLEND_DECAY);

        uint256 toxErr = absDiff(tox, s.toxEma);
        s.toxVar = wmul(s.toxVar, TOXVAR_BLEND_DECAY) + wmul(toxErr, WAD - TOXVAR_BLEND_DECAY);

        uint256 disagree = s.pSlow > 0 ? wdiv(absDiff(s.pFast, s.pSlow), s.pSlow) : 0;
        if (disagree > DISAGREE_CAP) disagree = DISAGREE_CAP;
        s.disagreeEma = wmul(s.disagreeEma, DISAGREE_BLEND_DECAY) + wmul(disagree, WAD - DISAGREE_BLEND_DECAY);

        uint256 jumpInst = s.prevSpot > 0 ? wdiv(absDiff(spot, s.prevSpot), s.prevSpot) : 0;
        if (jumpInst > RET_CAP) jumpInst = RET_CAP;
        s.jumpEma = wmul(s.jumpEma, JUMP_BLEND_DECAY) + wmul(jumpInst, WAD - JUMP_BLEND_DECAY);

        uint256 impactInst = wdiv(jumpInst, tradeRatio + IMPACT_DENOM_FLOOR);
        if (impactInst > IMPACT_CAP) impactInst = IMPACT_CAP;
        s.impactEma = wmul(s.impactEma, IMPACT_BLEND_DECAY) + wmul(impactInst, WAD - IMPACT_BLEND_DECAY);
    }

    function _updateInventoryAndTrend(
        SwapState memory s,
        uint256 reserveX,
        uint256 reserveY
    ) internal pure returns (bool invSellPressure, uint256 trendGap, bool trendSellPressure) {
        uint256 xValue = wmul(reserveX, s.pSlow);
        uint256 totalValue = xValue + reserveY;

        if (totalValue > 0) {
            uint256 xShare = wdiv(xValue, totalValue);
            invSellPressure = xShare >= HALF_WAD;

            uint256 invSkew = absDiff(xShare, HALF_WAD) * 2;
            if (invSkew > WAD) invSkew = WAD;
            s.invSkewEma = wmul(s.invSkewEma, INV_BLEND_DECAY) + wmul(invSkew, WAD - INV_BLEND_DECAY);
        }

        trendGap = s.pSlow > 0 ? wdiv(absDiff(s.pFast, s.pSlow), s.pSlow) : 0;
        if (trendGap > DISAGREE_CAP) trendGap = DISAGREE_CAP;
        trendSellPressure = s.pFast <= s.pSlow;
    }

    function _computeMidFee(SwapState memory s) internal pure returns (uint256 fMid, uint256 volMix) {
        volMix = wmul(SIGMA_FAST_WEIGHT, s.sigmaFast) + wmul(WAD - SIGMA_FAST_WEIGHT, s.sigmaSlow);

        uint256 flowSize = wmul(s.lambdaHat, s.sizeHat);
        uint256 twoSidedFlow = s.sellXFlow + s.buyXFlow;
        if (twoSidedFlow > WAD) twoSidedFlow = WAD;

        uint256 toxExcess = s.toxEma > TOX_QUAD_KNEE ? s.toxEma - TOX_QUAD_KNEE : 0;

        fMid = BASE_FEE;
        fMid = fMid + wmul(SIGMA_COEF, volMix);
        fMid = fMid + wmul(LAMBDA_COEF, s.lambdaHat);
        fMid = fMid + wmul(FLOW_SIZE_COEF, flowSize);
        fMid = fMid + wmul(TOX_COEF, s.toxEma);
        fMid = fMid + wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        fMid = fMid + wmul(TOXVAR_COEF, s.toxVar);
        fMid = fMid + wmul(DISAGREE_COEF, s.disagreeEma);
        fMid = fMid + wmul(BURST_COEF, s.burstEma);
        fMid = fMid + wmul(JUMP_COEF, s.jumpEma);
        fMid = fMid + wmul(IMPACT_COEF, s.impactEma);
        fMid = fMid + wmul(TWOSIDE_COEF, twoSidedFlow);
        fMid = fMid + wmul(INV_MID_COEF, s.invSkewEma);
    }

    function _flowImbalance(SwapState memory s) internal pure returns (uint256 imbalance, bool sellPressure) {
        uint256 flowTotal = s.sellXFlow + s.buyXFlow + BPS;
        uint256 flowDiff;

        if (s.sellXFlow >= s.buyXFlow) {
            flowDiff = s.sellXFlow - s.buyXFlow;
            sellPressure = true;
        } else {
            flowDiff = s.buyXFlow - s.sellXFlow;
            sellPressure = false;
        }

        imbalance = wdiv(flowDiff, flowTotal);
        if (imbalance > WAD) imbalance = WAD;
    }

    function _rawQuote(
        SwapState memory s,
        uint256 spot,
        bool invSellPressure,
        uint256 trendGap,
        bool trendSellPressure
    ) internal pure returns (uint256 bidFee, uint256 askFee, uint256 volMix) {
        (bidFee, askFee, volMix) = _baseDirectionalQuote(s);
        (bidFee, askFee) = _applyDirectionalAndStale(
            s,
            spot,
            bidFee,
            askFee,
            invSellPressure,
            trendGap,
            trendSellPressure
        );
        (bidFee, askFee) = _applyDynamicTail(s, volMix, bidFee, askFee);
    }

    function _baseDirectionalQuote(SwapState memory s) internal pure returns (uint256 bidFee, uint256 askFee, uint256 volMix) {
        (uint256 fMid, bool sellPressure, uint256 imbalance) = _midAndImbalance(s);
        uint256 skew = wmul(DIR_FLOW_COEF, imbalance)
            + wmul(DIR_TOX_COEF, wmul(imbalance, s.toxEma))
            + wmul(DIR_DISAGREE_COEF, wmul(imbalance, s.disagreeEma))
            + wmul(DIR_IMPACT_COEF, wmul(imbalance, s.impactEma));

        if (sellPressure) {
            bidFee = fMid + skew;
            askFee = fMid > skew ? fMid - skew : 0;
        } else {
            askFee = fMid + skew;
            bidFee = fMid > skew ? fMid - skew : 0;
        }

        (, volMix) = _computeMidFee(s);
    }

    function _midAndImbalance(SwapState memory s) internal pure returns (uint256 fMid, bool sellPressure, uint256 imbalance) {
        (fMid,) = _computeMidFee(s);
        (imbalance, sellPressure) = _flowImbalance(s);
    }

    function _applyDirectionalAndStale(
        SwapState memory s,
        uint256 spot,
        uint256 bidFee,
        uint256 askFee,
        bool invSellPressure,
        uint256 trendGap,
        bool trendSellPressure
    ) internal pure returns (uint256, uint256) {
        uint256 invShift = wmul(INV_SKEW_COEF, s.invSkewEma);
        (bidFee, askFee) = _applyDirectionalShift(bidFee, askFee, invShift, invSellPressure);

        uint256 trendShift = wmul(TREND_SKEW_COEF, trendGap);
        (bidFee, askFee) = _applyDirectionalShift(bidFee, askFee, trendShift, trendSellPressure);

        uint256 stale = s.pSlow > 0 ? wdiv(absDiff(spot, s.pSlow), s.pSlow) : 0;
        if (stale > TOX_CAP) stale = TOX_CAP;
        uint256 staleShift = wmul(STALE_SHIFT_COEF, stale);

        if (spot >= s.pSlow) {
            bidFee = bidFee + staleShift;
            askFee = askFee > staleShift ? askFee - staleShift : 0;
        } else {
            askFee = askFee + staleShift;
            bidFee = bidFee > staleShift ? bidFee - staleShift : 0;
        }

        return (bidFee, askFee);
    }

    function _applyDynamicTail(
        SwapState memory s,
        uint256 volMix,
        uint256 bidFee,
        uint256 askFee
    ) internal pure returns (uint256, uint256) {
        uint256 tailKnee = TAIL_KNEE_BASE
            + wmul(TAIL_KNEE_TOX_COEF, s.toxEma)
            + wmul(TAIL_KNEE_VOL_COEF, volMix)
            + wmul(TAIL_KNEE_DISAGREE_COEF, s.disagreeEma)
            + wmul(TAIL_KNEE_JUMP_COEF, s.jumpEma)
            + wmul(TAIL_KNEE_IMPACT_COEF, s.impactEma);
        if (tailKnee > TAIL_KNEE_MAX) tailKnee = TAIL_KNEE_MAX;

        if (bidFee > askFee) {
            bidFee = _compressTail(bidFee, tailKnee, TAIL_SLOPE_PROTECT);
            askFee = _compressTail(askFee, tailKnee, TAIL_SLOPE_ATTRACT);
        } else if (askFee > bidFee) {
            bidFee = _compressTail(bidFee, tailKnee, TAIL_SLOPE_ATTRACT);
            askFee = _compressTail(askFee, tailKnee, TAIL_SLOPE_PROTECT);
        } else {
            bidFee = _compressTail(bidFee, tailKnee, TAIL_SLOPE);
            askFee = _compressTail(askFee, tailKnee, TAIL_SLOPE);
        }
        return (bidFee, askFee);
    }

    function _applyDirectionalShift(
        uint256 bidFee,
        uint256 askFee,
        uint256 shift,
        bool sellPressure
    ) internal pure returns (uint256, uint256) {
        if (sellPressure) {
            bidFee = bidFee + shift;
            askFee = askFee > shift ? askFee - shift : 0;
        } else {
            askFee = askFee + shift;
            bidFee = bidFee > shift ? bidFee - shift : 0;
        }
        return (bidFee, askFee);
    }

    function _riskNorm(SwapState memory s, uint256 volMix) internal pure returns (uint256) {
        uint256 risk = s.toxEma
            + volMix
            + s.disagreeEma
            + s.toxVar
            + s.jumpEma
            + s.impactEma
            + wmul(HALF_WAD, s.invSkewEma);
        return risk > WAD ? WAD : risk;
    }

    function _calcImplied(uint256 spot, uint256 feeUsed, bool isBuy) internal pure returns (uint256) {
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        if (gamma == 0) return spot;
        return isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
    }

    function _compressTail(uint256 fee, uint256 knee, uint256 slope) internal pure returns (uint256) {
        if (fee <= knee) return fee;
        return knee + wmul(fee - knee, slope);
    }

    function _boundedTarget(uint256 refPrice, uint256 candidate, uint256 cap) internal pure returns (uint256) {
        uint256 delta = wmul(refPrice, cap);
        if (candidate >= refPrice) {
            uint256 up = refPrice + delta;
            return candidate > up ? up : candidate;
        }
        uint256 down = refPrice > delta ? refPrice - delta : 0;
        return candidate < down ? down : candidate;
    }

    function _applyRateLimit(uint256 prevFee, uint256 targetFee, uint256 riskNorm) internal pure returns (uint256) {
        uint256 upCap = RATE_UP_MIN + wmul(RATE_UP_RISK_RANGE, riskNorm);
        uint256 downCap = RATE_DOWN_MIN + wmul(RATE_DOWN_CALM_RANGE, WAD - riskNorm);

        if (targetFee > prevFee) {
            uint256 upMove = targetFee - prevFee;
            return upMove > upCap ? prevFee + upCap : targetFee;
        }

        uint256 downMove = prevFee - targetFee;
        return downMove > downCap ? prevFee - downCap : targetFee;
    }

    function _powWad(uint256 factor, uint256 exp) internal pure returns (uint256 result) {
        result = WAD;
        while (exp > 0) {
            if ((exp & 1) == 1) result = wmul(result, factor);
            factor = wmul(factor, factor);
            exp >>= 1;
        }
    }

    function getName() external pure override returns (string memory) {
        return "wildcard_mod_v225";
    }
}
