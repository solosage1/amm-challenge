pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"continue","hypothesis_id":"H_MICROSTRUCT_234","confidence":0.66,"ceiling_probability":0.34,"ev_next_5":0.14,"best_delta_seen":0.18,"reason":"Replace first-trade anchoring with continuous robust fair-price tracking plus jump and burst-aware fee decomposition.","next_mechanism":"continuous_anchor_jump_burst"}

    uint256 constant ELAPSED_CAP = 12;
    uint256 constant STEP_COUNT_CAP = 96;

    uint256 constant SIGNAL_THRESHOLD = WAD / 1200;
    uint256 constant TRADE_RATIO_CAP = WAD / 4;
    uint256 constant ARB_RATIO_MAX = WAD / 420;
    uint256 constant RET_CAP = WAD / 5;
    uint256 constant TOX_CAP = WAD / 4;
    uint256 constant RATE_CAP = 6 * WAD;
    uint256 constant SIZE_CAP = WAD / 12;
    uint256 constant MISPRICE_CAP = WAD / 8;

    uint256 constant FLOW_DECAY = 890000000000000000;
    uint256 constant VOL_DECAY = 820000000000000000;
    uint256 constant RATE_DECAY = 950000000000000000;
    uint256 constant SIZE_DECAY = 720000000000000000;
    uint256 constant TOX_DECAY = 900000000000000000;
    uint256 constant JUMP_DECAY = 850000000000000000;
    uint256 constant ADV_DECAY = 910000000000000000;
    uint256 constant BURST_DECAY = 700000000000000000;

    uint256 constant RATE_BLEND = 860000000000000000;
    uint256 constant BURST_BLEND = 760000000000000000;
    uint256 constant SIZE_BLEND = 780000000000000000;
    uint256 constant TOX_BLEND = 860000000000000000;
    uint256 constant ADV_BLEND = 900000000000000000;
    uint256 constant JUMP_BLEND = 820000000000000000;
    uint256 constant VOL_BLEND_ARB = 840000000000000000;
    uint256 constant VOL_BLEND_RETAIL = 930000000000000000;

    uint256 constant PREF_BLEND_BASE = 930000000000000000;
    uint256 constant PREF_BLEND_FAST = 760000000000000000;
    uint256 constant PREF_BLEND_SLOW = 978000000000000000;
    uint256 constant RATE_ARB_GATE = 900000000000000000;

    uint256 constant SHOCK_KNEE = 22 * BPS;
    uint256 constant SHOCK_CAP = WAD / 25;
    uint256 constant SHOCK_FREEZE_GATE = 90 * BPS;

    uint256 constant FLOW_PUSH_MULT = 3;
    uint256 constant FLOW_PUSH_CAP = WAD / 3;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant VOL_COEF = 280000000000000000;
    uint256 constant RATE_COEF = 6 * BPS;
    uint256 constant FLOW_SIZE_COEF = 2600 * BPS;
    uint256 constant TOX_COEF = 230 * BPS;
    uint256 constant TOX2_COEF = 24000 * BPS;
    uint256 constant TOX_KNEE = 10 * BPS;
    uint256 constant ADV_COEF = 420 * BPS;
    uint256 constant JUMP_COEF = 210 * BPS;
    uint256 constant BURST_COEF = 80 * BPS;
    uint256 constant FLOW_SKEW_COEF = 110 * BPS;
    uint256 constant FLOW_TOX_SKEW_COEF = 35 * BPS;
    uint256 constant MISPRICE_SKEW_COEF = 5200 * BPS;
    uint256 constant COUNTERFLOW_DISCOUNT = 250000000000000000;

    uint256 constant TAIL_KNEE = 650 * BPS;
    uint256 constant TAIL_SLOPE = 900000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 820000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 955000000000000000;

    struct State {
        uint256 prevBidFee;
        uint256 prevAskFee;
        uint256 lastTs;
        uint256 pRef;
        uint256 volEma;
        uint256 flowState;
        uint256 rateEma;
        uint256 sizeEma;
        uint256 toxEma;
        uint256 jumpEma;
        uint256 advEma;
        uint256 burstEma;
        uint256 stepTradeCount;
        uint256 bidFee;
        uint256 askFee;
    }

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        uint256 p0 = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;

        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = p0;
        slots[4] = 900000000000000;
        slots[5] = WAD;
        slots[6] = 600000000000000000;
        slots[7] = 1500000000000000;
        slots[8] = 0;
        slots[9] = 0;
        slots[10] = 0;
        slots[11] = 0;
        slots[12] = 0;

        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        State memory s;
        s.prevBidFee = slots[0];
        s.prevAskFee = slots[1];
        s.lastTs = slots[2];
        s.pRef = slots[3];
        s.volEma = slots[4];
        s.flowState = slots[5];
        s.rateEma = slots[6];
        s.sizeEma = slots[7];
        s.toxEma = slots[8];
        s.jumpEma = slots[9];
        s.advEma = slots[10];
        s.burstEma = slots[11];
        s.stepTradeCount = slots[12];

        if (trade.timestamp > s.lastTs) {
            uint256 elapsedRaw = trade.timestamp - s.lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            s.flowState = _decayCentered(s.flowState, FLOW_DECAY, elapsed);
            s.volEma = wmul(s.volEma, _powWad(VOL_DECAY, elapsed));
            s.rateEma = wmul(s.rateEma, _powWad(RATE_DECAY, elapsed));
            s.sizeEma = wmul(s.sizeEma, _powWad(SIZE_DECAY, elapsed));
            s.toxEma = wmul(s.toxEma, _powWad(TOX_DECAY, elapsed));
            s.jumpEma = wmul(s.jumpEma, _powWad(JUMP_DECAY, elapsed));
            s.advEma = wmul(s.advEma, _powWad(ADV_DECAY, elapsed));
            s.burstEma = wmul(s.burstEma, _powWad(BURST_DECAY, elapsed));

            if (s.stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 instRate = (s.stepTradeCount * WAD) / elapsedRaw;
                if (instRate > RATE_CAP) instRate = RATE_CAP;
                s.rateEma = wmul(s.rateEma, RATE_BLEND) + wmul(instRate, WAD - RATE_BLEND);

                uint256 burstInst = (s.stepTradeCount * WAD) / (s.stepTradeCount + 4);
                s.burstEma = wmul(s.burstEma, BURST_BLEND) + wmul(burstInst, WAD - BURST_BLEND);
            }

            s.stepTradeCount = 0;
        }

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : s.pRef;
        if (s.pRef == 0) s.pRef = spot;
        uint256 staleShift;
        bool spotAboveRef;
        {
            uint256 pTrade;
            {
                uint256 feeUsed = trade.isBuy ? s.prevBidFee : s.prevAskFee;
                uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
                pTrade = gamma == 0 ? spot : (trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma));
            }

            uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
            if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

            uint256 ret = s.pRef > 0 ? wdiv(absDiff(pTrade, s.pRef), s.pRef) : 0;
            if (ret > RET_CAP) ret = RET_CAP;

            uint256 jumpInst = ret > SHOCK_KNEE ? ret - SHOCK_KNEE : 0;
            if (jumpInst > SHOCK_CAP) jumpInst = SHOCK_CAP;
            s.jumpEma = wmul(s.jumpEma, JUMP_BLEND) + wmul(jumpInst, WAD - JUMP_BLEND);

            bool likelyArb = tradeRatio <= ARB_RATIO_MAX && s.rateEma >= RATE_ARB_GATE;
            {
                uint256 pBlend = PREF_BLEND_BASE;
                if (likelyArb) pBlend = PREF_BLEND_FAST;
                if (jumpInst > SHOCK_FREEZE_GATE) pBlend = PREF_BLEND_SLOW;
                s.pRef = wmul(s.pRef, pBlend) + wmul(pTrade, WAD - pBlend);
            }
            {
                uint256 volBlend = likelyArb ? VOL_BLEND_ARB : VOL_BLEND_RETAIL;
                s.volEma = wmul(s.volEma, volBlend) + wmul(ret, WAD - volBlend);
            }

            if (tradeRatio > SIGNAL_THRESHOLD) {
                uint256 push = tradeRatio * FLOW_PUSH_MULT;
                if (push > FLOW_PUSH_CAP) push = FLOW_PUSH_CAP;

                if (trade.isBuy) {
                    s.flowState = s.flowState + push;
                    if (s.flowState > 2 * WAD) s.flowState = 2 * WAD;
                } else {
                    s.flowState = s.flowState > push ? s.flowState - push : 0;
                }

                s.sizeEma = wmul(s.sizeEma, SIZE_BLEND) + wmul(tradeRatio, WAD - SIZE_BLEND);
                if (s.sizeEma > SIZE_CAP) s.sizeEma = SIZE_CAP;
            }

            uint256 tox = s.pRef > 0 ? wdiv(absDiff(spot, s.pRef), s.pRef) : 0;
            if (tox > TOX_CAP) tox = TOX_CAP;
            s.toxEma = wmul(s.toxEma, TOX_BLEND) + wmul(tox, WAD - TOX_BLEND);

            {
                bool adverseSide = (spot >= s.pRef && trade.isBuy) || (spot <= s.pRef && !trade.isBuy);
                uint256 advInst = adverseSide ? ret : wmul(ret, COUNTERFLOW_DISCOUNT);
                if (advInst > TOX_CAP) advInst = TOX_CAP;
                s.advEma = wmul(s.advEma, ADV_BLEND) + wmul(advInst, WAD - ADV_BLEND);
            }

            uint256 mispricing = s.pRef > 0 ? wdiv(absDiff(spot, s.pRef), s.pRef) : 0;
            if (mispricing > MISPRICE_CAP) mispricing = MISPRICE_CAP;
            staleShift = wmul(MISPRICE_SKEW_COEF, mispricing);
            spotAboveRef = spot >= s.pRef;
        }

        uint256 flowSize = wmul(s.rateEma, s.sizeEma);
        uint256 toxExcess = s.toxEma > TOX_KNEE ? s.toxEma - TOX_KNEE : 0;

        uint256 fMid = BASE_FEE + wmul(VOL_COEF, s.volEma) + wmul(RATE_COEF, s.rateEma) + wmul(FLOW_SIZE_COEF, flowSize);
        fMid = fMid + wmul(TOX_COEF, s.toxEma) + wmul(TOX2_COEF, wmul(toxExcess, toxExcess));
        fMid = fMid + wmul(ADV_COEF, s.advEma) + wmul(JUMP_COEF, s.jumpEma) + wmul(BURST_COEF, s.burstEma);

        uint256 dirDev;
        bool sellPressure;
        if (s.flowState >= WAD) {
            dirDev = s.flowState - WAD;
            sellPressure = true;
        } else {
            dirDev = WAD - s.flowState;
            sellPressure = false;
        }

        uint256 skew = wmul(FLOW_SKEW_COEF, dirDev) + wmul(FLOW_TOX_SKEW_COEF, wmul(dirDev, s.toxEma));
        if (sellPressure) {
            s.bidFee = fMid + skew;
            s.askFee = fMid > skew ? fMid - skew : 0;
        } else {
            s.askFee = fMid + skew;
            s.bidFee = fMid > skew ? fMid - skew : 0;
        }

        if (spotAboveRef) {
            s.bidFee = s.bidFee + staleShift;
            s.askFee = s.askFee > staleShift ? s.askFee - staleShift : 0;
        } else {
            s.askFee = s.askFee + staleShift;
            s.bidFee = s.bidFee > staleShift ? s.bidFee - staleShift : 0;
        }

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

        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;

        slots[0] = s.bidFee;
        slots[1] = s.askFee;
        slots[2] = trade.timestamp;
        slots[3] = s.pRef;
        slots[4] = s.volEma;
        slots[5] = s.flowState;
        slots[6] = s.rateEma;
        slots[7] = s.sizeEma;
        slots[8] = s.toxEma;
        slots[9] = s.jumpEma;
        slots[10] = s.advEma;
        slots[11] = s.burstEma;
        slots[12] = s.stepTradeCount;

        return (s.bidFee, s.askFee);
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
        return "wildcard_mod_v234";
    }
}
