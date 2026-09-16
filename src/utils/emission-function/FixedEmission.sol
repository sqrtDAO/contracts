// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IEmissionFunction} from "src/utils/emission-function/IEmissionFunction.sol";

contract FixedEmission is IEmissionFunction {
    function calculate(bytes calldata _curveConfig, uint256) external pure returns (uint256 reward) {
        FixedEmissionConfig memory config = abi.decode(_curveConfig, (FixedEmissionConfig));
        return config.amount;
    }

    /// @notice every epoch gives the same reward so the sum is just a multiplication (exact, O(1))
    function calculateTotal(bytes calldata _curveConfig, uint256 _numEpochs) external pure returns (uint256 total) {
        if (_numEpochs == 0) return 0;
        FixedEmissionConfig memory config = abi.decode(_curveConfig, (FixedEmissionConfig));
        return config.amount * _numEpochs;
    }
}

struct FixedEmissionConfig {
    uint256 amount;
}
