// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IEmissionFunction} from "src/utils/emission-function/IEmissionFunction.sol";

/// f(x) = a * b^x
/// where a is initial value and b is curve factor
/// if b > 1 its a exponential growth
/// if 1 > b > 0 its a exponential decay
contract ExponentialEmission is IEmissionFunction {
    function calculate(bytes calldata _curveConfig, uint256 _epochNumber) external pure returns (uint256 reward) {
        ExponentialEmissionConfig memory config = abi.decode(_curveConfig, (ExponentialEmissionConfig));

        // Handle edge cases
        if (_epochNumber == 0) {
            return config.initialAmount;
        }

        if (config.numerator == 0) {
            return 0;
        }

        if (config.numerator >= config.denominator) {
            // If numerator >= denominator, the reward would increase or stay same
            // But still need to handle potential overflow
            if (config.numerator == config.denominator) {
                return config.initialAmount;
            }
        }

        // Start with initialAmount
        reward = config.initialAmount;

        // We need to compute (numerator/denominator)^epoch
        // Using exponentiation by squaring: keep track of the current base (num/denom)^(2^k)
        uint256 baseNumerator = config.numerator;
        uint256 baseDenominator = config.denominator;
        uint256 exponent = _epochNumber;

        while (exponent > 0) {
            // If current bit is 1, multiply reward by current base (baseNumerator/baseDenominator)
            if (exponent & 1 == 1) {
                reward = (reward * baseNumerator) / baseDenominator;
            }

            // Square the base for the next bit: (num/denom)^(2^(k+1))
            // This means: newNum = oldNum^2, newDen = oldDen^2
            exponent >>= 1;
            if (exponent > 0) {
                baseNumerator *= baseNumerator;
                baseDenominator *= baseDenominator;
                while (baseNumerator > (1 << 20)) {
                    baseNumerator >>= 1;
                    baseDenominator >>= 1;
                }
            }
        }

        return reward;
    }
}

/// curve factor = numerator / denominator
/// example:
///  1005 and 1000 means 1.005
struct ExponentialEmissionConfig {
    uint256 initialAmount;
    uint256 numerator; // e.g., 101 for 1% growth
    uint256 denominator; // e.g., 100
}
