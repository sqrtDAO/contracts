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

        if (_epochNumber == 0) return config.initialAmount;
        if (config.numerator == 0) return 0;
        if (config.numerator == config.denominator) return config.initialAmount;

        reward = config.initialAmount;
        uint256 num = config.numerator;
        uint256 den = config.denominator;
        uint256 exp = _epochNumber;

        // For exponential decay (numerator < denominator)
        if (num < den) {
            while (exp > 0 && reward > 0) {
                if (exp & 1 == 1) {
                    reward = (reward * num) / den;
                }

                exp >>= 1;
                if (exp > 0) {
                    // Scale before squaring to prevent overflow
                    uint256 scale = 1e18;
                    // Convert to scaled representation: num/den becomes num*scale/den
                    uint256 scaledNum = (num * scale) / den;
                    uint256 scaledDen = scale;

                    // Now square in the scaled space
                    num = (scaledNum * scaledNum) / scale;
                    den = (scaledDen * scaledDen) / scale;
                }
            }
        } else {
            // For growth (numerator > denominator)
            while (exp > 0) {
                if (exp & 1 == 1) {
                    reward = (reward * num) / den;
                }

                exp >>= 1;
                if (exp > 0) {
                    // Scale before squaring
                    uint256 scale = 1e18;
                    uint256 scaledNum = (num * scale) / den;
                    uint256 scaledDen = scale;

                    num = (scaledNum * scaledNum) / scale;
                    den = (scaledDen * scaledDen) / scale;
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
