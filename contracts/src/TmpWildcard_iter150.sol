pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"pivot","hypothesis_id":"H_STRUCT_DUAL_ANCHOR_150","confidence":0.74,"ceiling_probability":0.21,"ev_next_5":0.29,"best_delta_seen":0.15,"reason":"Shift from single-anchor asymmetry to dual-anchor adaptive surface for cleaner trend-tox separation and steadier two-sided quoting.","next_mechanism":"dual_anchor_vol_surface"}

    uint256 constant ELAPSED_CAP = 12;
    uint256 constant SIGNAL_THRESHOLD = WAD / 1000;

    uint256 constant DIR_DECAY = 880000000000000000;
    uint256 constant ACT_DECAY = 760000000000000000;
    uint256 constant SIZE_DECAY = 740000000000000000;
    uint256 constant TOX_DECAY = 900000000000000000;
    uint256 constant VOL_FAST_DECAY = 720000000000000000;
    uint256 constant VOL_SLOW_DECAY = 955000000000000000;
    uint256 constant SHOCK_DECAY = 910000000000000000;
    uint256 constant LAMBDA_DECAY = 995500000000000000;

    uint256 constant SIZE_BLEND_DECAY = 820000000000000000;
    uint256 constant ACT_BLEND_DECAY = 993000000000000000;
    uint256 constant TOX_BLEND_DECAY = 250000000000000000;

    uint256 constant PRICE_FAST_ALPHA_BASE = 160000000000000000;
    uint256 constant PRICE_FAST_ALPHA_SHOCK = 500000000000000000;
    uint256 constant PRICE_FAST_ALPHA_MAX = 700000000000000000;
    uint256 constant PRICE_SLOW_ALPHA = 30000000000000000;

    uint256 constant FLOW_IMPACT_MULT = 1;
    uint256 constant TREND_TOX_WEIGHT = 450000000000000000;

    uint256 constant RET_CAP = WAD / 8;
    uint256 constant TOX_CAP = WAD / 4;
    uint256 constant SHOCK_CAP = WAD / 6;
    uint256 constant TRADE_RATIO_CAP = WAD / 4;
    uint256 constant LAMBDA_CAP = 6 * WAD;
    uint256 constant STEP_COUNT_CAP = 96;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant VOL_SLOW_COEF = 260000000000000000;
    uint256 constant VOL_FAST_COEF = 120000000000000000;
    uint256 constant LAMBDA_COEF = 10 * BPS;
    uint256 constant FLOW_SIZE_COEF = 4200 * BPS;
    uint256 constant ACT_COEF = 9000 * BPS;
    uint256 constant TOX_COEF = 260 * BPS;
    uint256 constant TOX_QUAD_COEF = 26000 * BPS;
    uint256 constant TOX_KNEE = 12 * BPS;
    uint256 constant SHOCK_COEF = 100 * BPS;

    uint256 constant DIR_FLOW_COEF = 95 * BPS;
    uint256 constant DIR_TREND_COEF = 70 * BPS;
    uint256 constant DIR_CROSS_COEF = 30 * BPS;
    uint256 constant ALIGN_BOOST_COEF = 45 * BPS;
    uint256 constant MISALIGN_DAMP = 720000000000000000;
    uint256 constant STALE_SHIFT_COEF = 5200 * BPS;
    uint256 constant MAX_SKEW = WAD / 10;

    uint256 constant SPREAD_BASE = 1 * BPS;
    uint256 constant SPREAD_VOL_COEF = 24 * BPS;
    uint256 constant SPREAD_TOX_COEF = 32 * BPS;

    uint256 constant TAIL_KNEE = 650 * BPS;
    uint256 constant TAIL_SLOPE_NEUTRAL = 900000000000000000;
    uint256 constant TAIL_PROTECT_BASE = 780000000000000000;
    uint256 constant TAIL_PROTECT_TOX = 220000000000000000;
    uint256 constant TAIL_ATTRACT_BASE = 930000000000000000;
    uint256 constant TAIL_ATTRACT_VOL = 60000000000000000;
    uint256 constant TAIL_MIN = 650000000000000000;
    uint256 constant TAIL_MAX = 980000000000000000;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;

        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD;
        slots[4] = 0;
        slots[5] = p0;
        slots[6] = p0;
        slots[7] = 1200000000000000;
        slots[8] = 1800000000000000;
        slots[9] = 700000000000000000;
        slots[10] = 1500000000000000;
        slots[11] = 0;
        slots[12] = 0;
        slots[13] = 0;

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        uint256 prevBidFee = slots[0];
        uint256 prevAskFee = slots[1];
        uint256 lastTs = slots[2];
        uint256 dirState = slots[3];
        uint256 actEma = slots[4];
        uint256 pFast = slots[5];
        uint256 pSlow = slots[6];
        uint256 volFast = slots[7];
        uint256 volSlow = slots[8];
        uint256 lambdaHat = slots[9];
        uint256 sizeHat = slots[10];
        uint256 toxEma = slots[11];
        uint256 shockEma = slots[12];
        uint256 stepTradeCount = slots[13];

        bool isNewStep = trade.timestamp > lastTs;
        if (isNewStep) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            dirState = _decayCentered(dirState, DIR_DECAY, elapsed);
            actEma = wmul(actEma, _powWad(ACT_DECAY, elapsed));
            sizeHat = wmul(sizeHat, _powWad(SIZE_DECAY, elapsed));
            toxEma = wmul(toxEma, _powWad(TOX_DECAY, elapsed));
            volFast = wmul(volFast, _powWad(VOL_FAST_DECAY, elapsed));
            volSlow = wmul(volSlow, _powWad(VOL_SLOW_DECAY, elapsed));
            shockEma = wmul(shockEma, _powWad(SHOCK_DECAY, elapsed));

            if (stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                lambdaHat = wmul(lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
            }

            stepTradeCount = 0;
        }

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pSlow;
        if (pFast == 0) pFast = spot;
        if (pSlow == 0) pSlow = spot;

        uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied = gamma == 0 ? spot : (trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma));

        uint256 ret = pSlow > 0 ? wdiv(absDiff(pImplied, pSlow), pSlow) : 0;
        if (ret > RET_CAP) ret = RET_CAP;

        volFast = wmul(volFast, VOL_FAST_DECAY) + wmul(ret, WAD - VOL_FAST_DECAY);
        volSlow = wmul(volSlow, VOL_SLOW_DECAY) + wmul(ret, WAD - VOL_SLOW_DECAY);

        uint256 anchorGap = pFast > 0 ? wdiv(absDiff(spot, pFast), pFast) : 0;
        if (anchorGap > SHOCK_CAP) anchorGap = SHOCK_CAP;
        shockEma = wmul(shockEma, SHOCK_DECAY) + wmul(anchorGap, WAD - SHOCK_DECAY);

        uint256 alphaFast = PRICE_FAST_ALPHA_BASE + wmul(PRICE_FAST_ALPHA_SHOCK, shockEma);
        if (alphaFast > PRICE_FAST_ALPHA_MAX) alphaFast = PRICE_FAST_ALPHA_MAX;

        pFast = _blend(pFast, spot, alphaFast);
        pSlow = _blend(pSlow, spot, PRICE_SLOW_ALPHA);

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = tradeRatio * FLOW_IMPACT_MULT;
            if (push > WAD / 3) push = WAD / 3;

            if (trade.isBuy) {
                dirState = dirState + push;
                if (dirState > 2 * WAD) dirState = 2 * WAD;
            } else {
                dirState = dirState > push ? dirState - push : 0;
            }

            sizeHat = wmul(sizeHat, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
            if (sizeHat > WAD) sizeHat = WAD;

            actEma = wmul(actEma, ACT_BLEND_DECAY) + wmul(tradeRatio, WAD - ACT_BLEND_DECAY);
        }

        uint256 anchorTox = pSlow > 0 ? wdiv(absDiff(spot, pSlow), pSlow) : 0;
        if (anchorTox > TOX_CAP) anchorTox = TOX_CAP;

        uint256 trendDev = pSlow > 0 ? wdiv(absDiff(pFast, pSlow), pSlow) : 0;
        if (trendDev > TOX_CAP) trendDev = TOX_CAP;

        uint256 toxRaw = anchorTox + wmul(TREND_TOX_WEIGHT, trendDev);
        if (toxRaw > TOX_CAP) toxRaw = TOX_CAP;
        toxEma = wmul(toxEma, TOX_BLEND_DECAY) + wmul(toxRaw, WAD - TOX_BLEND_DECAY);

        uint256 flowSize = wmul(lambdaHat, sizeHat);
        uint256 fBase = BASE_FEE
            + wmul(VOL_SLOW_COEF, volSlow)
            + wmul(VOL_FAST_COEF, volFast)
            + wmul(LAMBDA_COEF, lambdaHat)
            + wmul(FLOW_SIZE_COEF, flowSize);

        uint256 toxExcess = toxEma > TOX_KNEE ? toxEma - TOX_KNEE : 0;
        uint256 fMid = fBase
            + wmul(TOX_COEF, toxEma)
            + wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess))
            + wmul(ACT_COEF, actEma)
            + wmul(SHOCK_COEF, shockEma);

        uint256 flowDev;
        bool pressureOnBid;
        if (dirState >= WAD) {
            flowDev = dirState - WAD;
            pressureOnBid = true;
        } else {
            flowDev = WAD - dirState;
            pressureOnBid = false;
        }

        uint256 skew = wmul(DIR_FLOW_COEF, flowDev)
            + wmul(DIR_TREND_COEF, trendDev)
            + wmul(DIR_CROSS_COEF, wmul(flowDev, toxEma));

        bool trendUp = pFast >= pSlow;
        if (pressureOnBid == trendUp) {
            skew = skew + wmul(ALIGN_BOOST_COEF, wmul(flowDev, trendDev));
        } else {
            skew = wmul(skew, MISALIGN_DAMP);
        }
        if (skew > MAX_SKEW) skew = MAX_SKEW;

        uint256 bidFee;
        uint256 askFee;
        if (pressureOnBid) {
            bidFee = fMid + skew;
            askFee = fMid > skew ? fMid - skew : 0;
        } else {
            askFee = fMid + skew;
            bidFee = fMid > skew ? fMid - skew : 0;
        }

        uint256 staleShift = wmul(STALE_SHIFT_COEF, anchorTox);
        if (spot >= pSlow) {
            bidFee = bidFee + staleShift;
            askFee = askFee > staleShift ? askFee - staleShift : 0;
        } else {
            askFee = askFee + staleShift;
            bidFee = bidFee > staleShift ? bidFee - staleShift : 0;
        }

        uint256 spreadFloor = SPREAD_BASE + wmul(SPREAD_VOL_COEF, volSlow) + wmul(SPREAD_TOX_COEF, toxEma);
        (bidFee, askFee) = _enforceMinSpread(bidFee, askFee, spreadFloor);

        uint256 protectSlope = TAIL_PROTECT_BASE;
        uint256 protectAdj = wmul(TAIL_PROTECT_TOX, toxEma);
        if (protectAdj >= protectSlope) {
            protectSlope = TAIL_MIN;
        } else {
            protectSlope = protectSlope - protectAdj;
            if (protectSlope < TAIL_MIN) protectSlope = TAIL_MIN;
        }

        uint256 attractSlope = TAIL_ATTRACT_BASE + wmul(TAIL_ATTRACT_VOL, volSlow);
        if (attractSlope > TAIL_MAX) attractSlope = TAIL_MAX;

        if (bidFee > askFee) {
            bidFee = clampFee(_compressTail(bidFee, protectSlope));
            askFee = clampFee(_compressTail(askFee, attractSlope));
        } else if (askFee > bidFee) {
            bidFee = clampFee(_compressTail(bidFee, attractSlope));
            askFee = clampFee(_compressTail(askFee, protectSlope));
        } else {
            bidFee = clampFee(_compressTail(bidFee, TAIL_SLOPE_NEUTRAL));
            askFee = clampFee(_compressTail(askFee, TAIL_SLOPE_NEUTRAL));
        }

        stepTradeCount = stepTradeCount + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = dirState;
        slots[4] = actEma;
        slots[5] = pFast;
        slots[6] = pSlow;
        slots[7] = volFast;
        slots[8] = volSlow;
        slots[9] = lambdaHat;
        slots[10] = sizeHat;
        slots[11] = toxEma;
        slots[12] = shockEma;
        slots[13] = stepTradeCount;

        return (bidFee, askFee);
    }

    function _enforceMinSpread(uint256 bidFee, uint256 askFee, uint256 minSpread) internal pure returns (uint256, uint256) {
        if (bidFee >= askFee) {
            uint256 diff = bidFee - askFee;
            if (diff < minSpread) {
                uint256 need = minSpread - diff;
                uint256 up = need / 2;
                uint256 down = need - up;
                bidFee = bidFee + up;
                askFee = askFee > down ? askFee - down : 0;
            }
        } else {
            uint256 diff = askFee - bidFee;
            if (diff < minSpread) {
                uint256 need = minSpread - diff;
                uint256 up = need / 2;
                uint256 down = need - up;
                askFee = askFee + up;
                bidFee = bidFee > down ? bidFee - down : 0;
            }
        }
        return (bidFee, askFee);
    }

    function _compressTail(uint256 fee, uint256 slope) internal pure returns (uint256) {
        if (fee <= TAIL_KNEE) return fee;
        return TAIL_KNEE + wmul(fee - TAIL_KNEE, slope);
    }

    function _blend(uint256 prev, uint256 next, uint256 alpha) internal pure returns (uint256) {
        if (alpha >= WAD) return next;
        return wmul(prev, WAD - alpha) + wmul(next, alpha);
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
        return "wildcard_mod_v150";
    }
}
