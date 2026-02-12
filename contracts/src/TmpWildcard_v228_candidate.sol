pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"pivot","hypothesis_id":"H_STRESS_TENSOR_228","confidence":0.67,"ceiling_probability":0.24,"ev_next_5":0.19,"best_delta_seen":0.15,"reason":"Shift from gate-centric activity logic to a continuous stress tensor with adaptive fair-price tracking and dual signed skew drivers.","next_mechanism":"stress_tensor_and_dual_skew"}

    struct State {
        uint256 fairPrice;
        uint256 volEma;
        uint256 jumpEma;
        uint256 flowState;
        uint256 sizeEma;
        uint256 lambdaEma;
        uint256 activityEma;
        uint256 stepTradeCount;
        uint256 driftEma;
    }

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant STEP_COUNT_CAP = 96;

    uint256 constant RET_CAP = WAD / 10;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant TRADE_RATIO_CAP = WAD / 5;
    uint256 constant LAMBDA_CAP = 6 * WAD;

    uint256 constant FLOW_PUSH_MULT = 2;

    uint256 constant VOL_DECAY = 720000000000000000;
    uint256 constant JUMP_DECAY = 900000000000000000;
    uint256 constant SIZE_DECAY = 620000000000000000;
    uint256 constant FLOW_DECAY = 860000000000000000;
    uint256 constant ACTIVITY_DECAY = 740000000000000000;
    uint256 constant DRIFT_DECAY = 920000000000000000;
    uint256 constant LAMBDA_DECAY = 993000000000000000;

    uint256 constant SIZE_BLEND = 800000000000000000;
    uint256 constant FLOW_BLEND = 840000000000000000;
    uint256 constant VOL_BLEND = 780000000000000000;
    uint256 constant JUMP_BLEND = 140000000000000000;
    uint256 constant ACTIVITY_BLEND = 900000000000000000;
    uint256 constant DRIFT_BLEND = 920000000000000000;

    uint256 constant FAIR_ALPHA_BASE = 45000000000000000;
    uint256 constant FAIR_ALPHA_SIZE = 380000000000000000;
    uint256 constant FAIR_ALPHA_TOX = 220000000000000000;
    uint256 constant FAIR_ALPHA_MAX = 240000000000000000;
    uint256 constant FAIR_SHOCK_CUTOFF = 25000000000000000;
    uint256 constant FAIR_SHOCK_DAMP = 420000000000000000;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant VOL_COEF = 260 * BPS;
    uint256 constant JUMP_COEF = 230 * BPS;
    uint256 constant LAMBDA_COEF = 9 * BPS;
    uint256 constant SIZE_COEF = 1800 * BPS;
    uint256 constant ACTIVITY_COEF = 7000 * BPS;
    uint256 constant CROSS_COEF = 9000 * BPS;

    uint256 constant TOX_QUAD_KNEE = 12 * BPS;
    uint256 constant TOX_QUAD_COEF = 28000 * BPS;

    uint256 constant FLOW_SKEW_COEF = 190 * BPS;
    uint256 constant DRIFT_SKEW_COEF = 1400 * BPS;
    uint256 constant TOX_SKEW_COEF = 260 * BPS;
    uint256 constant STRESS_WIDEN_COEF = 12000 * BPS;

    uint256 constant TAIL_KNEE = 700 * BPS;
    uint256 constant TAIL_SLOPE = 900000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 860000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 950000000000000000;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        slots[4] = 800000000000000;
        slots[5] = 0;
        slots[6] = WAD;
        slots[7] = 1600000000000000;
        slots[8] = 850000000000000000;
        slots[9] = 0;
        slots[10] = 0;
        slots[11] = WAD;
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 prevBidFee = slots[0];
        uint256 prevAskFee = slots[1];
        uint256 lastTs = slots[2];

        State memory s = State({
            fairPrice: slots[3],
            volEma: slots[4],
            jumpEma: slots[5],
            flowState: slots[6],
            sizeEma: slots[7],
            lambdaEma: slots[8],
            activityEma: slots[9],
            stepTradeCount: slots[10],
            driftEma: slots[11]
        });

        s = _applyElapsedDecay(s, lastTs, trade.timestamp);

        {
            uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : s.fairPrice;
            if (s.fairPrice == 0) s.fairPrice = spot;
            uint256 fairRef = s.fairPrice;

            uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
            uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
            uint256 pImplied = gamma == 0 ? spot : (trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma));

            uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
            if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

            s.sizeEma = wmul(s.sizeEma, SIZE_BLEND) + wmul(tradeRatio, WAD - SIZE_BLEND);
            if (s.sizeEma > WAD) s.sizeEma = WAD;

            uint256 push = tradeRatio * FLOW_PUSH_MULT;
            if (push > WAD / 3) push = WAD / 3;
            uint256 flowTarget = trade.isBuy ? WAD + push : (WAD > push ? WAD - push : 0);
            s.flowState = wmul(s.flowState, FLOW_BLEND) + wmul(flowTarget, WAD - FLOW_BLEND);
            if (s.flowState > 2 * WAD) s.flowState = 2 * WAD;

            uint256 tox = fairRef > 0 ? wdiv(absDiff(spot, fairRef), fairRef) : 0;
            if (tox > TOX_CAP) tox = TOX_CAP;
            s.jumpEma = wmul(s.jumpEma, JUMP_BLEND) + wmul(tox, WAD - JUMP_BLEND);

            uint256 ret = fairRef > 0 ? wdiv(absDiff(pImplied, fairRef), fairRef) : 0;
            if (ret > RET_CAP) ret = RET_CAP;
            s.volEma = wmul(s.volEma, VOL_BLEND) + wmul(ret, WAD - VOL_BLEND);

            uint256 alpha = FAIR_ALPHA_BASE + wmul(FAIR_ALPHA_SIZE, s.sizeEma) + wmul(FAIR_ALPHA_TOX, s.jumpEma);
            if (alpha > FAIR_ALPHA_MAX) alpha = FAIR_ALPHA_MAX;
            if (ret > FAIR_SHOCK_CUTOFF) alpha = wmul(alpha, FAIR_SHOCK_DAMP);
            s.fairPrice = wmul(s.fairPrice, WAD - alpha) + wmul(pImplied, alpha);

            uint256 driftTarget = spot >= fairRef ? WAD + tox : (WAD > tox ? WAD - tox : 0);
            s.driftEma = wmul(s.driftEma, DRIFT_BLEND) + wmul(driftTarget, WAD - DRIFT_BLEND);

            uint256 flowLoad = wmul(s.lambdaEma, s.sizeEma);
            if (flowLoad > WAD) flowLoad = WAD;
            s.activityEma = wmul(s.activityEma, ACTIVITY_BLEND) + wmul(flowLoad, WAD - ACTIVITY_BLEND);
        }

        (uint256 bidFee, uint256 askFee) = _quoteFromState(s);

        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = s.fairPrice;
        slots[4] = s.volEma;
        slots[5] = s.jumpEma;
        slots[6] = s.flowState;
        slots[7] = s.sizeEma;
        slots[8] = s.lambdaEma;
        slots[9] = s.activityEma;
        slots[10] = s.stepTradeCount;
        slots[11] = s.driftEma;

        return (bidFee, askFee);
    }

    function _applyElapsedDecay(State memory s, uint256 lastTs, uint256 ts) internal pure returns (State memory) {
        if (ts <= lastTs) return s;

        uint256 elapsedRaw = ts - lastTs;
        uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

        s.volEma = wmul(s.volEma, _powWad(VOL_DECAY, elapsed));
        s.jumpEma = wmul(s.jumpEma, _powWad(JUMP_DECAY, elapsed));
        s.sizeEma = wmul(s.sizeEma, _powWad(SIZE_DECAY, elapsed));
        s.activityEma = wmul(s.activityEma, _powWad(ACTIVITY_DECAY, elapsed));
        s.flowState = _decayCentered(s.flowState, FLOW_DECAY, elapsed);
        s.driftEma = _decayCentered(s.driftEma, DRIFT_DECAY, elapsed);

        if (s.stepTradeCount > 0 && elapsedRaw > 0) {
            uint256 lambdaInst = (s.stepTradeCount * WAD) / elapsedRaw;
            if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
            s.lambdaEma = wmul(s.lambdaEma, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
        }

        s.stepTradeCount = 0;
        return s;
    }

    function _quoteFromState(State memory s) internal pure returns (uint256 bidFee, uint256 askFee) {
        uint256 flowDev = s.flowState >= WAD ? s.flowState - WAD : WAD - s.flowState;
        uint256 driftDev = s.driftEma >= WAD ? s.driftEma - WAD : WAD - s.driftEma;
        uint256 toxExcess = s.jumpEma > TOX_QUAD_KNEE ? s.jumpEma - TOX_QUAD_KNEE : 0;

        uint256 fCore = BASE_FEE
            + wmul(VOL_COEF, s.volEma)
            + wmul(JUMP_COEF, s.jumpEma)
            + wmul(LAMBDA_COEF, s.lambdaEma)
            + wmul(SIZE_COEF, s.sizeEma)
            + wmul(ACTIVITY_COEF, s.activityEma)
            + wmul(CROSS_COEF, wmul(s.jumpEma, flowDev))
            + wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));

        uint256 stressWiden = wmul(STRESS_WIDEN_COEF, wmul(s.jumpEma, s.activityEma));
        uint256 flowSkew = wmul(FLOW_SKEW_COEF, flowDev) + wmul(TOX_SKEW_COEF, wmul(s.jumpEma, flowDev));
        uint256 driftSkew = wmul(DRIFT_SKEW_COEF, driftDev);

        bidFee = fCore + stressWiden;
        askFee = fCore + stressWiden;

        if (s.flowState >= WAD) {
            bidFee = bidFee + flowSkew;
            askFee = askFee > flowSkew ? askFee - flowSkew : 0;
        } else {
            askFee = askFee + flowSkew;
            bidFee = bidFee > flowSkew ? bidFee - flowSkew : 0;
        }

        if (s.driftEma >= WAD) {
            bidFee = bidFee + driftSkew;
            askFee = askFee > driftSkew ? askFee - driftSkew : 0;
        } else {
            askFee = askFee + driftSkew;
            bidFee = bidFee > driftSkew ? bidFee - driftSkew : 0;
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
        return "wildcard_mod_v228";
    }
}
