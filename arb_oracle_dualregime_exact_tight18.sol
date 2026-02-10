// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Variant of ArbOracleDualRegimeExact with a more aggressive tight-regime fee.
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

        if (trade.timestamp != lastTs) {
            uint256 feeUsed = trade.isBuy ? prevBid : prevAsk;
            uint256 gamma = feeUsed >= WAD ? 0 : (WAD - feeUsed);

            // Reconstruct pre-trade reserves.
            uint256 preX;
            uint256 preY;
            if (trade.isBuy) {
                preX = rx >= wmul(trade.amountX, gamma) ? (rx - wmul(trade.amountX, gamma)) : 0;
                preY = ry + trade.amountY;
            } else {
                preX = rx + trade.amountX;
                uint256 netY = wmul(trade.amountY, gamma);
                preY = ry >= netY ? (ry - netY) : 0;
            }

            uint256 fairCandidate = fair;
            if (gamma != 0 && preX != 0 && preY != 0) {
                uint256 k = wmul(preX, preY); // WAD-scaled

                if (trade.isBuy) {
                    // AMM buys X: postX = preX + gamma*amountX
                    uint256 xVirtual = preX + wmul(trade.amountX, gamma);
                    if (xVirtual != 0) {
                        fairCandidate = wdiv(wmul(k, gamma), wmul(xVirtual, xVirtual));
                    }
                } else {
                    // AMM sells X: postX = rx
                    if (rx != 0) {
                        fairCandidate = wdiv(k, wmul(gamma, wmul(rx, rx)));
                    }
                }
            }

            // Clamp candidate jumps (retail can be first-trade when no arb).
            uint256 maxJump = 400 * BPS;
            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                if (rel > maxJump) {
                    uint256 delta = wmul(fair, maxJump);
                    fairCandidate = fairCandidate > fair ? fair + delta : fair - delta;
                }
            }

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
        uint256 tightBand = bpsToWad(15);

        if (mis <= tightBand) {
            // More aggressive than baseline: 18 bps.
            uint256 tightFee = bpsToWad(18);
            bidFee = tightFee;
            askFee = tightFee;
        } else {
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 undercut = bpsToWad(2);
            uint256 buffer = bpsToWad(10);

            if (spot > fair) {
                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer);

                uint256 gammaMatch = wdiv(wmul(spot, gammaBase), fair);
                askFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                askFee = askFee > undercut ? (askFee - undercut) : 0;
            } else {
                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer);

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
        return "ArbOracleDualRegimeExact_Tight18";
    }
}

