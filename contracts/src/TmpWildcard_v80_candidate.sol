pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"pivot","hypothesis_id":"H_WILDCARD_080","confidence":0.63,"ceiling_probability":0.27,"ev_next_5":0.19,"best_delta_seen":0.15,"reason":"Move to continuous dual-horizon risk pricing with adaptive fair-value tracking and dynamic tail shaping.","next_mechanism":"dual_horizon_risk_surface"}

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant STEP_COUNT_CAP = 96;
    uint256 constant SIGNAL_THRESHOLD = WAD / 850;
    uint256 constant PUSH_CAP = WAD / 5;
    uint256 constant TRADE_RATIO_CAP = WAD / 4;
    uint256 constant RET_CAP = WAD / 8;
    uint256 constant TOX_CAP = WAD / 4;
    uint256 constant LAMBDA_CAP = 6 * WAD;

    uint256 constant DIR_DECAY = 880000000000000000;
    uint256 constant DRIFT_DECAY = 960000000000000000;
    uint256 constant ACT_DECAY = 760000000000000000;
    uint256 constant SIZE_DECAY = 700000000000000000;
    uint256 constant TOX_DECAY = 900000000000000000;
    uint256 constant VFAST_DECAY = 700000000000000000;
    uint256 constant VSLOW_DECAY = 930000000000000000;
    uint256 constant LAMBDA_DECAY = 990000000000000000;
    uint256 constant JUMP_DECAY = 860000000000000000;

    uint256 constant ACT_BLEND_DECAY = 992000000000000000;
    uint256 constant SIZE_BLEND_DECAY = 850000000000000000;
    uint256 constant VOL_FAST_BLEND_DECAY = 650000000000000000;
    uint256 constant VOL_SLOW_BLEND_DECAY = 930000000000000000;
    uint256 constant TOX_BLEND_DECAY = 250000000000000000;
    uint256 constant JUMP_BLEND_DECAY = 500000000000000000;
    uint256 constant LAMBDA_BLEND_DECAY = 985000000000000000;

    uint256 constant ALPHA_BASE = 80000000000000000;
    uint256 constant ALPHA_SIZE_COEF = 700000000000000000;
    uint256 constant ALPHA_MAX = 320000000000000000;
    uint256 constant ALPHA_DAMP_KNEE = 25000000000000000;
    uint256 constant ALPHA_DAMP_SLOPE = 1200000000000000000;
    uint256 constant ALPHA_DAMP_MAX = 750000000000000000;

    uint256 constant DRIFT_PUSH_MULT = 350000000000000000;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant VFAST_COEF = 120000000000000000;
    uint256 constant VSLOW_COEF = 70000000000000000;
    uint256 constant VGAP_COEF = 180000000000000000;
    uint256 constant TOX_COEF = 240 * BPS;
    uint256 constant JUMP_COEF = 2600 * BPS;
    uint256 constant ACT_COEF = 32000 * BPS;
    uint256 constant SIZE_COEF = 9000 * BPS;
    uint256 constant LAMBDA_COEF = 10 * BPS;
    uint256 constant FLOW_COEF = 4200 * BPS;
    uint256 constant TOX_QUAD_COEF = 20000 * BPS;
    uint256 constant TOX_KNEE = 9 * BPS;
    uint256 constant SHOCK_KNEE = 18 * BPS;

    uint256 constant DIR_FAST_WEIGHT = 650000000000000000;
    uint256 constant DIR_COEF = 110 * BPS;
    uint256 constant DIR_VOL_COEF = 55 * BPS;
    uint256 constant DIR_TOX_COEF = 35 * BPS;
    uint256 constant DIR_JUMP_COEF = 20 * BPS;

    uint256 constant ANCHOR_COEF = 7800 * BPS;
    uint256 constant ANCHOR_JUMP_COEF = 90 * BPS;

    uint256 constant TAIL_KNEE_BASE = 650 * BPS;
    uint256 constant TAIL_KNEE_VOL_COEF = 2200 * BPS;
    uint256 constant TAIL_KNEE_TOX_COEF = 1400 * BPS;
    uint256 constant TAIL_KNEE_MAX = WAD / 8;

    uint256 constant TAIL_SLOPE_PROTECT_BASE = 780000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT_BASE = 940000000000000000;
    uint256 constant TAIL_SLOPE_TOX_ADJ = 220000000000000000;
    uint256 constant TAIL_SLOPE_VOL_ADJ = 100000000000000000;

    uint256 constant SIDE_FLOOR = 1 * BPS;

    struct State {
        uint256 bidFee;
        uint256 askFee;
        uint256 dirState;
        uint256 actEma;
        uint256 pRef;
        uint256 volFast;
        uint256 volSlow;
        uint256 toxEma;
        uint256 sizeEma;
        uint256 lambdaEma;
        uint256 jumpEma;
        uint256 driftState;
        uint256 stepTradeCount;
        uint256 spot;
        uint256 tox;
    }

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD;
        slots[4] = 0;
        slots[5] = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        slots[6] = 900000000000000;
        slots[7] = 700000000000000;
        slots[8] = 0;
        slots[9] = 1500000000000000;
        slots[10] = 900000000000000000;
        slots[11] = 0;
        slots[12] = WAD;
        slots[13] = slots[5];
        slots[14] = 0;
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        State memory s;
        s.bidFee = slots[0];
        s.askFee = slots[1];
        s.dirState = slots[3];
        s.actEma = slots[4];
        s.pRef = slots[5];
        s.volFast = slots[6];
        s.volSlow = slots[7];
        s.toxEma = slots[8];
        s.sizeEma = slots[9];
        s.lambdaEma = slots[10];
        s.jumpEma = slots[11];
        s.driftState = slots[12];
        s.stepTradeCount = slots[14];

        uint256 lastTs = slots[2];
        if (trade.timestamp > lastTs) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;
            _decayState(s, elapsed);
            if (s.stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (s.stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                s.lambdaEma = wmul(s.lambdaEma, LAMBDA_BLEND_DECAY) + wmul(lambdaInst, WAD - LAMBDA_BLEND_DECAY);
            }
            s.stepTradeCount = 0;
        }

        s.spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : s.pRef;
        if (s.pRef == 0) s.pRef = s.spot;
        if (s.spot == 0) s.spot = s.pRef;

        _updateFromTrade(s, trade, trade.isBuy ? s.bidFee : s.askFee);

        uint256 fMid = _calcMidFee(s);
        (uint256 skew, bool upperPressure) = _calcSkew(s);

        if (upperPressure) {
            s.bidFee = fMid + skew;
            s.askFee = fMid > skew ? fMid - skew : 0;
        } else {
            s.askFee = fMid + skew;
            s.bidFee = fMid > skew ? fMid - skew : 0;
        }

        uint256 anchorShift = wmul(ANCHOR_COEF, s.tox) + wmul(ANCHOR_JUMP_COEF, s.jumpEma);
        if (s.spot >= s.pRef) {
            s.bidFee = s.bidFee + anchorShift;
            s.askFee = s.askFee > anchorShift ? s.askFee - anchorShift : 0;
        } else {
            s.askFee = s.askFee + anchorShift;
            s.bidFee = s.bidFee > anchorShift ? s.bidFee - anchorShift : 0;
        }

        if (s.bidFee < SIDE_FLOOR) s.bidFee = SIDE_FLOOR;
        if (s.askFee < SIDE_FLOOR) s.askFee = SIDE_FLOOR;

        (uint256 tailKnee, uint256 protectSlope, uint256 attractSlope) = _tailParams(s.volSlow, s.volFast, s.toxEma);
        if (s.bidFee > s.askFee) {
            s.bidFee = clampFee(_compressTail(s.bidFee, tailKnee, protectSlope));
            s.askFee = clampFee(_compressTail(s.askFee, tailKnee, attractSlope));
        } else if (s.askFee > s.bidFee) {
            s.bidFee = clampFee(_compressTail(s.bidFee, tailKnee, attractSlope));
            s.askFee = clampFee(_compressTail(s.askFee, tailKnee, protectSlope));
        } else {
            uint256 midSlope = (protectSlope + attractSlope) / 2;
            s.bidFee = clampFee(_compressTail(s.bidFee, tailKnee, midSlope));
            s.askFee = clampFee(_compressTail(s.askFee, tailKnee, midSlope));
        }

        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;

        slots[0] = s.bidFee;
        slots[1] = s.askFee;
        slots[2] = trade.timestamp;
        slots[3] = s.dirState;
        slots[4] = s.actEma;
        slots[5] = s.pRef;
        slots[6] = s.volFast;
        slots[7] = s.volSlow;
        slots[8] = s.toxEma;
        slots[9] = s.sizeEma;
        slots[10] = s.lambdaEma;
        slots[11] = s.jumpEma;
        slots[12] = s.driftState;
        slots[13] = s.spot;
        slots[14] = s.stepTradeCount;

        return (s.bidFee, s.askFee);
    }

    function _decayState(State memory s, uint256 elapsed) internal pure {
        s.dirState = _decayCentered(s.dirState, DIR_DECAY, elapsed);
        s.driftState = _decayCentered(s.driftState, DRIFT_DECAY, elapsed);
        s.actEma = wmul(s.actEma, _powWad(ACT_DECAY, elapsed));
        s.sizeEma = wmul(s.sizeEma, _powWad(SIZE_DECAY, elapsed));
        s.toxEma = wmul(s.toxEma, _powWad(TOX_DECAY, elapsed));
        s.volFast = wmul(s.volFast, _powWad(VFAST_DECAY, elapsed));
        s.volSlow = wmul(s.volSlow, _powWad(VSLOW_DECAY, elapsed));
        s.lambdaEma = wmul(s.lambdaEma, _powWad(LAMBDA_DECAY, elapsed));
        s.jumpEma = wmul(s.jumpEma, _powWad(JUMP_DECAY, elapsed));
    }

    function _updateFromTrade(State memory s, TradeInfo calldata trade, uint256 feeUsed) internal pure {
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied = gamma == 0 ? s.spot : (trade.isBuy ? wmul(s.spot, gamma) : wdiv(s.spot, gamma));

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        s.actEma = wmul(s.actEma, ACT_BLEND_DECAY) + wmul(tradeRatio, WAD - ACT_BLEND_DECAY);
        s.sizeEma = wmul(s.sizeEma, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
        if (s.sizeEma > WAD) s.sizeEma = WAD;

        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = tradeRatio > PUSH_CAP ? PUSH_CAP : tradeRatio;
            uint256 driftPush = wmul(push, DRIFT_PUSH_MULT);
            if (trade.isBuy) {
                s.dirState = s.dirState + push;
                if (s.dirState > 2 * WAD) s.dirState = 2 * WAD;
                s.driftState = s.driftState + driftPush;
                if (s.driftState > 2 * WAD) s.driftState = 2 * WAD;
            } else {
                s.dirState = s.dirState > push ? s.dirState - push : 0;
                s.driftState = s.driftState > driftPush ? s.driftState - driftPush : 0;
            }
        }

        uint256 ret = s.pRef > 0 ? wdiv(absDiff(pImplied, s.pRef), s.pRef) : 0;
        if (ret > RET_CAP) ret = RET_CAP;
        s.volFast = wmul(s.volFast, VOL_FAST_BLEND_DECAY) + wmul(ret, WAD - VOL_FAST_BLEND_DECAY);
        s.volSlow = wmul(s.volSlow, VOL_SLOW_BLEND_DECAY) + wmul(ret, WAD - VOL_SLOW_BLEND_DECAY);

        s.tox = s.pRef > 0 ? wdiv(absDiff(s.spot, s.pRef), s.pRef) : 0;
        if (s.tox > TOX_CAP) s.tox = TOX_CAP;
        s.toxEma = wmul(s.toxEma, TOX_BLEND_DECAY) + wmul(s.tox, WAD - TOX_BLEND_DECAY);

        uint256 shockExcess = s.tox > SHOCK_KNEE ? s.tox - SHOCK_KNEE : 0;
        s.jumpEma = wmul(s.jumpEma, JUMP_BLEND_DECAY) + wmul(shockExcess, WAD - JUMP_BLEND_DECAY);

        uint256 alpha = ALPHA_BASE + wmul(ALPHA_SIZE_COEF, tradeRatio);
        if (alpha > ALPHA_MAX) alpha = ALPHA_MAX;
        if (s.tox > ALPHA_DAMP_KNEE) {
            uint256 damp = wmul(ALPHA_DAMP_SLOPE, s.tox - ALPHA_DAMP_KNEE);
            if (damp > ALPHA_DAMP_MAX) damp = ALPHA_DAMP_MAX;
            if (damp >= WAD) alpha = 0;
            else alpha = wmul(alpha, WAD - damp);
        }
        if (alpha > 0) s.pRef = wmul(s.pRef, WAD - alpha) + wmul(pImplied, alpha);
    }

    function _calcMidFee(State memory s) internal pure returns (uint256) {
        uint256 volGap = s.volFast > s.volSlow ? s.volFast - s.volSlow : 0;
        uint256 flowSize = wmul(s.lambdaEma, s.sizeEma);
        if (flowSize > WAD) flowSize = WAD;

        uint256 fBase = BASE_FEE;
        fBase = fBase + wmul(VFAST_COEF, s.volFast);
        fBase = fBase + wmul(VSLOW_COEF, s.volSlow);
        fBase = fBase + wmul(VGAP_COEF, volGap);
        fBase = fBase + wmul(TOX_COEF, s.toxEma);
        fBase = fBase + wmul(JUMP_COEF, s.jumpEma);
        fBase = fBase + wmul(ACT_COEF, s.actEma);
        fBase = fBase + wmul(SIZE_COEF, s.sizeEma);
        fBase = fBase + wmul(LAMBDA_COEF, s.lambdaEma);
        fBase = fBase + wmul(FLOW_COEF, flowSize);

        uint256 toxExcess = s.toxEma > TOX_KNEE ? s.toxEma - TOX_KNEE : 0;
        return fBase + wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess));
    }

    function _calcSkew(State memory s) internal pure returns (uint256, bool) {
        uint256 dirFastDev = s.dirState >= WAD ? s.dirState - WAD : WAD - s.dirState;
        uint256 dirSlowDev = s.driftState >= WAD ? s.driftState - WAD : WAD - s.driftState;
        uint256 dirBlend = wmul(DIR_FAST_WEIGHT, dirFastDev) + wmul(WAD - DIR_FAST_WEIGHT, dirSlowDev);

        uint256 skew = wmul(DIR_COEF, dirBlend)
            + wmul(DIR_VOL_COEF, wmul(dirBlend, s.volFast))
            + wmul(DIR_TOX_COEF, wmul(dirBlend, s.toxEma))
            + wmul(DIR_JUMP_COEF, wmul(dirBlend, s.jumpEma));

        return (skew, s.dirState >= WAD);
    }

    function _tailParams(uint256 volSlow, uint256 volFast, uint256 toxEma)
        internal
        pure
        returns (uint256 tailKnee, uint256 protectSlope, uint256 attractSlope)
    {
        tailKnee = TAIL_KNEE_BASE + wmul(TAIL_KNEE_VOL_COEF, volSlow) + wmul(TAIL_KNEE_TOX_COEF, toxEma);
        if (tailKnee > TAIL_KNEE_MAX) tailKnee = TAIL_KNEE_MAX;

        uint256 slopeCut = wmul(TAIL_SLOPE_TOX_ADJ, toxEma) + wmul(TAIL_SLOPE_VOL_ADJ, volFast);

        protectSlope = TAIL_SLOPE_PROTECT_BASE > slopeCut ? TAIL_SLOPE_PROTECT_BASE - slopeCut : WAD / 2;
        if (protectSlope < WAD / 2) protectSlope = WAD / 2;

        attractSlope = TAIL_SLOPE_ATTRACT_BASE + wmul(TAIL_SLOPE_TOX_ADJ / 2, toxEma);
        if (attractSlope > WAD) attractSlope = WAD;
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
        return "wildcard_mod_v80";
    }
}
