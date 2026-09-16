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

    /// @notice sum of max(0, base + slope * x) for x in [0, _numEpochs) using arithmetic series formula (exact, O(1))
    function calculateTotal(bytes calldata _curveConfig, uint256 _numEpochs) external pure returns (uint256 total) {
        if (_numEpochs == 0) return 0;

        LinearEmissionConfig memory config = abi.decode(_curveConfig, (LinearEmissionConfig));

        if (config.slope >= 0) {
            // all rewards are non negative: sum = N * base + slope * N * (N - 1) / 2
            // forge-lint: disable-next-line(unsafe-typecast) slope is checked to be non negative
            return _numEpochs * config.base + uint256(config.slope) * _triangle(_numEpochs);
        }

        // negative slope: reward is positive while base - s * x > 0, so only first k epochs give anything
        // k = min(_numEpochs, ceil(base / s)) where s = -slope
        uint256 s = uint256(-config.slope);
        uint256 positiveEpochs = config.base == 0 ? 0 : (config.base - 1) / s + 1;
        uint256 k = positiveEpochs < _numEpochs ? positiveEpochs : _numEpochs;

        // sum = k * base - s * k * (k - 1) / 2 (every summed term is >= 1 so the result can not be negative)
        return k * config.base - s * _triangle(k);
    }

    /// @notice k * (k - 1) / 2 without intermediate overflow
    function _triangle(uint256 k) private pure returns (uint256) {
        if (k < 2) return 0;
        // one of k, k-1 is even so dividing the even one first is exact
        return k % 2 == 0 ? (k / 2) * (k - 1) : k * ((k - 1) / 2);
    }
}

struct LinearEmissionConfig {
    uint256 base;
    int256 slope;
}
