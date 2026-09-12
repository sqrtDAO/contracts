// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IEmissionFunction} from "src/utils/emission-function/IEmissionFunction.sol";

contract LinearEmission is IEmissionFunction {
    function calculate(bytes calldata _curveConfig, uint256 _epochNumber) external pure returns (uint256 reward) {
        LinearEmissionConfig memory config = abi.decode(_curveConfig, (LinearEmissionConfig));

        // forge-lint: disable-next-line(unsafe-typecast) epoch numbers are not that big!
        int256 iReward = int256(config.base) + (config.slope * int256(_epochNumber));

        if (iReward < 0) return 0;

        // forge-lint: disable-next-line(unsafe-typecast) I already checked if iReward is positive
        return uint256(iReward);
    }
}

struct LinearEmissionConfig {
    uint256 base;
    int256 slope;
}
