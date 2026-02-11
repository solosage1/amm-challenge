// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Dual-regime band-matching with **confidence-gated exact arb inversion**.
///         Key idea: reconstruct *pre-trade reserves* accounting for fee buckets, then invert the
///         simulator's closed-form arb sizing to infer fair price exactly on true arb trades.
///         Use dt-scaled jump clamps + volatility EWMA to avoid retail-first noise and keep routing.
contract Strategy is AMMStrategyBase {
    // slots:
    // 0 lastTimestamp
    // 1 currentBidFee
    // 2 currentAskFee
    // 3 fairPrice (WAD, Y per X)
    // 4 volEwma (WAD fraction, approx abs return)

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);

        // Treat first observed trade as new step.
        slots[0] = type(uint256).max;
        slots[3] = p0;
        slots[4] = 0;

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

        uint256 fair = slots[3];
        uint256 vol = slots[4];
        uint256 oldFair = fair;

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        bool newStep = trade.timestamp != lastTs;
        uint256 dt = 1;
        if (lastTs != type(uint256).max && trade.timestamp > lastTs) {
            dt = trade.timestamp - lastTs;
        }

        bool arbLikely = false;
        bool capHit = false;

        if (newStep) {
            // Fee used for this trade (fee-on-input).
            uint256 feeUsed = trade.isBuy ? prevBid : prevAsk;
            uint256 gamma = feeUsed >= WAD ? 0 : (WAD - feeUsed);

            // Reconstruct pre-trade reserves accounting for fee buckets.
            uint256 preX;
            uint256 preY;
            if (trade.isBuy) {
                // AMM bought X: input is X (gross = amountX, net = gamma*amountX), output is Y (= amountY).
                uint256 netX = wmul(trade.amountX, gamma);
                preX = rx >= netX ? (rx - netX) : 0;
                preY = ry + trade.amountY;
            } else {
                // AMM sold X: input is Y (gross = amountY, net = gamma*amountY), output is X (= amountX).
                uint256 netY = wmul(trade.amountY, gamma);
                preX = rx + trade.amountX;
                preY = ry >= netY ? (ry - netY) : 0;
            }

            // Detect buy-arb cap (99% of X reserves) which makes inversion biased.
            if (!trade.isBuy && preX != 0) {
                uint256 cap = (preX * 99) / 100;
                if (trade.amountX >= cap) capHit = true;
            }

            uint256 k = 0;
            if (gamma != 0 && preX != 0 && preY != 0) {
                k = wmul(preX, preY);
            }

            // Predict arb sizing using previous fair (classification gate).
            if (!capHit && gamma != 0 && k != 0 && oldFair != 0 && preX != 0) {
                uint256 preSpot = wdiv(preY, preX);

                // Helper: sqrt on WAD-scaled values.
                // sqrtWad(xWad) = sqrt(xWad * WAD), returning WAD-scaled sqrt(x).
                if (preSpot > oldFair) {
                    // Expected sell-arb (AMM buys X).
                    uint256 ratio = wdiv(wmul(k, gamma), oldFair); // k*gamma/fair
                    uint256 xVirtualOpt = sqrt(ratio * WAD);
                    if (xVirtualOpt > preX) {
                        uint256 netX = xVirtualOpt - preX;
                        uint256 dxIn = wdiv(netX, gamma); // gross input
                        if (trade.isBuy && dxIn != 0) {
                            uint256 err = wdiv(absDiff(trade.amountX, dxIn), dxIn);
                            if (err <= (WAD * 25) / 100) arbLikely = true; // 25% tolerance
                        }
                    }
                } else if (preSpot < oldFair) {
                    // Expected buy-arb (AMM sells X).
                    uint256 denom = wmul(gamma, oldFair);
                    if (denom != 0) {
                        uint256 ratio = wdiv(k, denom); // k/(gamma*fair)
                        uint256 newXOpt = sqrt(ratio * WAD);
                        if (preX > newXOpt) {
                            uint256 dxOut = preX - newXOpt;
                            uint256 cap = (preX * 99) / 100;
                            if (dxOut > cap) dxOut = cap;
                            if (!trade.isBuy && dxOut != 0) {
                                uint256 err = wdiv(absDiff(trade.amountX, dxOut), dxOut);
                                if (err <= (WAD * 25) / 100) arbLikely = true; // 25% tolerance
                            }
                        }
                    }
                }
            }

            // Fair update: treat arb-like first-trades as fee-adjusted boundary anchors.
            // For retail-like first-trades, use raw post-trade spot as a noisy fair proxy
            // (gamma-adjustment is not valid for retail trades).
            uint256 fairCandidate = oldFair;
            if (spot != 0) {
                if (!capHit && arbLikely && gamma != 0) {
                    fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
                } else {
                    fairCandidate = spot;
                }
            }

            // Clamp fair jumps (retail-first can be very noisy).
            if (oldFair != 0 && fairCandidate != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, oldFair), oldFair);
                uint256 maxJump = 400 * BPS; // 4%
                if (rel > maxJump) {
                    uint256 delta = wmul(oldFair, maxJump);
                    fairCandidate = fairCandidate > oldFair ? (oldFair + delta) : (oldFair - delta);
                }
            }

            // Confidence-gated update: faster on arb anchors, slower otherwise.
            uint256 alphaNewPct = arbLikely ? 25 : 10; // percent weight on new candidate
            if (capHit) alphaNewPct = 0;

            fair = (oldFair * (100 - alphaNewPct) + fairCandidate * alphaNewPct) / 100;

            // Update volatility EWMA from fair moves.
            if (oldFair != 0) {
                uint256 ret = wdiv(absDiff(fair, oldFair), oldFair);
                vol = (vol * 90 + ret * 10) / 100;
            }

            slots[0] = trade.timestamp;
            slots[3] = fair;
            slots[4] = vol;
        }

        if (spot == 0 || fair == 0) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
            slots[1] = bidFee;
            slots[2] = askFee;
            return (bidFee, askFee);
        }

        // Dual-regime quoting parameters (intentionally simple; let fair inference do the work).
        // These mirror the best-known dual-regime family, but with improved fair inference above.
        uint256 tightBandBps = 15;
        uint256 tightFeeBps = 25;
        uint256 undercutBps = 2;
        uint256 bufferBps = 10;

        uint256 mis = wdiv(absDiff(spot, fair), fair);
        uint256 tightBand = bpsToWad(tightBandBps);

        if (mis <= tightBand) {
            uint256 f = bpsToWad(tightFeeBps);
            bidFee = f;
            askFee = f;
        } else {
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 undercut = bpsToWad(undercutBps);
            uint256 buffer = bpsToWad(bufferBps);

            if (spot > fair) {
                // Spot > fair: protect bid side (arb would sell X to us).
                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer);

                // Competitive ask side: match baseline marginal and undercut.
                uint256 gammaMatch = wdiv(wmul(spot, gammaBase), fair);
                askFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                askFee = askFee > undercut ? (askFee - undercut) : 0;
            } else {
                // Spot < fair: protect ask side (arb would buy X from us).
                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer);

                // Competitive bid side: match baseline marginal and undercut.
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
        return "ArbOracleAdaptiveConfidence";
    }
}
