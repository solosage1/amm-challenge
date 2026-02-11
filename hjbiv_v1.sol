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

    // Tight-band flow memory from iskewx_v11.
    uint256 private constant FLOW_ALPHA_PCT = 20;
    uint256 private constant FLOW_DECAY_PCT = 95;
    uint256 private constant FLOW_DEADBAND_BPS = 6;
    uint256 private constant FLOW_TILT_DIV = 9;
    uint256 private constant FLOW_MAX_TILT_BPS = 2;
    uint256 private constant FLOW_IMPULSE_CAP_BPS = 100;
    uint256 private constant FLOW_CLAMP_BPS = 500;

    // Post-arb retightening.
    uint256 private constant ARB_TAG_MIS_BPS = 32;
    uint256 private constant POST_ARB_CUT_BPS = 2;

    // HJB-like inventory controls for wide-regime quoting.
    uint256 private constant INV_WIDE_DEADBAND_BPS = 8;
    uint256 private constant INV_WIDE_DIV = 8;
    uint256 private constant INV_WIDE_MAX_BPS = 0;
    uint256 private constant INV_COMP_BONUS_PCT = 0;
    uint256 private constant INV_PROTECT_BUFFER_PCT = 0;

    function centiBpsToWad(uint256 centiBps) internal pure returns (uint256) {
        return (centiBps * BPS) / 100;
    }

    function invStressBps(uint256 flow) internal pure returns (uint256) {
        uint256 deadband = bpsToWad(INV_WIDE_DEADBAND_BPS);
        uint256 dev = absDiff(flow, WAD);
        if (dev <= deadband) return 0;

        uint256 eff = dev - deadband;
        uint256 rawBps = eff / BPS;
        uint256 stress = INV_WIDE_DIV == 0 ? rawBps : (rawBps / INV_WIDE_DIV);
        if (stress > INV_WIDE_MAX_BPS) stress = INV_WIDE_MAX_BPS;
        return stress;
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

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        bool isNewStep = trade.timestamp != lastTs;
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
            return (bidFee, askFee);
        }

        uint256 mis = wdiv(absDiff(spot, fair), fair);
        if (isNewStep) {
            bool toward = (spot >= fair && trade.isBuy) || (spot <= fair && !trade.isBuy);
            if (toward && mis >= bpsToWad(ARB_TAG_MIS_BPS)) {
                slots[5] = trade.timestamp;
            }
        }

        if (mis <= bpsToWad(TIGHT_BAND_BPS)) {
            uint256 tight = centiBpsToWad(TIGHT_FEE_CENTI_BPS);
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
            uint256 undercut = centiBpsToWad(UNDERCUT_CENTI_BPS);
            uint256 buffer = centiBpsToWad(BUFFER_CENTI_BPS);

            uint256 invBps = invStressBps(flow);
            uint256 invCompBonus = 0;
            uint256 invProtectBoost = 0;
            if (invBps > 0) {
                uint256 invAdj = bpsToWad(invBps);
                invCompBonus = (invAdj * INV_COMP_BONUS_PCT) / 100;
                invProtectBoost = (invAdj * INV_PROTECT_BUFFER_PCT) / 100;
            }

            if (spot > fair) {
                uint256 protectBoost = flow > WAD ? invProtectBoost : 0;
                uint256 compBoost = flow > WAD ? invCompBonus : 0;

                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer + protectBoost);

                uint256 gammaMatch = wdiv(wmul(spot, gammaBaseSq), fair);
                uint256 askRaw = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                uint256 totalCut = undercut + compBoost;
                askFee = askRaw > totalCut ? (askRaw - totalCut) : 0;
            } else {
                uint256 protectBoost = flow < WAD ? invProtectBoost : 0;
                uint256 compBoost = flow < WAD ? invCompBonus : 0;

                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer + protectBoost);

                uint256 gammaMatch = wdiv(wmul(fair, gammaBaseSq), spot);
                uint256 bidRaw = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                uint256 totalCut = undercut + compBoost;
                bidFee = bidRaw > totalCut ? (bidRaw - totalCut) : 0;
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
        return "hjbiv_v1";
    }
}
