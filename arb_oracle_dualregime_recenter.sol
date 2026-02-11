// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Dual-regime band-matching with a **post-retail recenter mode**.
///         - New step (first trade): update fair from gamma-adjusted spot; quote conservatively.
///         - Same-step trades are retail-only (arb already happened): quote aggressively to pull spot back toward fair
///           while keeping the adverse side protected for next-step arb.
contract Strategy is AMMStrategyBase {
    // slots:
    // 0 lastTimestamp
    // 1 currentBidFee
    // 2 currentAskFee
    // 3 fairPrice (WAD, Y per X)

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);
        slots[0] = type(uint256).max;
        slots[3] = p0;

        // Slightly competitive start to win routing and get frequent anchors.
        bidFee = bpsToWad(25);
        askFee = bpsToWad(25);
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

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        uint256 fair = slots[3];

        bool newStep = trade.timestamp != lastTs;

        // Update fair once per step from the first observed trade.
        if (newStep) {
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate = fair;
            if (gamma != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            // Clamp candidate jumps (first-trade can be retail when no arb hits us).
            uint256 maxJump = 400 * BPS; // 4%
            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                if (rel > maxJump) {
                    uint256 delta = wmul(fair, maxJump);
                    fairCandidate = fairCandidate > fair ? fair + delta : fair - delta;
                }
            }

            // EWMA (old 80% / new 20%): reacts quickly but still damps retail-first noise.
            fair = (fair * 80 + fairCandidate * 20) / 100;
            slots[0] = trade.timestamp;
            slots[3] = fair;
        }

        if (spot == 0 || fair == 0) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
            slots[1] = bidFee;
            slots[2] = askFee;
            return (bidFee, askFee);
        }

        uint256 mis = wdiv(absDiff(spot, fair), fair);
        uint256 tightBand = bpsToWad(25);

        // Baseline gamma (30 bps normalizer).
        uint256 gammaBase = WAD - bpsToWad(30);

        // New-step: don't over-undercut; same-step (retail): undercut more to recenter.
        uint256 undercut = newStep ? bpsToWad(0) : bpsToWad(2);

        // Buffer for the protective side (same-step retail: add a little more protection).
        uint256 buffer = newStep ? bpsToWad(4) : bpsToWad(8);

        if (mis <= tightBand) {
            // When we're near fair, match baseline fees; we win on price accuracy.
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
        } else {
            if (spot > fair) {
                // Spot > fair: arb would sell X to us → protect bid side.
                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer);

                // Competitive ask side: match baseline marginal and undercut (recenter mode same-step).
                uint256 gammaMatch = wdiv(wmul(spot, gammaBase), fair);
                askFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                askFee = askFee > undercut ? (askFee - undercut) : 0;
            } else {
                // Spot < fair: arb would buy X from us → protect ask side.
                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer);

                // Competitive bid side: match baseline marginal and undercut (recenter mode same-step).
                uint256 gammaMatch = wdiv(wmul(fair, gammaBase), spot);
                bidFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                bidFee = bidFee > undercut ? (bidFee - undercut) : 0;
            }
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function getName() external pure override returns (string memory) {
        return "ArbOracleDualRegimeRecenter";
    }
}
