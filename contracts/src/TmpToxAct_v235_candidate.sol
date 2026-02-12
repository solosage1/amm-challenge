pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_TOX_ACT_010","confidence":0.59,"ceiling_probability":0.34,"ev_next_5":0.06,"best_delta_seen":0.15,"reason":"Selected H_TOX_ACT_010 on highest eff_priority 0.812 with repeat_streak 0 and steps_since_last 5 to test smoother tox/activity transitions.","next_mechanism":"toxicity_and_activity"}

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant SIGNAL_THRESHOLD = WAD / 700;
    uint256 constant DIR_DECAY = 850000000000000000;
    uint256 constant ACT_DECAY = 700000000000000000;
    uint256 constant SIZE_DECAY = 600000000000000000;
    uint256 constant TOX_DECAY = 900000000000000000;
    uint256 constant SIGMA_DECAY = 650000000000000000;
    uint256 constant LAMBDA_DECAY = 994000000000000000;
    uint256 constant SIZE_BLEND_DECAY = 800000000000000000;
    uint256 constant TOX_BLEND_DECAY = 100000000000000000;
    uint256 constant ACT_BLEND_DECAY = 993000000000000000;
    uint256 constant PHAT_ALPHA_ARB = 340000000000000000;
    uint256 constant PHAT_ALPHA_RETAIL = 120000000000000000;
    uint256 constant PHAT_SHOCK_GATE = 30000000000000000;
    uint256 constant DIR_IMPACT_MULT = 1;
    uint256 constant ARB_MAX_RATIO = WAD / 360;
    uint256 constant SIGMA_RETAIL_DECAY = 999000000000000000;

    uint256 constant RET_CAP = WAD / 10;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant TRADE_RATIO_CAP = WAD / 5;
    uint256 constant LAMBDA_CAP = 5 * WAD;
    uint256 constant STEP_COUNT_CAP = 64;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant SIGMA_COEF = 200000000000000000;
    uint256 constant LAMBDA_COEF = 12 * BPS;
    uint256 constant FLOW_SIZE_COEF = 6800 * BPS;
    uint256 constant TOX_COEF = 180 * BPS;
    uint256 constant TOX_QUAD_COEF = 19000 * BPS;
    uint256 constant TOX_QUAD_KNEE = 12 * BPS;
    uint256 constant TOX_FAVORABLE_MULT = 920000000000000000;
    uint256 constant TOX_ADVERSE_MULT = 1080000000000000000;
    uint256 constant ACT_COEF = 42000 * BPS;
    uint256 constant ACT_GATE_LAMBDA = 950000000000000000;
    uint256 constant ACT_GATE_SIZE = 3000000000000000;
    uint256 constant TOX_ACT_DELTA_CAP = 120 * BPS;
    uint256 constant DIR_COEF = 90 * BPS;
    uint256 constant DIR_TOX_COEF = 20 * BPS;
    uint256 constant STALE_DIR_COEF = 6900 * BPS;
    uint256 constant TAIL_KNEE = 700 * BPS;
    uint256 constant TAIL_SLOPE = 900000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 820000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 960000000000000000;

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
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 prevBidFee = slots[0];
        uint256 prevAskFee = slots[1];
        uint256 lastTs = slots[2];
        uint256 dirState = slots[3];
        uint256 actEma = slots[4];
        uint256 pHat = slots[5];
        uint256 sigmaHat = slots[6];
        uint256 lambdaHat = slots[7];
        uint256 sizeHat = slots[8];
        uint256 toxEma = slots[9];
        uint256 stepTradeCount = slots[10];

        bool isNewStep = trade.timestamp > lastTs;
        if (isNewStep) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            dirState = _decayCentered(dirState, DIR_DECAY, elapsed);
            actEma = wmul(actEma, _powWad(ACT_DECAY, elapsed));
            sizeHat = wmul(sizeHat, _powWad(SIZE_DECAY, elapsed));
            toxEma = wmul(toxEma, _powWad(TOX_DECAY, elapsed));

            if (stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                lambdaHat = wmul(lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
            }

            stepTradeCount = 0;
        }

        bool firstInStep = stepTradeCount == 0;

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pHat;
        if (pHat == 0) pHat = spot;

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
        if (firstInStep) {
            uint256 ret = pHat > 0 ? wdiv(absDiff(pImplied, pHat), pHat) : 0;
            if (likelyArb) {
                if (ret <= PHAT_SHOCK_GATE) {
                    pHat = wmul(pHat, WAD - PHAT_ALPHA_ARB) + wmul(pImplied, PHAT_ALPHA_ARB);
                }
                if (ret > RET_CAP) ret = RET_CAP;
                sigmaHat = wmul(sigmaHat, SIGMA_DECAY) + wmul(ret, WAD - SIGMA_DECAY);
            } else {
                if (ret <= PHAT_SHOCK_GATE) {
                    pHat = wmul(pHat, WAD - PHAT_ALPHA_RETAIL) + wmul(pImplied, PHAT_ALPHA_RETAIL);
                }
                sigmaHat = wmul(sigmaHat, SIGMA_RETAIL_DECAY);
            }
        }

        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = tradeRatio * DIR_IMPACT_MULT;
            if (push > WAD / 4) push = WAD / 4;

            if (trade.isBuy) {
                dirState = dirState + push;
                if (dirState > 2 * WAD) dirState = 2 * WAD;
            } else {
                dirState = dirState > push ? dirState - push : 0;
            }

            actEma = wmul(actEma, ACT_BLEND_DECAY) + wmul(tradeRatio, WAD - ACT_BLEND_DECAY);

            sizeHat = wmul(sizeHat, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
            if (sizeHat > WAD) sizeHat = WAD;
        }

        uint256 tox = pHat > 0 ? wdiv(absDiff(spot, pHat), pHat) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;
        toxEma = wmul(toxEma, TOX_BLEND_DECAY) + wmul(tox, WAD - TOX_BLEND_DECAY);
        uint256 toxSignal = toxEma;

        uint256 flowSize = wmul(lambdaHat, sizeHat);
        uint256 fBase = BASE_FEE + wmul(SIGMA_COEF, sigmaHat) + wmul(LAMBDA_COEF, lambdaHat) + wmul(FLOW_SIZE_COEF, flowSize);

        uint256 toxExcess = toxSignal > TOX_QUAD_KNEE ? toxSignal - TOX_QUAD_KNEE : 0;
        uint256 toxAdd = wmul(TOX_COEF, toxSignal) + wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
        uint256 toxFavAdd = wmul(toxAdd, TOX_FAVORABLE_MULT);
        uint256 toxAdverseAdd = wmul(toxAdd, TOX_ADVERSE_MULT);
        uint256 toxSplitAdd = toxAdverseAdd > toxFavAdd ? toxAdverseAdd - toxFavAdd : 0;

        uint256 actAdd = 0;
        if (lambdaHat >= ACT_GATE_LAMBDA && sizeHat >= ACT_GATE_SIZE) {
            actAdd = wmul(ACT_COEF, actEma);
        }
        uint256 toxActAdd = toxFavAdd + actAdd;
        uint256 prevMidFee = (prevBidFee + prevAskFee) / 2;
        uint256 prevToxActAdd = prevMidFee > fBase ? prevMidFee - fBase : 0;
        if (toxActAdd > prevToxActAdd) {
            uint256 upMove = toxActAdd - prevToxActAdd;
            if (upMove > TOX_ACT_DELTA_CAP) toxActAdd = prevToxActAdd + TOX_ACT_DELTA_CAP;
        } else {
            uint256 downMove = prevToxActAdd - toxActAdd;
            if (downMove > TOX_ACT_DELTA_CAP) {
                toxActAdd = prevToxActAdd > TOX_ACT_DELTA_CAP ? prevToxActAdd - TOX_ACT_DELTA_CAP : 0;
            }
        }
        uint256 fMid = fBase + toxActAdd;

        uint256 dirDev;
        bool sellPressure;
        if (dirState >= WAD) {
            dirDev = dirState - WAD;
            sellPressure = true;
        } else {
            dirDev = WAD - dirState;
            sellPressure = false;
        }

        uint256 skew = wmul(DIR_COEF, dirDev) + wmul(DIR_TOX_COEF, wmul(dirDev, toxSignal));

        uint256 bidFee;
        uint256 askFee;
        if (sellPressure) {
            bidFee = fMid + skew;
            askFee = fMid > skew ? fMid - skew : 0;
        } else {
            askFee = fMid + skew;
            bidFee = fMid > skew ? fMid - skew : 0;
        }

        if (toxSplitAdd > 0) {
            if (spot >= pHat) {
                bidFee = bidFee + toxSplitAdd;
            } else {
                askFee = askFee + toxSplitAdd;
            }
        }

        if (STALE_DIR_COEF > 0) {
            uint256 staleShift = wmul(STALE_DIR_COEF, toxSignal);
            if (spot >= pHat) {
                bidFee = bidFee + staleShift;
                askFee = askFee > staleShift ? askFee - staleShift : 0;
            } else {
                askFee = askFee + staleShift;
                bidFee = bidFee > staleShift ? bidFee - staleShift : 0;
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

        stepTradeCount = stepTradeCount + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = dirState;
        slots[4] = actEma;
        slots[5] = pHat;
        slots[6] = sigmaHat;
        slots[7] = lambdaHat;
        slots[8] = sizeHat;
        slots[9] = toxEma;
        slots[10] = stepTradeCount;

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
        return "toxicity_and_activity_mod_v236";
    }
}
