pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_WILDCARD_231_A","confidence":0.74,"ceiling_probability":0.31,"ev_next_5":0.18,"best_delta_seen":0.17,"reason":"Continuous adaptive anchoring plus dual-volatility and burst-flow coupling should broaden adverse-selection defense without brittle step gating.","next_mechanism":"adaptive_anchor_dual_vol_burst"}

    uint256 constant ELAPSED_CAP = 12;
    uint256 constant SIGNAL_THRESHOLD = WAD / 1000;

    uint256 constant RET_CAP = WAD / 7;
    uint256 constant TOX_CAP = WAD / 4;
    uint256 constant TRADE_RATIO_CAP = WAD / 4;
    uint256 constant VOL_CAP = WAD / 4;
    uint256 constant LAMBDA_CAP = 6 * WAD;
    uint256 constant FLOW_CAP = (12 * WAD) / 10;
    uint256 constant BURST_CAP = 4 * WAD;
    uint256 constant STEP_COUNT_CAP = 96;

    uint256 constant IMB_DECAY = 850000000000000000;
    uint256 constant SIZE_DECAY = 760000000000000000;
    uint256 constant TOX_DECAY = 900000000000000000;
    uint256 constant VOL_FAST_DECAY = 730000000000000000;
    uint256 constant VOL_SLOW_DECAY = 965000000000000000;
    uint256 constant LAMBDA_TIME_DECAY = 860000000000000000;
    uint256 constant BURST_DECAY = 700000000000000000;

    uint256 constant LAMBDA_BLEND_DECAY = 992000000000000000;
    uint256 constant BURST_BLEND_DECAY = 840000000000000000;
    uint256 constant SIZE_BLEND_DECAY = 830000000000000000;
    uint256 constant TOX_BLEND_DECAY = 260000000000000000;
    uint256 constant VOL_FAST_BLEND_DECAY = 540000000000000000;
    uint256 constant VOL_SLOW_BLEND_DECAY = 930000000000000000;
    uint256 constant BURST_INTRA_BLEND_DECAY = 860000000000000000;

    uint256 constant ANCHOR_ALPHA_MIN = 30000000000000000;
    uint256 constant ANCHOR_ALPHA_SIZE = 1000000000000000000;
    uint256 constant ANCHOR_ALPHA_MAX = 360000000000000000;
    uint256 constant ANCHOR_SHOCK_GATE = 3200000000000000;
    uint256 constant ANCHOR_SHOCK_DAMP = 320000000000000000;

    uint256 constant DIR_IMPACT_MULT = 2;
    uint256 constant FLOW_PUSH_CAP = WAD / 3;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant VOL_COEF = 280000000000000000;
    uint256 constant VOL_BURST_COEF = 1100000000000000000;
    uint256 constant LAMBDA_COEF = 9 * BPS;
    uint256 constant SIZE_COEF = 900 * BPS;
    uint256 constant FLOW_COEF = 2200 * BPS;
    uint256 constant BURST_COEF = 70 * BPS;
    uint256 constant TOX_COEF = 230 * BPS;
    uint256 constant TOX_QUAD_COEF = 21000 * BPS;
    uint256 constant TOX_QUAD_KNEE = 11 * BPS;
    uint256 constant VOL_TOX_COEF = 3800 * BPS;

    uint256 constant IMB_COEF = 110 * BPS;
    uint256 constant IMB_TOX_COEF = 30 * BPS;
    uint256 constant IMB_BURST_COEF = 18 * BPS;
    uint256 constant STALE_TOX_COEF = 5400 * BPS;
    uint256 constant STALE_VOL_COEF = 800 * BPS;

    uint256 constant TAIL_KNEE = 700 * BPS;
    uint256 constant TAIL_SLOPE = 880000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 800000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 950000000000000000;

    struct SwapState {
        uint256 imbalance;
        uint256 sizeEma;
        uint256 pAnchor;
        uint256 volFast;
        uint256 volSlow;
        uint256 lambdaHat;
        uint256 toxEma;
        uint256 burstEma;
        uint256 stepTradeCount;
    }

    struct QuoteState {
        uint256 volDiff;
        uint256 volSignal;
        uint256 flowSignal;
        uint256 fBase;
        uint256 toxExcess;
        uint256 fMid;
        uint256 dirDev;
        uint256 skew;
        uint256 staleShift;
        uint256 bidFee;
        uint256 askFee;
    }

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;

        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD;
        slots[4] = 2000000000000000;
        slots[5] = p0;
        slots[6] = 900000000000000;
        slots[7] = 1200000000000000;
        slots[8] = 700000000000000000;
        slots[9] = 0;
        slots[10] = 0;
        slots[11] = 0;

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 prevBidFee = slots[0];
        uint256 prevAskFee = slots[1];
        uint256 lastTs = slots[2];

        SwapState memory s = SwapState({
            imbalance: slots[3],
            sizeEma: slots[4],
            pAnchor: slots[5],
            volFast: slots[6],
            volSlow: slots[7],
            lambdaHat: slots[8],
            toxEma: slots[9],
            burstEma: slots[10],
            stepTradeCount: slots[11]
        });

        bool isNewStep = trade.timestamp > lastTs;
        if (isNewStep) _decayForElapsed(s, trade.timestamp - lastTs);

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : s.pAnchor;
        if (s.pAnchor == 0) s.pAnchor = spot;

        uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
        uint256 tradeRatio = _updateAnchorAndSignals(s, trade, spot, feeUsed);
        _updateFlowAndBurst(s, trade.isBuy, tradeRatio, isNewStep);

        (uint256 bidFee, uint256 askFee) = _quoteFees(s, spot);

        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = s.imbalance;
        slots[4] = s.sizeEma;
        slots[5] = s.pAnchor;
        slots[6] = s.volFast;
        slots[7] = s.volSlow;
        slots[8] = s.lambdaHat;
        slots[9] = s.toxEma;
        slots[10] = s.burstEma;
        slots[11] = s.stepTradeCount;

        return (bidFee, askFee);
    }

    function _decayForElapsed(SwapState memory s, uint256 elapsedRaw) internal pure {
        uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

        s.imbalance = _decayCentered(s.imbalance, IMB_DECAY, elapsed);
        s.sizeEma = wmul(s.sizeEma, _powWad(SIZE_DECAY, elapsed));
        s.toxEma = wmul(s.toxEma, _powWad(TOX_DECAY, elapsed));
        s.volFast = wmul(s.volFast, _powWad(VOL_FAST_DECAY, elapsed));
        s.volSlow = wmul(s.volSlow, _powWad(VOL_SLOW_DECAY, elapsed));
        s.lambdaHat = wmul(s.lambdaHat, _powWad(LAMBDA_TIME_DECAY, elapsed));
        s.burstEma = wmul(s.burstEma, _powWad(BURST_DECAY, elapsed));

        if (s.stepTradeCount > 0) {
            uint256 lambdaInst = (s.stepTradeCount * WAD) / elapsedRaw;
            if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
            s.lambdaHat = wmul(s.lambdaHat, LAMBDA_BLEND_DECAY) + wmul(lambdaInst, WAD - LAMBDA_BLEND_DECAY);

            uint256 burstInst = (s.stepTradeCount * WAD) / (elapsedRaw + 1);
            if (burstInst > BURST_CAP) burstInst = BURST_CAP;
            s.burstEma = wmul(s.burstEma, BURST_BLEND_DECAY) + wmul(burstInst, WAD - BURST_BLEND_DECAY);
        }

        if (s.lambdaHat > LAMBDA_CAP) s.lambdaHat = LAMBDA_CAP;
        if (s.burstEma > BURST_CAP) s.burstEma = BURST_CAP;
        s.stepTradeCount = 0;
    }

    function _updateAnchorAndSignals(SwapState memory s, TradeInfo calldata trade, uint256 spot, uint256 feeUsed)
        internal
        pure
        returns (uint256 tradeRatio)
    {
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied = gamma == 0 ? spot : (trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma));

        tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        uint256 ret = s.pAnchor > 0 ? wdiv(absDiff(pImplied, s.pAnchor), s.pAnchor) : 0;
        if (ret > RET_CAP) ret = RET_CAP;

        uint256 alpha = ANCHOR_ALPHA_MIN + wmul(ANCHOR_ALPHA_SIZE, tradeRatio);
        if (alpha > ANCHOR_ALPHA_MAX) alpha = ANCHOR_ALPHA_MAX;
        if (ret > ANCHOR_SHOCK_GATE) alpha = wmul(alpha, ANCHOR_SHOCK_DAMP);

        s.pAnchor = _mixWad(s.pAnchor, pImplied, alpha);

        s.volFast = wmul(s.volFast, VOL_FAST_BLEND_DECAY) + wmul(ret, WAD - VOL_FAST_BLEND_DECAY);
        s.volSlow = wmul(s.volSlow, VOL_SLOW_BLEND_DECAY) + wmul(ret, WAD - VOL_SLOW_BLEND_DECAY);

        s.sizeEma = wmul(s.sizeEma, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
        if (s.sizeEma > WAD) s.sizeEma = WAD;

        uint256 toxInst = s.pAnchor > 0 ? wdiv(absDiff(spot, s.pAnchor), s.pAnchor) : 0;
        if (toxInst > TOX_CAP) toxInst = TOX_CAP;
        s.toxEma = wmul(s.toxEma, TOX_BLEND_DECAY) + wmul(toxInst, WAD - TOX_BLEND_DECAY);
    }

    function _updateFlowAndBurst(SwapState memory s, bool isBuy, uint256 tradeRatio, bool isNewStep) internal pure {
        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = tradeRatio * DIR_IMPACT_MULT;
            if (push > FLOW_PUSH_CAP) push = FLOW_PUSH_CAP;

            if (isBuy) {
                s.imbalance = s.imbalance + push;
                if (s.imbalance > 2 * WAD) s.imbalance = 2 * WAD;
            } else {
                s.imbalance = s.imbalance > push ? s.imbalance - push : 0;
            }
        }

        if (!isNewStep && s.stepTradeCount > 0) {
            s.burstEma = wmul(s.burstEma, BURST_INTRA_BLEND_DECAY) + wmul(WAD, WAD - BURST_INTRA_BLEND_DECAY);
            if (s.burstEma > BURST_CAP) s.burstEma = BURST_CAP;
        }
    }

    function _quoteFees(SwapState memory s, uint256 spot) internal pure returns (uint256, uint256) {
        QuoteState memory q;

        q.volDiff = s.volFast > s.volSlow ? s.volFast - s.volSlow : 0;
        q.volSignal = s.volFast + wmul(VOL_BURST_COEF, q.volDiff);
        if (q.volSignal > VOL_CAP) q.volSignal = VOL_CAP;

        q.flowSignal = wmul(s.lambdaHat, s.sizeEma);
        if (q.flowSignal > FLOW_CAP) q.flowSignal = FLOW_CAP;

        q.fBase = BASE_FEE;
        q.fBase = q.fBase + wmul(VOL_COEF, q.volSignal);
        q.fBase = q.fBase + wmul(LAMBDA_COEF, s.lambdaHat);
        q.fBase = q.fBase + wmul(SIZE_COEF, s.sizeEma);
        q.fBase = q.fBase + wmul(FLOW_COEF, q.flowSignal);
        q.fBase = q.fBase + wmul(BURST_COEF, s.burstEma);

        q.toxExcess = s.toxEma > TOX_QUAD_KNEE ? s.toxEma - TOX_QUAD_KNEE : 0;
        q.fMid = q.fBase;
        q.fMid = q.fMid + wmul(TOX_COEF, s.toxEma);
        q.fMid = q.fMid + wmul(TOX_QUAD_COEF, wmul(q.toxExcess, q.toxExcess));
        q.fMid = q.fMid + wmul(VOL_TOX_COEF, wmul(q.volSignal, s.toxEma));

        bool buyDominant;
        if (s.imbalance >= WAD) {
            q.dirDev = s.imbalance - WAD;
            buyDominant = true;
        } else {
            q.dirDev = WAD - s.imbalance;
            buyDominant = false;
        }

        q.skew = wmul(IMB_COEF, q.dirDev);
        q.skew = q.skew + wmul(IMB_TOX_COEF, wmul(q.dirDev, s.toxEma));
        q.skew = q.skew + wmul(IMB_BURST_COEF, wmul(q.dirDev, s.burstEma));

        if (buyDominant) {
            q.bidFee = q.fMid + q.skew;
            q.askFee = q.fMid > q.skew ? q.fMid - q.skew : 0;
        } else {
            q.askFee = q.fMid + q.skew;
            q.bidFee = q.fMid > q.skew ? q.fMid - q.skew : 0;
        }

        q.staleShift = wmul(STALE_TOX_COEF, s.toxEma) + wmul(STALE_VOL_COEF, q.volDiff);
        if (spot >= s.pAnchor) {
            q.bidFee = q.bidFee + q.staleShift;
            q.askFee = q.askFee > q.staleShift ? q.askFee - q.staleShift : 0;
        } else {
            q.askFee = q.askFee + q.staleShift;
            q.bidFee = q.bidFee > q.staleShift ? q.bidFee - q.staleShift : 0;
        }

        if (q.bidFee > q.askFee) {
            q.bidFee = clampFee(_compressTail(q.bidFee, TAIL_SLOPE_PROTECT));
            q.askFee = clampFee(_compressTail(q.askFee, TAIL_SLOPE_ATTRACT));
        } else if (q.askFee > q.bidFee) {
            q.bidFee = clampFee(_compressTail(q.bidFee, TAIL_SLOPE_ATTRACT));
            q.askFee = clampFee(_compressTail(q.askFee, TAIL_SLOPE_PROTECT));
        } else {
            q.bidFee = clampFee(_compressTail(q.bidFee, TAIL_SLOPE));
            q.askFee = clampFee(_compressTail(q.askFee, TAIL_SLOPE));
        }

        return (q.bidFee, q.askFee);
    }

    function _mixWad(uint256 oldValue, uint256 newValue, uint256 alpha) internal pure returns (uint256) {
        if (alpha >= WAD) return newValue;
        return wmul(oldValue, WAD - alpha) + wmul(newValue, alpha);
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
        return "wildcard_mod_v231";
    }
}
