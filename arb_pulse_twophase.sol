// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Two-phase quoting:
///         - First trade each step (usually arb) updates an arb-implied fair and switches to a
///           competitive asymmetric quote for retail.
///         - Any subsequent same-step trade switches back to a symmetric "protect" quote to
///           reduce next-step arbitrage losses regardless of direction.
/// @dev Focuses on H-001 (fair inference from arb) + H-002 (post-arb tighten, post-retail widen).
contract Strategy is AMMStrategyBase {
    // slots:
    // 0: lastTimestamp
    // 1: currentBidFee
    // 2: currentAskFee
    // 3: fairPriceEwma (WAD, Y per X)

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);

        // Ensure first observed trade is treated as "new step".
        slots[0] = type(uint256).max;
        slots[3] = p0;

        // Start protective.
        bidFee = bpsToWad(70);
        askFee = bpsToWad(70);
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

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        bool newStep = trade.timestamp != lastTs;

        if (newStep) {
            // --- Phase 1: "arb pulse" fair inference (first trade of step) ---
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate = fair;
            if (gamma != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            // Clamp candidate jumps; first-trade can be retail when no arb hits us.
            uint256 maxJump = 500 * BPS; // 5%
            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                if (rel > maxJump) {
                    uint256 delta = wmul(fair, maxJump);
                    fairCandidate = fairCandidate > fair ? fair + delta : fair - delta;
                }
            }

            // Fast-ish EWMA: arb anchors are usually clean.
            fair = (fair * 70 + fairCandidate * 30) / 100;
            slots[0] = trade.timestamp;
            slots[3] = fair;

            if (spot == 0 || fair == 0) {
                bidFee = bpsToWad(45);
                askFee = bpsToWad(45);
            } else {
                // --- Phase 2: competitive asymmetric quote for retail ---
                uint256 gammaBase = WAD - bpsToWad(30);
                uint256 undercut = bpsToWad(3);
                uint256 buffer = bpsToWad(8);

                if (spot > fair) {
                    // Protect bid side against sells/arbs; make asks competitive to attract buys.
                    uint256 gammaReq = wdiv(fair, spot);
                    uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                    bidFee = clampFee(req + buffer);

                    uint256 gammaMatch = wdiv(wmul(spot, gammaBase), fair);
                    askFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                    askFee = askFee > undercut ? (askFee - undercut) : 0;
                } else {
                    // Protect ask side against buys/arbs; make bids competitive to attract sells.
                    uint256 gammaReq = wdiv(spot, fair);
                    uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                    askFee = clampFee(req + buffer);

                    uint256 gammaMatch = wdiv(wmul(fair, gammaBase), spot);
                    bidFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                    bidFee = bidFee > undercut ? (bidFee - undercut) : 0;
                }
            }
        } else {
            // --- Phase 3: post-retail protection for next step's arb (symmetric) ---
            if (spot == 0 || fair == 0) {
                bidFee = bpsToWad(60);
                askFee = bpsToWad(60);
            } else {
                // Protect fee scales with current mispricing to avoid getting picked off next step.
                uint256 misCap = WAD / 50; // 2%
                uint256 mis = wdiv(absDiff(spot, fair), fair);
                if (mis > misCap) mis = misCap;

                uint256 baseProtect = bpsToWad(45);
                uint256 maxExtra = bpsToWad(120);
                uint256 extra = misCap == 0 ? 0 : wmul(maxExtra, wdiv(mis, misCap));

                uint256 protect = baseProtect + extra;
                bidFee = clampFee(protect);
                askFee = clampFee(protect);
            }
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function getName() external pure override returns (string memory) {
        return "ArbPulseTwoPhase";
    }
}

