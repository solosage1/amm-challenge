// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // slots:
    // 0 lastTimestamp
    // 1 currentBidFee
    // 2 currentAskFee
    // 3 fairPrice (WAD, Y per X)
    // 4 flowScore (WAD-centered, >WAD means net X-inflow pressure)
    // 5 lastArbTagTimestamp
    // 6 microScore (WAD-centered, signed short-horizon impact)
    // 7 queueScore (WAD-centered, signed flow-cluster hysteresis)
    // 8 lastStepSpot
    // 9 lastTradeSide (0 none, 1 isBuy, 2 isSell)
    // 10 sideStreakLen
    // 11 arbConfidenceBps (0..10000)

    // Frozen outer-regime core from ubj7_v6.
    uint256 private constant TIGHT_BAND_BPS = 25;
    uint256 private constant INIT_FEE_CENTI_BPS = 2500;
    uint256 private constant TIGHT_FEE_CENTI_BPS = 2788;
    uint256 private constant UNDERCUT_CENTI_BPS = 1100;
    uint256 private constant BUFFER_CENTI_BPS = 200;

    // Keep proven quiet guardrail and arb tagging.
    uint256 private constant QUIET_MIS_BPS = 15;
    uint256 private constant ARB_TAG_MIS_BPS = 36;
    uint256 private constant POST_ARB_CUT_BPS = 4;

    // Frozen flow-memory knobs from champion family.
    uint256 private constant FLOW_ALPHA_PCT = 20;
    uint256 private constant FLOW_DECAY_PCT = 95;
    uint256 private constant FLOW_DEADBAND_BPS = 6;
    uint256 private constant FLOW_TILT_DIV = 9;
    uint256 private constant FLOW_MAX_TILT_BPS = 2;
    uint256 private constant FLOW_IMPULSE_CAP_BPS = 100;
    uint256 private constant FLOW_CLAMP_BPS = 500;

    // Frozen micro/queue dimensions from champion family.
    uint256 private constant MICRO_ALPHA_PCT = 18;
    uint256 private constant MICRO_DECAY_PCT = 95;
    uint256 private constant MICRO_MOVE_CAP_BPS = 35;
    uint256 private constant MICRO_DEADBAND_BPS = 6;
    uint256 private constant MICRO_TILT_DIV = 7;
    uint256 private constant MICRO_MAX_TILT_BPS = 1;

    uint256 private constant QUEUE_ALPHA_PCT = 0;
    uint256 private constant QUEUE_DECAY_PCT = 95;
    uint256 private constant QUEUE_TRIGGER = 3;
    uint256 private constant QUEUE_STEP_BPS = 0;
    uint256 private constant QUEUE_MAX_BPS = 0;
    uint256 private constant QUEUE_DEADBAND_BPS = 999;
    uint256 private constant QUEUE_TILT_DIV = 1;
    uint256 private constant QUEUE_MAX_TILT_BPS = 0;
    uint256 private constant QUEUE_GAP_RESET = 1;

    uint256 private constant SIGNAL_FLOW_W_PCT = 75;
    uint256 private constant SIGNAL_MICRO_W_PCT = 25;
    uint256 private constant SIGNAL_QUEUE_W_PCT = 0;
    uint256 private constant EXTRA_TILT_MAX_BPS = 1;

    uint256 private constant WIDE_SIGNAL_DIV = 12;
    uint256 private constant WIDE_SIGNAL_MAX_BPS = 4;
    uint256 private constant WIDE_COMP_BONUS_PCT = 60;
    uint256 private constant WIDE_PROTECT_BONUS_PCT = 60;

    // Arb-implied classifier + confidence-aware fair updates.
    uint256 private constant ARB_CLASS_MIS_BPS = 20;
    uint256 private constant ARB_CLASS_SIZE_BPS = 8;
    uint256 private constant ARB_CLASS_RATIO_TOL_BPS = 4500;

    uint256 private constant ARB_CONF_DECAY_PCT = 89;
    uint256 private constant ARB_CONF_HIT_BPS = 3200;
    uint256 private constant ARB_CONF_MISS_BPS = 600;

    uint256 private constant ARB_ALPHA_PCT = 29;
    uint256 private constant RETAIL_ALPHA_PCT = 9;
    uint256 private constant RETAIL_INV_W_PCT = 40;

    uint256 private constant ARB_JUMP_BPS = 650;
    uint256 private constant RETAIL_JUMP_BPS = 200;

    uint256 private constant CONF_GATE_BPS = 4300;
    uint256 private constant CONF_TIGHT_BAND_CUT_BPS = 1;
    uint256 private constant CONF_UNDERCUT_ADD_CENTI_BPS = 160;
    uint256 private constant CONF_BUFFER_CUT_CENTI_BPS = 110;
    uint256 private constant CONF_POST_ARB_ADD_BPS = 1;

    function centiBpsToWad(uint256 centiBps) internal pure returns (uint256) {
        return (centiBps * BPS) / 100;
    }

    function sqrtWad(uint256 x) internal pure returns (uint256) {
        return sqrt(x * WAD);
    }

    function clampCentered(uint256 value, uint256 clampBps) internal pure returns (uint256) {
        uint256 clamp = bpsToWad(clampBps);
        uint256 lo = WAD > clamp ? (WAD - clamp) : 0;
        uint256 hi = WAD + clamp;
        if (value < lo) return lo;
        if (value > hi) return hi;
        return value;
    }

    function centeredTiltBps(uint256 value, uint256 deadbandBps, uint256 div, uint256 maxBps)
        internal
        pure
        returns (uint256)
    {
        if (maxBps == 0) return 0;

        uint256 dev = absDiff(value, WAD);
        uint256 deadband = bpsToWad(deadbandBps);
        if (dev <= deadband) return 0;

        uint256 eff = dev - deadband;
        uint256 bps = eff / BPS;
        if (div > 0) bps /= div;
        if (bps > maxBps) bps = maxBps;
        return bps;
    }

    function signalIsBuyPressure(uint256 flow, uint256 micro, uint256 queue)
        internal
        pure
        returns (bool isBuyPressure, uint256 weightedDev)
    {
        uint256 up = 0;
        uint256 dn = 0;

        uint256 fdev = absDiff(flow, WAD);
        uint256 mdev = absDiff(micro, WAD);
        uint256 qdev = absDiff(queue, WAD);

        if (flow >= WAD) up += fdev * SIGNAL_FLOW_W_PCT;
        else dn += fdev * SIGNAL_FLOW_W_PCT;

        if (micro >= WAD) up += mdev * SIGNAL_MICRO_W_PCT;
        else dn += mdev * SIGNAL_MICRO_W_PCT;

        if (queue >= WAD) up += qdev * SIGNAL_QUEUE_W_PCT;
        else dn += qdev * SIGNAL_QUEUE_W_PCT;

        isBuyPressure = up >= dn;
        weightedDev = up >= dn ? (up - dn) : (dn - up);
    }

    function computeArbOptimalAmountX(
        bool isBuy,
        uint256 preX,
        uint256 preY,
        uint256 gamma,
        uint256 fair
    ) internal pure returns (uint256) {
        if (preX == 0 || preY == 0 || gamma == 0 || fair == 0) return 0;

        uint256 k = wmul(preX, preY);
        if (k == 0) return 0;

        if (isBuy) {
            // AMM buys X; arb sells X if spot > fair.
            uint256 xVirtualSq = wdiv(wmul(k, gamma), fair);
            uint256 xVirtual = sqrtWad(xVirtualSq);
            if (xVirtual <= preX) return 0;
            uint256 netX = xVirtual - preX;
            return wdiv(netX, gamma);
        } else {
            // AMM sells X; arb buys X if spot < fair.
            uint256 denom = wmul(gamma, fair);
            if (denom == 0) return 0;
            uint256 xNewSq = wdiv(k, denom);
            uint256 xNew = sqrtWad(xNewSq);
            if (preX <= xNew) return 0;
            return preX - xNew;
        }
    }

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);
        slots[0] = type(uint256).max;
        slots[3] = p0;
        slots[4] = WAD;
        slots[5] = type(uint256).max;
        slots[6] = WAD;
        slots[7] = WAD;
        slots[8] = p0;
        slots[9] = 0;
        slots[10] = 0;
        slots[11] = 0;

        uint256 initFee = centiBpsToWad(INIT_FEE_CENTI_BPS);
        bidFee = initFee;
        askFee = initFee;
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function afterSwap(TradeInfo calldata trade)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 lastTs = slots[0];
        uint256 prevBid = slots[1];
        uint256 prevAsk = slots[2];
        uint256 fair = slots[3];
        uint256 flow = slots[4];
        uint256 micro = slots[6];
        uint256 queue = slots[7];
        uint256 lastSpot = slots[8];
        uint256 lastSide = slots[9];
        uint256 streak = slots[10];
        uint256 arbConf = slots[11];

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        bool isNewStep = trade.timestamp != lastTs;
        bool arbLikeStep = false;

        if (isNewStep) {
            if (FLOW_DECAY_PCT < 100) {
                flow = (flow * FLOW_DECAY_PCT + WAD * (100 - FLOW_DECAY_PCT)) / 100;
            }
            if (MICRO_DECAY_PCT < 100) {
                micro = (micro * MICRO_DECAY_PCT + WAD * (100 - MICRO_DECAY_PCT)) / 100;
            }
            if (QUEUE_DECAY_PCT < 100) {
                queue = (queue * QUEUE_DECAY_PCT + WAD * (100 - QUEUE_DECAY_PCT)) / 100;
            }

            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairInv = fair;
            if (gamma != 0 && spot != 0) {
                fairInv = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            uint256 preX;
            uint256 preY;
            if (trade.isBuy) {
                uint256 netX = wmul(trade.amountX, gamma);
                preX = rx > netX ? (rx - netX) : 0;
                preY = ry + trade.amountY;
            } else {
                preX = rx + trade.amountX;
                uint256 netY = wmul(trade.amountY, gamma);
                preY = ry > netY ? (ry - netY) : 0;
            }

            uint256 preSpot = preX == 0 ? 0 : wdiv(preY, preX);

            bool toward = false;
            uint256 misPreBps = 0;
            if (fair != 0 && preSpot != 0) {
                toward = (preSpot >= fair && trade.isBuy) || (preSpot <= fair && !trade.isBuy);
                misPreBps = wdiv(absDiff(preSpot, fair), fair) / BPS;
            }

            uint256 sizeBps = preX == 0 ? 0 : (wdiv(trade.amountX, preX) / BPS);

            uint256 optAmountX = computeArbOptimalAmountX(trade.isBuy, preX, preY, gamma, fair);
            uint256 ratioBps = 0;
            if (trade.amountX != 0 || optAmountX != 0) {
                uint256 maxAmt = trade.amountX > optAmountX ? trade.amountX : optAmountX;
                if (maxAmt != 0) {
                    ratioBps = wdiv(absDiff(trade.amountX, optAmountX), maxAmt) / BPS;
                }
            }

            arbLikeStep = toward
                && (misPreBps >= ARB_CLASS_MIS_BPS)
                && (sizeBps >= ARB_CLASS_SIZE_BPS)
                && (ratioBps <= ARB_CLASS_RATIO_TOL_BPS);

            uint256 fairCandidate = fairInv;
            if (!arbLikeStep && spot != 0) {
                fairCandidate = (fairInv * RETAIL_INV_W_PCT + spot * (100 - RETAIL_INV_W_PCT)) / 100;
            }

            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                uint256 cap = bpsToWad(arbLikeStep ? ARB_JUMP_BPS : RETAIL_JUMP_BPS);
                if (rel > cap) {
                    uint256 delta = wmul(fair, cap);
                    if (fairCandidate > fair) {
                        fairCandidate = fair + delta;
                    } else {
                        fairCandidate = fair > delta ? (fair - delta) : 0;
                    }
                }
            }

            uint256 alpha = arbLikeStep ? ARB_ALPHA_PCT : RETAIL_ALPHA_PCT;
            if (!arbLikeStep && fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                if (rel <= bpsToWad(QUIET_MIS_BPS) && alpha > QUIET_MIS_BPS) {
                    alpha = QUIET_MIS_BPS;
                }
            }
            fair = (fair * (100 - alpha) + fairCandidate * alpha) / 100;

            arbConf = (arbConf * ARB_CONF_DECAY_PCT) / 100;
            if (arbLikeStep) {
                arbConf += ARB_CONF_HIT_BPS;
                if (arbConf > 10000) arbConf = 10000;
                slots[5] = trade.timestamp;
            } else {
                arbConf = arbConf > ARB_CONF_MISS_BPS ? (arbConf - ARB_CONF_MISS_BPS) : 0;
                slots[5] = type(uint256).max;
            }

            slots[0] = trade.timestamp;
            slots[3] = fair;
            slots[11] = arbConf;

            if (lastSpot != 0 && spot != 0 && MICRO_ALPHA_PCT > 0) {
                uint256 move = wdiv(absDiff(spot, lastSpot), lastSpot);
                uint256 cap = bpsToWad(MICRO_MOVE_CAP_BPS);
                if (move > cap) move = cap;

                uint256 target;
                if (spot < lastSpot) {
                    target = WAD + move;
                } else {
                    target = WAD > move ? (WAD - move) : 0;
                }
                micro = (micro * (100 - MICRO_ALPHA_PCT) + target * MICRO_ALPHA_PCT) / 100;
            }

            if (lastTs != type(uint256).max && trade.timestamp > lastTs + QUEUE_GAP_RESET) {
                streak = 0;
            }
            slots[8] = spot;
        }

        if (ry != 0 && FLOW_ALPHA_PCT > 0) {
            uint256 impulse = wdiv(trade.amountY, ry);
            uint256 impulseCap = bpsToWad(FLOW_IMPULSE_CAP_BPS);
            if (impulse > impulseCap) impulse = impulseCap;

            uint256 target = trade.isBuy
                ? (WAD + impulse)
                : (WAD > impulse ? (WAD - impulse) : 0);

            flow = (flow * (100 - FLOW_ALPHA_PCT) + target * FLOW_ALPHA_PCT) / 100;
            flow = clampCentered(flow, FLOW_CLAMP_BPS);
        }

        uint256 side = trade.isBuy ? 1 : 2;
        if (side == lastSide) {
            streak += 1;
        } else {
            streak = 1;
            lastSide = side;
        }

        if (QUEUE_ALPHA_PCT > 0 && QUEUE_STEP_BPS > 0 && streak >= QUEUE_TRIGGER) {
            uint256 burst = (streak - QUEUE_TRIGGER + 1) * QUEUE_STEP_BPS;
            if (burst > QUEUE_MAX_BPS) burst = QUEUE_MAX_BPS;

            uint256 impulse = bpsToWad(burst);
            uint256 target = trade.isBuy
                ? (WAD + impulse)
                : (WAD > impulse ? (WAD - impulse) : 0);
            queue = (queue * (100 - QUEUE_ALPHA_PCT) + target * QUEUE_ALPHA_PCT) / 100;
        }

        micro = clampCentered(micro, FLOW_CLAMP_BPS);
        queue = clampCentered(queue, FLOW_CLAMP_BPS);

        slots[4] = flow;
        slots[6] = micro;
        slots[7] = queue;
        slots[9] = lastSide;
        slots[10] = streak;

        if (spot == 0 || fair == 0) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
            slots[1] = bidFee;
            slots[2] = askFee;
            return (bidFee, askFee);
        }

        uint256 mis = wdiv(absDiff(spot, fair), fair);

        (bool buyPressure, uint256 signedDev) = signalIsBuyPressure(flow, micro, queue);
        uint256 signalBps = signedDev / BPS;
        if (WIDE_SIGNAL_DIV > 0) signalBps /= WIDE_SIGNAL_DIV;
        if (signalBps > WIDE_SIGNAL_MAX_BPS) signalBps = WIDE_SIGNAL_MAX_BPS;

        bool highConf = arbConf >= CONF_GATE_BPS;
        uint256 tightBandBps = TIGHT_BAND_BPS;
        if (highConf && tightBandBps > CONF_TIGHT_BAND_CUT_BPS) {
            tightBandBps -= CONF_TIGHT_BAND_CUT_BPS;
        }

        if (mis <= bpsToWad(tightBandBps)) {
            uint256 tight = centiBpsToWad(TIGHT_FEE_CENTI_BPS);
            bidFee = tight;
            askFee = tight;

            uint256 flowTiltBps = centeredTiltBps(flow, FLOW_DEADBAND_BPS, FLOW_TILT_DIV, FLOW_MAX_TILT_BPS);
            uint256 microTiltBps = centeredTiltBps(micro, MICRO_DEADBAND_BPS, MICRO_TILT_DIV, MICRO_MAX_TILT_BPS);
            uint256 queueTiltBps = centeredTiltBps(queue, QUEUE_DEADBAND_BPS, QUEUE_TILT_DIV, QUEUE_MAX_TILT_BPS);

            uint256 extraBps = microTiltBps + queueTiltBps;
            if (extraBps > EXTRA_TILT_MAX_BPS) extraBps = EXTRA_TILT_MAX_BPS;

            uint256 tiltBps = flowTiltBps + extraBps;
            uint256 tilt = bpsToWad(tiltBps);

            if (buyPressure) {
                bidFee = clampFee(bidFee + tilt);
                askFee = askFee > tilt ? (askFee - tilt) : 0;
            } else {
                askFee = clampFee(askFee + tilt);
                bidFee = bidFee > tilt ? (bidFee - tilt) : 0;
            }

        } else {
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 gammaBaseSq = wmul(gammaBase, gammaBase);
            uint256 undercut = centiBpsToWad(UNDERCUT_CENTI_BPS);
            uint256 buffer = centiBpsToWad(BUFFER_CENTI_BPS);

            if (highConf) {
                undercut += centiBpsToWad(CONF_UNDERCUT_ADD_CENTI_BPS);
                uint256 bufCut = centiBpsToWad(CONF_BUFFER_CUT_CENTI_BPS);
                buffer = buffer > bufCut ? (buffer - bufCut) : 0;
            }

            uint256 signalAdj = bpsToWad(signalBps);
            uint256 compBoost = (signalAdj * WIDE_COMP_BONUS_PCT) / 100;
            uint256 protectBoost = (signalAdj * WIDE_PROTECT_BONUS_PCT) / 100;

            if (spot > fair) {
                uint256 useProtect = buyPressure ? protectBoost : 0;
                uint256 useComp = buyPressure ? compBoost : 0;

                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer + useProtect);

                uint256 gammaMatch = wdiv(wmul(spot, gammaBaseSq), fair);
                uint256 askRaw = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                uint256 cut = undercut + useComp;
                askFee = askRaw > cut ? (askRaw - cut) : 0;
            } else {
                uint256 useProtect = buyPressure ? 0 : protectBoost;
                uint256 useComp = buyPressure ? 0 : compBoost;

                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer + useProtect);

                uint256 gammaMatch = wdiv(wmul(fair, gammaBaseSq), spot);
                uint256 bidRaw = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                uint256 cut = undercut + useComp;
                bidFee = bidRaw > cut ? (bidRaw - cut) : 0;
            }
        }

        uint256 postArbCutBps = POST_ARB_CUT_BPS;
        if (highConf) postArbCutBps += CONF_POST_ARB_ADD_BPS;
        if (postArbCutBps > 0 && slots[5] == trade.timestamp) {
            uint256 cut = bpsToWad(postArbCutBps);
            bidFee = bidFee > cut ? (bidFee - cut) : 0;
            askFee = askFee > cut ? (askFee - cut) : 0;
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function getName() external pure override returns (string memory) {
        return "arbinf_v6";
    }
}
