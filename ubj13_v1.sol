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
    // 11 aggrState (WAD-centered)
    // 12 riskState (WAD-centered)
    // 13 confidenceBps (0..10000)
    // 14 inventoryScore (WAD-centered; >WAD means Y-heavy / wants more X)
    // 7 is repurposed as signedFlowSkew in this family

    uint256 private constant INIT_FEE_CENTI_BPS = 2500;

    // Fee arms (band/tight/wide parameters).
    uint256 private constant ARM0_BAND_BPS = 23;
    uint256 private constant ARM1_BAND_BPS = 24;
    uint256 private constant ARM2_BAND_BPS = 25;

    uint256 private constant ARM0_TIGHT_CENTI_BPS = 2805;
    uint256 private constant ARM1_TIGHT_CENTI_BPS = 2788;
    uint256 private constant ARM2_TIGHT_CENTI_BPS = 2768;

    uint256 private constant ARM0_UNDERCUT_CENTI_BPS = 980;
    uint256 private constant ARM1_UNDERCUT_CENTI_BPS = 1050;
    uint256 private constant ARM2_UNDERCUT_CENTI_BPS = 1135;

    uint256 private constant ARM0_BUFFER_CENTI_BPS = 220;
    uint256 private constant ARM1_BUFFER_CENTI_BPS = 200;
    uint256 private constant ARM2_BUFFER_CENTI_BPS = 170;

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
    uint256 private constant WIDE_COMP_BONUS_PCT = 62;
    uint256 private constant WIDE_PROTECT_BONUS_PCT = 58;

    // Meta-learning / gating.
    uint256 private constant META_AGGR_ALPHA_PCT = 20;
    uint256 private constant META_RISK_ALPHA_PCT = 18;
    uint256 private constant META_MAG_CAP_BPS = 14;
    uint256 private constant META_CLAMP_BPS = 520;

    uint256 private constant RISK_ARM_TRIG_BPS = 36;
    uint256 private constant AGGR_ARM_TRIG_BPS = 23;
    uint256 private constant AGGR_MAX_RISK_BPS = 25;

    uint256 private constant CONF_GATE_BPS = 4300;
    uint256 private constant CONF_UP_BPS = 100;
    uint256 private constant CONF_DOWN_BPS = 145;
    uint256 private constant CONF_MISS_BPS = 40;

    // Inventory-skewed asymmetric layer (targeted mutation dimensions).
    uint256 private constant INV_ALPHA_PCT = 12;
    uint256 private constant INV_DEADBAND_BPS = 999;
    uint256 private constant INV_DIV = 1;
    uint256 private constant INV_MAX_BPS = 0;

    uint256 private constant SKEW_ALPHA_PCT = 12;
    uint256 private constant SKEW_DEADBAND_BPS = 999;
    uint256 private constant SKEW_DIV = 1;
    uint256 private constant SKEW_MAX_BPS = 0;
    uint256 private constant SKEW_STREAK_BONUS_BPS = 0;

    uint256 private constant BIAS_ENTER_BPS = 9999;
    uint256 private constant BIAS_FLIP_BPS = 9999;
    uint256 private constant BIAS_HOLD_STEPS = 0;

    uint256 private constant ALIGN_COMP_BONUS_PCT = 0;
    uint256 private constant MISALIGN_COMP_CUT_PCT = 0;
    uint256 private constant ALIGN_PROTECT_CUT_PCT = 0;
    uint256 private constant MISALIGN_PROTECT_BONUS_PCT = 0;
    uint256 private constant BIAS_COMP_MAX_BPS = 0;
    uint256 private constant BIAS_PROTECT_MAX_BPS = 0;
    uint256 private constant TIGHT_INV_TILT_MAX_BPS = 0;

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

    function armBandBps(uint256 arm) internal pure returns (uint256) {
        if (arm == 0) return ARM0_BAND_BPS;
        if (arm == 2) return ARM2_BAND_BPS;
        return ARM1_BAND_BPS;
    }

    function armTightCentiBps(uint256 arm) internal pure returns (uint256) {
        if (arm == 0) return ARM0_TIGHT_CENTI_BPS;
        if (arm == 2) return ARM2_TIGHT_CENTI_BPS;
        return ARM1_TIGHT_CENTI_BPS;
    }

    function armUndercutCentiBps(uint256 arm) internal pure returns (uint256) {
        if (arm == 0) return ARM0_UNDERCUT_CENTI_BPS;
        if (arm == 2) return ARM2_UNDERCUT_CENTI_BPS;
        return ARM1_UNDERCUT_CENTI_BPS;
    }

    function armBufferCentiBps(uint256 arm) internal pure returns (uint256) {
        if (arm == 0) return ARM0_BUFFER_CENTI_BPS;
        if (arm == 2) return ARM2_BUFFER_CENTI_BPS;
        return ARM1_BUFFER_CENTI_BPS;
    }

    function preferredSideFromState(uint256 inv, uint256 skew)
        internal
        pure
        returns (uint256 side, uint256 strengthBps)
    {
        uint256 bid = 0;
        uint256 ask = 0;

        uint256 invBps = centeredTiltBps(inv, INV_DEADBAND_BPS, INV_DIV, INV_MAX_BPS);
        if (invBps > 0) {
            if (inv > WAD) bid += invBps;
            else ask += invBps;
        }

        uint256 skewBps = centeredTiltBps(skew, SKEW_DEADBAND_BPS, SKEW_DIV, SKEW_MAX_BPS);
        if (skewBps > 0) {
            if (skew > WAD) bid += skewBps;
            else ask += skewBps;
        }

        if (bid > ask) return (1, bid - ask);
        if (ask > bid) return (2, ask - bid);
        return (0, 0);
    }

    function applyWideBias(
        uint256 useComp,
        uint256 useProtect,
        uint256 biasSide,
        uint256 compSide,
        uint256 protectSide,
        uint256 biasBps
    ) internal pure returns (uint256 outComp, uint256 outProtect) {
        outComp = useComp;
        outProtect = useProtect;
        if (biasSide == 0 || biasBps == 0) return (outComp, outProtect);

        uint256 biasAdj = bpsToWad(biasBps);
        uint256 alignComp = (biasAdj * ALIGN_COMP_BONUS_PCT) / 100;
        uint256 misalignComp = (biasAdj * MISALIGN_COMP_CUT_PCT) / 100;
        uint256 alignProtectCut = (biasAdj * ALIGN_PROTECT_CUT_PCT) / 100;
        uint256 misalignProtect = (biasAdj * MISALIGN_PROTECT_BONUS_PCT) / 100;

        uint256 compCap = bpsToWad(BIAS_COMP_MAX_BPS);
        uint256 protectCap = bpsToWad(BIAS_PROTECT_MAX_BPS);
        if (alignComp > compCap) alignComp = compCap;
        if (misalignComp > compCap) misalignComp = compCap;
        if (alignProtectCut > protectCap) alignProtectCut = protectCap;
        if (misalignProtect > protectCap) misalignProtect = protectCap;

        if (biasSide == compSide) outComp += alignComp;
        else outComp = outComp > misalignComp ? (outComp - misalignComp) : 0;

        if (biasSide == protectSide) {
            outProtect = outProtect > alignProtectCut ? (outProtect - alignProtectCut) : 0;
        } else {
            outProtect += misalignProtect;
        }
    }

    function updateMetaStates(
        uint256 fairPrev,
        uint256 amountX,
        uint256 amountY,
        bool isBuy,
        uint256 spot,
        uint256 fair,
        uint256 mis,
        uint256 aggr,
        uint256 risk,
        uint256 conf
    ) internal pure returns (uint256 nextAggr, uint256 nextRisk, uint256 nextConf, bool arbLike) {
        bool toward = (spot >= fair && isBuy) || (spot <= fair && !isBuy);
        arbLike = toward && mis >= bpsToWad(ARB_TAG_MIS_BPS);

        uint256 magBps = 0;
        bool edgePos = false;
        uint256 ref = fairPrev == 0 ? 0 : wmul(amountX, fairPrev);
        if (ref != 0) {
            if (isBuy) {
                if (amountY >= ref) {
                    edgePos = true;
                    magBps = wdiv(amountY - ref, ref) / BPS;
                } else {
                    magBps = wdiv(ref - amountY, ref) / BPS;
                }
            } else {
                if (ref >= amountY) {
                    edgePos = true;
                    magBps = wdiv(ref - amountY, ref) / BPS;
                } else {
                    magBps = wdiv(amountY - ref, ref) / BPS;
                }
            }
        }
        if (magBps > META_MAG_CAP_BPS) magBps = META_MAG_CAP_BPS;

        uint256 aggrTarget = WAD;
        uint256 riskTarget = WAD;

        if (arbLike) {
            uint256 bump = 2 + (mis / BPS) / 10;
            if (bump > META_MAG_CAP_BPS) bump = META_MAG_CAP_BPS;
            uint256 bumpW = bpsToWad(bump);
            aggrTarget = WAD > bumpW ? (WAD - bumpW) : 0;
            riskTarget = WAD + bumpW;
            conf = conf > CONF_DOWN_BPS ? (conf - CONF_DOWN_BPS) : 0;
        } else if (edgePos) {
            uint256 bump = magBps / 2;
            if (bump > 6) bump = 6;
            uint256 bumpW = bpsToWad(bump);
            aggrTarget = WAD + bumpW;
            uint256 soften = bpsToWad(bump / 2);
            riskTarget = WAD > soften ? (WAD - soften) : 0;
            conf += CONF_UP_BPS;
            if (conf > 10000) conf = 10000;
        } else {
            uint256 bump = magBps / 2;
            if (bump > 4) bump = 4;
            uint256 bumpW = bpsToWad(bump);
            aggrTarget = WAD > bumpW ? (WAD - bumpW) : 0;
            conf = conf > CONF_MISS_BPS ? (conf - CONF_MISS_BPS) : 0;
        }

        if (META_AGGR_ALPHA_PCT > 0) {
            aggr = (aggr * (100 - META_AGGR_ALPHA_PCT) + aggrTarget * META_AGGR_ALPHA_PCT) / 100;
        }
        if (META_RISK_ALPHA_PCT > 0) {
            risk = (risk * (100 - META_RISK_ALPHA_PCT) + riskTarget * META_RISK_ALPHA_PCT) / 100;
        }

        nextAggr = clampCentered(aggr, META_CLAMP_BPS);
        nextRisk = clampCentered(risk, META_CLAMP_BPS);
        nextConf = conf;
    }

    function chooseArm(uint256 conf, uint256 aggr, uint256 risk, uint256 mis, uint256 signalBps)
        internal
        pure
        returns (uint256)
    {
        if (conf < CONF_GATE_BPS) return 1;

        uint256 misBps = mis / BPS;
        if (misBps >= RISK_ARM_TRIG_BPS) return 0;
        if (risk >= WAD + bpsToWad(RISK_ARM_TRIG_BPS)) return 0;

        if (
            misBps <= AGGR_MAX_RISK_BPS
                && aggr >= WAD + bpsToWad(AGGR_ARM_TRIG_BPS)
                && signalBps <= (WIDE_SIGNAL_MAX_BPS + 1)
        ) {
            return 2;
        }

        return 1;
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
        uint256 aggr = slots[11];
        uint256 risk = slots[12];
        uint256 conf = slots[13];
        uint256 inv = slots[14];
        if (aggr == 0) aggr = WAD;
        if (risk == 0) risk = WAD;
        if (conf == 0) conf = 5000;
        if (inv == 0) inv = WAD;
        if (queue == 0) queue = WAD;

        uint256 fairPrev = fair;
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

            if (INV_ALPHA_PCT > 0 && rx != 0 && fair != 0) {
                uint256 invTarget = WAD;
                uint256 xValueInY = wmul(rx, fair);
                if (xValueInY != 0) {
                    invTarget = wdiv(ry, xValueInY);
                }
                inv = (inv * (100 - INV_ALPHA_PCT) + invTarget * INV_ALPHA_PCT) / 100;
                inv = clampCentered(inv, FLOW_CLAMP_BPS);
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

        if (SKEW_ALPHA_PCT > 0 && ry != 0) {
            uint256 impulse = wdiv(trade.amountY, ry);
            uint256 streakBonus = streak > 1 ? (streak - 1) * SKEW_STREAK_BONUS_BPS : 0;
            uint256 bonusCap = bpsToWad(SKEW_MAX_BPS);
            uint256 bonus = bpsToWad(streakBonus);
            if (bonus > bonusCap) bonus = bonusCap;
            impulse += bonus;

            uint256 impulseCap = bpsToWad(FLOW_IMPULSE_CAP_BPS + SKEW_MAX_BPS);
            if (impulse > impulseCap) impulse = impulseCap;

            uint256 target = trade.isBuy
                ? (WAD + impulse)
                : (WAD > impulse ? (WAD - impulse) : 0);
            queue = (queue * (100 - SKEW_ALPHA_PCT) + target * SKEW_ALPHA_PCT) / 100;
            queue = clampCentered(queue, FLOW_CLAMP_BPS);
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
        slots[14] = inv;

        if (spot == 0 || fair == 0) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
            slots[1] = bidFee;
            slots[2] = askFee;
            return (bidFee, askFee);
        }

        uint256 mis = wdiv(absDiff(spot, fair), fair);
        bool arbLike;
        (aggr, risk, conf, arbLike) = updateMetaStates(
            fairPrev,
            trade.amountX,
            trade.amountY,
            trade.isBuy,
            spot,
            fair,
            mis,
            aggr,
            risk,
            conf
        );
        slots[11] = aggr;
        slots[12] = risk;
        slots[13] = conf;

        if (isNewStep && arbLike) {
            slots[5] = trade.timestamp;
        }

        (bool buyPressure, uint256 signedDev) = signalIsBuyPressure(flow, micro, queue);
        uint256 signalBps = signedDev / BPS;
        if (WIDE_SIGNAL_DIV > 0) signalBps /= WIDE_SIGNAL_DIV;
        if (signalBps > WIDE_SIGNAL_MAX_BPS) signalBps = WIDE_SIGNAL_MAX_BPS;

        (uint256 biasSide, uint256 biasBps) = preferredSideFromState(inv, queue);
        if (streak >= BIAS_HOLD_STEPS) {
            uint256 streakSide = lastSide;
            uint256 streakStrength = streak - BIAS_HOLD_STEPS + 1;
            if (streakStrength > BIAS_FLIP_BPS) streakStrength = BIAS_FLIP_BPS;

            if (biasSide == 0 || biasBps < BIAS_ENTER_BPS) {
                biasSide = streakSide;
                biasBps = BIAS_ENTER_BPS;
            } else if (biasSide != streakSide && biasBps < BIAS_FLIP_BPS + streakStrength) {
                biasSide = streakSide;
            }
        }

        uint256 activeArm = chooseArm(conf, aggr, risk, mis, signalBps);

        uint256 tightBandBps = armBandBps(activeArm);
        uint256 tightFee = centiBpsToWad(armTightCentiBps(activeArm));

        if (mis <= bpsToWad(tightBandBps)) {
            bidFee = tightFee;
            askFee = tightFee;

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

            uint256 invTightBps = centeredTiltBps(inv, INV_DEADBAND_BPS, INV_DIV, TIGHT_INV_TILT_MAX_BPS);
            if (invTightBps > 0) {
                uint256 invTilt = bpsToWad(invTightBps);
                if (biasSide == 1) {
                    bidFee = clampFee(bidFee + invTilt);
                    askFee = askFee > invTilt ? (askFee - invTilt) : 0;
                } else if (biasSide == 2) {
                    askFee = clampFee(askFee + invTilt);
                    bidFee = bidFee > invTilt ? (bidFee - invTilt) : 0;
                }
            }

        } else {
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 gammaBaseSq = wmul(gammaBase, gammaBase);
            uint256 undercut = centiBpsToWad(armUndercutCentiBps(activeArm));
            uint256 buffer = centiBpsToWad(armBufferCentiBps(activeArm));

            uint256 signalAdj = bpsToWad(signalBps);
            uint256 compBoost = (signalAdj * WIDE_COMP_BONUS_PCT) / 100;
            uint256 protectBoost = (signalAdj * WIDE_PROTECT_BONUS_PCT) / 100;

            if (spot > fair) {
                uint256 useProtect = buyPressure ? protectBoost : 0;
                uint256 useComp = buyPressure ? compBoost : 0;
                (useComp, useProtect) = applyWideBias(useComp, useProtect, biasSide, 2, 1, biasBps);

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
                (useComp, useProtect) = applyWideBias(useComp, useProtect, biasSide, 1, 2, biasBps);

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
        return "ubj13_v1";
    }
}
