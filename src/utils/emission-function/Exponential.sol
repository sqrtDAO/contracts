// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {
    IEmissionFunction
} from "src/utils/emission-function/IEmissionFunction.sol";

/// f(x) = a * b^x
/// where a is initial value and b is curve factor
/// if b > 1 its a exponential growth
/// if 1 > b > 0 its a exponential decay
contract ExponentialEmissionFunction is IEmissionFunction {
    function calculate(
        bytes calldata _curveConfig,
        uint256 _epochNumber
    ) external pure returns (uint256 reward) {
        ExponentialEmissionConfig memory config = abi.decode(
            _curveConfig,
            (ExponentialEmissionConfig)
        );

        // main formula:
        //  reward = initialAmount * (numerator/denominator)^epoch
        //
        // problem:
        //  we need to use integer math - no floating point!
        //  numerator/denominator can goes 0 or 1 (its integer)
        //
        // solution: power of a Quotient Rule:
        //  (A / B)^x == A^x / B^x

        uint256 factor = config.numerator ** _epochNumber;
        uint256 divisor = config.denominator ** _epochNumber;
        return (config.initialAmount * factor) / divisor;
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
