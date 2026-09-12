// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IEmissionFunction} from "src/utils/emission-function/IEmissionFunction.sol";

contract FixedEmission is IEmissionFunction {
    function calculate(bytes calldata _curveConfig, uint256) external pure returns (uint256 reward) {
        FixedEmissionConfig memory config = abi.decode(_curveConfig, (FixedEmissionConfig));
        return config.amount;
    }
}

struct FixedEmissionConfig {
    uint256 amount;
}
