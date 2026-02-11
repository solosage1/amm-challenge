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
    // 6 stressScoreBps (EWMA)
    // 7 stressMode (0 normal, 1 stress)
    // 8 stressHoldUntilTimestamp
    // 9 lastStressShockTimestamp
    // 10 lastSign (0 flat, 1 spot>fair, 2 spot<fair)

    // Frozen outer-regime core from mode2_v1.
    uint256 private constant TIGHT_BAND_BPS = 26;
    uint256 private constant INIT_FEE_CENTI_BPS = 2500;
    uint256 private constant TIGHT_FEE_CENTI_BPS = 2788;
    uint256 private constant UNDERCUT_CENTI_BPS = 1000;
    uint256 private constant BUFFER_CENTI_BPS = 35;

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

    // Frozen tight-band flow-memory knobs.
    uint256 private constant FLOW_ALPHA_PCT = 20;
    uint256 private constant FLOW_DECAY_PCT = 95;
    uint256 private constant FLOW_DEADBAND_BPS = 6;
    uint256 private constant FLOW_TILT_DIV = 9;
    uint256 private constant FLOW_MAX_TILT_BPS = 2;
    uint256 private constant FLOW_IMPULSE_CAP_BPS = 100;
    uint256 private constant FLOW_CLAMP_BPS = 500;

    uint256 private constant ARB_TAG_MIS_BPS = 32;
    uint256 private constant POST_ARB_CUT_BPS = 2;

    // Adversarial change-point + replay weighting knobs.
    uint256 private constant CP_JUMP_W_PCT = 50;
    uint256 private constant CP_MIS_W_PCT = 50;
    uint256 private constant CP_FLIP_BONUS_BPS = 28;
    uint256 private constant CP_TOWARD_BONUS_BPS = 28;
    uint256 private constant CP_SIGNAL_CAP_BPS = 200;
    uint256 private constant CP_ALPHA_PCT = 17;
    uint256 private constant CP_DECAY_PCT = 83;
    uint256 private constant CP_REPLAY_WINDOW = 6;
    uint256 private constant CP_REPLAY_SIGNAL_FLOOR_BPS = 18;
    uint256 private constant CP_REPLAY_BONUS_BPS = 32;

    // Stress mode hysteresis.
    uint256 private constant STRESS_ENTER_BPS = 29;
    uint256 private constant STRESS_EXIT_BPS = 13;
    uint256 private constant STRESS_INSTANT_BPS = 48;
    uint256 private constant STRESS_MIN_HOLD_STEPS = 7;

    // Stress-mode spread/undercut clamps.
    uint256 private constant STRESS_TIGHT_ADD_BPS = 4;
    uint256 private constant STRESS_BUFFER_ADD_CENTI_BPS = 40;
    uint256 private constant STRESS_UNDERCUT_CUT_CENTI_BPS = 400;
    uint256 private constant STRESS_COMP_FLOOR_BPS = 26;
    uint256 private constant STRESS_MAX_SPREAD_BPS = 48;
    uint256 private constant STRESS_POST_ARB_CUT_SCALE_PCT = 10;

    function centiBpsToWad(uint256 centiBps) internal pure returns (uint256) {
        return (centiBps * BPS) / 100;
    }

    function applyStressState(
        uint256 stress,
        uint256 mode,
        uint256 holdUntil,
        uint256 lastShockTs,
        uint256 prevSign,
        uint256 ts,
        uint256 relBps,
        uint256 misBps,
        bool toward,
        uint256 sign
    ) internal pure returns (uint256, uint256, uint256, uint256, uint256) {
        uint256 signal = (relBps * CP_JUMP_W_PCT + misBps * CP_MIS_W_PCT) / 100;
        if (sign != 0 && prevSign != 0 && sign != prevSign) {
            signal += CP_FLIP_BONUS_BPS;
        }
        if (toward && misBps >= ARB_TAG_MIS_BPS) {
            signal += CP_TOWARD_BONUS_BPS;
        }
        if (
            lastShockTs != type(uint256).max
                && ts <= lastShockTs + CP_REPLAY_WINDOW
                && signal >= CP_REPLAY_SIGNAL_FLOOR_BPS
        ) {
            signal += CP_REPLAY_BONUS_BPS;
        }
        if (signal > CP_SIGNAL_CAP_BPS) {
            signal = CP_SIGNAL_CAP_BPS;
        }

        stress = (stress * CP_DECAY_PCT + signal * CP_ALPHA_PCT) / 100;
        if (stress > CP_SIGNAL_CAP_BPS) {
            stress = CP_SIGNAL_CAP_BPS;
        }

        bool shock = signal >= STRESS_INSTANT_BPS;
        if (shock) {
            lastShockTs = ts;
        }

        if (mode == 0) {
            if (stress >= STRESS_ENTER_BPS || shock) {
                mode = 1;
                holdUntil = ts + STRESS_MIN_HOLD_STEPS;
            }
        } else {
            if (shock) {
                holdUntil = ts + STRESS_MIN_HOLD_STEPS;
            }
            if (ts >= holdUntil && stress <= STRESS_EXIT_BPS) {
                mode = 0;
            }
        }

        prevSign = sign;
        return (stress, mode, holdUntil, lastShockTs, prevSign);
    }

    function applyStressSpreadClamp(uint256 mode, uint256 bidFee, uint256 askFee, bool protectBid)
        internal
        pure
        returns (uint256, uint256)
    {
        if (mode == 0) {
            return (bidFee, askFee);
        }

        uint256 compFloor = bpsToWad(STRESS_COMP_FLOOR_BPS);
        if (protectBid) {
            if (askFee < compFloor) askFee = compFloor;
        } else {
            if (bidFee < compFloor) bidFee = compFloor;
        }

        uint256 spreadCap = bpsToWad(STRESS_MAX_SPREAD_BPS);
        if (bidFee > askFee) {
            uint256 spread = bidFee - askFee;
            if (spread > spreadCap) bidFee = askFee + spreadCap;
        } else {
            uint256 spread = askFee - bidFee;
            if (spread > spreadCap) askFee = bidFee + spreadCap;
        }

        return (bidFee, askFee);
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
        slots[6] = 0;
        slots[7] = 0;
        slots[8] = 0;
        slots[9] = type(uint256).max;
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
        uint256 stress = slots[6];
        uint256 mode = slots[7];
        uint256 holdUntil = slots[8];
        uint256 lastShockTs = slots[9];
        uint256 prevSign = slots[10];

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        bool isNewStep = trade.timestamp != lastTs;
        uint256 relBps = 0;
        if (isNewStep) {
            if (FLOW_DECAY_PCT < 100) {
                flow = (flow * FLOW_DECAY_PCT + WAD * (100 - FLOW_DECAY_PCT)) / 100;
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
            relBps = rel / BPS;

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
        }

        if (ry != 0 && FLOW_ALPHA_PCT > 0) {
            uint256 impulse = wdiv(trade.amountY, ry);
            uint256 impulseCap = bpsToWad(FLOW_IMPULSE_CAP_BPS);
            if (impulse > impulseCap) impulse = impulseCap;

            uint256 target = trade.isBuy
                ? (WAD + impulse)
                : (WAD > impulse ? (WAD - impulse) : 0);

            flow = (flow * (100 - FLOW_ALPHA_PCT) + target * FLOW_ALPHA_PCT) / 100;

            uint256 clamp = bpsToWad(FLOW_CLAMP_BPS);
            uint256 lo = WAD > clamp ? (WAD - clamp) : 0;
            uint256 hi = WAD + clamp;
            if (flow < lo) flow = lo;
            if (flow > hi) flow = hi;
        }
        slots[4] = flow;

        if (spot == 0 || fair == 0) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
            slots[1] = bidFee;
            slots[2] = askFee;
            slots[6] = stress;
            slots[7] = mode;
            slots[8] = holdUntil;
            slots[9] = lastShockTs;
            slots[10] = prevSign;
            return (bidFee, askFee);
        }

        uint256 mis = wdiv(absDiff(spot, fair), fair);
        uint256 misBps = mis / BPS;
        if (isNewStep) {
            bool toward = (spot >= fair && trade.isBuy) || (spot <= fair && !trade.isBuy);
            if (toward && mis >= bpsToWad(ARB_TAG_MIS_BPS)) {
                slots[5] = trade.timestamp;
            }

            uint256 sign = spot > fair ? 1 : (spot < fair ? 2 : 0);
            (stress, mode, holdUntil, lastShockTs, prevSign) = applyStressState(
                stress,
                mode,
                holdUntil,
                lastShockTs,
                prevSign,
                trade.timestamp,
                relBps,
                misBps,
                toward,
                sign
            );
        }

        uint256 tight = centiBpsToWad(TIGHT_FEE_CENTI_BPS);
        uint256 undercut = centiBpsToWad(UNDERCUT_CENTI_BPS);
        uint256 buffer = centiBpsToWad(BUFFER_CENTI_BPS);
        uint256 postArbCutBps = POST_ARB_CUT_BPS;

        if (mode == 1) {
            tight = clampFee(tight + bpsToWad(STRESS_TIGHT_ADD_BPS));
            buffer += centiBpsToWad(STRESS_BUFFER_ADD_CENTI_BPS);

            uint256 undercutCut = centiBpsToWad(STRESS_UNDERCUT_CUT_CENTI_BPS);
            undercut = undercut > undercutCut ? (undercut - undercutCut) : 0;

            postArbCutBps = (postArbCutBps * STRESS_POST_ARB_CUT_SCALE_PCT) / 100;
        }

        if (mis <= bpsToWad(TIGHT_BAND_BPS)) {
            bidFee = tight;
            askFee = tight;

            uint256 deadband = bpsToWad(FLOW_DEADBAND_BPS);
            uint256 dev = absDiff(flow, WAD);
            if (FLOW_MAX_TILT_BPS > 0 && dev > deadband) {
                uint256 eff = dev - deadband;
                uint256 devBps = eff / BPS;
                uint256 tiltBps = FLOW_TILT_DIV == 0 ? devBps : (devBps / FLOW_TILT_DIV);
                if (tiltBps > FLOW_MAX_TILT_BPS) tiltBps = FLOW_MAX_TILT_BPS;

                uint256 tilt = bpsToWad(tiltBps);
                if (flow > WAD) {
                    bidFee = clampFee(bidFee + tilt);
                    askFee = askFee > tilt ? (askFee - tilt) : 0;
                } else {
                    askFee = clampFee(askFee + tilt);
                    bidFee = bidFee > tilt ? (bidFee - tilt) : 0;
                }
            }

        } else {
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 gammaBaseSq = wmul(gammaBase, gammaBase);

            if (spot > fair) {
                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer);

                uint256 gammaMatch = wdiv(wmul(spot, gammaBaseSq), fair);
                uint256 askRaw = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                askFee = askRaw > undercut ? (askRaw - undercut) : 0;

                (bidFee, askFee) = applyStressSpreadClamp(mode, bidFee, askFee, true);
            } else {
                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer);

                uint256 gammaMatch = wdiv(wmul(fair, gammaBaseSq), spot);
                uint256 bidRaw = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                bidFee = bidRaw > undercut ? (bidRaw - undercut) : 0;

                (bidFee, askFee) = applyStressSpreadClamp(mode, bidFee, askFee, false);
            }
        }

        if (postArbCutBps > 0 && slots[5] == trade.timestamp) {
            uint256 cut = bpsToWad(postArbCutBps);
            bidFee = bidFee > cut ? (bidFee - cut) : 0;
            askFee = askFee > cut ? (askFee - cut) : 0;
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
        slots[6] = stress;
        slots[7] = mode;
        slots[8] = holdUntil;
        slots[9] = lastShockTs;
        slots[10] = prevSign;
    }

    function getName() external pure override returns (string memory) {
        return "advsr_v8";
    }
}
