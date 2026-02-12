// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    uint256 constant TAIL_KNEE = 180 * BPS;
    uint256 constant TAIL_TRANSITION = 40 * BPS;
    uint256 constant TAIL_SLOPE_PROTECT = 940000000000000000;
    uint256 constant TAIL_SLOPE_ATTRACT = 780000000000000000;
    uint256 constant TAIL_MAX_EFFECTIVE_PROTECT = 820 * BPS;
    uint256 constant TAIL_MAX_EFFECTIVE_ATTRACT = 500 * BPS;

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);
        slots[0] = type(uint256).max;
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
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate = fair;
            if (gamma != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

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
        uint256 tightBand = bpsToWad(25);

        bool protectBid;

        if (mis <= tightBand) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
            protectBid = false;
        } else {
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 gammaBaseSq = wmul(gammaBase, gammaBase);
            uint256 buffer = bpsToWad(4);

            if (spot > fair) {
                protectBid = true;
                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer);

                uint256 gammaMatch = wdiv(wmul(spot, gammaBaseSq), fair);
                askFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
            } else {
                protectBid = false;
                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer);

                uint256 gammaMatch = wdiv(wmul(fair, gammaBaseSq), spot);
                bidFee = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
            }

            (bidFee, askFee) = _compressTailPair(bidFee, askFee, protectBid);
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

        if (transition == 0) {
            uint256 hardCompressed = _compressTailCore(fee, knee, slope);
            return hardCompressed > capFee ? capFee : hardCompressed;
        }

        uint256 low = knee > transition ? knee - transition : 0;
        if (fee <= low) return fee;

        uint256 coreCompressed = _compressTailCore(fee, knee, slope);
        uint256 high = knee + transition;

        if (fee >= high) {
            return coreCompressed > capFee ? capFee : coreCompressed;
        }

        uint256 blend = wdiv(fee - low, high - low);
        uint256 blended = wmul(fee, WAD - blend) + wmul(coreCompressed, blend);
        return blended > capFee ? capFee : blended;
    }

    function _compressTailCore(uint256 fee, uint256 knee, uint256 slope) internal pure returns (uint256) {
        if (fee <= knee) return fee;
        return knee + wmul(fee - knee, slope);
    }

    function getName() external pure override returns (string memory) {
        return "tmp";
    }
}
