pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"pivot","hypothesis_id":"H_WILDCARD_100","confidence":0.72,"ceiling_probability":0.18,"ev_next_5":0.24,"best_delta_seen":0.15,"reason":"Shift to continuous dual-anchor convex risk surface to capture drift shocks and flow toxicity with lower starvation risk.","next_mechanism":"dual_anchor_convex_surface"}

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant STEP_COUNT_CAP = 96;
    uint256 constant SIGNAL_THRESHOLD = WAD / 900;
    uint256 constant TRADE_RATIO_CAP = WAD / 4;
    uint256 constant RET_CAP = WAD / 7;
    uint256 constant TOX_CAP = WAD / 4;
    uint256 constant GAP_CAP = WAD / 3;
    uint256 constant LAMBDA_CAP = 6 * WAD;

    uint256 constant PUSH_CAP_FAST = WAD / 5;
    uint256 constant PUSH_SLOW_MULT = 450000000000000000;

    uint256 constant DIR_FAST_DECAY = 870000000000000000;
    uint256 constant DIR_SLOW_DECAY = 950000000000000000;
    uint256 constant ACT_DECAY = 760000000000000000;
    uint256 constant SIZE_DECAY = 700000000000000000;
    uint256 constant TOX_DECAY = 900000000000000000;
    uint256 constant VFAST_DECAY = 730000000000000000;
    uint256 constant VSLOW_DECAY = 940000000000000000;
    uint256 constant LAMBDA_DECAY = 992000000000000000;
    uint256 constant JUMP_DECAY = 860000000000000000;
    uint256 constant GAP_DECAY = 900000000000000000;

    uint256 constant ACT_BLEND_DECAY = 992000000000000000;
    uint256 constant SIZE_BLEND_DECAY = 850000000000000000;
    uint256 constant VFAST_BLEND_DECAY = 650000000000000000;
    uint256 constant VSLOW_BLEND_DECAY = 930000000000000000;
    uint256 constant TOX_BLEND_DECAY = 300000000000000000;
    uint256 constant JUMP_BLEND_DECAY = 550000000000000000;
    uint256 constant GAP_BLEND_DECAY = 700000000000000000;
    uint256 constant LAMBDA_BLEND_DECAY = 986000000000000000;

    uint256 constant ALPHA_FAST_BASE = 110000000000000000;
    uint256 constant ALPHA_FAST_SIZE_COEF = 650000000000000000;
    uint256 constant ALPHA_FAST_MAX = 420000000000000000;
    uint256 constant ALPHA_SLOW_BASE = 12000000000000000;
    uint256 constant ALPHA_SLOW_SIZE_COEF = 90000000000000000;
    uint256 constant ALPHA_SLOW_MAX = 90000000000000000;
    uint256 constant ALPHA_DAMP_KNEE = 25000000000000000;
    uint256 constant ALPHA_DAMP_SLOPE = 1800000000000000000;
    uint256 constant ALPHA_DAMP_CAP = 850000000000000000;
    uint256 constant ALPHA_SLOW_DAMP_MULT = 650000000000000000;
    uint256 constant GAP_FEED_FAST = 220000000000000000;
    uint256 constant GAP_FEED_SLOW = 60000000000000000;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant VFAST_COEF = 130000000000000000;
    uint256 constant VSLOW_COEF = 70000000000000000;
    uint256 constant VGAP_COEF = 210000000000000000;
    uint256 constant TOX_COEF = 280 * BPS;
    uint256 constant JUMP_COEF = 3000 * BPS;
    uint256 constant ACT_COEF = 30000 * BPS;
    uint256 constant SIZE_COEF = 9000 * BPS;
    uint256 constant LAMBDA_COEF = 9 * BPS;
    uint256 constant FLOW_COEF = 4600 * BPS;
    uint256 constant GAP_COEF = 120 * BPS;
    uint256 constant TOX_QUAD_COEF = 22000 * BPS;
    uint256 constant TOX_KNEE = 9 * BPS;
    uint256 constant JUMP_KNEE = 12 * BPS;
    uint256 constant GAP_QUAD_COEF = 9000 * BPS;
    uint256 constant GAP_KNEE = 15 * BPS;

    uint256 constant DIR_FAST_WEIGHT = 680000000000000000;
    uint256 constant DIR_COEF = 120 * BPS;
    uint256 constant DIR_TOX_COEF = 45 * BPS;
    uint256 constant DIR_GAP_COEF = 40 * BPS;

    uint256 constant ANCHOR_COEF = 7500 * BPS;
    uint256 constant ANCHOR_GAP_COEF = 140 * BPS;
    uint256 constant TREND_COEF = 80 * BPS;

    uint256 constant TAIL_KNEE_BASE = 620 * BPS;
    uint256 constant TAIL_KNEE_VOL_COEF = 2200 * BPS;
    uint256 constant TAIL_KNEE_TOX_COEF = 1600 * BPS;
    uint256 constant TAIL_KNEE_GAP_COEF = 1200 * BPS;
    uint256 constant TAIL_KNEE_MAX = WAD / 8;

    uint256 constant TAIL_SLOPE_PROTECT_BASE = 760000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT_BASE = 945000000000000000;
    uint256 constant TAIL_SLOPE_TOX_ADJ = 240000000000000000;
    uint256 constant TAIL_SLOPE_VOL_ADJ = 110000000000000000;
    uint256 constant TAIL_SLOPE_GAP_ADJ = 90000000000000000;

    uint256 constant SIDE_FLOOR = 1 * BPS;

    struct State {
        uint256 bidFee;
        uint256 askFee;
        uint256 dirFast;
        uint256 dirSlow;
        uint256 actEma;
        uint256 pFast;
        uint256 pSlow;
        uint256 volFast;
        uint256 volSlow;
        uint256 toxEma;
        uint256 sizeEma;
        uint256 lambdaEma;
        uint256 jumpEma;
        uint256 gapEma;
        uint256 stepTradeCount;
        uint256 spot;
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

        s.spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : s.pSlow;
        if (s.pSlow == 0) s.pSlow = s.spot;
        if (s.pFast == 0) s.pFast = s.spot;
        if (s.spot == 0) s.spot = s.pSlow;

        uint256 feeUsed = trade.isBuy ? s.bidFee : s.askFee;
        uint256 pImplied = _calcImpliedPrice(s.spot, feeUsed, trade.isBuy);
        uint256 tradeRatio = _tradeRatio(trade);

        _updateFlowAndDirection(s, trade, tradeRatio);
        _updateVolToxGap(s, pImplied);
        _updateAnchors(s, pImplied, tradeRatio);

        uint256 fMid = _computeMidFee(s);
        (uint256 bidFee, uint256 askFee) = _computeRawSideFees(s, fMid);
        (bidFee, askFee) = _applyTailCompression(bidFee, askFee, s);

        s.bidFee = bidFee;
        s.askFee = askFee;

        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;

        _storeState(s, trade.timestamp);
        return (s.bidFee, s.askFee);
    }

    function _loadState() internal view returns (State memory s) {
        s.bidFee = slots[0];
        s.askFee = slots[1];
        s.dirFast = slots[3];
        s.dirSlow = slots[4];
        s.actEma = slots[5];
        s.pFast = slots[6];
        s.pSlow = slots[7];
        s.volFast = slots[8];
        s.volSlow = slots[9];
        s.toxEma = slots[10];
        s.sizeEma = slots[11];
        s.lambdaEma = slots[12];
        s.jumpEma = slots[13];
        s.gapEma = slots[14];
        s.stepTradeCount = slots[15];
    }

    function _storeState(State memory s, uint256 ts) internal {
        slots[0] = s.bidFee;
        slots[1] = s.askFee;
        slots[2] = ts;
        slots[3] = s.dirFast;
        slots[4] = s.dirSlow;
        slots[5] = s.actEma;
        slots[6] = s.pFast;
        slots[7] = s.pSlow;
        slots[8] = s.volFast;
        slots[9] = s.volSlow;
        slots[10] = s.toxEma;
        slots[11] = s.sizeEma;
        slots[12] = s.lambdaEma;
        slots[13] = s.jumpEma;
        slots[14] = s.gapEma;
        slots[15] = s.stepTradeCount;
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

    function _updateLambdaFromStepCount(State memory s, uint256 elapsedRaw) internal pure {
        if (s.stepTradeCount == 0 || elapsedRaw == 0) return;

        uint256 lambdaInst = (s.stepTradeCount * WAD) / elapsedRaw;
        if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
        s.lambdaEma = wmul(s.lambdaEma, LAMBDA_BLEND_DECAY) + wmul(lambdaInst, WAD - LAMBDA_BLEND_DECAY);
    }

    function _updateFlowAndDirection(State memory s, TradeInfo calldata trade, uint256 tradeRatio) internal pure {
        s.actEma = wmul(s.actEma, ACT_BLEND_DECAY) + wmul(tradeRatio, WAD - ACT_BLEND_DECAY);
        s.sizeEma = wmul(s.sizeEma, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
        if (s.sizeEma > WAD) s.sizeEma = WAD;

        if (tradeRatio <= SIGNAL_THRESHOLD) return;

        uint256 pushFast = tradeRatio > PUSH_CAP_FAST ? PUSH_CAP_FAST : tradeRatio;
        uint256 pushSlow = wmul(pushFast, PUSH_SLOW_MULT);

        if (trade.isBuy) {
            s.dirFast = s.dirFast + pushFast;
            if (s.dirFast > 2 * WAD) s.dirFast = 2 * WAD;

            s.dirSlow = s.dirSlow + pushSlow;
            if (s.dirSlow > 2 * WAD) s.dirSlow = 2 * WAD;
        } else {
            s.dirFast = s.dirFast > pushFast ? s.dirFast - pushFast : 0;
            s.dirSlow = s.dirSlow > pushSlow ? s.dirSlow - pushSlow : 0;
        }
    }

    function _updateVolToxGap(State memory s, uint256 pImplied) internal pure {
        uint256 retFast = s.pFast > 0 ? wdiv(absDiff(pImplied, s.pFast), s.pFast) : 0;
        uint256 retSlow = s.pSlow > 0 ? wdiv(absDiff(pImplied, s.pSlow), s.pSlow) : 0;
        if (retFast > RET_CAP) retFast = RET_CAP;
        if (retSlow > RET_CAP) retSlow = RET_CAP;

        s.volFast = wmul(s.volFast, VFAST_BLEND_DECAY) + wmul(retFast, WAD - VFAST_BLEND_DECAY);
        s.volSlow = wmul(s.volSlow, VSLOW_BLEND_DECAY) + wmul(retSlow, WAD - VSLOW_BLEND_DECAY);

        uint256 tox = s.pSlow > 0 ? wdiv(absDiff(s.spot, s.pSlow), s.pSlow) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;
        s.toxEma = wmul(s.toxEma, TOX_BLEND_DECAY) + wmul(tox, WAD - TOX_BLEND_DECAY);

        uint256 jumpExcess = retFast > JUMP_KNEE ? retFast - JUMP_KNEE : 0;
        s.jumpEma = wmul(s.jumpEma, JUMP_BLEND_DECAY) + wmul(jumpExcess, WAD - JUMP_BLEND_DECAY);

        uint256 gapInst = s.pSlow > 0 ? wdiv(absDiff(s.pFast, s.pSlow), s.pSlow) : 0;
        if (gapInst > GAP_CAP) gapInst = GAP_CAP;
        s.gapEma = wmul(s.gapEma, GAP_BLEND_DECAY) + wmul(gapInst, WAD - GAP_BLEND_DECAY);
    }

    function _updateAnchors(State memory s, uint256 pImplied, uint256 tradeRatio) internal pure {
        uint256 alphaFast = ALPHA_FAST_BASE + wmul(ALPHA_FAST_SIZE_COEF, tradeRatio) + wmul(GAP_FEED_FAST, s.gapEma);
        if (alphaFast > ALPHA_FAST_MAX) alphaFast = ALPHA_FAST_MAX;

        uint256 alphaSlow = ALPHA_SLOW_BASE + wmul(ALPHA_SLOW_SIZE_COEF, tradeRatio) + wmul(GAP_FEED_SLOW, s.gapEma);
        if (alphaSlow > ALPHA_SLOW_MAX) alphaSlow = ALPHA_SLOW_MAX;

        uint256 dampSignal = s.toxEma + s.jumpEma;
        if (dampSignal > ALPHA_DAMP_KNEE) {
            uint256 damp = wmul(ALPHA_DAMP_SLOPE, dampSignal - ALPHA_DAMP_KNEE);
            if (damp > ALPHA_DAMP_CAP) damp = ALPHA_DAMP_CAP;

            alphaFast = wmul(alphaFast, WAD - damp);

            uint256 dampSlow = wmul(damp, ALPHA_SLOW_DAMP_MULT);
            alphaSlow = wmul(alphaSlow, WAD - dampSlow);
        }

        if (alphaFast > 0) s.pFast = wmul(s.pFast, WAD - alphaFast) + wmul(pImplied, alphaFast);
        if (alphaSlow > 0) s.pSlow = wmul(s.pSlow, WAD - alphaSlow) + wmul(pImplied, alphaSlow);
    }

    function _computeMidFee(State memory s) internal pure returns (uint256 fMid) {
        uint256 flowSize = wmul(s.lambdaEma, s.sizeEma);
        if (flowSize > WAD) flowSize = WAD;

        uint256 volGap = s.volFast > s.volSlow ? s.volFast - s.volSlow : 0;

        fMid = BASE_FEE;
        fMid = fMid + wmul(VFAST_COEF, s.volFast);
        fMid = fMid + wmul(VSLOW_COEF, s.volSlow);
        fMid = fMid + wmul(VGAP_COEF, volGap);
        fMid = fMid + wmul(TOX_COEF, s.toxEma);
        fMid = fMid + wmul(JUMP_COEF, s.jumpEma);
        fMid = fMid + wmul(ACT_COEF, s.actEma);
        fMid = fMid + wmul(SIZE_COEF, s.sizeEma);
        fMid = fMid + wmul(LAMBDA_COEF, s.lambdaEma);
        fMid = fMid + wmul(FLOW_COEF, flowSize);
        fMid = fMid + wmul(GAP_COEF, s.gapEma);

        uint256 toxExcess = s.toxEma > TOX_KNEE ? s.toxEma - TOX_KNEE : 0;
        uint256 gapExcess = s.gapEma > GAP_KNEE ? s.gapEma - GAP_KNEE : 0;

        fMid = fMid + wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        fMid = fMid + wmul(GAP_QUAD_COEF, wmul(gapExcess, gapExcess));
    }

    function _computeRawSideFees(State memory s, uint256 fMid) internal pure returns (uint256 bidFee, uint256 askFee) {
        (uint256 skew, bool sellPressure) = _directionalSkew(s);

        if (sellPressure) {
            bidFee = fMid + skew;
            askFee = fMid > skew ? fMid - skew : 0;
        } else {
            askFee = fMid + skew;
            bidFee = fMid > skew ? fMid - skew : 0;
        }

        uint256 anchorShift = wmul(ANCHOR_COEF, s.toxEma) + wmul(ANCHOR_GAP_COEF, s.gapEma);
        if (s.spot >= s.pSlow) {
            bidFee = bidFee + anchorShift;
            askFee = askFee > anchorShift ? askFee - anchorShift : 0;
        } else {
            askFee = askFee + anchorShift;
            bidFee = bidFee > anchorShift ? bidFee - anchorShift : 0;
        }

        uint256 trendGap = s.pSlow > 0 ? wdiv(absDiff(s.pFast, s.pSlow), s.pSlow) : 0;
        if (trendGap > GAP_CAP) trendGap = GAP_CAP;
        uint256 trendShift = wmul(TREND_COEF, trendGap);

        if (s.pFast >= s.pSlow) {
            bidFee = bidFee + trendShift;
            askFee = askFee > trendShift ? askFee - trendShift : 0;
        } else {
            askFee = askFee + trendShift;
            bidFee = bidFee > trendShift ? bidFee - trendShift : 0;
        }

        if (bidFee < SIDE_FLOOR) bidFee = SIDE_FLOOR;
        if (askFee < SIDE_FLOOR) askFee = SIDE_FLOOR;
    }

    function _directionalSkew(State memory s) internal pure returns (uint256 skew, bool sellPressure) {
        uint256 dirFastDev = s.dirFast >= WAD ? s.dirFast - WAD : WAD - s.dirFast;
        uint256 dirSlowDev = s.dirSlow >= WAD ? s.dirSlow - WAD : WAD - s.dirSlow;
        uint256 dirBlend = wmul(DIR_FAST_WEIGHT, dirFastDev) + wmul(WAD - DIR_FAST_WEIGHT, dirSlowDev);

        skew = wmul(DIR_COEF, dirBlend)
            + wmul(DIR_TOX_COEF, wmul(dirBlend, s.toxEma))
            + wmul(DIR_GAP_COEF, wmul(dirBlend, s.gapEma));

        sellPressure = s.dirFast >= WAD;
    }

    function _applyTailCompression(uint256 bidFee, uint256 askFee, State memory s)
        internal
        pure
        returns (uint256, uint256)
    {
        (uint256 tailKnee, uint256 protectSlope, uint256 attractSlope) = _tailParams(s);

        if (bidFee > askFee) {
            bidFee = clampFee(_compressTail(bidFee, tailKnee, protectSlope));
            askFee = clampFee(_compressTail(askFee, tailKnee, attractSlope));
        } else if (askFee > bidFee) {
            bidFee = clampFee(_compressTail(bidFee, tailKnee, attractSlope));
            askFee = clampFee(_compressTail(askFee, tailKnee, protectSlope));
        } else {
            uint256 midSlope = (protectSlope + attractSlope) / 2;
            bidFee = clampFee(_compressTail(bidFee, tailKnee, midSlope));
            askFee = clampFee(_compressTail(askFee, tailKnee, midSlope));
        }

        return (bidFee, askFee);
    }

    function _tailParams(State memory s) internal pure returns (uint256 tailKnee, uint256 protectSlope, uint256 attractSlope) {
        tailKnee = TAIL_KNEE_BASE + wmul(TAIL_KNEE_VOL_COEF, s.volSlow) + wmul(TAIL_KNEE_TOX_COEF, s.toxEma)
            + wmul(TAIL_KNEE_GAP_COEF, s.gapEma);
        if (tailKnee > TAIL_KNEE_MAX) tailKnee = TAIL_KNEE_MAX;

        uint256 slopeCut = wmul(TAIL_SLOPE_TOX_ADJ, s.toxEma) + wmul(TAIL_SLOPE_VOL_ADJ, s.volFast)
            + wmul(TAIL_SLOPE_GAP_ADJ, s.gapEma);

        protectSlope = TAIL_SLOPE_PROTECT_BASE > slopeCut ? TAIL_SLOPE_PROTECT_BASE - slopeCut : WAD / 2;
        if (protectSlope < WAD / 2) protectSlope = WAD / 2;

        attractSlope = TAIL_SLOPE_ATTRACT_BASE + wmul(TAIL_SLOPE_TOX_ADJ / 2, s.toxEma)
            + wmul(TAIL_SLOPE_GAP_ADJ / 2, s.gapEma);
        if (attractSlope > WAD) attractSlope = WAD;
    }

    function _decayState(State memory s, uint256 elapsed) internal pure {
        s.dirFast = _decayCentered(s.dirFast, DIR_FAST_DECAY, elapsed);
        s.dirSlow = _decayCentered(s.dirSlow, DIR_SLOW_DECAY, elapsed);
        s.actEma = wmul(s.actEma, _powWad(ACT_DECAY, elapsed));
        s.sizeEma = wmul(s.sizeEma, _powWad(SIZE_DECAY, elapsed));
        s.toxEma = wmul(s.toxEma, _powWad(TOX_DECAY, elapsed));
        s.volFast = wmul(s.volFast, _powWad(VFAST_DECAY, elapsed));
        s.volSlow = wmul(s.volSlow, _powWad(VSLOW_DECAY, elapsed));
        s.lambdaEma = wmul(s.lambdaEma, _powWad(LAMBDA_DECAY, elapsed));
        s.jumpEma = wmul(s.jumpEma, _powWad(JUMP_DECAY, elapsed));
        s.gapEma = wmul(s.gapEma, _powWad(GAP_DECAY, elapsed));
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
        return "wildcard_mod_v100";
    }
}
