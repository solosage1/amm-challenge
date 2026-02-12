pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_WILDCARD_120B","confidence":0.68,"ceiling_probability":0.30,"ev_next_5":0.16,"best_delta_seen":0.15,"reason":"Replace first-trade arb inference with continuous adaptive recentering and dual-horizon sigma to stabilize stale-risk pricing.","next_mechanism":"continuous_dual_sigma"}

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant SIGNAL_THRESHOLD = WAD / 700;

    uint256 constant DIR_DECAY = 850000000000000000;
    uint256 constant ACT_DECAY = 700000000000000000;
    uint256 constant SIZE_DECAY = 600000000000000000;
    uint256 constant TOX_DECAY = 900000000000000000;
    uint256 constant SIG_FAST_DECAY = 680000000000000000;
    uint256 constant SIG_SLOW_DECAY = 960000000000000000;
    uint256 constant LAMBDA_DECAY = 994000000000000000;

    uint256 constant SIZE_BLEND_DECAY = 800000000000000000;
    uint256 constant TOX_BLEND_DECAY = 100000000000000000;
    uint256 constant ACT_BLEND_DECAY = 993000000000000000;
    uint256 constant SIG_FAST_BLEND_DECAY = 620000000000000000;
    uint256 constant SIG_SLOW_BLEND_DECAY = 950000000000000000;

    uint256 constant PHAT_ALPHA_BASE = 150000000000000000;
    uint256 constant PHAT_ALPHA_SIZE_COEF = 500000000000000000;
    uint256 constant PHAT_ALPHA_MAX = 420000000000000000;
    uint256 constant PHAT_DAMP_KNEE = 4 * BPS;
    uint256 constant PHAT_DAMP_SLOPE = 1400000000000000000;
    uint256 constant PHAT_DAMP_CAP = 800000000000000000;

    uint256 constant DIR_IMPACT_MULT = 1;

    uint256 constant RET_CAP = WAD / 10;
    uint256 constant TOX_CAP = WAD / 5;
    uint256 constant TRADE_RATIO_CAP = WAD / 5;
    uint256 constant LAMBDA_CAP = 5 * WAD;
    uint256 constant STEP_COUNT_CAP = 64;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant SIG_SLOW_COEF = 170000000000000000;
    uint256 constant SIG_GAP_COEF = 320000000000000000;
    uint256 constant LAMBDA_COEF = 11 * BPS;
    uint256 constant FLOW_SIZE_COEF = 7200 * BPS;
    uint256 constant TOX_COEF = 170 * BPS;
    uint256 constant TOX_QUAD_COEF = 18500 * BPS;
    uint256 constant TOX_QUAD_KNEE = 11 * BPS;
    uint256 constant ACT_COEF = 45000 * BPS;
    uint256 constant DIR_COEF = 95 * BPS;
    uint256 constant DIR_TOX_COEF = 28 * BPS;
    uint256 constant DIR_SIG_COEF = 22 * BPS;
    uint256 constant STALE_DIR_COEF = 6100 * BPS;
    uint256 constant STALE_SIG_COEF = 110 * BPS;

    uint256 constant TAIL_KNEE_BASE = 700 * BPS;
    uint256 constant TAIL_KNEE_SIG_COEF = 1900 * BPS;
    uint256 constant TAIL_KNEE_TOX_COEF = 1300 * BPS;
    uint256 constant TAIL_KNEE_MAX = WAD / 8;

    uint256 constant TAIL_SLOPE = 900000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT_BASE = 830000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT_BASE = 960000000000000000;
    uint256 constant TAIL_SLOPE_SIG_ADJ = 130000000000000000;
    uint256 constant TAIL_SLOPE_TOX_ADJ = 180000000000000000;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD;
        slots[4] = 0;
        slots[5] = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        slots[6] = 1200000000000000;
        slots[7] = 950000000000000;
        slots[8] = 800000000000000000;
        slots[9] = 2000000000000000;
        slots[10] = 0;
        slots[11] = 0;
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 prevBidFee = slots[0];
        uint256 prevAskFee = slots[1];
        uint256 lastTs = slots[2];
        uint256 dirState = slots[3];
        uint256 actEma = slots[4];
        uint256 pHat = slots[5];
        uint256 sigmaFast = slots[6];
        uint256 sigmaSlow = slots[7];
        uint256 lambdaHat = slots[8];
        uint256 sizeHat = slots[9];
        uint256 toxEma = slots[10];
        uint256 stepTradeCount = slots[11];

        if (trade.timestamp > lastTs) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            dirState = _decayCentered(dirState, DIR_DECAY, elapsed);
            actEma = wmul(actEma, _powWad(ACT_DECAY, elapsed));
            sizeHat = wmul(sizeHat, _powWad(SIZE_DECAY, elapsed));
            toxEma = wmul(toxEma, _powWad(TOX_DECAY, elapsed));
            sigmaFast = wmul(sigmaFast, _powWad(SIG_FAST_DECAY, elapsed));
            sigmaSlow = wmul(sigmaSlow, _powWad(SIG_SLOW_DECAY, elapsed));

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
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied = gamma == 0 ? spot : (trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma));

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        uint256 alpha = PHAT_ALPHA_BASE + wmul(PHAT_ALPHA_SIZE_COEF, tradeRatio);
        if (alpha > PHAT_ALPHA_MAX) alpha = PHAT_ALPHA_MAX;

        if (toxEma > PHAT_DAMP_KNEE) {
            uint256 damp = wmul(PHAT_DAMP_SLOPE, toxEma - PHAT_DAMP_KNEE);
            if (damp > PHAT_DAMP_CAP) damp = PHAT_DAMP_CAP;
            alpha = wmul(alpha, WAD - damp);
        }

        pHat = wmul(pHat, WAD - alpha) + wmul(pImplied, alpha);

        uint256 ret = pHat > 0 ? wdiv(absDiff(pImplied, pHat), pHat) : 0;
        if (ret > RET_CAP) ret = RET_CAP;
        sigmaFast = wmul(sigmaFast, SIG_FAST_BLEND_DECAY) + wmul(ret, WAD - SIG_FAST_BLEND_DECAY);
        sigmaSlow = wmul(sigmaSlow, SIG_SLOW_BLEND_DECAY) + wmul(ret, WAD - SIG_SLOW_BLEND_DECAY);

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

        uint256 sigmaGap = sigmaFast > sigmaSlow ? sigmaFast - sigmaSlow : 0;
        uint256 flowSize = wmul(lambdaHat, sizeHat);
        uint256 fBase = BASE_FEE
            + wmul(SIG_SLOW_COEF, sigmaSlow)
            + wmul(SIG_GAP_COEF, sigmaGap)
            + wmul(LAMBDA_COEF, lambdaHat)
            + wmul(FLOW_SIZE_COEF, flowSize);

        uint256 toxExcess = toxEma > TOX_QUAD_KNEE ? toxEma - TOX_QUAD_KNEE : 0;
        uint256 fMid = fBase
            + wmul(TOX_COEF, toxEma)
            + wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess))
            + wmul(ACT_COEF, actEma);

        uint256 dirDev;
        bool sellPressure;
        if (dirState >= WAD) {
            dirDev = dirState - WAD;
            sellPressure = true;
        } else {
            dirDev = WAD - dirState;
            sellPressure = false;
        }

        uint256 skew = wmul(DIR_COEF, dirDev)
            + wmul(DIR_TOX_COEF, wmul(dirDev, toxEma))
            + wmul(DIR_SIG_COEF, wmul(dirDev, sigmaGap));

        uint256 bidFee;
        uint256 askFee;
        if (sellPressure) {
            bidFee = fMid + skew;
            askFee = fMid > skew ? fMid - skew : 0;
        } else {
            askFee = fMid + skew;
            bidFee = fMid > skew ? fMid - skew : 0;
        }

        uint256 staleShift = wmul(STALE_DIR_COEF, toxEma) + wmul(STALE_SIG_COEF, sigmaGap);
        if (spot >= pHat) {
            bidFee = bidFee + staleShift;
            askFee = askFee > staleShift ? askFee - staleShift : 0;
        } else {
            askFee = askFee + staleShift;
            bidFee = bidFee > staleShift ? bidFee - staleShift : 0;
        }

        uint256 tailKnee = TAIL_KNEE_BASE + wmul(TAIL_KNEE_SIG_COEF, sigmaSlow) + wmul(TAIL_KNEE_TOX_COEF, toxEma);
        if (tailKnee > TAIL_KNEE_MAX) tailKnee = TAIL_KNEE_MAX;

        uint256 slopeCut = wmul(TAIL_SLOPE_SIG_ADJ, sigmaGap) + wmul(TAIL_SLOPE_TOX_ADJ, toxEma);
        uint256 tailProtect = TAIL_SLOPE_PROTECT_BASE > slopeCut ? TAIL_SLOPE_PROTECT_BASE - slopeCut : WAD / 2;
        if (tailProtect < WAD / 2) tailProtect = WAD / 2;
        uint256 tailAttract = TAIL_SLOPE_ATTRACT_BASE + (slopeCut / 2);
        if (tailAttract > WAD) tailAttract = WAD;

        if (bidFee > askFee) {
            bidFee = clampFee(_compressTail(bidFee, tailKnee, tailProtect));
            askFee = clampFee(_compressTail(askFee, tailKnee, tailAttract));
        } else if (askFee > bidFee) {
            bidFee = clampFee(_compressTail(bidFee, tailKnee, tailAttract));
            askFee = clampFee(_compressTail(askFee, tailKnee, tailProtect));
        } else {
            bidFee = clampFee(_compressTail(bidFee, tailKnee, TAIL_SLOPE));
            askFee = clampFee(_compressTail(askFee, tailKnee, TAIL_SLOPE));
        }

        if (bidFee < BPS) bidFee = BPS;
        if (askFee < BPS) askFee = BPS;

        stepTradeCount = stepTradeCount + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = dirState;
        slots[4] = actEma;
        slots[5] = pHat;
        slots[6] = sigmaFast;
        slots[7] = sigmaSlow;
        slots[8] = lambdaHat;
        slots[9] = sizeHat;
        slots[10] = toxEma;
        slots[11] = stepTradeCount;

        return (bidFee, askFee);
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
        return "TmpWildcard_v160_v8";
    }
}
