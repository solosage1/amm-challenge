pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_WILDCARD_200","confidence":0.67,"ceiling_probability":0.29,"ev_next_5":0.11,"best_delta_seen":0.15,"reason":"Replace first-trade anchor logic with continuous bounded anchors and dual-horizon flow skew to better balance arb protection vs retail capture.","next_mechanism":"continuous_anchor_dual_flow"}

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant SIGNAL_THRESHOLD = WAD / 700;

    uint256 constant DIR_FAST_DECAY = 840000000000000000;
    uint256 constant DIR_SLOW_DECAY = 950000000000000000;
    uint256 constant ACT_DECAY = 700000000000000000;
    uint256 constant SIZE_DECAY = 610000000000000000;
    uint256 constant TOX_DECAY = 900000000000000000;
    uint256 constant SIGMA_DECAY = 740000000000000000;
    uint256 constant LAMBDA_DECAY = 994000000000000000;
    uint256 constant BURST_DECAY = 760000000000000000;

    uint256 constant SIZE_BLEND_DECAY = 800000000000000000;
    uint256 constant TOX_BLEND_DECAY = 120000000000000000;
    uint256 constant ACT_BLEND_DECAY = 993000000000000000;
    uint256 constant BURST_BLEND_DECAY = 760000000000000000;

    uint256 constant SIGMA_ARB_BLEND = 700000000000000000;
    uint256 constant SIGMA_RETAIL_BLEND = 960000000000000000;

    uint256 constant PHAT_ALPHA_BASE = 70000000000000000;
    uint256 constant PHAT_ALPHA_SIZE = 340000000000000000;
    uint256 constant PHAT_ALPHA_TOX = 180000000000000000;
    uint256 constant PHAT_ALPHA_MAX = 330000000000000000;
    uint256 constant PHAT_MOVE_CAP = 140 * BPS;

    uint256 constant DIR_IMPACT_MULT = 1;
    uint256 constant DIR_SLOW_PUSH_MULT = 440000000000000000;
    uint256 constant ARB_MAX_RATIO = WAD / 360;

    uint256 constant RET_CAP = WAD / 10;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant TRADE_RATIO_CAP = WAD / 5;
    uint256 constant LAMBDA_CAP = 5 * WAD;
    uint256 constant STEP_COUNT_CAP = 64;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant SIGMA_COEF = 190000000000000000;
    uint256 constant LAMBDA_COEF = 12 * BPS;
    uint256 constant FLOW_SIZE_COEF = 6500 * BPS;

    uint256 constant TOX_COEF = 170 * BPS;
    uint256 constant TOX_QUAD_COEF = 18000 * BPS;
    uint256 constant TOX_QUAD_KNEE = 11 * BPS;

    uint256 constant ACT_COEF = 37000 * BPS;
    uint256 constant BURST_COEF = 12000 * BPS;

    uint256 constant DIR_FAST_WEIGHT = 700000000000000000;
    uint256 constant DIR_COEF = 95 * BPS;
    uint256 constant DIR_TOX_COEF = 24 * BPS;
    uint256 constant DIR_LEAD_COEF = 48 * BPS;

    uint256 constant STALE_DIR_COEF = 6000 * BPS;

    uint256 constant TAIL_KNEE_BASE = 680 * BPS;
    uint256 constant TAIL_KNEE_TOX_COEF = 2300 * BPS;
    uint256 constant TAIL_KNEE_SIGMA_COEF = 1700 * BPS;
    uint256 constant TAIL_KNEE_MAX = 1200 * BPS;

    uint256 constant TAIL_SLOPE = 900000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 830000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 965000000000000000;

    uint256 constant RATE_UP_MIN = 40 * BPS;
    uint256 constant RATE_UP_RISK_RANGE = 170 * BPS;
    uint256 constant RATE_DOWN_MIN = 28 * BPS;
    uint256 constant RATE_DOWN_CALM_RANGE = 140 * BPS;

    uint256 constant SIDE_FLOOR = 1 * BPS;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD;
        slots[4] = WAD;
        slots[5] = 0;
        slots[6] = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        slots[7] = 950000000000000;
        slots[8] = 800000000000000000;
        slots[9] = 2000000000000000;
        slots[10] = 0;
        slots[11] = 0;
        slots[12] = 0;
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 prevBidFee = slots[0];
        uint256 prevAskFee = slots[1];
        uint256 lastTs = slots[2];
        uint256 dirFast = slots[3];
        uint256 dirSlow = slots[4];
        uint256 actEma = slots[5];
        uint256 pHat = slots[6];
        uint256 sigmaHat = slots[7];
        uint256 lambdaHat = slots[8];
        uint256 sizeHat = slots[9];
        uint256 toxEma = slots[10];
        uint256 stepTradeCount = slots[11];
        uint256 burstEma = slots[12];

        bool isNewStep = trade.timestamp > lastTs;
        if (isNewStep) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            dirFast = _decayCentered(dirFast, DIR_FAST_DECAY, elapsed);
            dirSlow = _decayCentered(dirSlow, DIR_SLOW_DECAY, elapsed);

            actEma = wmul(actEma, _powWad(ACT_DECAY, elapsed));
            sizeHat = wmul(sizeHat, _powWad(SIZE_DECAY, elapsed));
            toxEma = wmul(toxEma, _powWad(TOX_DECAY, elapsed));
            sigmaHat = wmul(sigmaHat, _powWad(SIGMA_DECAY, elapsed));
            burstEma = wmul(burstEma, _powWad(BURST_DECAY, elapsed));

            if (stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                lambdaHat = wmul(lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
            }

            stepTradeCount = 0;
        }

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pHat;
        if (pHat == 0) pHat = spot;

        uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
        uint256 pImplied = _calcImplied(spot, feeUsed, trade.isBuy);

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        actEma = wmul(actEma, ACT_BLEND_DECAY) + wmul(tradeRatio, WAD - ACT_BLEND_DECAY);
        sizeHat = wmul(sizeHat, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
        if (sizeHat > WAD) sizeHat = WAD;

        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 pushFast = tradeRatio * DIR_IMPACT_MULT;
            if (pushFast > WAD / 4) pushFast = WAD / 4;

            uint256 pushSlow = wmul(pushFast, DIR_SLOW_PUSH_MULT);
            dirFast = _pushCentered(dirFast, pushFast, trade.isBuy);
            dirSlow = _pushCentered(dirSlow, pushSlow, trade.isBuy);

            burstEma = wmul(burstEma, BURST_BLEND_DECAY) + wmul(tradeRatio, WAD - BURST_BLEND_DECAY);
        } else {
            burstEma = wmul(burstEma, BURST_BLEND_DECAY);
        }

        uint256 ret = pHat > 0 ? wdiv(absDiff(pImplied, pHat), pHat) : 0;
        if (ret > RET_CAP) ret = RET_CAP;

        bool likelyArb = tradeRatio <= ARB_MAX_RATIO;
        uint256 sigmaBlend = likelyArb ? SIGMA_ARB_BLEND : SIGMA_RETAIL_BLEND;
        sigmaHat = wmul(sigmaHat, sigmaBlend) + wmul(ret, WAD - sigmaBlend);

        uint256 alpha = PHAT_ALPHA_BASE + wmul(PHAT_ALPHA_SIZE, tradeRatio) + wmul(PHAT_ALPHA_TOX, toxEma);
        if (alpha > PHAT_ALPHA_MAX) alpha = PHAT_ALPHA_MAX;

        uint256 target = _boundedTarget(pHat, pImplied, PHAT_MOVE_CAP);
        pHat = wmul(pHat, WAD - alpha) + wmul(target, alpha);

        uint256 tox = pHat > 0 ? wdiv(absDiff(spot, pHat), pHat) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;
        toxEma = wmul(toxEma, TOX_BLEND_DECAY) + wmul(tox, WAD - TOX_BLEND_DECAY);

        uint256 flowSize = wmul(lambdaHat, sizeHat);
        uint256 fBase = BASE_FEE + wmul(SIGMA_COEF, sigmaHat) + wmul(LAMBDA_COEF, lambdaHat) + wmul(FLOW_SIZE_COEF, flowSize);

        uint256 toxExcess = toxEma > TOX_QUAD_KNEE ? toxEma - TOX_QUAD_KNEE : 0;
        uint256 lambdaGate = lambdaHat > WAD ? WAD : lambdaHat;
        uint256 actPressure = wmul(actEma, lambdaGate);

        uint256 fMid = fBase
            + wmul(TOX_COEF, toxEma)
            + wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess))
            + wmul(ACT_COEF, actPressure)
            + wmul(BURST_COEF, burstEma);

        uint256 dirBlend = wmul(dirFast, DIR_FAST_WEIGHT) + wmul(dirSlow, WAD - DIR_FAST_WEIGHT);

        uint256 dirDev;
        bool sellPressure;
        if (dirBlend >= WAD) {
            dirDev = dirBlend - WAD;
            sellPressure = true;
        } else {
            dirDev = WAD - dirBlend;
            sellPressure = false;
        }

        uint256 dirLead = dirFast > dirSlow ? dirFast - dirSlow : dirSlow - dirFast;
        uint256 skew = wmul(DIR_COEF, dirDev)
            + wmul(DIR_TOX_COEF, wmul(dirDev, toxEma))
            + wmul(DIR_LEAD_COEF, wmul(dirDev, dirLead));

        uint256 bidFee;
        uint256 askFee;
        if (sellPressure) {
            bidFee = fMid + skew;
            askFee = fMid > skew ? fMid - skew : 0;
        } else {
            askFee = fMid + skew;
            bidFee = fMid > skew ? fMid - skew : 0;
        }

        if (STALE_DIR_COEF > 0) {
            uint256 staleShift = wmul(STALE_DIR_COEF, toxEma);
            if (spot >= pHat) {
                bidFee = bidFee + staleShift;
                askFee = askFee > staleShift ? askFee - staleShift : 0;
            } else {
                askFee = askFee + staleShift;
                bidFee = bidFee > staleShift ? bidFee - staleShift : 0;
            }
        }

        uint256 tailKnee = TAIL_KNEE_BASE + wmul(TAIL_KNEE_TOX_COEF, toxEma) + wmul(TAIL_KNEE_SIGMA_COEF, sigmaHat);
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

        uint256 riskNorm = toxEma + sigmaHat + burstEma;
        if (riskNorm > WAD) riskNorm = WAD;

        bidFee = _applyRateLimit(prevBidFee, bidFee, riskNorm);
        askFee = _applyRateLimit(prevAskFee, askFee, riskNorm);

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        if (bidFee < SIDE_FLOOR) bidFee = SIDE_FLOOR;
        if (askFee < SIDE_FLOOR) askFee = SIDE_FLOOR;

        stepTradeCount = stepTradeCount + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = dirFast;
        slots[4] = dirSlow;
        slots[5] = actEma;
        slots[6] = pHat;
        slots[7] = sigmaHat;
        slots[8] = lambdaHat;
        slots[9] = sizeHat;
        slots[10] = toxEma;
        slots[11] = stepTradeCount;
        slots[12] = burstEma;

        return (bidFee, askFee);
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

    function _pushCentered(uint256 centered, uint256 push, bool positive) internal pure returns (uint256) {
        if (positive) {
            centered = centered + push;
            if (centered > 2 * WAD) centered = 2 * WAD;
            return centered;
        }
        return centered > push ? centered - push : 0;
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
            if (upMove > upCap) return prevFee + upCap;
            return targetFee;
        }

        uint256 downMove = prevFee - targetFee;
        if (downMove > downCap) return prevFee - downCap;
        return targetFee;
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
        return "wildcard_mod_v200";
    }
}
