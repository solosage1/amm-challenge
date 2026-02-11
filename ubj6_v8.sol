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

    // Frozen outer-regime core from mode2_v1/iskewx_v11.
    uint256 private constant TIGHT_BAND_BPS = 25;
    uint256 private constant INIT_FEE_CENTI_BPS = 2500;
    uint256 private constant TIGHT_FEE_CENTI_BPS = 2788;
    uint256 private constant UNDERCUT_CENTI_BPS = 1000;
    uint256 private constant BUFFER_CENTI_BPS = 0;

    // Frozen fair-value update logic from champion family.
    uint256 private constant BASE_ALPHA_NEW_PCT = 19;
    uint256 private constant QUIET_ALPHA_NEW_PCT = 15;
    uint256 private constant QUIET_MIS_BPS = 15;
    uint256 private constant FAST_ALPHA_NEW_PCT = 19;
    uint256 private constant FAST_MIS_BPS = 9999;
    uint256 private constant STALE_ALPHA_BOOST_PCT = 0;
    uint256 private constant MAX_ALPHA_NEW_PCT = 19;

    uint256 private constant JUMP_UP_BPS = 400;
    uint256 private constant JUMP_DOWN_BPS = 400;

    // Frozen flow-memory knobs from champion family.
    uint256 private constant FLOW_ALPHA_PCT = 20;
    uint256 private constant FLOW_DECAY_PCT = 95;
    uint256 private constant FLOW_DEADBAND_BPS = 6;
    uint256 private constant FLOW_TILT_DIV = 9;
    uint256 private constant FLOW_MAX_TILT_BPS = 2;
    uint256 private constant FLOW_IMPULSE_CAP_BPS = 100;
    uint256 private constant FLOW_CLAMP_BPS = 500;

    uint256 private constant ARB_TAG_MIS_BPS = 36;
    uint256 private constant POST_ARB_CUT_BPS = 4;

    // Targeted microprice/queue dimensions.
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

    function centiBpsToWad(uint256 centiBps) internal pure returns (uint256) {
        return (centiBps * BPS) / 100;
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

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        bool isNewStep = trade.timestamp != lastTs;
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
            uint256 fairCandidate = fair;
            if (gamma != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            uint256 rel = 0;
            if (fair != 0) {
                rel = wdiv(absDiff(fairCandidate, fair), fair);

                uint256 upCap = bpsToWad(JUMP_UP_BPS);
                uint256 downCap = bpsToWad(JUMP_DOWN_BPS);
                if (fairCandidate > fair && rel > upCap) {
                    fairCandidate = fair + wmul(fair, upCap);
                    rel = upCap;
                } else if (fairCandidate < fair && rel > downCap) {
                    fairCandidate = fair - wmul(fair, downCap);
                    rel = downCap;
                }
            }

            uint256 alpha = BASE_ALPHA_NEW_PCT;
            if (rel <= bpsToWad(QUIET_MIS_BPS) && QUIET_ALPHA_NEW_PCT < alpha) {
                alpha = QUIET_ALPHA_NEW_PCT;
            }
            if (rel >= bpsToWad(FAST_MIS_BPS) && FAST_ALPHA_NEW_PCT > alpha) {
                alpha = FAST_ALPHA_NEW_PCT;
            }
            if (lastTs != type(uint256).max && trade.timestamp > lastTs + 1) {
                uint256 dt = trade.timestamp - lastTs - 1;
                alpha += dt * STALE_ALPHA_BOOST_PCT;
            }
            if (alpha > MAX_ALPHA_NEW_PCT) alpha = MAX_ALPHA_NEW_PCT;

            fair = (fair * (100 - alpha) + fairCandidate * alpha) / 100;
            slots[0] = trade.timestamp;
            slots[3] = fair;
            slots[5] = type(uint256).max;

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
        if (isNewStep) {
            bool toward = (spot >= fair && trade.isBuy) || (spot <= fair && !trade.isBuy);
            if (toward && mis >= bpsToWad(ARB_TAG_MIS_BPS)) {
                slots[5] = trade.timestamp;
            }
        }

        (bool buyPressure, uint256 signedDev) = signalIsBuyPressure(flow, micro, queue);
        uint256 signalBps = signedDev / BPS;
        if (WIDE_SIGNAL_DIV > 0) signalBps /= WIDE_SIGNAL_DIV;
        if (signalBps > WIDE_SIGNAL_MAX_BPS) signalBps = WIDE_SIGNAL_MAX_BPS;

        if (mis <= bpsToWad(TIGHT_BAND_BPS)) {
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

        if (POST_ARB_CUT_BPS > 0 && slots[5] == trade.timestamp) {
            uint256 cut = bpsToWad(POST_ARB_CUT_BPS);
            bidFee = bidFee > cut ? (bidFee - cut) : 0;
            askFee = askFee > cut ? (askFee - cut) : 0;
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function getName() external pure override returns (string memory) {
        return "ubj6_v8";
    }
}
