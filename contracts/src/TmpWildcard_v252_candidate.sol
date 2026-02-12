pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_WILDCARD_STRUCT_252","confidence":0.42,"ceiling_probability":0.61,"ev_next_5":0.12,"best_delta_seen":0.0,"reason":"promotion_edge 519.26 baseline; T1/T2 wildcard with bounded fees, coherent spread behavior, no pathological liquidity collapse","next_mechanism":"wildcard"}

    struct State {
        uint256 bidFee;
        uint256 askFee;
        uint256 lastTs;
        uint256 pFast;
        uint256 pSlow;
        uint256 sigmaFast;
        uint256 sigmaSlow;
        uint256 flowState;
        uint256 intensityEma;
        uint256 shockEma;
        uint256 stepTradeCount;
    }

    uint256 constant ELAPSED_CAP = 8;
    uint256 constant STEP_COUNT_CAP = 64;

    uint256 constant SIGNAL_THRESHOLD = WAD / 900;
    uint256 constant TRADE_RATIO_CAP = WAD / 4;
    uint256 constant RET_CAP = WAD / 6;
    uint256 constant SHOCK_GATE = 180 * BPS;
    uint256 constant SHOCK_CAP = WAD / 5;
    uint256 constant DISLOCATION_CAP = WAD / 4;
    uint256 constant JUMP_CAP = WAD / 5;

    uint256 constant FLOW_DECAY = 880000000000000000;
    uint256 constant INTENSITY_DECAY = 760000000000000000;
    uint256 constant SHOCK_DECAY = 820000000000000000;
    uint256 constant SIGMA_FAST_DECAY = 900000000000000000;
    uint256 constant SIGMA_SLOW_DECAY = 980000000000000000;

    uint256 constant SIGMA_FAST_BLEND = 550000000000000000;
    uint256 constant SIGMA_SLOW_BLEND = 930000000000000000;
    uint256 constant INTENSITY_BLEND = 860000000000000000;
    uint256 constant SHOCK_BLEND = 700000000000000000;

    uint256 constant ALPHA_FAST_CALM = 260000000000000000;
    uint256 constant ALPHA_FAST_SHOCK = 420000000000000000;
    uint256 constant ALPHA_SLOW_CALM = 60000000000000000;
    uint256 constant ALPHA_SLOW_SHOCK = 20000000000000000;
    uint256 constant FLOW_SHOCK_PUSH_COEF = 500000000000000000;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant SIGMA_SLOW_COEF = 1900 * BPS;
    uint256 constant INTENSITY_COEF = 14000 * BPS;
    uint256 constant SHOCK_COEF = 2600 * BPS;
    uint256 constant JUMP_COEF = 1800 * BPS;
    uint256 constant JUMP_QUAD_COEF = 26000 * BPS;
    uint256 constant JUMP_QUAD_CAP = 420 * BPS;
    uint256 constant FLOW_SKEW_COEF = 340 * BPS;
    uint256 constant DISLOC_SKEW_COEF = 4200 * BPS;
    uint256 constant STALE_SKEW_COEF = 2800 * BPS;

    uint256 constant SHOCK_MODE_GATE = 45 * BPS;
    uint256 constant JUMP_MODE_GATE = 20 * BPS;
    uint256 constant DISLOC_MODE_GATE = 90 * BPS;
    uint256 constant STEP_UP_CAP_CALM = 80 * BPS;
    uint256 constant STEP_DOWN_CAP_CALM = 110 * BPS;
    uint256 constant STEP_UP_CAP_SHOCK = 280 * BPS;
    uint256 constant STEP_DOWN_CAP_SHOCK = 360 * BPS;

    uint256 constant LOCAL_MIN_FEE = BPS / 2;
    uint256 constant TAIL_KNEE = 760 * BPS;
    uint256 constant TAIL_SLOPE = 900000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 840000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 960000000000000000;

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 px = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = px;
        slots[4] = px;
        slots[5] = 1000000000000000;
        slots[6] = 1200000000000000;
        slots[7] = WAD;
        slots[8] = 1500000000000000;
        slots[9] = 0;
        slots[10] = 0;
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        State memory s = _loadState();
        _decayState(s, trade.timestamp);

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : (s.pFast > 0 ? s.pFast : WAD);
        if (s.pFast == 0) s.pFast = spot;
        if (s.pSlow == 0) s.pSlow = spot;

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        _updateSignals(s, trade, spot, tradeRatio);

        (uint256 bidTarget, uint256 askTarget, uint256 jump, uint256 dislocation) = _computeTargets(s, spot);

        bool shockMode = s.shockEma > SHOCK_MODE_GATE || jump > JUMP_MODE_GATE || dislocation > DISLOC_MODE_GATE;
        uint256 upCap = shockMode ? STEP_UP_CAP_SHOCK : STEP_UP_CAP_CALM;
        uint256 downCap = shockMode ? STEP_DOWN_CAP_SHOCK : STEP_DOWN_CAP_CALM;

        s.bidFee = _limitChange(s.bidFee, bidTarget, upCap, downCap);
        s.askFee = _limitChange(s.askFee, askTarget, upCap, downCap);

        if (s.bidFee < LOCAL_MIN_FEE) s.bidFee = LOCAL_MIN_FEE;
        if (s.askFee < LOCAL_MIN_FEE) s.askFee = LOCAL_MIN_FEE;

        if (s.bidFee > s.askFee) {
            s.bidFee = clampFee(_compressTail(s.bidFee, TAIL_SLOPE_PROTECT));
            s.askFee = clampFee(_compressTail(s.askFee, TAIL_SLOPE_ATTRACT));
        } else if (s.askFee > s.bidFee) {
            s.bidFee = clampFee(_compressTail(s.bidFee, TAIL_SLOPE_ATTRACT));
            s.askFee = clampFee(_compressTail(s.askFee, TAIL_SLOPE_PROTECT));
        } else {
            s.bidFee = clampFee(_compressTail(s.bidFee, TAIL_SLOPE));
            s.askFee = clampFee(_compressTail(s.askFee, TAIL_SLOPE));
        }

        if (s.bidFee < LOCAL_MIN_FEE) s.bidFee = LOCAL_MIN_FEE;
        if (s.askFee < LOCAL_MIN_FEE) s.askFee = LOCAL_MIN_FEE;

        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;
        s.lastTs = trade.timestamp;

        _storeState(s);
        return (s.bidFee, s.askFee);
    }

    function _loadState() internal view returns (State memory s) {
        s.bidFee = slots[0];
        s.askFee = slots[1];
        s.lastTs = slots[2];
        s.pFast = slots[3];
        s.pSlow = slots[4];
        s.sigmaFast = slots[5];
        s.sigmaSlow = slots[6];
        s.flowState = slots[7];
        s.intensityEma = slots[8];
        s.shockEma = slots[9];
        s.stepTradeCount = slots[10];
    }

    function _storeState(State memory s) internal {
        slots[0] = s.bidFee;
        slots[1] = s.askFee;
        slots[2] = s.lastTs;
        slots[3] = s.pFast;
        slots[4] = s.pSlow;
        slots[5] = s.sigmaFast;
        slots[6] = s.sigmaSlow;
        slots[7] = s.flowState;
        slots[8] = s.intensityEma;
        slots[9] = s.shockEma;
        slots[10] = s.stepTradeCount;
    }

    function _decayState(State memory s, uint256 timestamp) internal pure {
        if (timestamp <= s.lastTs) return;

        uint256 elapsedRaw = timestamp - s.lastTs;
        uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

        s.flowState = _decayCentered(s.flowState, FLOW_DECAY, elapsed);
        s.intensityEma = wmul(s.intensityEma, _powWad(INTENSITY_DECAY, elapsed));
        s.shockEma = wmul(s.shockEma, _powWad(SHOCK_DECAY, elapsed));
        s.sigmaFast = wmul(s.sigmaFast, _powWad(SIGMA_FAST_DECAY, elapsed));
        s.sigmaSlow = wmul(s.sigmaSlow, _powWad(SIGMA_SLOW_DECAY, elapsed));
        s.stepTradeCount = 0;
    }

    function _updateSignals(State memory s, TradeInfo calldata trade, uint256 spot, uint256 tradeRatio) internal pure {
        uint256 feeUsed = trade.isBuy ? s.bidFee : s.askFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied = gamma == 0 ? spot : (trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma));

        uint256 retFast = s.pFast > 0 ? wdiv(absDiff(pImplied, s.pFast), s.pFast) : 0;
        if (retFast > RET_CAP) retFast = RET_CAP;

        uint256 retSlow = s.pSlow > 0 ? wdiv(absDiff(pImplied, s.pSlow), s.pSlow) : 0;
        if (retSlow > RET_CAP) retSlow = RET_CAP;

        uint256 shockNow = retSlow > SHOCK_GATE ? retSlow - SHOCK_GATE : 0;
        if (shockNow > SHOCK_CAP) shockNow = SHOCK_CAP;

        uint256 alphaFast = shockNow > 0 ? ALPHA_FAST_SHOCK : ALPHA_FAST_CALM;
        uint256 alphaSlow = shockNow > 0 ? ALPHA_SLOW_SHOCK : ALPHA_SLOW_CALM;

        s.pFast = wmul(s.pFast, WAD - alphaFast) + wmul(pImplied, alphaFast);
        s.pSlow = wmul(s.pSlow, WAD - alphaSlow) + wmul(pImplied, alphaSlow);

        s.sigmaFast = wmul(s.sigmaFast, SIGMA_FAST_BLEND) + wmul(retFast, WAD - SIGMA_FAST_BLEND);
        s.sigmaSlow = wmul(s.sigmaSlow, SIGMA_SLOW_BLEND) + wmul(retSlow, WAD - SIGMA_SLOW_BLEND);
        s.shockEma = wmul(s.shockEma, SHOCK_BLEND) + wmul(shockNow, WAD - SHOCK_BLEND);

        if (tradeRatio <= SIGNAL_THRESHOLD) return;

        uint256 push = tradeRatio + wmul(s.shockEma, FLOW_SHOCK_PUSH_COEF);
        if (push > WAD / 3) push = WAD / 3;

        if (trade.isBuy) {
            s.flowState = s.flowState + push;
            if (s.flowState > 2 * WAD) s.flowState = 2 * WAD;
        } else {
            s.flowState = s.flowState > push ? s.flowState - push : 0;
        }

        s.intensityEma = wmul(s.intensityEma, INTENSITY_BLEND) + wmul(tradeRatio, WAD - INTENSITY_BLEND);
    }

    function _computeTargets(State memory s, uint256 spot)
        internal
        pure
        returns (uint256 bidTarget, uint256 askTarget, uint256 jump, uint256 dislocation)
    {
        dislocation = s.pSlow > 0 ? wdiv(absDiff(spot, s.pSlow), s.pSlow) : 0;
        if (dislocation > DISLOCATION_CAP) dislocation = DISLOCATION_CAP;

        jump = s.sigmaFast > s.sigmaSlow ? s.sigmaFast - s.sigmaSlow : 0;
        if (jump > JUMP_CAP) jump = JUMP_CAP;

        uint256 base = BASE_FEE + wmul(SIGMA_SLOW_COEF, s.sigmaSlow) + wmul(INTENSITY_COEF, s.intensityEma);
        uint256 jumpQuad = wmul(JUMP_QUAD_COEF, wmul(jump, jump));
        if (jumpQuad > JUMP_QUAD_CAP) jumpQuad = JUMP_QUAD_CAP;

        uint256 mid = base + wmul(SHOCK_COEF, s.shockEma) + wmul(JUMP_COEF, jump) + jumpQuad;

        uint256 dirDev;
        bool sellPressure;
        if (s.flowState >= WAD) {
            dirDev = s.flowState - WAD;
            sellPressure = true;
        } else {
            dirDev = WAD - s.flowState;
            sellPressure = false;
        }

        uint256 skew = wmul(FLOW_SKEW_COEF, dirDev) + wmul(DISLOC_SKEW_COEF, wmul(dirDev, dislocation));

        if (sellPressure) {
            bidTarget = mid + skew;
            askTarget = mid > skew ? mid - skew : 0;
        } else {
            askTarget = mid + skew;
            bidTarget = mid > skew ? mid - skew : 0;
        }

        uint256 staleShift = wmul(STALE_SKEW_COEF, dislocation);
        if (spot >= s.pSlow) {
            askTarget = askTarget + staleShift;
            bidTarget = bidTarget > staleShift ? bidTarget - staleShift : 0;
        } else {
            bidTarget = bidTarget + staleShift;
            askTarget = askTarget > staleShift ? askTarget - staleShift : 0;
        }
    }

    function _limitChange(uint256 prevFee, uint256 targetFee, uint256 upCap, uint256 downCap) internal pure returns (uint256) {
        if (targetFee > prevFee) {
            uint256 rise = targetFee - prevFee;
            return rise > upCap ? prevFee + upCap : targetFee;
        }
        uint256 drop = prevFee - targetFee;
        return drop > downCap ? prevFee - downCap : targetFee;
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
        return "wildcard_mod_v252";
    }
}
