// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Arb-anchored fair-price inference + inventory-skewed asymmetric fees.
/// @dev Uses only AMMStrategyBase.slots[0..31] for state.
contract Strategy is AMMStrategyBase {
    // Slot layout:
    // 0: lastTimestamp
    // 1: currentBidFee (also the fee used for the next trade)
    // 2: currentAskFee
    // 3: fairPriceEwma (WAD, Y per X)
    // 4: volEwma (WAD, abs return proxy)

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);

        // Initialize EWMA fair price and a small vol prior (~10 bps per step).
        slots[0] = 0;
        slots[3] = p0;
        slots[4] = bpsToWad(10);

        // Start moderately wide; asymmetry will handle inventory.
        (bidFee, askFee) = _computeFees(p0, p0, slots[4]);
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
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx); // Y per X (WAD)

        uint256 fair = slots[3];
        uint256 vol = slots[4];

        // Update fair/vol once per step, using the first observed trade as an anchor.
        if (trade.timestamp != lastTs) {
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);

            // Arb-implied fair: if AMM bought X => spot = fair/gamma; else spot = gamma*fair.
            uint256 fairCandidate;
            if (gamma == 0 || spot == 0) {
                fairCandidate = fair;
            } else if (trade.isBuy) {
                fairCandidate = wmul(spot, gamma);
            } else {
                fairCandidate = wdiv(spot, gamma);
            }

            // Robustify against retail-as-first-trade: clamp per-step fair jumps to ±0.50%.
            uint256 maxJump = WAD / 200; // 0.5%
            if (fair != 0) {
                uint256 diff = absDiff(fairCandidate, fair);
                uint256 rel = wdiv(diff, fair);
                if (rel > maxJump) {
                    if (fairCandidate > fair) {
                        fairCandidate = fair + wmul(fair, maxJump);
                    } else {
                        fairCandidate = fair - wmul(fair, maxJump);
                    }
                }
            }

            // EWMA update (alpha = 0.35) for fair.
            // fair = 0.65*fair + 0.35*fairCandidate
            fair = (fair * 65 + fairCandidate * 35) / 100;

            // Vol proxy = |Δfair| / fair (EWMA beta = 0.25), floor at 1 bp to avoid zeroing.
            if (fair != 0) {
                uint256 ret = wdiv(absDiff(fairCandidate, fair), fair);
                vol = (vol * 75 + ret * 25) / 100;
                uint256 volFloor = bpsToWad(1);
                if (vol < volFloor) vol = volFloor;
            }

            slots[0] = trade.timestamp;
            slots[3] = fair;
            slots[4] = vol;
        }

        (bidFee, askFee) = _computeFees(spot, fair, vol);
        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);

        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function _computeFees(uint256 spot, uint256 fair, uint256 vol)
        internal
        pure
        returns (uint256 bidFee, uint256 askFee)
    {
        // Base fee tracks volatility with a floor.
        // base = 40 bps + 4 * vol
        uint256 base = bpsToWad(40) + vol * 4;

        // Inventory skew proxy: |spot - fair| / fair, capped at 1%.
        uint256 skewCap = WAD / 100; // 1%
        uint256 skew = 0;
        bool spotAbove = false;
        if (fair != 0 && spot != 0) {
            if (spot > fair) {
                spotAbove = true;
                skew = wdiv(spot - fair, fair);
            } else {
                skew = wdiv(fair - spot, fair);
            }
            if (skew > skewCap) skew = skewCap;
        }

        // Asymmetry scale: up to 50 bps at max skew.
        uint256 maxAdj = bpsToWad(50);
        uint256 adj = skewCap == 0 ? 0 : wmul(maxAdj, wdiv(skew, skewCap));

        if (spotAbove) {
            // Spot > fair: make AMM-buy-X cheap (bidFee↓), AMM-sell-X expensive (askFee↑)
            bidFee = base > adj ? base - adj : 0;
            askFee = base + adj;
        } else {
            // Spot < fair: make AMM-sell-X cheap (askFee↓), AMM-buy-X expensive (bidFee↑)
            bidFee = base + adj;
            askFee = base > adj ? base - adj : 0;
        }
    }

    function getName() external pure override returns (string memory) {
        return "ArbInferredSkew";
    }
}

