// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    function afterInitialize(uint256, uint256) external pure override returns (uint256 bidFee, uint256 askFee) {
        bidFee = 0;
        askFee = 0;
    }

    function afterSwap(TradeInfo calldata) external pure override returns (uint256 bidFee, uint256 askFee) {
        bidFee = 0;
        askFee = 0;
    }

    function getName() external pure override returns (string memory) {
        return "Const_0bps";
    }
}
