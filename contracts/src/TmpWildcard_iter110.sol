pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"pivot","hypothesis_id":"H_DUAL_HORIZON_002","confidence":0.74,"ceiling_probability":0.31,"ev_next_5":0.22,"best_delta_seen":0.18,"reason":"Tail-only refinements have lower marginal EV; dual-horizon volatility, continuous anchor updates, and blended signed-flow should unlock larger edge.","next_mechanism":"dual_horizon_anchor_flow"}

    uint256 constant ELAPSED_CAP = 10;
    uint256 constant STEP_COUNT_CAP = 96;
    uint256 constant SIGNAL_THRESHOLD = WAD / 900;
    uint256 constant TRADE_RATIO_CAP = WAD / 5;
    uint256 constant RET_CAP = WAD / 8;
    uint256 constant TOX_CAP = WAD / 4;
    uint256 constant LAMBDA_CAP = 6 * WAD;

    uint256 constant IMB_DECAY = 880000000000000000;
    uint256 constant FLOW_DECAY = 760000000000000000;
    uint256 constant TOX_DECAY = 905000000000000000;
    uint256 constant IMPACT_DECAY = 870000000000000000;
    uint256 constant SHOCK_DECAY = 830000000000000000;
    uint256 constant SIGMA_FAST_DECAY = 760000000000000000;
    uint256 constant SIGMA_SLOW_DECAY = 960000000000000000;
    uint256 constant LAMBDA_DECAY = 994000000000000000;

    uint256 constant SIG_FAST_BLEND_DECAY = 620000000000000000;
    uint256 constant SIG_SLOW_BLEND_DECAY = 930000000000000000;
    uint256 constant FLOW_BLEND_DECAY = 985000000000000000;
    uint256 constant TOX_BLEND_DECAY = 250000000000000000;
    uint256 constant SHOCK_BLEND_DECAY = 700000000000000000;

    uint256 constant REF_ALPHA_BASE = 120000000000000000;
    uint256 constant REF_ALPHA_VOL = 300000000000000000;
    uint256 constant REF_ALPHA_TOX = 220000000000000000;
    uint256 constant REF_ALPHA_CAP = 460000000000000000;
    uint256 constant REF_MOVE_CAP = 250 * BPS;

    uint256 constant FLOW_PUSH_MULT = 1300000000000000000;
    uint256 constant FLOW_PUSH_CAP = WAD / 3;
    uint256 constant IMPACT_TRADE_PUSH = 700000000000000000;
    uint256 constant IMPACT_DISLOC_PUSH = 900000000000000000;
    uint256 constant DISLOC_THRESHOLD = 5 * BPS;

    uint256 constant IMB_SIGNAL_WEIGHT = 700000000000000000;
    uint256 constant IMP_SIGNAL_WEIGHT = 500000000000000000;

    uint256 constant BASE_FEE = 3 * BPS;
    uint256 constant SIG_FAST_COEF = 2600 * BPS;
    uint256 constant SIG_SLOW_COEF = 900 * BPS;
    uint256 constant VOL_SPREAD_COEF = 1800 * BPS;
    uint256 constant LAMBDA_COEF = 14 * BPS;
    uint256 constant FLOW_SIZE_COEF = 5600 * BPS;
    uint256 constant FLOW_ACTIVITY_COEF = 18000 * BPS;
    uint256 constant TOX_COEF = 220 * BPS;
    uint256 constant TOX_QUAD_COEF = 24000 * BPS;
    uint256 constant TOX_QUAD_KNEE = 10 * BPS;
    uint256 constant SHOCK_KNEE = 10 * BPS;
    uint256 constant SHOCK_COEF = 2200 * BPS;
    uint256 constant SKEW_COEF = 110 * BPS;
    uint256 constant SKEW_TOX_COEF = 30 * BPS;
    uint256 constant STALE_COEF = 5000 * BPS;

    uint256 constant TAIL_KNEE_BASE = 650 * BPS;
    uint256 constant KNEE_VOL_COEF = 5000 * BPS;
    uint256 constant KNEE_TOX_COEF = 6000 * BPS;
    uint256 constant TAIL_KNEE_MAX = 1400 * BPS;
    uint256 constant TAIL_SLOPE_NEUTRAL = 900000000000000000;
    uint256 constant TAIL_SLOPE_PROTECT = 830000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 965000000000000000;

    struct State {
        uint256 bidFee;
        uint256 askFee;
        uint256 lastTs;
        uint256 pRef;
        uint256 sigmaFast;
        uint256 sigmaSlow;
        uint256 imbalance;
        uint256 flowEma;
        uint256 toxEma;
        uint256 lambdaHat;
        uint256 stepTradeCount;
        uint256 impactState;
        uint256 shockEma;
    }

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        slots[4] = 1000000000000000;
        slots[5] = 1200000000000000;
        slots[6] = WAD;
        slots[7] = 0;
        slots[8] = 0;
        slots[9] = 600000000000000000;
        slots[10] = 0;
        slots[11] = WAD;
        slots[12] = 0;
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        State memory s = State({
            bidFee: slots[0],
            askFee: slots[1],
            lastTs: slots[2],
            pRef: slots[3],
            sigmaFast: slots[4],
            sigmaSlow: slots[5],
            imbalance: slots[6],
            flowEma: slots[7],
            toxEma: slots[8],
            lambdaHat: slots[9],
            stepTradeCount: slots[10],
            impactState: slots[11],
            shockEma: slots[12]
        });

        if (trade.timestamp > s.lastTs) {
            uint256 elapsedRaw = trade.timestamp - s.lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            s.imbalance = _decayCentered(s.imbalance, IMB_DECAY, elapsed);
            s.impactState = _decayCentered(s.impactState, IMPACT_DECAY, elapsed);
            s.flowEma = wmul(s.flowEma, _powWad(FLOW_DECAY, elapsed));
            s.toxEma = wmul(s.toxEma, _powWad(TOX_DECAY, elapsed));
            s.shockEma = wmul(s.shockEma, _powWad(SHOCK_DECAY, elapsed));
            s.sigmaFast = wmul(s.sigmaFast, _powWad(SIGMA_FAST_DECAY, elapsed));
            s.sigmaSlow = wmul(s.sigmaSlow, _powWad(SIGMA_SLOW_DECAY, elapsed));

            if (s.stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (s.stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                s.lambdaHat = wmul(s.lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
            }

            s.stepTradeCount = 0;
        }

        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : s.pRef;
        if (s.pRef == 0) s.pRef = spot;

        uint256 feeUsed = trade.isBuy ? s.bidFee : s.askFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied = gamma == 0 ? spot : (trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma));

        uint256 ret = s.pRef > 0 ? wdiv(absDiff(pImplied, s.pRef), s.pRef) : 0;
        if (ret > RET_CAP) ret = RET_CAP;

        s.sigmaFast = wmul(s.sigmaFast, SIG_FAST_BLEND_DECAY) + wmul(ret, WAD - SIG_FAST_BLEND_DECAY);
        s.sigmaSlow = wmul(s.sigmaSlow, SIG_SLOW_BLEND_DECAY) + wmul(ret, WAD - SIG_SLOW_BLEND_DECAY);

        uint256 shockExc = ret > SHOCK_KNEE ? ret - SHOCK_KNEE : 0;
        s.shockEma = wmul(s.shockEma, SHOCK_BLEND_DECAY) + wmul(shockExc, WAD - SHOCK_BLEND_DECAY);

        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        s.flowEma = wmul(s.flowEma, FLOW_BLEND_DECAY) + wmul(tradeRatio, WAD - FLOW_BLEND_DECAY);

        if (tradeRatio > SIGNAL_THRESHOLD) {
            uint256 push = wmul(tradeRatio, FLOW_PUSH_MULT);
            if (push > FLOW_PUSH_CAP) push = FLOW_PUSH_CAP;

            s.imbalance = _pushCentered(s.imbalance, push, trade.isBuy);

            uint256 tradePush = wmul(push, IMPACT_TRADE_PUSH);
            s.impactState = _pushCentered(s.impactState, tradePush, trade.isBuy);
        }

        uint256 alpha = REF_ALPHA_BASE + wmul(REF_ALPHA_VOL, s.sigmaSlow) + wmul(REF_ALPHA_TOX, s.toxEma);
        if (alpha > REF_ALPHA_CAP) alpha = REF_ALPHA_CAP;
        uint256 targetRef = _boundedTarget(s.pRef, pImplied, REF_MOVE_CAP);
        s.pRef = wmul(s.pRef, WAD - alpha) + wmul(targetRef, alpha);

        uint256 tox = s.pRef > 0 ? wdiv(absDiff(spot, s.pRef), s.pRef) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;
        s.toxEma = wmul(s.toxEma, TOX_BLEND_DECAY) + wmul(tox, WAD - TOX_BLEND_DECAY);

        if (tox > DISLOC_THRESHOLD) {
            uint256 dislocPush = wmul(tox, IMPACT_DISLOC_PUSH);
            s.impactState = _pushCentered(s.impactState, dislocPush, spot >= s.pRef);
        }

        uint256 flowIntensity = wmul(s.lambdaHat, s.flowEma);
        uint256 volSpread = s.sigmaFast > s.sigmaSlow ? s.sigmaFast - s.sigmaSlow : 0;
        uint256 toxExcess = s.toxEma > TOX_QUAD_KNEE ? s.toxEma - TOX_QUAD_KNEE : 0;

        uint256 mid = BASE_FEE
            + wmul(SIG_FAST_COEF, s.sigmaFast)
            + wmul(SIG_SLOW_COEF, s.sigmaSlow)
            + wmul(VOL_SPREAD_COEF, volSpread)
            + wmul(LAMBDA_COEF, s.lambdaHat)
            + wmul(FLOW_SIZE_COEF, flowIntensity)
            + wmul(FLOW_ACTIVITY_COEF, s.flowEma)
            + wmul(TOX_COEF, s.toxEma)
            + wmul(TOX_QUAD_COEF, wmul(toxExcess, toxExcess))
            + wmul(SHOCK_COEF, s.shockEma);

        (bool signalPositive, uint256 dirDev) = _signalDelta(s.imbalance, s.impactState);
        uint256 skew = wmul(SKEW_COEF, dirDev) + wmul(SKEW_TOX_COEF, wmul(dirDev, s.toxEma));

        uint256 bidFee;
        uint256 askFee;
        if (signalPositive) {
            bidFee = mid + skew;
            askFee = mid > skew ? mid - skew : 0;
        } else {
            askFee = mid + skew;
            bidFee = mid > skew ? mid - skew : 0;
        }

        uint256 staleShift = wmul(STALE_COEF, s.toxEma);
        if (spot >= s.pRef) {
            bidFee = bidFee + staleShift;
            askFee = askFee > staleShift ? askFee - staleShift : 0;
        } else {
            askFee = askFee + staleShift;
            bidFee = bidFee > staleShift ? bidFee - staleShift : 0;
        }

        uint256 knee = TAIL_KNEE_BASE + wmul(KNEE_VOL_COEF, s.sigmaSlow) + wmul(KNEE_TOX_COEF, s.toxEma);
        if (knee > TAIL_KNEE_MAX) knee = TAIL_KNEE_MAX;

        if (bidFee > askFee) {
            bidFee = clampFee(_compressTail(bidFee, knee, TAIL_SLOPE_PROTECT));
            askFee = clampFee(_compressTail(askFee, knee, TAIL_SLOPE_ATTRACT));
        } else if (askFee > bidFee) {
            bidFee = clampFee(_compressTail(bidFee, knee, TAIL_SLOPE_ATTRACT));
            askFee = clampFee(_compressTail(askFee, knee, TAIL_SLOPE_PROTECT));
        } else {
            bidFee = clampFee(_compressTail(bidFee, knee, TAIL_SLOPE_NEUTRAL));
            askFee = clampFee(_compressTail(askFee, knee, TAIL_SLOPE_NEUTRAL));
        }

        s.stepTradeCount = s.stepTradeCount + 1;
        if (s.stepTradeCount > STEP_COUNT_CAP) s.stepTradeCount = STEP_COUNT_CAP;

        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = s.pRef;
        slots[4] = s.sigmaFast;
        slots[5] = s.sigmaSlow;
        slots[6] = s.imbalance;
        slots[7] = s.flowEma;
        slots[8] = s.toxEma;
        slots[9] = s.lambdaHat;
        slots[10] = s.stepTradeCount;
        slots[11] = s.impactState;
        slots[12] = s.shockEma;

        return (bidFee, askFee);
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

    function _signalDelta(uint256 imbalance, uint256 impactState) internal pure returns (bool positive, uint256 dev) {
        uint256 pos;
        uint256 neg;

        if (imbalance >= WAD) {
            pos = pos + wmul(IMB_SIGNAL_WEIGHT, imbalance - WAD);
        } else {
            neg = neg + wmul(IMB_SIGNAL_WEIGHT, WAD - imbalance);
        }

        if (impactState >= WAD) {
            pos = pos + wmul(IMP_SIGNAL_WEIGHT, impactState - WAD);
        } else {
            neg = neg + wmul(IMP_SIGNAL_WEIGHT, WAD - impactState);
        }

        if (pos >= neg) {
            positive = true;
            dev = pos - neg;
        } else {
            positive = false;
            dev = neg - pos;
        }
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
        return "wildcard_mod_v110";
    }
}
