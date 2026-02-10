// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Arb-implied fair inference + within-step pulse:
///         - First trade of step: update fair, quote competitive/asymmetric for retail.
///         - Any later trade same step (retail): switch to symmetric protective lock for next-step arb.
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

        // Start in protective lock so first-step arb is expensive.
        bidFee = bpsToWad(80);
        askFee = bpsToWad(80);
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
            // Update fair from first observed trade of the step.
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate = fair;
            if (gamma != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            // Clamp jump (retail can be first-trade when no arb occurs).
            uint256 maxJump = 300 * BPS; // 3%
            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                if (rel > maxJump) {
                    uint256 delta = wmul(fair, maxJump);
                    fairCandidate = fairCandidate > fair ? fair + delta : fair - delta;
                }
            }

            // Moderately fast EWMA: favor arb anchors but limit retail noise.
            fair = (fair * 70 + fairCandidate * 30) / 100;
            slots[0] = trade.timestamp;
            slots[3] = fair;

            // --- Retail quote (dual regime) ---
            if (spot == 0 || fair == 0) {
                bidFee = bpsToWad(30);
                askFee = bpsToWad(30);
            } else {
                uint256 mis = wdiv(absDiff(spot, fair), fair);
                uint256 tightBand = bpsToWad(25); // wider "tight" regime

                if (mis <= tightBand) {
                    // Aggressively competitive near fair.
                    uint256 tightFee = bpsToWad(18);
                    bidFee = tightFee;
                    askFee = tightFee;
                } else {
                    // Off-fair: asymmetric protect + competitive side undercut.
                    uint256 gammaBase = WAD - bpsToWad(30);
                    uint256 undercut = bpsToWad(4);
                    uint256 buffer = bpsToWad(8);

                    if (spot > fair) {
                        // Protect bid side.
                        uint256 gammaReq = wdiv(fair, spot);
                        uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                        bidFee = clampFee(req + buffer);

                        // Competitive ask side roughly matches baseline marginal quote.
                        uint256 gammaMatch = wdiv(wmul(spot, gammaBase), fair);
                        askFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                        askFee = askFee > undercut ? (askFee - undercut) : 0;
                    } else {
                        // Protect ask side.
                        uint256 gammaReq = wdiv(spot, fair);
                        uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                        askFee = clampFee(req + buffer);

                        // Competitive bid side roughly matches baseline marginal quote.
                        uint256 gammaMatch = wdiv(wmul(fair, gammaBase), spot);
                        bidFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                        bidFee = bidFee > undercut ? (bidFee - undercut) : 0;
                    }
                }
            }
        } else {
            // Same-step retail already hit us: lock in protection for next-step arb.
            // Scale lock fee with mispricing to avoid big next-step arb losses.
            if (spot == 0 || fair == 0) {
                bidFee = bpsToWad(80);
                askFee = bpsToWad(80);
            } else {
                uint256 misCap = WAD / 50; // 2%
                uint256 mis = wdiv(absDiff(spot, fair), fair);
                if (mis > misCap) mis = misCap;

                uint256 baseLock = bpsToWad(70);
                uint256 maxExtra = bpsToWad(120);
                uint256 extra = misCap == 0 ? 0 : wmul(maxExtra, wdiv(mis, misCap));
                uint256 lockFee = baseLock + extra;

                bidFee = clampFee(lockFee);
                askFee = clampFee(lockFee);
            }
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function getName() external pure override returns (string memory) {
        return "DualRegimePulseCandidate";
    }
}

