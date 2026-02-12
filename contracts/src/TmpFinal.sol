// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @notice Dual-regime arb-oracle with gamma^2 competitor anchoring on the competitive side.
contract Strategy is AMMStrategyBase {
    // ITERATION_POLICY {"decision":"ceiling_reached","confidence":0.71,"ceiling_probability":0.62,"ev_next_5":0.25,"best_delta_seen":1.99,"reason":"Tuned tail knee/transition and removed protect cap bind; +~1.9 edge on 1000-sim screen with diminishing returns expected.","next_mechanism":null}

    uint256 constant TAIL_KNEE = 50 * BPS;
    uint256 constant TAIL_TRANSITION = 60 * BPS;
    uint256 constant TAIL_SLOPE_PROTECT = 945000000000000000; // 0.945
    uint256 constant TAIL_SLOPE_ATTRACT = 800000000000000000; // 0.80
    uint256 constant TAIL_MAX_EFFECTIVE_PROTECT = 1000 * BPS;
    uint256 constant TAIL_MAX_EFFECTIVE_ATTRACT = 520 * BPS;

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

        // Slightly competitive start to get early retail flow / anchors.
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

        // Update fair once per step from first observed trade (arb anchor when present).
        if (trade.timestamp != lastTs) {
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate = fair;
            if (gamma != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            // Robust jump clamp (retail can be first-trade when no arb hits us).
            uint256 maxJump = 400 * BPS; // 4%
            if (fair != 0) {
                uint256 rel = wdiv(absDiff(fairCandidate, fair), fair);
                if (rel > maxJump) {
                    uint256 delta = wmul(fair, maxJump);
                    fairCandidate = fairCandidate > fair ? fair + delta : fair - delta;
                }
            }

            // EWMA (old 80% / new 20%).
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

        if (mis <= tightBand) {
            // Near fair: match the normalizer so we don't pay unnecessary fee undercuts.
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
        } else {
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 gammaBaseSq = wmul(gammaBase, gammaBase);
            uint256 buffer = bpsToWad(4);

            if (spot > fair) {
                // Spot > fair: protect bid side (arb would sell X to us).
                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer);

                // Competitive ask side: match normalizer's weak ask quote (~p/gamma^2).
                uint256 gammaMatch = wdiv(wmul(spot, gammaBaseSq), fair);
                askFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);

                (bidFee, askFee) = _compressTailPair(bidFee, askFee, true);
            } else {
                // Spot < fair: protect ask side (arb would buy X from us).
                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer);

                // Competitive bid side: match normalizer's weak bid quote (~gamma^2*p).
                uint256 gammaMatch = wdiv(wmul(fair, gammaBaseSq), spot);
                bidFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);

                (bidFee, askFee) = _compressTailPair(bidFee, askFee, false);
            }
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function _compressTailPair(uint256 bidFee, uint256 askFee, bool protectBid)
        internal
        pure
        returns (uint256, uint256)
    {
        if (protectBid) {
            bidFee = _compressTail(bidFee, TAIL_SLOPE_PROTECT, TAIL_MAX_EFFECTIVE_PROTECT);
            askFee = _compressTail(askFee, TAIL_SLOPE_ATTRACT, TAIL_MAX_EFFECTIVE_ATTRACT);
        } else {
            askFee = _compressTail(askFee, TAIL_SLOPE_PROTECT, TAIL_MAX_EFFECTIVE_PROTECT);
            bidFee = _compressTail(bidFee, TAIL_SLOPE_ATTRACT, TAIL_MAX_EFFECTIVE_ATTRACT);
        }
        return (bidFee, askFee);
    }

    function _compressTail(uint256 fee, uint256 slope, uint256 capFee) internal pure returns (uint256) {
        uint256 knee = TAIL_KNEE;
        uint256 transition = TAIL_TRANSITION;

        if (fee <= knee) return fee;

        if (transition == 0) {
            uint256 hardCompressed = _compressTailCore(fee, knee, slope);
            return hardCompressed > capFee ? capFee : hardCompressed;
        }

        uint256 coreCompressed = _compressTailCore(fee, knee, slope);
        uint256 high = knee + transition;

        if (fee >= high) {
            return coreCompressed > capFee ? capFee : coreCompressed;
        }

        uint256 blend = wdiv(fee - knee, transition);
        uint256 blended = wmul(fee, WAD - blend) + wmul(coreCompressed, blend);
        return blended > capFee ? capFee : blended;
    }

    function _compressTailCore(uint256 fee, uint256 knee, uint256 slope) internal pure returns (uint256) {
        if (fee <= knee) return fee;
        return knee + wmul(fee - knee, slope);
    }

    function getName() external pure override returns (string memory) {
        return "tail_compression_mod_v3";
    }
}
