// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Fair-price inference from arb + fee set to keep spot inside inferred no-arb band.
/// @dev Protect-side fee is computed from `spot` vs `fair` so that, if fair is correct,
///      the pool sits exactly at (or inside) the no-arb boundary next step.
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
        slots[0] = 0;
        slots[3] = p0;

        // Start a bit wide until we get a fair anchor.
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

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        uint256 fair = slots[3];

        // Update fair once per step from the first observed trade (arb gives exact anchor).
        if (trade.timestamp != lastTs) {
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate;
            if (gamma == 0 || spot == 0) {
                fairCandidate = fair;
            } else if (trade.isBuy) {
                // AMM bought X => post spot = fair/gamma
                fairCandidate = wmul(spot, gamma);
            } else {
                // AMM sold X => post spot = gamma*fair
                fairCandidate = wdiv(spot, gamma);
            }

            // Clamp candidate jumps; retail can be first-trade when no arb.
            uint256 maxJump = 500 * BPS; // 5.0%
            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                if (rel > maxJump) {
                    uint256 delta = wmul(fair, maxJump);
                    fairCandidate = fairCandidate > fair ? fair + delta : fair - delta;
                }
            }

            // EWMA (old 80% / new 20%)
            fair = (fair * 80 + fairCandidate * 20) / 100;
            slots[0] = trade.timestamp;
            slots[3] = fair;
        }

        // If we can't form a price, just quote a moderate symmetric fee.
        if (spot == 0 || fair == 0) {
            bidFee = bpsToWad(50);
            askFee = bpsToWad(50);
            slots[1] = bidFee;
            slots[2] = askFee;
            return (bidFee, askFee);
        }

        bool spotAbove = spot > fair;

        // Discounted (competitive) side.
        uint256 base = bpsToWad(10);
        uint256 minComp = bpsToWad(5);

        // Protect-side fee computed from no-arb condition:
        // - If spot > fair, need bidFee >= 1 - fair/spot  (so spot <= fair/gammaBid)
        // - If spot < fair, need askFee >= 1 - spot/fair  (so spot >= fair*gammaAsk)
        uint256 buffer = bpsToWad(8); // safety vs fair estimation error

        if (spotAbove) {
            uint256 gammaReq = wdiv(fair, spot); // < 1
            uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
            bidFee = clampFee(req + buffer);

            // To attract buys despite high spot, cut ask fee (but keep a floor).
            askFee = base;
            if (askFee < minComp) askFee = minComp;
        } else {
            uint256 gammaReq = wdiv(spot, fair); // < 1
            uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
            askFee = clampFee(req + buffer);

            // To attract sells despite low spot, cut bid fee (but keep a floor).
            bidFee = base;
            if (bidFee < minComp) bidFee = minComp;
        }

        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function getName() external pure override returns (string memory) {
        return "ArbBandProtect";
    }
}
