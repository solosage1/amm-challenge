pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_TOX_ACT_001","confidence":0.63,"ceiling_probability":0.36,"ev_next_5":0.09,"best_delta_seen":2.3074,"reason":"promotion_edge 519.26 supports T5 confidence-weighted asymmetry with bounded fees, coherent spread behavior, and no pathological liquidity collapse","next_mechanism":"wildcard"}

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant STEP_COUNT_CAP = 64;

    uint256 constant SIGNAL_THRESHOLD = WAD / 900;
    uint256 constant TRADE_RATIO_CAP = WAD / 5;
    uint256 constant ARB_MAX_RATIO = WAD / 360;
    uint256 constant RET_CAP = WAD / 10;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant LAMBDA_CAP = 5 * WAD;
    uint256 constant FLOW_CAP = 40000000000000000;

    uint256 constant DIR_DECAY_PER_SEC = 150000000000000000;
    uint256 constant SIGMA_DECAY_PER_SEC = 90000000000000000;
    uint256 constant TOX_DECAY_PER_SEC = 70000000000000000;
    uint256 constant SIZE_DECAY_PER_SEC = 120000000000000000;
    uint256 constant CONF_DECAY_PER_SEC = 60000000000000000;
    uint256 constant LAMBDA_KEEP = 994000000000000000;

    uint256 constant ALPHA_FIRST_ARB = 260000000000000000;
    uint256 constant ALPHA_FIRST_RETAIL = 120000000000000000;
    uint256 constant ALPHA_FOLLOW = 50000000000000000;
    uint256 constant ALPHA_SHOCK_DAMP = 250000000000000000;
    uint256 constant SHOCK_GATE = 30 * BPS;

    uint256 constant SIGMA_ALPHA_FIRST = 220000000000000000;
    uint256 constant SIGMA_ALPHA_FOLLOW = 70000000000000000;
    uint256 constant TOX_ALPHA = 180000000000000000;
    uint256 constant SIZE_ALPHA = 180000000000000000;
    uint256 constant CONF_ALPHA = 180000000000000000;
    uint256 constant CONF_NEUTRAL = 650000000000000000;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant SIGMA_COEF = 170000000000000000;
    uint256 constant FLOW_COEF = 6200 * BPS;
    uint256 constant TOX_COEF = 180 * BPS;
    uint256 constant TOX_QUAD_COEF = 14000 * BPS;
    uint256 constant TOX_QUAD_KNEE = 12 * BPS;
    uint256 constant TOX_QUAD_CAP = 350 * BPS;
    uint256 constant CONF_GUARD_COEF = 180 * BPS;
    uint256 constant CONF_RELIEF_COEF = 70 * BPS;

    uint256 constant CONF_TOX_W = 2400000000000000000;
    uint256 constant CONF_SIGMA_W = 1400000000000000000;
    uint256 constant CONF_FLOW_W = 900000000000000000;
    uint256 constant CONF_RET_W = 700000000000000000;

    uint256 constant MID_FLOOR = 2 * BPS;
    uint256 constant MID_UP_CAP = 130 * BPS;
    uint256 constant MID_DOWN_CAP = 180 * BPS;

    uint256 constant SPREAD_BASE = 8 * BPS;
    uint256 constant SPREAD_TOX_COEF = 170 * BPS;
    uint256 constant SPREAD_SIGMA_COEF = 120 * BPS;
    uint256 constant SPREAD_FLOW_COEF = 180 * BPS;
    uint256 constant SPREAD_CONF_RELIEF = 90 * BPS;
    uint256 constant SPREAD_MIN = 4 * BPS;
    uint256 constant SPREAD_MAX = 220 * BPS;
    uint256 constant SPREAD_UP_CAP = 140 * BPS;
    uint256 constant SPREAD_DOWN_CAP = 160 * BPS;

    uint256 constant AGREE_TOX_GATE = 9 * BPS;
    uint256 constant AGREE_SIGMA_GATE = 8 * BPS;
    uint256 constant AGREE_FLOW_GATE = 1200000000000000;
    uint256 constant AGREE_ADD = 28 * BPS;

    uint256 constant DIR_COEF = 100 * BPS;
    uint256 constant DIR_TOX_COEF = 40 * BPS;
    uint256 constant SKEW_CAP = 160 * BPS;

    uint256 constant SPLIT_COEF = 220 * BPS;
    uint256 constant SPLIT_CONF_COEF = 300 * BPS;
    uint256 constant REBATE_COEF = 140 * BPS;
    uint256 constant MIN_SIDE_FEE = 2 * BPS;
    uint256 constant MAX_SIDE_SPREAD = 260 * BPS;

    uint256 constant TAIL_KNEE = 700 * BPS;
    uint256 constant TAIL_SLOPE = 900000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 830000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 950000000000000000;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD;
        slots[4] = p0;
        slots[5] = 1000000000000000;
        slots[6] = 0;
        slots[7] = 800000000000000000;
        slots[8] = 1800000000000000;
        slots[9] = CONF_NEUTRAL;
        slots[10] = 0;
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 prevBidFee = slots[0];
        uint256 prevAskFee = slots[1];
        uint256 lastTs = slots[2];
        uint256 flowState = slots[3];
        uint256 pRef = slots[4];
        uint256 sigmaEma = slots[5];
        uint256 toxEma = slots[6];
        uint256 lambdaEma = slots[7];
        uint256 sizeEma = slots[8];
        uint256 confEma = slots[9];
        uint256 stepTradeCount = slots[10];

        if (trade.timestamp > lastTs) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            flowState = _decayCenteredLinear(flowState, DIR_DECAY_PER_SEC, elapsed);
            sigmaEma = _decayLinear(sigmaEma, SIGMA_DECAY_PER_SEC, elapsed);
            toxEma = _decayLinear(toxEma, TOX_DECAY_PER_SEC, elapsed);
            sizeEma = _decayLinear(sizeEma, SIZE_DECAY_PER_SEC, elapsed);
            confEma = _decayToward(confEma, CONF_NEUTRAL, CONF_DECAY_PER_SEC, elapsed);

            if (stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                lambdaEma = _blend(lambdaEma, lambdaInst, WAD - LAMBDA_KEEP);
            }

            stepTradeCount = 0;
        }

        bool firstInStep = stepTradeCount == 0;

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pRef;
        if (pRef == 0) pRef = spot;

        uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied;
        if (gamma == 0) {
            pImplied = spot;
        } else {
            pImplied = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
        }

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        bool likelyArb = firstInStep && tradeRatio <= ARB_MAX_RATIO;

        uint256 ret = pRef > 0 ? wdiv(absDiff(pImplied, pRef), pRef) : 0;
        if (ret > RET_CAP) ret = RET_CAP;

        uint256 alpha;
        if (firstInStep) {
            alpha = likelyArb ? ALPHA_FIRST_ARB : ALPHA_FIRST_RETAIL;
        } else {
            alpha = ALPHA_FOLLOW;
        }
        if (ret > SHOCK_GATE) alpha = wmul(alpha, ALPHA_SHOCK_DAMP);
        pRef = _blend(pRef, pImplied, alpha);

        uint256 sigmaInput = firstInStep ? ret : ret / 2;
        sigmaEma = _blend(sigmaEma, sigmaInput, firstInStep ? SIGMA_ALPHA_FIRST : SIGMA_ALPHA_FOLLOW);

        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = tradeRatio;
            if (push > WAD / 4) push = WAD / 4;
            if (trade.isBuy) {
                flowState = flowState + push;
                if (flowState > 2 * WAD) flowState = 2 * WAD;
            } else {
                flowState = flowState > push ? flowState - push : 0;
            }
        }

        sizeEma = _blend(sizeEma, tradeRatio, SIZE_ALPHA);
        if (sizeEma > WAD) sizeEma = WAD;

        uint256 toxInst = pRef > 0 ? wdiv(absDiff(spot, pRef), pRef) : 0;
        if (toxInst > TOX_CAP) toxInst = TOX_CAP;
        toxEma = _blend(toxEma, toxInst, TOX_ALPHA);

        uint256 flowPressure = wmul(lambdaEma, sizeEma);
        if (flowPressure > FLOW_CAP) flowPressure = FLOW_CAP;

        uint256 confPenalty =
            wmul(CONF_TOX_W, toxEma)
            + wmul(CONF_SIGMA_W, sigmaEma)
            + wmul(CONF_FLOW_W, flowPressure);
        if (firstInStep) confPenalty = confPenalty + wmul(CONF_RET_W, ret);
        uint256 confInst = confPenalty >= WAD ? 0 : WAD - confPenalty;
        confEma = _blend(confEma, confInst, CONF_ALPHA);

        uint256 toxExcess = toxEma > TOX_QUAD_KNEE ? toxEma - TOX_QUAD_KNEE : 0;
        uint256 toxQuad = wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        if (toxQuad > TOX_QUAD_CAP) toxQuad = TOX_QUAD_CAP;

        uint256 center =
            BASE_FEE
            + wmul(SIGMA_COEF, sigmaEma)
            + wmul(FLOW_COEF, flowPressure)
            + wmul(TOX_COEF, toxEma)
            + toxQuad
            + wmul(CONF_GUARD_COEF, WAD - confEma);

        uint256 centerRelief = wmul(CONF_RELIEF_COEF, confEma);
        if (center > centerRelief) {
            center = center - centerRelief;
        } else {
            center = MID_FLOOR;
        }
        if (center < MID_FLOOR) center = MID_FLOOR;
        center = _capMove(center, (prevBidFee + prevAskFee) / 2, MID_UP_CAP, MID_DOWN_CAP);

        uint256 spread =
            SPREAD_BASE
            + wmul(SPREAD_TOX_COEF, toxEma)
            + wmul(SPREAD_SIGMA_COEF, sigmaEma)
            + wmul(SPREAD_FLOW_COEF, flowPressure);

        if (toxEma > AGREE_TOX_GATE && sigmaEma > AGREE_SIGMA_GATE && flowPressure > AGREE_FLOW_GATE) {
            spread = spread + AGREE_ADD;
        }

        uint256 spreadRelief = wmul(SPREAD_CONF_RELIEF, confEma);
        spread = spread > spreadRelief ? spread - spreadRelief : SPREAD_MIN;
        if (spread < SPREAD_MIN) spread = SPREAD_MIN;
        if (spread > SPREAD_MAX) spread = SPREAD_MAX;
        spread = _capMove(spread, absDiff(prevBidFee, prevAskFee), SPREAD_UP_CAP, SPREAD_DOWN_CAP);
        if (spread < SPREAD_MIN) spread = SPREAD_MIN;
        if (spread > SPREAD_MAX) spread = SPREAD_MAX;

        uint256 dirDev;
        bool protectBid;
        if (flowState >= WAD) {
            dirDev = flowState - WAD;
            protectBid = true;
        } else {
            dirDev = WAD - flowState;
            protectBid = false;
        }

        uint256 skew = wmul(DIR_COEF, dirDev) + wmul(DIR_TOX_COEF, wmul(dirDev, toxEma));
        if (skew > SKEW_CAP) skew = SKEW_CAP;

        uint256 half = spread / 2;
        uint256 bidFee;
        uint256 askFee;
        if (protectBid) {
            bidFee = center + half + skew;
            askFee = center > half ? center - half : 0;
        } else {
            askFee = center + half + skew;
            bidFee = center > half ? center - half : 0;
        }

        uint256 split = wmul(SPLIT_COEF, toxEma) + wmul(SPLIT_CONF_COEF, wmul(toxEma, WAD - confEma));
        if (spot >= pRef) {
            bidFee = bidFee + split;
        } else {
            askFee = askFee + split;
        }

        uint256 rebate = wmul(REBATE_COEF, wmul(confEma, WAD - toxEma));
        if (spot >= pRef) {
            askFee = askFee > rebate ? askFee - rebate : 0;
        } else {
            bidFee = bidFee > rebate ? bidFee - rebate : 0;
        }

        if (bidFee > askFee) {
            uint256 d = bidFee - askFee;
            if (d > MAX_SIDE_SPREAD) {
                uint256 cut = d - MAX_SIDE_SPREAD;
                bidFee = bidFee > cut ? bidFee - cut : 0;
            }
        } else {
            uint256 d = askFee - bidFee;
            if (d > MAX_SIDE_SPREAD) {
                uint256 cut = d - MAX_SIDE_SPREAD;
                askFee = askFee > cut ? askFee - cut : 0;
            }
        }

        if (bidFee < MIN_SIDE_FEE) bidFee = MIN_SIDE_FEE;
        if (askFee < MIN_SIDE_FEE) askFee = MIN_SIDE_FEE;

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

        if (bidFee < MIN_SIDE_FEE) bidFee = MIN_SIDE_FEE;
        if (askFee < MIN_SIDE_FEE) askFee = MIN_SIDE_FEE;

        stepTradeCount = stepTradeCount + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = flowState;
        slots[4] = pRef;
        slots[5] = sigmaEma;
        slots[6] = toxEma;
        slots[7] = lambdaEma;
        slots[8] = sizeEma;
        slots[9] = confEma;
        slots[10] = stepTradeCount;

        return (bidFee, askFee);
    }

    function _blend(uint256 oldValue, uint256 newValue, uint256 alpha) internal pure returns (uint256) {
        return wmul(oldValue, WAD - alpha) + wmul(newValue, alpha);
    }

    function _decayLinear(uint256 value, uint256 perSec, uint256 elapsed) internal pure returns (uint256) {
        uint256 d = perSec * elapsed;
        if (d >= WAD) return 0;
        return wmul(value, WAD - d);
    }

    function _decayToward(uint256 value, uint256 target, uint256 perSec, uint256 elapsed) internal pure returns (uint256) {
        uint256 d = perSec * elapsed;
        if (d > WAD) d = WAD;
        return wmul(value, WAD - d) + wmul(target, d);
    }

    function _decayCenteredLinear(uint256 centered, uint256 perSec, uint256 elapsed) internal pure returns (uint256) {
        uint256 d = perSec * elapsed;
        if (d > WAD) d = WAD;
        uint256 keep = WAD - d;
        if (centered >= WAD) {
            return WAD + wmul(centered - WAD, keep);
        }
        uint256 below = wmul(WAD - centered, keep);
        return below < WAD ? WAD - below : 0;
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

    function getName() external pure override returns (string memory) {
        return "wildcard_mod_v255";
    }
}
