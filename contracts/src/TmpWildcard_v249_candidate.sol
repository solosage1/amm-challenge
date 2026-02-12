pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_WILDCARD_249","confidence":0.71,"ceiling_probability":0.30,"ev_next_5":0.11,"best_delta_seen":0.0,"reason":"promotion_edge 519.26 with wildcard best_delta 0.00 supports a T1 structural jump while enforcing bounded fees, coherent spreads, and no pathological liquidity collapse.","next_mechanism":"wildcard"}

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant STEP_COUNT_CAP = 96;

    uint256 constant SIGNAL_THRESHOLD = WAD / 900;
    uint256 constant TRADE_RATIO_CAP = WAD / 4;
    uint256 constant RET_CAP = WAD / 6;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant SHOCK_CAP = WAD / 5;
    uint256 constant LAMBDA_CAP = 6 * WAD;

    uint256 constant FLOW_DECAY = 850000000000000000;
    uint256 constant SIGMA_DECAY = 720000000000000000;
    uint256 constant TOX_DECAY = 820000000000000000;
    uint256 constant SIZE_DECAY = 760000000000000000;
    uint256 constant SHOCK_DECAY = 780000000000000000;
    uint256 constant LAMBDA_DECAY = 993000000000000000;

    uint256 constant FLOW_BLEND_DECAY = 930000000000000000;
    uint256 constant SIGMA_BLEND_CALM_DECAY = 880000000000000000;
    uint256 constant SIGMA_BLEND_SHOCK_DECAY = 700000000000000000;
    uint256 constant TOX_BLEND_DECAY = 810000000000000000;
    uint256 constant SIZE_BLEND_DECAY = 850000000000000000;
    uint256 constant SHOCK_BLEND_DECAY = 840000000000000000;

    uint256 constant FAST_ALPHA_CALM = 210000000000000000;
    uint256 constant FAST_ALPHA_SHOCK = 620000000000000000;
    uint256 constant SLOW_ALPHA_CALM = 35000000000000000;
    uint256 constant SLOW_ALPHA_SHOCK = 140000000000000000;
    uint256 constant SHOCK_GATE = 20 * BPS;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant SIGMA_COEF = 220000000000000000;
    uint256 constant LAMBDA_COEF = 15 * BPS;
    uint256 constant FLOW_SIZE_COEF = 6200 * BPS;
    uint256 constant TOX_COEF = 260 * BPS;
    uint256 constant TOX_QUAD_COEF = 17000 * BPS;
    uint256 constant TOX_QUAD_KNEE = 12 * BPS;
    uint256 constant TOX_QUAD_ADD_CAP = 420 * BPS;
    uint256 constant TOX_FAVORABLE_MULT = 850000000000000000;
    uint256 constant TOX_ADVERSE_MULT = 1150000000000000000;
    uint256 constant SHOCK_COEF = 320 * BPS;

    uint256 constant SPREAD_BASE = 8 * BPS;
    uint256 constant SPREAD_TOX_COEF = 190 * BPS;
    uint256 constant SPREAD_SHOCK_COEF = 240 * BPS;
    uint256 constant SPREAD_SHOCK_STEP = 25 * BPS;
    uint256 constant SPREAD_CAP = 900 * BPS;

    uint256 constant SKEW_COEF = 120 * BPS;
    uint256 constant SKEW_TOX_COEF = 60 * BPS;
    uint256 constant MAX_SPREAD = 220 * BPS;
    uint256 constant MIN_SIDE_FEE = 2 * BPS;

    uint256 constant TAIL_KNEE = 700 * BPS;
    uint256 constant TAIL_SLOPE = 880000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 810000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 950000000000000000;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;

        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD;
        slots[4] = p0;
        slots[5] = p0;
        slots[6] = 1200000000000000;
        slots[7] = 0;
        slots[8] = 1800000000000000;
        slots[9] = 700000000000000000;
        slots[10] = 0;
        slots[11] = 0;

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 prevBidFee = slots[0];
        uint256 prevAskFee = slots[1];
        uint256 lastTs = slots[2];
        uint256 flowState = slots[3];
        uint256 pFast = slots[4];
        uint256 pSlow = slots[5];
        uint256 sigmaEma = slots[6];
        uint256 toxEma = slots[7];
        uint256 sizeEma = slots[8];
        uint256 lambdaEma = slots[9];
        uint256 shockEma = slots[10];
        uint256 stepTradeCount = slots[11];

        if (trade.timestamp > lastTs) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            flowState = _decayCentered(flowState, FLOW_DECAY, elapsed);
            sigmaEma = wmul(sigmaEma, _powWad(SIGMA_DECAY, elapsed));
            toxEma = wmul(toxEma, _powWad(TOX_DECAY, elapsed));
            sizeEma = wmul(sizeEma, _powWad(SIZE_DECAY, elapsed));
            shockEma = wmul(shockEma, _powWad(SHOCK_DECAY, elapsed));

            if (stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                lambdaEma = wmul(lambdaEma, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
            }

            stepTradeCount = 0;
        }

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pSlow;
        if (pFast == 0) pFast = spot;
        if (pSlow == 0) pSlow = spot;

        uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied;
        if (gamma == 0) {
            pImplied = spot;
        } else {
            pImplied = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
        }

        uint256 retFast = pFast > 0 ? wdiv(absDiff(pImplied, pFast), pFast) : 0;
        uint256 retSlow = pSlow > 0 ? wdiv(absDiff(pImplied, pSlow), pSlow) : 0;
        if (retFast > RET_CAP) retFast = RET_CAP;
        if (retSlow > RET_CAP) retSlow = RET_CAP;

        uint256 shockInst = retFast > retSlow ? retFast : retSlow;
        if (shockInst > SHOCK_CAP) shockInst = SHOCK_CAP;
        shockEma = wmul(shockEma, SHOCK_BLEND_DECAY) + wmul(shockInst, WAD - SHOCK_BLEND_DECAY);

        bool shockOn = shockEma >= SHOCK_GATE;

        uint256 fastAlpha = shockOn ? FAST_ALPHA_SHOCK : FAST_ALPHA_CALM;
        uint256 slowAlpha = shockOn ? SLOW_ALPHA_SHOCK : SLOW_ALPHA_CALM;
        pFast = wmul(pFast, WAD - fastAlpha) + wmul(pImplied, fastAlpha);
        pSlow = wmul(pSlow, WAD - slowAlpha) + wmul(pImplied, slowAlpha);

        uint256 sigmaBlendDecay = shockOn ? SIGMA_BLEND_SHOCK_DECAY : SIGMA_BLEND_CALM_DECAY;
        sigmaEma = wmul(sigmaEma, sigmaBlendDecay) + wmul(retFast, WAD - sigmaBlendDecay);

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = tradeRatio;
            if (push > WAD / 4) push = WAD / 4;

            if (trade.isBuy) {
                flowState = flowState + push;
                if (flowState > 2 * WAD) flowState = 2 * WAD;
            } else {
                flowState = flowState > push ? flowState - push : 0;
            }

            flowState = _decayCentered(flowState, FLOW_BLEND_DECAY, 1);
            sizeEma = wmul(sizeEma, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
            if (sizeEma > WAD) sizeEma = WAD;
        }

        uint256 toxStale = pSlow > 0 ? wdiv(absDiff(spot, pSlow), pSlow) : 0;
        uint256 toxGap = pSlow > 0 ? wdiv(absDiff(pFast, pSlow), pSlow) : 0;
        uint256 toxInst = toxStale > toxGap ? toxStale : toxGap;
        if (toxInst > TOX_CAP) toxInst = TOX_CAP;
        toxEma = wmul(toxEma, TOX_BLEND_DECAY) + wmul(toxInst, WAD - TOX_BLEND_DECAY);

        uint256 flowSize = wmul(lambdaEma, sizeEma);
        uint256 fBase = BASE_FEE
            + wmul(SIGMA_COEF, sigmaEma)
            + wmul(LAMBDA_COEF, lambdaEma)
            + wmul(FLOW_SIZE_COEF, flowSize)
            + wmul(SHOCK_COEF, shockEma);

        uint256 toxExcess = toxEma > TOX_QUAD_KNEE ? toxEma - TOX_QUAD_KNEE : 0;
        uint256 toxQuadAdd = wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        if (toxQuadAdd > TOX_QUAD_ADD_CAP) toxQuadAdd = TOX_QUAD_ADD_CAP;

        uint256 toxAdd = wmul(TOX_COEF, toxEma) + toxQuadAdd;
        uint256 toxFavAdd = wmul(toxAdd, TOX_FAVORABLE_MULT);
        uint256 toxAdverseAdd = wmul(toxAdd, TOX_ADVERSE_MULT);
        uint256 toxSplitAdd = toxAdverseAdd > toxFavAdd ? toxAdverseAdd - toxFavAdd : 0;

        uint256 spread = SPREAD_BASE + wmul(SPREAD_TOX_COEF, toxEma) + wmul(SPREAD_SHOCK_COEF, shockEma);
        if (shockOn) spread = spread + SPREAD_SHOCK_STEP;
        if (spread > SPREAD_CAP) spread = SPREAD_CAP;

        uint256 dirDev;
        bool bidPressure;
        if (flowState >= WAD) {
            dirDev = flowState - WAD;
            bidPressure = true;
        } else {
            dirDev = WAD - flowState;
            bidPressure = false;
        }

        uint256 skew = wmul(SKEW_COEF, dirDev) + wmul(SKEW_TOX_COEF, wmul(dirDev, toxEma));
        if (skew > spread) skew = spread;

        uint256 protectAdd = spread + skew;
        uint256 attractAdd = spread > skew ? spread - skew : 0;

        uint256 core = fBase + toxFavAdd;

        uint256 bidFee;
        uint256 askFee;
        if (bidPressure) {
            bidFee = core + protectAdd;
            askFee = core + attractAdd;
        } else {
            askFee = core + protectAdd;
            bidFee = core + attractAdd;
        }

        if (toxSplitAdd > 0) {
            if (spot >= pSlow) {
                bidFee = bidFee + toxSplitAdd;
            } else {
                askFee = askFee + toxSplitAdd;
            }
        }

        if (bidFee < MIN_SIDE_FEE) bidFee = MIN_SIDE_FEE;
        if (askFee < MIN_SIDE_FEE) askFee = MIN_SIDE_FEE;

        if (bidFee > askFee) {
            uint256 spreadNow = bidFee - askFee;
            if (spreadNow > MAX_SPREAD) {
                uint256 cut = spreadNow - MAX_SPREAD;
                bidFee = bidFee > cut ? bidFee - cut : MIN_SIDE_FEE;
            }
        } else {
            uint256 spreadNow = askFee - bidFee;
            if (spreadNow > MAX_SPREAD) {
                uint256 cut = spreadNow - MAX_SPREAD;
                askFee = askFee > cut ? askFee - cut : MIN_SIDE_FEE;
            }
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

        if (bidFee < MIN_SIDE_FEE) bidFee = MIN_SIDE_FEE;
        if (askFee < MIN_SIDE_FEE) askFee = MIN_SIDE_FEE;

        stepTradeCount = stepTradeCount + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = flowState;
        slots[4] = pFast;
        slots[5] = pSlow;
        slots[6] = sigmaEma;
        slots[7] = toxEma;
        slots[8] = sizeEma;
        slots[9] = lambdaEma;
        slots[10] = shockEma;
        slots[11] = stepTradeCount;

        return (bidFee, askFee);
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
        return "wildcard_mod_v249";
    }
}
