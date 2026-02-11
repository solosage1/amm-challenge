// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Arb-implied fair inference with gap-aware smoothing and band-protect quoting.
/// @dev Key tweak vs typical arb-oracle strategies: when we haven't been traded for many steps,
///      we increase the fair update weight (and allow larger jumps) to reduce lag.
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

        // Ensure first observed trade is treated as a new step (t=0 has a price move + possible arb).
        slots[0] = type(uint256).max;
        slots[3] = p0;

        // Start slightly protective until we get a clean anchor.
        bidFee = bpsToWad(35);
        askFee = bpsToWad(35);
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

        if (trade.timestamp != lastTs) {
            // Gap since last trade we observed (can be >1 if we were not routed any flow).
            uint256 dt = lastTs == type(uint256).max ? 1 : (trade.timestamp - lastTs);
            if (dt > 25) dt = 25; // cap: we only need coarse responsiveness

            // Arb-implied fair anchor from first observed trade of the step.
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate = fair;
            if (gamma != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            // Allow larger fair jumps after long gaps; keep conservative for dt=1.
            // maxJumpBps = 250 + 25*dt  (e.g., dt=1 => 275 bps; dt=25 => 875 bps capped by clampFee elsewhere)
            uint256 maxJump = (250 + 25 * dt) * BPS;
            if (maxJump > 900 * BPS) maxJump = 900 * BPS;

            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                if (rel > maxJump) {
                    uint256 delta = wmul(fair, maxJump);
                    fairCandidate = fairCandidate > fair ? fair + delta : fair - delta;
                }
            }

            // Gap-aware EWMA: alphaPct = 20 + 2*dt  (dt=1 => 22%, dt=25 => 70%)
            uint256 alphaPct = 20 + 2 * dt;
            if (alphaPct > 70) alphaPct = 70;
            fair = (fair * (100 - alphaPct) + fairCandidate * alphaPct) / 100;

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

        // Signed mispricing proxy.
        uint256 mis = wdiv(absDiff(spot, fair), fair);

        // Tight regime: stay close to the normalizer to keep routed volume, but don't undercut aggressively.
        uint256 tightBand = 20 * BPS;
        if (mis <= tightBand) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
        } else {
            // Off-fair: adverse side gets band-protect fee; favorable side matches baseline marginal quote.
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 buffer = bpsToWad(4);

            if (spot > fair) {
                // Protect bid side: prevent profitable sell-X arb / toxic sells to us.
                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer);

                // Favorable side (asks): match baseline gross ask price assuming baseline spot ~ fair.
                uint256 gammaMatch = wdiv(wmul(spot, gammaBase), fair);
                askFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
            } else {
                // Protect ask side: prevent profitable buy-X arb / toxic buys from us.
                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer);

                // Favorable side (bids): match baseline gross bid price assuming baseline spot ~ fair.
                uint256 gammaMatch = wdiv(wmul(fair, gammaBase), spot);
                bidFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
            }
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function getName() external pure override returns (string memory) {
        return "ArbOracleGapAwareDualRegime";
    }
}

