pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"pivot","hypothesis_id":"H_DUAL_ANCHOR_FLOW_001","confidence":0.67,"ceiling_probability":0.21,"ev_next_5":0.14,"best_delta_seen":0.15,"reason":"Shift to side-specific dual-anchor toxicity with continuous flow stress for higher structural upside than local coefficient sweeps.","next_mechanism":"dual_anchor_flow_toxicity"}

    uint256 constant ELAPSED_CAP = 8;

    uint256 constant VOL_STEP_DECAY = 760000000000000000;
    uint256 constant SIZE_STEP_DECAY = 740000000000000000;
    uint256 constant FLOW_STEP_DECAY = 700000000000000000;
    uint256 constant TOX_STEP_DECAY = 820000000000000000;
    uint256 constant JUMP_STEP_DECAY = 780000000000000000;
    uint256 constant LAMBDA_EMA_DECAY = 992000000000000000;
    uint256 constant LAMBDA_GAP_DECAY = 960000000000000000;

    uint256 constant FAST_ALPHA_BASE = 220000000000000000;
    uint256 constant FAST_ALPHA_SHOCK = 620000000000000000;
    uint256 constant FAST_ALPHA_MAX = 820000000000000000;

    uint256 constant SLOW_ALPHA_BASE = 35000000000000000;
    uint256 constant SLOW_ALPHA_SHOCK = 220000000000000000;
    uint256 constant SLOW_ALPHA_MAX = 280000000000000000;

    uint256 constant VOL_ALPHA = 140000000000000000;
    uint256 constant SIZE_ALPHA = 180000000000000000;
    uint256 constant TOX_ALPHA = 160000000000000000;
    uint256 constant JUMP_ALPHA = 170000000000000000;
    uint256 constant FLOW_TRADE_DECAY = 860000000000000000;

    uint256 constant RET_CAP = WAD / 8;
    uint256 constant SHOCK_CAP = WAD / 5;
    uint256 constant TOX_CAP = WAD / 4;
    uint256 constant TRADE_RATIO_CAP = WAD / 4;
    uint256 constant LAMBDA_CAP = 5 * WAD;
    uint256 constant STEP_COUNT_CAP = 96;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant VOL_COEF = 900000000000000000;
    uint256 constant LAMBDA_COEF = 5 * BPS;
    uint256 constant FLOW_SIZE_COEF = 7800 * BPS;
    uint256 constant JUMP_COEF = 220 * BPS;

    uint256 constant TOX_LIN_COEF = 240 * BPS;
    uint256 constant TOX_QUAD_COEF = 18000 * BPS;
    uint256 constant TOX_QUAD_KNEE = 10 * BPS;
    uint256 constant INNOVATION_WEIGHT = 600000000000000000;
    uint256 constant FLOW_IMB_COEF = 480 * BPS;
    uint256 constant TREND_COEF = 260 * BPS;
    uint256 constant TREND_TOX_COUPLING = 55 * BPS;
    uint256 constant SAFE_SIDE_REBATE = 350000000000000000;

    uint256 constant TAIL_KNEE = 650 * BPS;
    uint256 constant TAIL_SLOPE = 860000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 780000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 930000000000000000;

    struct State {
        uint256 prevBidFee;
        uint256 prevAskFee;
        uint256 lastTs;
        uint256 pFast;
        uint256 pSlow;
        uint256 volEma;
        uint256 lambdaHat;
        uint256 sizeEma;
        uint256 flowBuyEma;
        uint256 flowSellEma;
        uint256 toxBidEma;
        uint256 toxAskEma;
        uint256 jumpEma;
        uint256 stepTradeCount;
    }

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;

        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = p0;
        slots[4] = p0;
        slots[5] = 1100000000000000;
        slots[6] = 700000000000000000;
        slots[7] = 1500000000000000;
        slots[8] = 0;
        slots[9] = 0;
        slots[10] = 0;
        slots[11] = 0;
        slots[12] = 0;
        slots[13] = 0;

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        State memory s = State({
            prevBidFee: slots[0],
            prevAskFee: slots[1],
            lastTs: slots[2],
            pFast: slots[3],
            pSlow: slots[4],
            volEma: slots[5],
            lambdaHat: slots[6],
            sizeEma: slots[7],
            flowBuyEma: slots[8],
            flowSellEma: slots[9],
            toxBidEma: slots[10],
            toxAskEma: slots[11],
            jumpEma: slots[12],
            stepTradeCount: slots[13]
        });

        _applyStepDecay(s, trade.timestamp);

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : s.pSlow;
        if (s.pFast == 0) s.pFast = spot;
        if (s.pSlow == 0) s.pSlow = spot;

        uint256 refFast = s.pFast;
        uint256 refSlow = s.pSlow;

        uint256 pImplied = _impliedPrice(spot, trade.isBuy ? s.prevBidFee : s.prevAskFee, trade.isBuy);

        uint256 ret = refFast > 0 ? wdiv(absDiff(pImplied, refFast), refFast) : 0;
        if (ret > RET_CAP) ret = RET_CAP;
        s.volEma = _ema(s.volEma, ret, VOL_ALPHA);

        uint256 drift = refSlow > 0 ? wdiv(absDiff(refFast, refSlow), refSlow) : 0;
        if (drift > SHOCK_CAP) drift = SHOCK_CAP;

        uint256 jumpInst = ret > drift ? ret : drift;
        s.jumpEma = _ema(s.jumpEma, jumpInst, JUMP_ALPHA);

        uint256 alpha = FAST_ALPHA_BASE + wmul(FAST_ALPHA_SHOCK, s.jumpEma);
        if (alpha > FAST_ALPHA_MAX) alpha = FAST_ALPHA_MAX;
        s.pFast = _ema(s.pFast, pImplied, alpha);

        alpha = SLOW_ALPHA_BASE + wmul(SLOW_ALPHA_SHOCK, s.jumpEma);
        if (alpha > SLOW_ALPHA_MAX) alpha = SLOW_ALPHA_MAX;
        s.pSlow = _ema(s.pSlow, pImplied, alpha);

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;
        s.sizeEma = _ema(s.sizeEma, tradeRatio, SIZE_ALPHA);

        s.flowBuyEma = wmul(s.flowBuyEma, FLOW_TRADE_DECAY);
        s.flowSellEma = wmul(s.flowSellEma, FLOW_TRADE_DECAY);
        uint256 flowInj = wmul(tradeRatio, WAD - FLOW_TRADE_DECAY);
        if (trade.isBuy) {
            s.flowBuyEma = s.flowBuyEma + flowInj;
        } else {
            s.flowSellEma = s.flowSellEma + flowInj;
        }

        uint256 stale = refSlow > 0 ? wdiv(absDiff(spot, refSlow), refSlow) : 0;
        if (stale > TOX_CAP) stale = TOX_CAP;

        uint256 toxBidInst;
        uint256 toxAskInst;

        if (spot >= refSlow) {
            toxBidInst = stale;
        } else {
            toxAskInst = stale;
        }

        uint256 innovWeighted = wmul(ret, INNOVATION_WEIGHT);
        if (pImplied >= refFast) {
            toxAskInst = toxAskInst + innovWeighted;
        } else {
            toxBidInst = toxBidInst + innovWeighted;
        }

        if (toxBidInst > TOX_CAP) toxBidInst = TOX_CAP;
        if (toxAskInst > TOX_CAP) toxAskInst = TOX_CAP;

        s.toxBidEma = _ema(s.toxBidEma, toxBidInst, TOX_ALPHA);
        s.toxAskEma = _ema(s.toxAskEma, toxAskInst, TOX_ALPHA);

        uint256 flowIntensity = wmul(s.lambdaHat, s.sizeEma);
        uint256 fBase = BASE_FEE
            + wmul(VOL_COEF, s.volEma)
            + wmul(LAMBDA_COEF, s.lambdaHat)
            + wmul(FLOW_SIZE_COEF, flowIntensity)
            + wmul(JUMP_COEF, s.jumpEma);

        uint256 bidAdd = _toxFee(s.toxBidEma);
        uint256 askAdd = _toxFee(s.toxAskEma);

        uint256 flowTot = s.flowBuyEma + s.flowSellEma;
        if (flowTot > 0) {
            uint256 imbalance = wdiv(absDiff(s.flowBuyEma, s.flowSellEma), flowTot);
            uint256 flowStress = wmul(FLOW_IMB_COEF, wmul(imbalance, flowTot));
            if (s.flowBuyEma >= s.flowSellEma) {
                bidAdd = bidAdd + flowStress;
            } else {
                askAdd = askAdd + flowStress;
            }
        }

        uint256 meanTox = (s.toxBidEma + s.toxAskEma) / 2;
        uint256 trendAdd = wmul(TREND_COEF, drift) + wmul(TREND_TOX_COUPLING, wmul(drift, meanTox));
        if (s.pFast >= s.pSlow) {
            askAdd = askAdd + trendAdd;
        } else {
            bidAdd = bidAdd + trendAdd;
        }

        uint256 bidFee = fBase + bidAdd;
        uint256 askFee = fBase + askAdd;

        if (bidFee > askFee) {
            uint256 rebate = wmul(SAFE_SIDE_REBATE, bidFee - askFee);
            askFee = askFee > rebate ? askFee - rebate : 0;
        } else if (askFee > bidFee) {
            uint256 rebate = wmul(SAFE_SIDE_REBATE, askFee - bidFee);
            bidFee = bidFee > rebate ? bidFee - rebate : 0;
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

        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = s.pFast;
        slots[4] = s.pSlow;
        slots[5] = s.volEma;
        slots[6] = s.lambdaHat;
        slots[7] = s.sizeEma;
        slots[8] = s.flowBuyEma;
        slots[9] = s.flowSellEma;
        slots[10] = s.toxBidEma;
        slots[11] = s.toxAskEma;
        slots[12] = s.jumpEma;
        slots[13] = s.stepTradeCount;

        return (bidFee, askFee);
    }

    function _applyStepDecay(State memory s, uint256 ts) internal pure {
        if (ts <= s.lastTs) return;

        uint256 elapsedRaw = ts - s.lastTs;
        uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;
        uint256 mul;

        mul = _powWad(VOL_STEP_DECAY, elapsed);
        s.volEma = wmul(s.volEma, mul);

        mul = _powWad(SIZE_STEP_DECAY, elapsed);
        s.sizeEma = wmul(s.sizeEma, mul);

        mul = _powWad(FLOW_STEP_DECAY, elapsed);
        s.flowBuyEma = wmul(s.flowBuyEma, mul);
        s.flowSellEma = wmul(s.flowSellEma, mul);

        mul = _powWad(TOX_STEP_DECAY, elapsed);
        s.toxBidEma = wmul(s.toxBidEma, mul);
        s.toxAskEma = wmul(s.toxAskEma, mul);

        mul = _powWad(JUMP_STEP_DECAY, elapsed);
        s.jumpEma = wmul(s.jumpEma, mul);

        if (s.stepTradeCount > 0 && elapsedRaw > 0) {
            uint256 lambdaInst = (s.stepTradeCount * WAD) / elapsedRaw;
            if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
            s.lambdaHat = wmul(s.lambdaHat, LAMBDA_EMA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_EMA_DECAY);
        } else {
            s.lambdaHat = wmul(s.lambdaHat, _powWad(LAMBDA_GAP_DECAY, elapsed));
        }

        s.stepTradeCount = 0;
    }

    function _impliedPrice(uint256 spot, uint256 feeUsed, bool isBuy) internal pure returns (uint256) {
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        if (gamma == 0) return spot;
        return isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
    }

    function _toxFee(uint256 tox) internal pure returns (uint256) {
        uint256 excess = tox > TOX_QUAD_KNEE ? tox - TOX_QUAD_KNEE : 0;
        return wmul(TOX_LIN_COEF, tox) + wmul(TOX_QUAD_COEF, wmul(excess, excess));
    }

    function _compressTail(uint256 fee, uint256 slope) internal pure returns (uint256) {
        if (fee <= TAIL_KNEE) return fee;
        return TAIL_KNEE + wmul(fee - TAIL_KNEE, slope);
    }

    function _ema(uint256 prev, uint256 value, uint256 alpha) internal pure returns (uint256) {
        if (alpha >= WAD) return value;
        return wmul(prev, WAD - alpha) + wmul(value, alpha);
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
        return "wildcard_mod_v237";
    }
}
